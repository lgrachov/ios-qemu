#!/usr/bin/env python3
"""Add the guest's CPU fallbacks (tools/guest/qemu-cpu) to an iOS guest disk.

  cpu-shims.py setup DISK     build libQEMUCPU.dylib (macOS + Xcode) and copy it
                              to /usr/lib/qemu/libQEMUCPU.dylib on DISK
  cpu-shims.py remove DISK    delete it again

The VM must be stopped. The iOS 18 kernel (patches-15.6/0115) inserts the
library into every process through DYLD_INSERT_LIBRARIES; without the file
dyld just skips it. Log: /private/var/tmp/QEMUCPU.log (cleared by setup) and
os_log.
"""
import os, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'tools/guest/qemu-cpu/QEMUCPU.m')
OUT = os.path.join(ROOT, 'research/guest/libQEMUCPU.dylib')
GUEST_PATH = 'usr/lib/qemu/libQEMUCPU.dylib'

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module
with_disk = import_module('audio-plugin').with_disk


def run(*cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def build():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    # arm64e for iOS 18 (every process is arm64e), arm64 for third-party apps
    run('xcrun', '-sdk', 'iphoneos', 'clang', '-arch', 'arm64', '-arch', 'arm64e', '-mios-version-min=16.0',
        '-Os', '-Wall', '-Wl,-no_warn_inits', '-dynamiclib', '-install_name', '/' + GUEST_PATH, '-lobjc', '-o', OUT, SRC)
    run('codesign', '-f', '-s', '-', OUT, stderr=subprocess.DEVNULL)


def setup(mnt):
    dst = os.path.join(mnt, GUEST_PATH)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(OUT, dst)
    os.chmod(dst, 0o755)
    log = os.path.join(mnt, 'private/var/tmp/QEMUCPU.log')
    if os.path.exists(log):
        open(log, 'w').close()
    print(f'/{GUEST_PATH} installed')


def remove(mnt):
    dst = os.path.join(mnt, GUEST_PATH)
    if os.path.exists(dst):
        os.remove(dst)
    print(f'/{GUEST_PATH} removed')


if __name__ == '__main__':
    args = sys.argv[1:]
    if len(args) != 2 or args[0] not in ('setup', 'remove'):
        sys.exit(__doc__)
    if args[0] == 'setup':
        build()
        with_disk(args[1], setup)
    else:
        with_disk(args[1], remove)
