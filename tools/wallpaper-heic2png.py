#!/usr/bin/env python3
"""Make the stock wallpapers' artwork render in the VM: HEIC layers -> PNG.

  wallpaper-heic2png.py DISK                macOS, VM stopped (hdiutil)
  sudo wallpaper-heic2png.py --root MOUNTED_ROOT

Converter: sips on macOS; elsewhere heif-convert (libheif; Debian, Ubuntu,
Raspberry Pi OS: apt install libheif-examples) or ImageMagick with HEIC
support. Linux, as root: `fsck.hfsplus -fy` the image's HFS+ partition, mount
it read-write (`mount -t hfsplus -o loop,force,offset=...` or via losetup -P),
run with --root, unmount.

The iOS 16 wallpapers (/Library/Wallpaper/Collections/*/Wallpapers/*.wallpaper)
are CoreAnimation archives (.ca) whose layers show HEIC images. iOS decodes
HEIC with the hardware decoder, which the VM does not have, so only the
layers' gradients render (the default "WWDC 2022" wallpaper is a plain blue
gradient). This converts every assets/*.HEIC next to itself as PNG (alpha
kept) and points the layer's main.caml at the PNG (edited in
place, so owner and mode stay). The HEIC files stay, nothing else changes.
Idempotent.
"""
import argparse, os, re, shutil, subprocess, sys, tempfile

WALLPAPER = 'Library/Wallpaper'


def run(*cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def converter():
    """argv prefix that turns SRC DST (HEIC -> PNG, alpha kept) into a command."""
    if sys.platform == 'darwin':
        return lambda src, dst: ['sips', '-s', 'format', 'png', src, '--out', dst]
    for heif in ('heif-dec', 'heif-convert'):     # libheif >= 1.17 renamed heif-convert
        if shutil.which(heif):
            return lambda src, dst, h=heif: [h, src, dst]
    for magick in ('magick', 'convert'):
        if shutil.which(magick):
            return lambda src, dst, m=magick: [m, src, dst]
    sys.exit('no HEIC converter: install libheif (Debian/Ubuntu/Raspberry Pi OS: apt install libheif-examples) '
             'or ImageMagick with HEIC support')


def convert(root):
    to_png = converter()
    base = os.path.join(root, WALLPAPER)
    images = layers = 0
    for dirpath, dirnames, filenames in os.walk(base):
        for f in filenames:
            if f.lower().endswith('.heic'):
                src = os.path.join(dirpath, f)
                dst = src[:-5] + '.png'
                if not os.path.exists(dst):
                    run(*to_png(src, dst), stdout=subprocess.DEVNULL)
                    os.chmod(dst, 0o644)
                    images += 1
        if 'main.caml' in filenames:
            path = os.path.join(dirpath, 'main.caml')
            with open(path, 'r+', encoding='utf-8') as f:
                text = f.read()
                new = re.sub(r'(src="assets/[^"]*?)\.heic"', r'\1.png"', text, flags=re.IGNORECASE)
                if new != text:
                    f.seek(0)
                    f.write(new)
                    f.truncate()
                    layers += 1
    print(f'{images} HEIC images converted to PNG, {layers} layers updated')


def disk_in_use(disk):
    """A running qemu has DISK (or a link to it) open as a drive."""
    real = os.path.realpath(disk)
    out = subprocess.run(['ps', '-axww', '-o', 'command='], capture_output=True, text=True).stdout
    # every file= (the loader's ram.bin and stub.bin come before the drive)
    return any(os.path.realpath(f) == real
               for line in out.splitlines() if 'qemu-system' in line
               for f in re.findall(r'file=([^,\s]+)', line))


def with_disk(disk, fn):
    # fsck -fy and a read-write mount under a running guest corrupt the volume
    if disk_in_use(disk):
        sys.exit(f'a VM is using {disk}: stop it first')
    dev = run('hdiutil', 'attach', '-nomount', '-imagekey', 'diskimage-class=CRawDiskImage', disk,
              capture_output=True, text=True).stdout.split()[0]
    mnt = tempfile.mkdtemp(prefix='ios-qemu-')
    try:
        run('fsck_hfs', '-fy', dev.replace('/dev/', '/dev/r') + 's1', stdout=subprocess.DEVNULL)
        run('mount', '-t', 'hfs', '-o', 'noowners', dev + 's1', mnt)
        try:
            fn(mnt)
        finally:
            run('umount', mnt)
    finally:
        run('hdiutil', 'detach', dev, stdout=subprocess.DEVNULL)
        os.rmdir(mnt)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('disk', nargs='?')
    ap.add_argument('--root', help='an already mounted guest root instead of DISK')
    a = ap.parse_args()
    if a.root:
        convert(a.root)
    elif a.disk:
        if sys.platform != 'darwin':
            sys.exit('DISK mode needs macOS (hdiutil); on Linux mount the root as root and use --root')
        with_disk(a.disk, convert)
    else:
        ap.error('DISK or --root is required')


if __name__ == '__main__':
    main()
