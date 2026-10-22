#!/usr/bin/env python3
"""Boot a SWEETXNU payload (tools/mkpayload.py) in QEMU's virt board.

  qemu-sweet.py PAYLOAD OUTDIR [--secs N] [--gdb] [--live-serial]

Does what shim/loader.c does on the phone, but on the host: places the
kernel segments, ADT and boot_args at their physical addresses and starts
the CPU at a 6-instruction stub that jumps to the entry with x0 = boot_args.
virt RAM starts at 0x40000000; with 4G it covers the phone's framebuffer
(0x9c000000) and the kernel's phys_base (0xb0000000) as plain memory.

After N seconds (--secs 0: no limit), on Ctrl-C, or when the guest stops,
it writes into OUTDIR (Ctrl-C and the time limit capture the screen too):
  fb.png     the 1080x2400 framebuffer (what the phone screen would show)
  regs.txt   QEMU's view of CPU state
  qemu.log   exceptions with ESR/FAR/ELR (-d int,guest_errors)

With --kernel KERNEL (the matching unstripped Mach-O), also decode the
framebuffer using its iso_font into fb.txt and write result.json. This is a
snapshot of the circular screen, not a complete boot log. --fail-on-panic
returns 2 when a panic is visible; absence of a panic does not prove boot.
An undecodable or blank screen returns 3 with --fail-on-panic.

With --display, the stub (tools/qemu-ramfb-stub.S, assembled with clang)
first points QEMU's ramfb device at the framebuffer, so a QEMU window shows
the screen live while the guest runs.
"""
import argparse, json, os, re, shutil, signal, socket, struct, subprocess, sys, time, zlib

FB_BASE, FB_W, FB_H = 0x9c000000, 1080, 2400
FB_STRIDE = FB_W * 4
PAGE = 0x4000
STUB_PA = 0x40200000	# above the dtb QEMU places at RAM base
# --ufs: QEMU's UFSHCI at 00:UFS_SLOT.0, BAR at the start of virt's 32-bit PCI window
# (mkadt.py QEMU_UFS must match)
UFS_SLOT, UFS_BAR = 1, 0x10000000
BOOT_LINE_LENGTH = 608


def check_qemu_dependency(cpu='cortex-a76'):
    """Verify qemu-system-aarch64 binary and CPU model support."""
    qemu_bin = shutil.which('qemu-system-aarch64')
    if not qemu_bin:
        print('[!] Error: qemu-system-aarch64 not found in PATH.', file=sys.stderr)
        print('    Install instructions:', file=sys.stderr)
        print('      Arch Linux:    sudo pacman -S qemu-system-aarch64', file=sys.stderr)
        print('      Ubuntu/Debian: sudo apt install qemu-system-arm', file=sys.stderr)
        print('      Fedora:         sudo dnf install qemu-system-aarch64', file=sys.stderr)
        print('      macOS:          brew install qemu', file=sys.stderr)
        return False
    try:
        ver = subprocess.check_output([qemu_bin, '--version'], text=True).splitlines()[0]
        print(f'[*] Found QEMU: {ver}', file=sys.stderr)
    except Exception as e:
        print(f'[!] Warning: Failed to query QEMU version: {e}', file=sys.stderr)
        return False

    try:
        cpu_list = subprocess.check_output([qemu_bin, '-M', 'virt', '-cpu', 'help'], text=True)
        if cpu in cpu_list:
            print(f'[*] CPU model {cpu} supported', file=sys.stderr)
        else:
            print(f'[!] Warning: CPU model {cpu} not explicitly listed in qemu-system-aarch64 -cpu help', file=sys.stderr)
    except Exception:
        pass
    return True


def check_kernel_tools(kernel_path):
    """Verify llvm-nm is available when --kernel is specified."""
    if not shutil.which('llvm-nm'):
        print('[!] Error: llvm-nm not found in PATH, required for --kernel font extraction.', file=sys.stderr)
        print('    Install instructions:', file=sys.stderr)
        print('      Arch Linux:    sudo pacman -S llvm', file=sys.stderr)
        print('      Ubuntu/Debian: sudo apt install llvm', file=sys.stderr)
        print('      Fedora:         sudo dnf install llvm', file=sys.stderr)
        print('      macOS:          brew install llvm', file=sys.stderr)
        return False
    if not os.path.isfile(kernel_path):
        print(f'[!] Error: kernel file does not exist: {kernel_path}', file=sys.stderr)
        return False
    return True


def build_image(payload):
    """Return (phys_base, ram_image, boot_args_pa, entry_pa)."""
    magic, ver, nsegs = struct.unpack_from('<8sII', payload, 0)
    assert magic == b'SWEETXNU' and ver == 1, 'not a SWEETXNU v1 payload'
    virt_base, entry_va, adt_off, adt_size, kernel_end, phys_base, mem_size = \
        struct.unpack_from('<7Q', payload, 0x10)
    cmdline = payload[0x48:0x48 + BOOT_LINE_LENGTH]
    delta = phys_base - virt_base
    adt_pa = kernel_end + delta
    ba_pa = (adt_pa + adt_size + PAGE - 1) & ~(PAGE - 1)
    top = ba_pa + PAGE
    img = bytearray(top - phys_base)
    for i in range(nsegs):
        vmaddr, vmsize, foff, fsize = struct.unpack_from('<4Q', payload, 0x2a8 + 32 * i)
        o = vmaddr + delta - phys_base
        img[o:o + fsize] = payload[foff:foff + fsize]
    img[adt_pa - phys_base:adt_pa - phys_base + adt_size] = payload[adt_off:adt_off + adt_size]
    ba = struct.pack('<HH4x4Q6QI4xQI', 2, 2, virt_base, phys_base, mem_size, top,
                     FB_BASE, 1, FB_STRIDE, FB_W, FB_H, 32, 0, adt_pa - delta, adt_size)
    ba += cmdline + b'\0' * 4 + struct.pack('<QQ', 0, mem_size)
    assert len(ba) == 736
    img[ba_pa - phys_base:ba_pa - phys_base + len(ba)] = ba
    return phys_base, bytes(img), ba_pa, entry_va + delta


def stub(ba_pa, entry_pa):
    # ldr x0, =ba ; ldr x1, =entry ; br x1 ; nop ; .quad ba ; .quad entry
    return struct.pack('<4I2Q', 0x58000080, 0x580000a1, 0xd61f0020, 0xd503201f, ba_pa, entry_pa)


def elf_section(obj, name):
    """Contents of one section of an ELF64 little-endian object."""
    assert obj[:4] == b'\x7fELF' and obj[4] == 2, 'not an ELF64 object'
    shoff, = struct.unpack_from('<Q', obj, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<3H', obj, 0x3a)
    sections = [struct.unpack_from('<IIQQQQ', obj, shoff + i * shentsize) for i in range(shnum)]
    strtab = sections[shstrndx][4]
    for sh_name, _, _, _, offset, size in sections:
        if obj[strtab + sh_name:obj.index(b'\0', strtab + sh_name)].decode() == name:
            return obj[offset:offset + size]
    raise ValueError(f'no {name} section')


def ramfb_stub(ba_pa, entry_pa, out, ufs=False):
    """Assemble tools/qemu-ramfb-stub.S: point ramfb at the framebuffer (and with ufs,
    bring up the UFS host like the phone's bootloader), then enter the kernel."""
    src = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'qemu-ramfb-stub.S')
    clang = ['xcrun', 'clang'] if sys.platform == 'darwin' else ['clang']
    obj = f'{out}/ramfb-stub.o'
    subprocess.check_call(clang + ['-target', 'aarch64-none-elf', '-c', src, '-o', obj,
                                   f'-DBOOT_ARGS={ba_pa:#x}', f'-DENTRY={entry_pa:#x}',
                                   f'-DFB_BASE={FB_BASE:#x}', f'-DFB_W={FB_W}', f'-DFB_H={FB_H}', f'-DFB_STRIDE={FB_STRIDE}']
                          + ([f'-DUFS_BAR={UFS_BAR:#x}', f'-DUFS_SLOT={UFS_SLOT}'] if ufs else []))
    data = open(obj, 'rb').read()
    os.unlink(obj)
    try:
        elf_section(data, '.rela.text')
    except ValueError:
        return elf_section(data, '.text')
    raise ValueError('ramfb stub has relocations; it must be position independent')


def write_png(path, raw):
    rows = []
    for y in range(FB_H):
        line = raw[y * FB_STRIDE:(y + 1) * FB_STRIDE]
        rgb = bytearray(FB_W * 3)	# a8r8g8b8 little endian = B G R A in memory
        rgb[0::3], rgb[1::3], rgb[2::3] = line[2::4], line[1::4], line[0::4]
        rows.append(b'\0' + bytes(rgb))
    chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', FB_W, FB_H, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(b''.join(rows), 6)) + chunk(b'IEND', b'')
    open(path, 'wb').write(png)


def payload_data(payload, va, size):
    """Read initialized segment bytes by VA (the payload has no slide)."""
    nsegs = struct.unpack_from('<I', payload, 12)[0]
    for i in range(nsegs):
        vmaddr, _, foff, fsize = struct.unpack_from('<4Q', payload, 0x2a8 + 32 * i)
        if vmaddr <= va and va + size <= vmaddr + fsize:
            offset = foff + va - vmaddr
            return payload[offset:offset + size]
    raise ValueError(f'VA {va:#x}+{size:#x} not in initialized payload segments')


def decode_screen(raw, font):
    """Exact glyph matching for pe_serial.c's 2x, white-on-black fbcon."""
    glyphs = {font[c * 16:(c + 1) * 16]: chr(c) for c in range(32, 127)}
    rows, unknown = [], 0
    for row in range(FB_H // 32):
        chars = []
        for col in range(FB_W // 16):
            glyph = bytearray(16)
            for y in range(16):
                offset = (row * 32 + y * 2) * FB_STRIDE + col * 16 * 4
                for x in range(8):
                    if raw[offset + x * 8:offset + x * 8 + 4] == b'\xff' * 4:
                        glyph[y] |= 1 << x
            key = bytes(glyph)
            char = glyphs.get(key, '?')
            unknown += key not in glyphs
            chars.append(char)
        rows.append(''.join(chars).rstrip())
    return '\n'.join(rows).rstrip() + '\n', unknown


def screen_result(screen, unknown):
    if 'panic(cpu ' in screen or 'SWEET EARLY PANIC:' in screen:
        status = 'panic'
    elif unknown:
        status = 'incomplete_decode'
    elif screen.strip():
        status = 'no_panic_observed'
    else:
        status = 'blank_screen'
    return {'status': status, 'unknown_glyphs': unknown, 'snapshot_only': True}


def qmp(sock_path, *cmds, pmemsave=None):
    """Run QEMU human-monitor commands over QMP (synchronous, unlike the echoing HMP socket)."""
    s = socket.socket(socket.AF_UNIX)
    s.connect(sock_path)
    f = s.makefile('rw')
    f.readline()

    def call(execute, **args):
        f.write(json.dumps({'execute': execute, 'arguments': args}) + '\n')
        f.flush()
        while True:
            r = json.loads(f.readline())
            if 'return' in r or 'error' in r:
                return r

    call('qmp_capabilities')
    out = []
    for c in cmds:
        r = call('human-monitor-command', **{'command-line': c})
        if 'error' in r:
            print(f'qmp {c!r}: {r["error"]}', file=sys.stderr)
        out.append(r.get('return', ''))
    if pmemsave:	# native QMP: HMP's argument parser chokes on '-' in paths
        r = call('pmemsave', val=pmemsave[0], size=pmemsave[1], filename=pmemsave[2])
        if 'error' in r:
            print(f'qmp pmemsave: {r["error"]}', file=sys.stderr)
    s.close()
    return out


def stream_serial_file(serial_path, file_pos, out_stream=sys.stdout):
    """Read newly appended content from serial.txt and write directly to stream."""
    if not os.path.exists(serial_path):
        return file_pos
    try:
        with open(serial_path, 'r', errors='replace') as f:
            f.seek(file_pos)
            data = f.read()
            if data:
                out_stream.write(data)
                out_stream.flush()
                return f.tell()
    except Exception:
        pass
    return file_pos


class MsgbufStream:
    """--live-log: print the kernel message buffer as it grows. The kernel has
    no UART driver (serial.txt stays empty); this follows struct msgbuf
    (magic/size, bufx/bufr, bufc) through its own QMP socket (log.sock), so
    qemu-touch.py and qemu-klog.py keep mon.sock (QMP is single-client)."""

    def __init__(self, sock, kernel, part, stream=sys.stdout):
        self.sock_path, self.part, self.stream = sock, os.path.abspath(part), stream
        self.msgbufp = None
        for line in subprocess.run(['llvm-nm', kernel], capture_output=True, text=True).stdout.splitlines():
            f = line.split()
            if len(f) == 3 and f[2] == '_msgbufp':
                self.msgbufp = int(f[0], 16)
        self.f = None
        self.pos = None

    def hmp(self, command):
        self.f.write(json.dumps({'execute': 'human-monitor-command',
                                 'arguments': {'command-line': command}}) + '\n')
        self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if 'error' in r:
                raise RuntimeError(r['error'])
            if 'return' in r:
                return r['return']

    def quads(self, addr, n):
        t = self.hmp(f'x /{n}gx {addr:#x}')
        v = [int(x, 16) for line in t.splitlines() if ':' in line
             for x in re.findall(r'0x[0-9a-f]+', line.split(':', 1)[1])]
        if len(v) < n:
            raise ValueError(t.strip())
        return v

    def copy(self, addr, size):
        self.hmp(f'memsave {addr:#x} {size} "{self.part}"')
        with open(self.part, 'rb') as fh:
            return fh.read()

    def poll(self):
        if self.msgbufp is None:
            return
        try:
            if self.f is None:
                s = socket.socket(socket.AF_UNIX)
                s.connect(self.sock_path)
                self.f = s.makefile('rw')
                self.f.readline()
                self.f.write(json.dumps({'execute': 'qmp_capabilities'}) + '\n')
                self.f.flush()
                self.f.readline()
            mb = self.quads(self.msgbufp, 1)[0]
            magic_size, bufx_bufr, bufc = self.quads(mb, 3)
            size, bufx = magic_size >> 32, bufx_bufr & 0xffffffff
            if not mb or not bufc or not 0 < size <= 1 << 24 or bufx >= size:
                return		# not set up yet
            if self.pos is None:	# first look: everything so far, oldest first
                data = self.copy(bufc, size)
                data = data[bufx:] + data[:bufx]
            elif bufx == self.pos:
                return
            elif bufx > self.pos:
                data = self.copy(bufc + self.pos, bufx - self.pos)
            else:			# wrapped
                data = self.copy(bufc + self.pos, size - self.pos) + (self.copy(bufc, bufx) if bufx else b'')
            self.pos = bufx
            self.stream.write(data.replace(b'\0', b'').decode('utf-8', 'replace'))
            self.stream.flush()
        except (OSError, ValueError, RuntimeError, json.JSONDecodeError):
            pass		# early boot (no MMU mapping yet) or QEMU going away


def main():
    ap = argparse.ArgumentParser(
        description="Boot a SWEETXNU payload in QEMU's virt board.",
        epilog="Examples:\n"
               "  qemu-sweet.py payload.bin out/\n"
               "  qemu-sweet.py payload.bin out/ --live-serial\n"
               "  qemu-sweet.py payload.bin out/ --kernel kernel.macho --fail-on-panic\n"
               "  qemu-sweet.py --check-env\n",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument('payload', nargs='?', help='SWEETXNU payload binary (from mkpayload.py)')
    ap.add_argument('outdir', nargs='?', help='Output directory for fb.png, regs.txt, and logs')
    ap.add_argument('--secs', type=float, default=20, help='Duration to run QEMU in seconds, 0 = until Ctrl-C or QEMU exits (default: 20)')
    ap.add_argument('--gdb', action='store_true', help='start halted, gdb stub on :1234, no timeout')
    ap.add_argument('--hmp', action='append', default=[], help='extra monitor command run after stop (repeatable), e.g. "x /8gx 0xfffffe..."')
    ap.add_argument('--cpu', default='cortex-a76', help='QEMU CPU model (default: cortex-a76)')
    ap.add_argument('--kernel', help='matching unstripped kernel, for exact framebuffer text decoding (uses llvm-nm)')
    ap.add_argument('--fail-on-panic', action='store_true', help='exit 2 for a visible panic, 3 for incomplete/blank decoding; requires --kernel')
    ap.add_argument('--live-serial', action='store_true', help='stream serial console output to stdout in real time')
    ap.add_argument('--live-log', action='store_true', help='stream the kernel message buffer to stdout (needs --kernel; own QMP socket log.sock)')
    ap.add_argument('--mux-port', type=int, default=62079, metavar='PORT',
                    help='with --ufs: forward host 127.0.0.1:PORT to the guest kernel mux relay (TCP 62079, '
                         'bsd/dev/sweet_mux.c) for tools/ios-usbmuxd.py; 0 = off')
    ap.add_argument('--smp', type=int, default=1, help='vCPUs (secondaries start powered off for PSCI CPU_ON); needs an ADT from mkadt.py --cpus N')
    ap.add_argument('--hvf', action='store_true', help='hardware virtualization on Apple Silicon (-accel hvf -cpu host); needs an ADT from mkadt.py --hvf')
    ap.add_argument('--ufs', metavar='DISK', help='raw disk image (4 KiB-sector GPT, e.g. a "userdata" HFS+ partition) as a UFS LU; needs an ADT from mkadt.py --qemu-ufs and rd=ufsroot0')
    ap.add_argument('--fullfb', action='store_true', help='1125x2436 framebuffer (the whole iOS display, no crop); needs an ADT from mkadt.py --qemu-fullfb and kernel 0085')
    ap.add_argument('--display', action='store_true', help='show the framebuffer live in a QEMU window (ramfb; needs clang)')
    ap.add_argument('--check-env', action='store_true', help='check QEMU installation and dependencies without running a payload')
    a = ap.parse_args()
    if a.fullfb:
        global FB_W, FB_H, FB_STRIDE
        FB_W, FB_H, FB_STRIDE = 1125, 2436, 1125 * 4	# mkadt.py QEMU_FULL_FB

    if a.check_env:
        ok = check_qemu_dependency(a.cpu)
        if shutil.which('llvm-nm'):
            print('[*] llvm-nm found in PATH', file=sys.stderr)
        else:
            print('[!] Optional: llvm-nm not found (needed only when using --kernel for text decoding)', file=sys.stderr)
        return 0 if ok else 1

    if not a.payload or not a.outdir:
        ap.error('payload and outdir are required unless --check-env is specified')

    if a.fail_on_panic and not a.kernel:
        ap.error('--fail-on-panic requires --kernel')

    if not check_qemu_dependency(a.cpu):
        return 1

    if a.kernel and not check_kernel_tools(a.kernel):
        return 1

    payload = open(a.payload, 'rb').read()
    font = None
    if a.kernel:
        symbols = subprocess.check_output(['llvm-nm', '--defined-only', a.kernel], text=True)
        fonts = [int(line.split()[0], 16) for line in symbols.splitlines()
                 if line.split()[-1:] == ['_iso_font']]
        if len(fonts) != 1:
            ap.error('kernel must contain exactly one _iso_font symbol')
        font = payload_data(payload, fonts[0], 256 * 16)
    os.makedirs(a.outdir, exist_ok=True)
    out = os.path.abspath(a.outdir)

    phys_base, img, ba_pa, entry_pa = build_image(payload)
    open(f'{out}/ram.bin', 'wb').write(img)
    open(f'{out}/stub.bin', 'wb').write(ramfb_stub(ba_pa, entry_pa, out, ufs=bool(a.ufs))
                                        if a.display or a.ufs else stub(ba_pa, entry_pa))
    print(f'phys_base={phys_base:#x} boot_args={ba_pa:#x} entry={entry_pa:#x}', file=sys.stderr)

    mon = f'{out}/mon.sock'
    for sock in (mon, f'{out}/log.sock'):
        if os.path.exists(sock):
            os.unlink(sock)
    # virt RAM starts at 0x40000000: cover the payload's RAM (mkadt.py --highmem needs 8G).
    mem_size = struct.unpack_from('<Q', payload, 0x40)[0]
    ram_gib = max(4, -(-(phys_base + mem_size - 0x40000000) // (1 << 30)))
    accel = ['-accel', 'hvf', '-cpu', 'host'] if a.hvf else ['-cpu', a.cpu]
    machine = 'virt,gic-version=3' + (',highmem-ecam=off' if a.ufs else '')
    cmd = ['qemu-system-aarch64', '-M', machine, *accel, '-smp', str(a.smp), '-m', f'{ram_gib}G',
           '-serial', f'file:{out}/serial.txt', '-qmp', f'unix:{mon},server,nowait',
           '-qmp', f'unix:{out}/log.sock,server,nowait',
           '-d', 'int,guest_errors,unimp', '-D', f'{out}/qemu.log', '-no-reboot',
           '-device', f'loader,file={out}/ram.bin,addr={phys_base:#x},force-raw=on',
           '-device', f'loader,file={out}/stub.bin,addr={STUB_PA:#x},force-raw=on',
           '-device', f'loader,addr={STUB_PA:#x},cpu-num=0']
    if a.ufs:
        cmd += ['-nic', 'none', '-drive', f'if=none,id=ufsdisk,format=raw,file={os.path.abspath(a.ufs)}',
                '-device', f'ufs,id=ufs0,serial=sweet,addr={UFS_SLOT:#x}', '-device', 'ufs-lu,drive=ufsdisk,lun=0']
        # input for bsd/dev/sweet_vinput.c (boot-arg sweetvinput=1): mouse in the window = touch
        cmd += ['-global', 'virtio-mmio.force-legacy=false',
                '-device', 'virtio-tablet-device', '-device', 'virtio-keyboard-device']
        # en0 for bsd/dev/sweet_vnet.c (sweetvnet=1): user-mode NAT, DHCP 10.0.2.15.
        # Host 127.0.0.1:MUX_PORT -> the guest's kernel mux relay, which reaches lockdownd
        # and its services as a USB peer (tools/ios-usbmuxd.py).
        fwd = f',hostfwd=tcp:127.0.0.1:{a.mux_port}-:62079' if a.mux_port else ''
        cmd += ['-netdev', f'user,id=net0{fwd}', '-device', 'virtio-net-device,netdev=net0']
    if a.display:
        # the 1080x2400 panel is taller than most screens; zoom-to-fit scales the window.
        # show-cursor: with the virtio tablet QEMU hides the host cursor (iOS draws none)
        backend = ('cocoa' if sys.platform == 'darwin' else 'gtk') + ',zoom-to-fit=on,show-cursor=on'
        cmd += ['-device', 'ramfb', '-display', backend, '-monitor', 'none']
    else:
        cmd += ['-nographic']
    if a.gdb:
        cmd += ['-S', '-gdb', 'tcp::1234']

    p = None
    serial_file = f'{out}/serial.txt'
    serial_pos = 0
    live_log = MsgbufStream(f'{out}/log.sock', a.kernel, f'{out}/msgbuf.part') if a.live_log and a.kernel else None

    try:
        # own process group: Ctrl-C reaches only this script, which then
        # captures the screen and stops QEMU itself. SIGTERM/SIGHUP (terminal
        # closed) do the same; SIGINT is set explicitly because a background
        # job (`cmd &` in a script) inherits it ignored.
        def interrupt(*_):
            raise KeyboardInterrupt
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, interrupt)
        p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, process_group=0)
        if a.gdb:
            print('gdb stub on :1234; QMP socket:', mon, file=sys.stderr)
            p.wait()
            return 0

        t0 = time.time()
        try:
            while p.poll() is None and (a.secs <= 0 or time.time() - t0 < a.secs):
                if a.live_serial:
                    serial_pos = stream_serial_file(serial_file, serial_pos)
                if live_log:
                    live_log.poll()
                time.sleep(0.2)
        except KeyboardInterrupt:
            print('\n[!] Interrupted, capturing the screen and stopping QEMU...', file=sys.stderr)

        if a.live_serial:
            stream_serial_file(serial_file, serial_pos)

        result = {'status': 'qemu_exited', 'qemu_returncode': p.returncode}
        if p.poll() is None:
            _, regs, *extra = qmp(mon, 'stop', 'info registers', *a.hmp, pmemsave=(FB_BASE, FB_STRIDE * FB_H, f'{out}/fb.raw'))
            open(f'{out}/regs.txt', 'w').write(regs + ''.join(f'\n(qemu) {c}\n{r}' for c, r in zip(a.hmp, extra)))
            p.kill()
            p.wait()
            raw = open(f'{out}/fb.raw', 'rb').read()
            write_png(f'{out}/fb.png', raw)
            result = {'status': 'not_decoded'}
            if font is not None:
                screen, unknown = decode_screen(raw, font)
                open(f'{out}/fb.txt', 'w').write(screen)
                result = screen_result(screen, unknown)
            os.unlink(f'{out}/fb.raw')
        else:
            print(f'qemu exited early: {p.returncode}', file=sys.stderr)

        open(f'{out}/result.json', 'w').write(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result), file=sys.stderr)
        print(f'{out}/fb.png  {out}/regs.txt  {out}/qemu.log', file=sys.stderr)
        if a.fail_on_panic and result['status'] == 'panic':
            return 2
        if a.fail_on_panic and result['status'] in ('incomplete_decode', 'blank_screen'):
            return 3
        if result['status'] == 'qemu_exited':
            # without a time limit, closing the window or powering off is the normal end
            return 0 if a.secs <= 0 and p.returncode == 0 else 1
        return 0

    except KeyboardInterrupt:
        print('\n[!] Interrupted by user, stopping QEMU...', file=sys.stderr)
        if p and p.poll() is None:
            p.kill()
            p.wait()
        return 130
    finally:
        if p and p.poll() is None:	# QEMU is in its own process group: never leave it running
            p.kill()
            p.wait()
        ram_file = f'{out}/ram.bin'
        if os.path.exists(ram_file):
            try:
                os.unlink(ram_file)
            except Exception:
                pass


if __name__ == '__main__':
    sys.exit(main())
