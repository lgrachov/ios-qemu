#!/usr/bin/env python3
"""Add the guest Metal plug-in (tools/guest/qemu-metal) to an iOS guest disk.

  metal-plugin.py setup DISK     build QEMUMetal.bundle (macOS + Xcode) and copy it to
                                 /System/Library/Extensions on DISK (VM stopped)

The bundle is only loaded when the kernel publishes its IOAcceleratorES
service, i.e. with boot-arg sweetmetal=1 (patch 0103):
  ./harness.sh --ios DISK --bootargs "sweetmetal=1"
Step 1 is a logging-only device: it records which Metal methods each process
calls in the guest's /private/var/tmp/QEMUMetal.log (and os_log).
"""
import os, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'tools/guest/qemu-metal')
BUNDLE = os.path.join(ROOT, 'research/guest/QEMUMetal.bundle')
GUEST_PATH = 'System/Library/Extensions/QEMUMetal.bundle'

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module
disk_in_use = import_module('install-app').disk_in_use


def run(*cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def build():
    os.makedirs(BUNDLE, exist_ok=True)
    run('xcrun', '-sdk', 'iphoneos', 'clang', '-arch', 'arm64', '-mios-version-min=16.0', '-fobjc-arc',
        '-Os', '-Wall', '-bundle', '-framework', 'Foundation', '-framework', 'Metal', '-framework', 'IOKit',
        '-o', os.path.join(BUNDLE, 'QEMUMetal'), os.path.join(SRC, 'QEMUMetal.m'))
    shutil.copyfile(os.path.join(SRC, 'Info.plist'), os.path.join(BUNDLE, 'Info.plist'))
    run('codesign', '-f', '-s', '-', BUNDLE, stderr=subprocess.DEVNULL)


def setup(disk):
    if sys.platform != 'darwin':
        sys.exit('setup needs macOS (Xcode for the iOS SDK, hdiutil for the disk)')
    if disk_in_use(disk):
        sys.exit(f'{disk} is in use by a running VM; stop it first')
    build()
    dev = run('hdiutil', 'attach', '-nomount', '-imagekey', 'diskimage-class=CRawDiskImage', disk,
              capture_output=True, text=True).stdout.split()[0]
    mnt = tempfile.mkdtemp(prefix='ios-qemu-')
    try:
        run('fsck_hfs', '-fy', dev.replace('/dev/', '/dev/r') + 's1', stdout=subprocess.DEVNULL)
        run('mount', '-t', 'hfs', '-o', 'noowners', dev + 's1', mnt)
        try:
            dst = os.path.join(mnt, GUEST_PATH)
            shutil.rmtree(dst, ignore_errors=True)
            shutil.copytree(BUNDLE, dst)
            print(f'{disk}: /{GUEST_PATH} installed; boot with --bootargs "sweetmetal=1"')
        finally:
            run('umount', mnt)
    finally:
        run('hdiutil', 'detach', dev, stdout=subprocess.DEVNULL)
        os.rmdir(mnt)


if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] != 'setup':
        sys.exit(__doc__)
    setup(sys.argv[2])
