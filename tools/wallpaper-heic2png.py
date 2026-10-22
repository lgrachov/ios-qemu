#!/usr/bin/env python3
"""Make the stock wallpapers' artwork render in the VM: HEIC layers -> PNG.

  wallpaper-heic2png.py DISK                (VM stopped)
  wallpaper-heic2png.py --root MOUNTED_ROOT

macOS only (hdiutil, and sips for the conversion).

The iOS 16 wallpapers (/Library/Wallpaper/Collections/*/Wallpapers/*.wallpaper)
are CoreAnimation archives (.ca) whose layers show HEIC images. iOS decodes
HEIC with the hardware decoder, which the VM does not have, so only the
layers' gradients render (the default "WWDC 2022" wallpaper is a plain blue
gradient). This converts every assets/*.HEIC next to itself as PNG with macOS
sips (alpha kept) and points the layer's main.caml at the PNG (edited in
place, so owner and mode stay). The HEIC files stay, nothing else changes.
Idempotent.
"""
import argparse, os, re, subprocess, sys, tempfile

WALLPAPER = 'Library/Wallpaper'


def run(*cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def convert(root):
    base = os.path.join(root, WALLPAPER)
    images = layers = 0
    for dirpath, dirnames, filenames in os.walk(base):
        for f in filenames:
            if f.lower().endswith('.heic'):
                src = os.path.join(dirpath, f)
                dst = src[:-5] + '.png'
                if not os.path.exists(dst):
                    run('sips', '-s', 'format', 'png', src, '--out', dst, stdout=subprocess.DEVNULL)
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


def with_disk(disk, fn):
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
    if sys.platform != 'darwin':
        sys.exit('wallpaper-heic2png.py needs macOS (sips converts the HEIC images)')
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('disk', nargs='?')
    ap.add_argument('--root', help='an already mounted guest root instead of DISK')
    a = ap.parse_args()
    if a.root:
        convert(a.root)
    elif a.disk:
        with_disk(a.disk, convert)
    else:
        ap.error('DISK or --root is required')


if __name__ == '__main__':
    main()
