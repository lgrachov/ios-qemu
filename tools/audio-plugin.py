#!/usr/bin/env python3
"""Add the guest audio driver (tools/guest/qemu-audio) to an iOS guest disk.

  audio-plugin.py setup DISK     build QEMUAudio.driver (macOS + Xcode), copy it to
                                 /System/Library/Audio/Plug-Ins/HAL on DISK and put
                                 VirtualAudio.plugin back in /Library/Audio/Plug-Ins/HAL
  audio-plugin.py setup --fake-vad DISK
                                 experiment: VirtualAudio.plugin stays disabled and the
                                 driver itself is VirtualAudioDevice_Default
  audio-plugin.py remove DISK    undo both (VirtualAudio.plugin back to HAL.disabled)

The VM must be stopped. sweet-root-tweaks.py moved VirtualAudio.plugin to
HAL.disabled because, with no audio device at all, it crashed mediaserverd;
QEMUAudio publishes the "Codec" device VirtualAudio builds its default device
from. Log: /private/var/tmp/QEMUAudio.log (cleared by setup) and os_log.
"""
import os, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'tools/guest/qemu-audio')
BUNDLE = os.path.join(ROOT, 'research/guest/QEMUAudio.driver')
GUEST_PATH = 'System/Library/Audio/Plug-Ins/HAL/QEMUAudio.driver'
VA_ON = 'Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin'
VA_OFF = 'Library/Audio/Plug-Ins/HAL.disabled/VirtualAudio.plugin'

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module
disk_in_use = import_module('install-app').disk_in_use


def run(*cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def build(fake_vad=False):
    os.makedirs(BUNDLE, exist_ok=True)
    # arm64 for the iPhone X userland, arm64e for the XS: an arm64e mediaserverd
    # only loads arm64e plug-ins
    run('xcrun', '-sdk', 'iphoneos', 'clang', '-arch', 'arm64', '-arch', 'arm64e', '-mios-version-min=16.0', '-Os', '-Wall', '-Wno-four-char-constants',
        '-DQEMUAUDIO_FAKE_VAD=%d' % fake_vad,
        '-bundle', '-framework', 'CoreFoundation', '-o', os.path.join(BUNDLE, 'QEMUAudio'),
        os.path.join(SRC, 'QEMUAudio.c'))
    shutil.copyfile(os.path.join(SRC, 'Info.plist'), os.path.join(BUNDLE, 'Info.plist'))
    run('codesign', '-f', '-s', '-', BUNDLE, stderr=subprocess.DEVNULL)


def move(src, dst):
    if os.path.exists(src) and not os.path.exists(dst):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        os.rename(src, dst)		# same volume: keeps owners and modes


def with_disk(disk, fn):
    if sys.platform != 'darwin':
        sys.exit('needs macOS (Xcode for the iOS SDK, hdiutil for the disk)')
    if disk_in_use(disk):
        sys.exit(f'{disk} is in use by a running VM; stop it first')
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


def setup(mnt, fake_vad=False):
    dst = os.path.join(mnt, GUEST_PATH)
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(BUNDLE, dst)
    if fake_vad:
        move(os.path.join(mnt, VA_ON), os.path.join(mnt, VA_OFF))
    else:
        move(os.path.join(mnt, VA_OFF), os.path.join(mnt, VA_ON))
    log = os.path.join(mnt, 'private/var/tmp/QEMUAudio.log')
    if os.path.exists(log):
        open(log, 'w').close()
    print(f'/{GUEST_PATH} installed, VirtualAudio.plugin enabled:',
          os.path.exists(os.path.join(mnt, VA_ON)))


def remove(mnt):
    shutil.rmtree(os.path.join(mnt, GUEST_PATH), ignore_errors=True)
    move(os.path.join(mnt, VA_ON), os.path.join(mnt, VA_OFF))
    print(f'/{GUEST_PATH} removed, VirtualAudio.plugin disabled again')


if __name__ == '__main__':
    args = sys.argv[1:]
    fake_vad = '--fake-vad' in args
    args = [a for a in args if a != '--fake-vad']
    if len(args) != 2 or args[0] not in ('setup', 'remove'):
        sys.exit(__doc__)
    if args[0] == 'setup':
        build(fake_vad)
        with_disk(args[1], lambda mnt: setup(mnt, fake_vad))
    else:
        with_disk(args[1], remove)
