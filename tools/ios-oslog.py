#!/usr/bin/env python3
"""Read the iOS guest's unified log (os_log) without Apple's `log` tool.

  ios-oslog.py DIR [--proc NAME[,NAME]] [--grep TEXT] [--files N] [--stats]

DIR holds `diagnostics/` and `uuidtext/` copied from the guest's
/private/var/db (mount the disk image with -o rdonly,noowners). macOS `log show`
opens a hand-built .logarchive of these but decodes nothing (missing archive
metadata), so this walks the tracev3 files itself.

tracev3: a sequence of chunks (u32 tag, u32 subtag, u64 size, data, 8-byte
aligned). 0x1000 header, 0x600b catalog (UUIDs, subsystem strings, processes),
0x600d chunkset = LZ4 block ('bv41') holding 0x6001 firehose chunks (log
entries), 0x6002 oversize, 0x6003 statedump, 0x6004 simpledump.
"""
import argparse, bisect, glob, os, re, struct, sys


def lz4_block(src, size):
    """LZ4 block decompression (no frame); size = expected output size."""
    dst = bytearray()
    i, n = 0, len(src)
    while i < n:
        tok = src[i]
        i += 1
        lit = tok >> 4
        if lit == 15:
            while True:
                b = src[i]
                i += 1
                lit += b
                if b != 255:
                    break
        dst += src[i:i + lit]
        i += lit
        if i >= n:
            break
        off = src[i] | src[i + 1] << 8
        i += 2
        ml = tok & 15
        if ml == 15:
            while True:
                b = src[i]
                i += 1
                ml += b
                if b != 255:
                    break
        ml += 4
        start = len(dst) - off
        if off >= ml:
            dst += dst[start:start + ml]
        else:			# overlapping copy repeats the last `off` bytes
            for k in range(ml):
                dst.append(dst[start + k])
    if len(dst) != size:
        raise ValueError(f'lz4: got {len(dst)} bytes, expected {size}')
    return bytes(dst)


def chunks(data, base=0):
    """(tag, subtag, offset of data, data) for each chunk."""
    off = 0
    while off + 16 <= len(data):
        tag, sub, size = struct.unpack_from('<IIQ', data, off)
        body = data[off + 16:off + 16 + size]
        yield tag, sub, base + off + 16, body
        off += 16 + size
        off = (off + 7) & ~7


def chunkset_data(body):
    magic, usize, csize = struct.unpack_from('<III', body, 0)
    if magic == 0x31347662:		# 'bv41'
        return lz4_block(body[12:12 + csize], usize)
    if magic == 0x2d347662:		# 'bv4-' stored uncompressed
        return body[8:8 + usize]
    raise ValueError(f'chunkset magic {magic:#x}')


LOG_TYPES = {0x0: 'Default', 0x1: 'Info', 0x2: 'Debug', 0x10: 'Error', 0x11: 'Fault'}
TIMEBASE = 24000000	# hvf: the host's 24 MHz counter (mkadt.py --hvf)


class Strings:
    """Format strings: uuidtext/XX/YYYY.. per binary, uuidtext/dsc/UUID per shared cache."""

    def __init__(self, root):
        self.root = os.path.join(root, 'uuidtext')
        self.bins, self.dscs = {}, {}

    def binary(self, uuid):
        if uuid not in self.bins:
            path = os.path.join(self.root, uuid[:2], uuid[2:])
            ent = None
            if os.path.exists(path):
                d = open(path, 'rb').read()
                n = struct.unpack_from('<I', d, 12)[0]
                ranges, data_off = [], 16 + 8 * n
                for i in range(n):
                    start, size = struct.unpack_from('<II', d, 16 + 8 * i)
                    ranges.append((start, size, data_off))
                    data_off += size
                ent = (d, ranges, d[data_off:].split(b'\0')[0].decode('utf-8', 'replace'))
            self.bins[uuid] = ent
        return self.bins[uuid]

    def binary_path(self, uuid):
        ent = self.binary(uuid)
        return ent[2] if ent else None

    def dsc(self, uuid):
        if uuid not in self.dscs:
            path = os.path.join(self.root, 'dsc', uuid)
            ent = None
            if os.path.exists(path):
                d = open(path, 'rb').read()
                _, _, _, nr, nu = struct.unpack_from('<IHHII', d)
                ranges = sorted(struct.unpack_from('<QIII', d, 16 + 24 * i) for i in range(nr))
                imgs = []
                for i in range(nu):
                    o = 16 + 24 * nr + 32 * i
                    to, ts = struct.unpack_from('<QI', d, o)
                    po = struct.unpack_from('<I', d, o + 28)[0]
                    imgs.append(d[po:po + 1024].split(b'\0')[0].decode('utf-8', 'replace'))
                ent = (d, ranges, [r[0] for r in ranges], imgs)
            self.dscs[uuid] = ent
        return self.dscs[uuid]

    @staticmethod
    def cstr(d, off):
        return d[off:d.index(b'\0', off)].decode('utf-8', 'replace')

    def from_binary(self, uuid, off):
        ent = self.binary(uuid)
        if ent:
            for start, size, data_off in ent[1]:
                if start <= off < start + size:
                    return self.cstr(ent[0], data_off + off - start)
        return None

    def from_dsc(self, uuid, off):
        ent = self.dsc(uuid)
        if ent:
            d, ranges, starts, imgs = ent
            i = bisect.bisect_right(starts, off) - 1
            if i >= 0:
                text, data_off, size, img = ranges[i]
                if off < text + size:
                    return self.cstr(d, data_off + off - text)
        return None


def uuid_hex(b):
    return b.hex().upper()


def parse_catalog(body):
    subsys_off, proc_off, nproc, sub_off, nsub = struct.unpack_from('<HHHHH', body, 0)
    uuids = [uuid_hex(body[24 + 16 * i:40 + 16 * i]) for i in range(subsys_off // 16)]
    strings = body[24 + subsys_off:24 + proc_off]
    procs, o = {}, 24 + proc_off
    for _ in range(nproc):
        _, _, main_i, dsc_i, first, second, pid, euid, _, nu, _ = struct.unpack_from('<HHHHQIIIIII', body, o)
        o += 40 + 16 * nu
        nsubsys = struct.unpack_from('<I', body, o)[0]
        o += 8
        subsystems = {}
        for k in range(nsubsys):
            ident, so, co = struct.unpack_from('<HHH', body, o + 6 * k)
            name = lambda x: strings[x:strings.index(b'\0', x)].decode('utf-8', 'replace')
            subsystems[ident] = (name(so), name(co))
        o += (6 * nsubsys + 7) & ~7
        procs[(first, second)] = {'pid': pid, 'euid': euid, 'main': uuids[main_i] if main_i < len(uuids) else None,
                                  'dsc': uuids[dsc_i] if dsc_i < len(uuids) else None, 'subsystems': subsystems}
    return procs


STRING_ITEMS = {0x20, 0x22, 0x40, 0x42, 0x30, 0x32, 0xf2}
PRIVATE_ITEMS = {0x1, 0x21, 0x25, 0x31, 0x35, 0x41, 0x45}
PRECISION_ITEMS = {0x10, 0x12}
SPEC = re.compile(r'%(\{[^}]*\})?([-+ #0]*)(\d+|\*)?(\.(\d+|\*))?(hh|h|ll|l|q|z|t|j|L)?([@sdiuoxXcpfFeEgGaAnSC%])')


def items(data, o):
    """Argument values after the formatter fields: (count byte, items, string pool)."""
    if o + 2 > len(data):
        return []
    n = data[o + 1]
    o += 2
    raw = []
    for _ in range(n):
        if o + 2 > len(data):
            break
        typ, size = data[o], data[o + 1]
        raw.append((typ, data[o + 2:o + 2 + size]))
        o += 2 + size
    pool, vals = data[o:], []
    for typ, v in raw:
        if typ in PRECISION_ITEMS:
            continue
        if typ in PRIVATE_ITEMS:
            vals.append('<private>')
        elif typ in STRING_ITEMS and len(v) >= 4:
            off, size = struct.unpack_from('<HH', v)
            vals.append(pool[off:off + size].rstrip(b'\0').decode('utf-8', 'replace') if size else '(null)')
        elif typ in (0x0, 0x2) and len(v) in (1, 2, 4, 8):
            vals.append(int.from_bytes(v, 'little', signed=False))
        else:
            vals.append(v.hex())
    return vals


def render(fmt, vals):
    it = iter(vals)

    def sub(m):
        conv = m.group(7)
        if conv == '%':
            return '%'
        v = next(it, '<?>')
        if isinstance(v, int):
            if conv in 'xX':
                return format(v, conv)
            if conv == 'p':
                return hex(v)
            if conv in 'di' and v >= 1 << 63:
                v -= 1 << 64
            elif conv in 'di' and m.group(6) not in ('l', 'll', 'q', 'z', 't', 'j') and v >= 1 << 31:
                v -= 1 << 32
            if conv == 'c':
                return chr(v & 0xff)
        return str(v)
    return SPEC.sub(sub, fmt)


def entries(path, strings):
    """Log entries of one tracev3 file: (seconds, pid, process, subsystem, type, message)."""
    data = open(path, 'rb').read()
    procs = {}
    for tag, sub, off, body in chunks(data):
        if tag == 0x600b:
            procs = parse_catalog(body)
        elif tag == 0x600d:
            for itag, _, _, fh in chunks(chunkset_data(body)):
                if itag != 0x6001:
                    continue
                first, second = struct.unpack_from('<QI', fh, 0)
                pub_size = struct.unpack_from('<H', fh, 16)[0]
                base_time = struct.unpack_from('<Q', fh, 24)[0]
                proc = procs.get((first, second), {})
                pub, o = fh[32:32 + pub_size - 16], 0
                while o + 24 <= len(pub):
                    atype, ltype, flags, fsl, tid, dlo, dhi, dsize = struct.unpack_from('<BBHIQIHH', pub, o)
                    if atype == 0:
                        break
                    d = pub[o + 24:o + 24 + dsize]
                    o += 24 + ((dsize + 7) & ~7)
                    if atype != 0x4:		# only plain log messages (not activity/signpost/trace/loss)
                        continue
                    yield parse_log(d, flags, fsl, ltype, base_time + dlo + (dhi << 32), proc, strings)


def parse_log(d, flags, fsl, ltype, t, proc, strings):
    o = 0
    if flags & 0x1:			# current activity id
        o += 8
    if flags & 0x100:			# private data range
        o += 4
    o += 4				# caller pc id (always present)
    fmt, kind = None, flags & 0xe
    large = 0
    if kind in (0x2, 0x4, 0xc) and flags & 0x20:	# has_large_offset
        large = struct.unpack_from('<H', d, o)[0]
        o += 2
    if kind == 0xc:				# large shared cache
        large = struct.unpack_from('<H', d, o)[0]
        o += 2
    elif kind == 0x8:			# absolute
        o += 2
    elif kind == 0xa:			# uuid relative
        o += 16
    sub = None
    if flags & 0x200:			# has_subsystem
        sub = proc.get('subsystems', {}).get(struct.unpack_from('<H', d, o)[0])
        o += 2
    if flags & 0x400:			# has_rules (ttl)
        o += 1
    oversize = bool(flags & 0x800)
    if flags & 0x800:			# has_oversize (data ref)
        o += 2
    loc = fsl | (large << 31)
    if kind == 0x2 and proc.get('main'):
        fmt = strings.from_binary(proc['main'], loc)
    elif kind in (0x4, 0xc) and proc.get('dsc'):
        fmt = strings.from_dsc(proc['dsc'], loc)
    vals = items(d, o) if not oversize else []
    if fmt is None:
        msg = f'<format {kind:#x} @{loc:#x} not found> {vals}'
    else:
        msg = render(fmt, vals) + (' <oversize data not decoded>' if oversize else '')
    path = strings.binary_path(proc['main']) if proc.get('main') else None
    name = os.path.basename(path) if path else '?'
    return t / TIMEBASE, proc.get('pid'), name, sub, LOG_TYPES.get(ltype, hex(ltype)), msg


def stats(path):
    data = open(path, 'rb').read()
    counts = {}
    for tag, sub, off, body in chunks(data):
        counts[tag] = counts.get(tag, 0) + 1
        if tag == 0x600d:
            for itag, *_ in chunks(chunkset_data(body)):
                counts[itag] = counts.get(itag, 0) + 1
    return counts


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('dir')
    ap.add_argument('--files', type=int, default=0, help='only the newest N tracev3 files per directory')
    ap.add_argument('--proc', help='comma separated process names (executable basename)')
    ap.add_argument('--grep', help='only messages containing TEXT')
    ap.add_argument('--stats', action='store_true', help='chunk counts per file')
    a = ap.parse_args()
    files = []
    for sub in ('Persist', 'Special', 'Signpost', 'HighVolume'):
        fs = sorted(glob.glob(os.path.join(a.dir, 'diagnostics', sub, '*.tracev3')))
        files += fs[-a.files:] if a.files else fs
    procs = set(a.proc.split(',')) if a.proc else None
    strings = Strings(a.dir)
    rows = []
    for f in files:
        if a.stats:
            print(os.path.relpath(f, a.dir), {hex(k): v for k, v in sorted(stats(f).items())})
            continue
        for t, pid, name, sub, typ, msg in entries(f, strings):
            if procs and name not in procs:
                continue
            if a.grep and a.grep not in msg:
                continue
            rows.append((t, pid, name, sub, typ, msg, os.path.basename(f)))
    rows.sort(key=lambda r: (r[6][:0], r[0]))
    for t, pid, name, sub, typ, msg, f in rows:
        ss = f' [{sub[0]}:{sub[1]}]' if sub else ''
        print(f'{t:12.6f} {name}[{pid}] {typ}{ss}: {msg}')


if __name__ == '__main__':
    main()
