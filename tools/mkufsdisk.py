#!/usr/bin/env python3
"""Wrap a partition image in a GPT disk with 4 KiB sectors, like sweet's UFS LUN 0.

  mkufsdisk.py OUT PARTITION.img [--name userdata]
  mkufsdisk.py --add-mac-gpt DISK          (retrofit the macOS view below)

For tools/qemu-sweet.py --ufs: bsd/dev/sweet_ufs.c reads the GPT header at
block 1 of 4096-byte blocks and looks the partition up by name (boot-arg
ufsroot=, default "userdata"); boot with rd=ufsroot0. macOS tools only make
512-byte-sector GPTs, so the tables are written here. The partition starts at
1 MiB; all-zero 1 MiB chunks are skipped, so OUT stays sparse. The partition
is 8 MiB longer than the image: with ufsrw=1 the kernel keeps its console
log in the last 4 MiB + 4 KiB of userdata (patch 0047).

A second, 512-byte-sector GPT (header at byte 512, 4 entries at 1024, backup
in the padding of the last 4 KiB block) describes the same partition, so
macOS can mount it in place: hdiutil attach -imagekey
diskimage-class=CRawDiskImage DISK. The guest only reads the 4 KiB tables.
"""
import argparse, os, struct, sys, uuid, zlib

BLOCK = 4096
NENT, ESZ = 128, 128
ENT_BLOCKS = NENT * ESZ // BLOCK
FIRST = (1 << 20) // BLOCK
# Apple HFS+ partition type 48465300-0000-11AA-AA11-00306543ECAC
HFS_TYPE = uuid.UUID('48465300-0000-11aa-aa11-00306543ecac')
CHUNK = 1 << 20
LOG_RESERVE = 8 << 20


def header(cur, backup, first_usable, last_usable, disk_guid, entry_lba, entries_crc):
    h = struct.pack('<8sIIIIQQQQ16sQIII', b'EFI PART', 0x10000, 92, 0, 0, cur, backup,
                    first_usable, last_usable, disk_guid.bytes_le, entry_lba, NENT, ESZ, entries_crc)
    h = h[:16] + struct.pack('<I', zlib.crc32(h)) + h[20:]
    return h.ljust(BLOCK, b'\0')


def mac_gpt(f, total_bytes, part_first, part_last, part_entry_tail):
    """512-byte-sector GPT for macOS around the same partition (byte bounds)."""
    n = total_bytes // 512
    first, last = part_first // 512, (part_last + 1) // 512 - 1
    entries = (part_entry_tail[:32] + struct.pack('<QQ', first, last) + part_entry_tail[48:]).ljust(4 * ESZ, b'\0')
    ecrc = zlib.crc32(entries)
    guid = uuid.uuid4()

    def hdr(cur, backup, entry_lba):
        h = struct.pack('<8sIIIIQQQQ16sQIII', b'EFI PART', 0x10000, 92, 0, 0, cur, backup,
                        first, last, guid.bytes_le, entry_lba, 4, ESZ, ecrc)
        return (h[:16] + struct.pack('<I', zlib.crc32(h)) + h[20:]).ljust(512, b'\0')
    mbr = bytearray(512)
    mbr[446:462] = struct.pack('<BBBBBBBBII', 0, 0, 2, 0, 0xee, 0xff, 0xff, 0xff, 1, min(n - 1, 0xffffffff))
    mbr[510:512] = b'\x55\xaa'
    f.seek(0)
    f.write(mbr + hdr(1, n - 1, 2) + entries)
    f.seek((n - 2) * 512)
    f.write(entries[:512] + hdr(n - 1, 1, n - 2))


def add_mac_gpt(path):
    with open(path, 'r+b') as f:
        f.seek(BLOCK)
        h = f.read(92)
        assert h[:8] == b'EFI PART', 'no 4 KiB GPT at block 1'
        entry_lba = struct.unpack_from('<Q', h, 72)[0]
        f.seek(entry_lba * BLOCK)
        e = f.read(ESZ)
        pfirst, plast = struct.unpack_from('<QQ', e, 32)
        total = os.path.getsize(path)
        mac_gpt(f, total, pfirst * BLOCK, (plast + 1) * BLOCK - 1, e)
    print(f'{path}: added 512-byte GPT for macOS', file=sys.stderr)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '--add-mac-gpt':
        return add_mac_gpt(sys.argv[2])
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('out')
    ap.add_argument('partition')
    ap.add_argument('--name', default='userdata')
    a = ap.parse_args()

    psize = os.path.getsize(a.partition)
    pblocks = -(-psize // BLOCK) + LOG_RESERVE // BLOCK
    last = FIRST + pblocks - 1
    total = last + 1 + ENT_BLOCKS + 1		# backup entries + backup header
    disk_guid = uuid.uuid4()

    name = a.name.encode('utf-16-le')
    assert len(name) <= 72, 'partition name too long'
    entry = struct.pack('<16s16sQQQ72s', HFS_TYPE.bytes_le, uuid.uuid4().bytes_le, FIRST, last, 0, name)
    entries = entry.ljust(NENT * ESZ, b'\0')
    ecrc = zlib.crc32(entries)

    # protective MBR: one 0xEE partition covering the disk (in 4 KiB sectors)
    mbr = bytearray(BLOCK)
    mbr[446:462] = struct.pack('<BBBBBBBBII', 0, 0, 2, 0, 0xee, 0xff, 0xff, 0xff, 1, min(total - 1, 0xffffffff))
    mbr[510:512] = b'\x55\xaa'

    with open(a.out, 'wb') as f:
        f.truncate(total * BLOCK)
        f.write(mbr)
        f.write(header(1, total - 1, FIRST, last, disk_guid, 2, ecrc))
        f.write(entries)
        f.seek((last + 1) * BLOCK)
        f.write(entries)
        f.write(header(total - 1, 1, FIRST, last, disk_guid, last + 1, ecrc))
        with open(a.partition, 'rb') as p:
            off = 0
            while True:
                buf = p.read(CHUNK)
                if not buf:
                    break
                if buf.count(0) != len(buf):
                    f.seek(FIRST * BLOCK + off)
                    f.write(buf)
                off += len(buf)
        mac_gpt(f, total * BLOCK, FIRST * BLOCK, (last + 1) * BLOCK - 1, entry)
    print(f'{a.out}: {total * BLOCK} bytes, partition "{a.name}" blocks {FIRST}..{last} '
          f'({pblocks * BLOCK} bytes)', file=sys.stderr)


if __name__ == '__main__':
    main()
