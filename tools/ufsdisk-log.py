#!/usr/bin/env python3
"""Read the persistent console log (patch 0047) out of a qemu-sweet.py --ufs disk.

  ufsdisk-log.py DISK.img OUT.txt [--name userdata]

The kernel keeps its 4 MiB console ring in the last 1 + 1024 blocks of the
userdata partition (ufsrw=1). This finds the partition in the 4 KiB-sector
GPT (tools/mkufsdisk.py), cuts that area out and decodes it with
tools/sweet-log.py, the reader used for the phone's log. Run it with the VM
stopped (the log is flushed by the guest).
"""
import os, struct, subprocess, sys, tempfile

BLOCK, LOG_BLOCKS = 4096, 1 + (4 << 20) // 4096


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    disk, out = sys.argv[1], sys.argv[2]
    want = sys.argv[4] if len(sys.argv) > 4 and sys.argv[3] == '--name' else 'userdata'
    with open(disk, 'rb') as f:
        f.seek(BLOCK)
        h = f.read(92)
        assert h[:8] == b'EFI PART', 'no 4 KiB GPT'
        entry_lba, nent, esz = struct.unpack_from('<QII', h, 72)
        f.seek(entry_lba * BLOCK)
        ents = f.read(nent * esz)
        for i in range(nent):
            e = ents[i * esz:(i + 1) * esz]
            if e[56:56 + 72].decode('utf-16-le', 'replace').rstrip('\0') == want:
                first, last = struct.unpack_from('<QQ', e, 32)
                break
        else:
            sys.exit(f'no partition {want!r}')
        f.seek((last + 1 - LOG_BLOCKS) * BLOCK)
        area = f.read(LOG_BLOCKS * BLOCK)
    with tempfile.NamedTemporaryFile(suffix='.bin', delete=False) as t:
        t.write(area)
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        subprocess.check_call([sys.executable, os.path.join(here, 'sweet-log.py'), t.name, out])
    finally:
        os.unlink(t.name)


if __name__ == '__main__':
    main()
