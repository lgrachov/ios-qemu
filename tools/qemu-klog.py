#!/usr/bin/env python3
"""Dump the kernel message buffer of a running qemu-sweet.py guest, oldest first.

  qemu-klog.py RUN_DIR OUT.txt [KERNEL]

KERNEL (default xnu/out-local/kernel.development.sweet) gives _msgbufp via
llvm-nm. Reads struct msgbuf (magic/size, bufx/bufr, bufc) and memsaves bufc
over QMP (RUN_DIR/mon.sock; QMP is single-client). The buffer is 128 KiB and
wraps quickly with verbose boot-args: dump right after the action of interest.
"""
import json, os, re, shutil, socket, subprocess, sys


def nm_addr(kernel, sym):
    nm = shutil.which('llvm-nm') or '/opt/homebrew/opt/llvm/bin/llvm-nm'
    if not os.path.exists(nm):
        nm = subprocess.check_output(['xcrun', '-f', 'llvm-nm'], text=True).strip()
    for line in subprocess.check_output([nm, kernel], text=True).splitlines():
        f = line.split()
        if len(f) == 3 and f[2] == sym:
            return int(f[0], 16)
    sys.exit(f'{sym} not in {kernel}')


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    run, out = sys.argv[1], sys.argv[2]
    kernel = sys.argv[3] if len(sys.argv) > 3 else 'xnu/out-local/kernel.development.sweet'
    msgbufp = nm_addr(kernel, '_msgbufp')
    s = socket.socket(socket.AF_UNIX)
    s.connect(os.path.join(run, 'mon.sock'))
    f = s.makefile('rw')
    f.readline()

    def call(ex, **a):
        f.write(json.dumps({'execute': ex, 'arguments': a}) + '\n')
        f.flush()
        while True:
            r = json.loads(f.readline())
            if 'error' in r:
                raise RuntimeError(f'{ex}: {r["error"]}')
            if 'return' in r:
                return r['return']

    def quads(addr, n):
        t = call('human-monitor-command', **{'command-line': f'x /{n}gx 0x{addr:x}'})
        return [int(v, 16) for line in t.splitlines() for v in re.findall(r'0x[0-9a-f]+', line.split(':', 1)[1])]

    call('qmp_capabilities')
    mb = quads(msgbufp, 1)[0]
    magic_size, bufx_bufr, bufc = quads(mb, 3)
    size, bufx = magic_size >> 32, bufx_bufr & 0xffffffff
    tmp = os.path.abspath(out + '.bin')
    call('human-monitor-command', **{'command-line': f'memsave 0x{bufc:x} {size} "{tmp}"'})
    f.close()   # the makefile() handle keeps the socket open otherwise
    s.close()
    with open(tmp, 'rb') as fh:
        d = fh.read()
    os.unlink(tmp)
    with open(out, 'wb') as fh:
        fh.write((d[bufx:] + d[:bufx]).replace(b'\0', b''))
    print(f'msgbuf {size} bytes, bufx {bufx} -> {out}')


if __name__ == '__main__':
    main()
