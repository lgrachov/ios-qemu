#!/usr/bin/env python3
"""Symbolicate unslid addresses against a split iOS dyld shared cache.

  dsc-a2s.py CACHE ADDR...            (or addresses on stdin, one per line;
                                       '#' lines are echoed as headings)

CACHE is the main dyld_shared_cache_arm64; its .01.. subcaches and .symbols
file must sit next to it. Prints "addr  image  symbol+offset". Addresses
are unslid (runtime address - slide, the slide from the SMP/CRASH lines).

`ipsw dyld a2s` hangs on this 16.7 cache (parses every symbol first, then
stalls); this reads only the images the addresses fall in: the image list
and every subcache's mappings, each image's LC_SYMTAB through __LINKEDIT,
plus its entries in the .symbols file's local symbol table (static
functions, which the image symtabs leave out).
"""
import bisect, glob, os, struct, sys

LC_SEGMENT_64, LC_SYMTAB = 0x19, 0x2


class Cache:
    def __init__(self, path):
        self.files, self.maps = [], []		# maps: (addr, size, fileoff, file index)
        for p in [path] + sorted(glob.glob(path + '.[0-9]*')):
            fd = open(p, 'rb')
            hdr = fd.read(0x200)
            moff, mcnt = struct.unpack_from('<II', hdr, 0x10)
            fd.seek(moff)
            for i in range(mcnt):
                addr, size, foff = struct.unpack_from('<QQQ', fd.read(32))
                self.maps.append((addr, size, foff, len(self.files)))
            self.files.append(fd)
        self.maps.sort()
        self.starts = [m[0] for m in self.maps]
        main = self.files[0]
        main.seek(0)
        hdr = main.read(0x200)
        self.base = struct.unpack_from('<Q', hdr, 0xe0)[0]
        ioff, icnt = struct.unpack_from('<II', hdr, 0x1c0)
        main.seek(ioff)
        raw = main.read(icnt * 32)
        self.images = []
        for i in range(icnt):
            addr, _, _, poff = struct.unpack_from('<QQQI', raw, i * 32)
            main.seek(poff)
            name = main.read(512).split(b'\0', 1)[0].decode()
            self.images.append((addr, name))
        self.images.sort()
        self.ranges = None
        self.syms = {}
        self.local = None
        self.symbols_path = path + '.symbols'

    def read(self, addr, size):
        i = bisect.bisect_right(self.starts, addr) - 1
        a, s, foff, fi = self.maps[i]
        if not (a <= addr and addr + size <= a + s):
            raise ValueError(f'{addr:#x} not mapped')
        fd = self.files[fi]
        fd.seek(foff + addr - a)
        return fd.read(size)

    def macho(self, addr):
        ncmds, sizeofcmds = struct.unpack_from('<II', self.read(addr, 32), 16)
        cmds = self.read(addr + 32, sizeofcmds)
        segs, symtab, off = {}, None, 0
        for _ in range(ncmds):
            cmd, csize = struct.unpack_from('<II', cmds, off)
            if cmd == LC_SEGMENT_64:
                name = cmds[off + 8:off + 24].split(b'\0', 1)[0].decode()
                vmaddr, vmsize, fileoff = struct.unpack_from('<QQQ', cmds, off + 24)
                segs[name] = (vmaddr, vmsize, fileoff)
            elif cmd == LC_SYMTAB:
                symtab = struct.unpack_from('<IIII', cmds, off + 8)
            off += csize
        return segs, symtab

    def image_for(self, addr):
        if self.ranges is None:		# __TEXT ranges, computed once
            self.ranges = []
            for base, name in self.images:
                segs, _ = self.macho(base)
                t = segs.get('__TEXT')
                if t:
                    self.ranges.append((t[0], t[0] + t[1], base, name))
            self.ranges.sort()
            self.rstarts = [r[0] for r in self.ranges]
        i = bisect.bisect_right(self.rstarts, addr) - 1
        if i >= 0 and self.ranges[i][0] <= addr < self.ranges[i][1]:
            return self.ranges[i][2], self.ranges[i][3]
        return None, None

    def local_symbols(self):
        if self.local is None:
            self.local = {}
            if os.path.exists(self.symbols_path):
                fd = open(self.symbols_path, 'rb')
                hdr = fd.read(0x200)
                lso = struct.unpack_from('<Q', hdr, 0x48)[0]
                fd.seek(lso)
                nlo, nlc, so, ss, eo, ec = struct.unpack_from('<6I', fd.read(24))
                fd.seek(lso + eo)
                ent = fd.read(ec * 16)
                for i in range(ec):
                    dyoff, start, cnt = struct.unpack_from('<QII', ent, i * 16)
                    self.local[self.base + dyoff] = (start, cnt)
                self.local_fd, self.local_geo = fd, (lso + nlo, lso + so, ss)
        return self.local

    def symbols(self, base):
        if base in self.syms:
            return self.syms[base]
        out = []
        segs, symtab = self.macho(base)
        le = segs.get('__LINKEDIT')
        if symtab and le:
            symoff, nsyms, stroff, strsize = symtab
            nl = self.read(le[0] + symoff - le[2], nsyms * 16)
            st = self.read(le[0] + stroff - le[2], strsize)
            out += self._nlist(nl, nsyms, st)
        loc = self.local_symbols().get(base)
        if loc:
            nlbase, strbase, strsize = self.local_geo
            self.local_fd.seek(nlbase + loc[0] * 16)
            nl = self.local_fd.read(loc[1] * 16)
            self.local_fd.seek(strbase)
            st = self.local_fd.read(strsize)
            out += self._nlist(nl, loc[1], st)
        out.sort()
        self.syms[base] = (out, [s[0] for s in out])
        return self.syms[base]

    @staticmethod
    def _nlist(nl, n, st):
        out = []
        for i in range(n):
            strx, ntype, sect, _, value = struct.unpack_from('<IBBHQ', nl, i * 16)
            # N_SECT symbols only, no debug (stab) entries
            if ntype & 0xe0 or (ntype & 0x0e) != 0x0e or not value:
                continue
            name = st[strx:st.index(b'\0', strx)].decode('utf-8', 'replace')
            out.append((value, name))
        return out

    def lookup(self, addr):
        base, image = self.image_for(addr)
        if base is None:
            return '?', '?'
        syms, starts = self.symbols(base)
        i = bisect.bisect_right(starts, addr) - 1
        short = os.path.basename(image)
        if i < 0:
            return short, f'+{addr - base:#x}'
        return short, f'{syms[i][1]}+{addr - syms[i][0]:#x}'


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    c = Cache(sys.argv[1])
    items = sys.argv[2:] or [l.strip() for l in sys.stdin if l.strip()]
    for a in items:
        if a.startswith('#'):
            print(a)
            continue
        addr = int(a, 16)
        image, sym = c.lookup(addr)
        print(f'  {addr:#x}  {image:28} {sym}')


if __name__ == '__main__':
    main()
