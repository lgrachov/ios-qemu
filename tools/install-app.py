#!/usr/bin/env python3
"""Install and remove user apps in the running iOS guest (optional add-on).

  install-app.py setup DISK            add the installer to a guest disk (macOS + Xcode,
                                       VM stopped); booting never needs this
  install-app.py install APP.ipa       install into the running guest
  install-app.py uninstall BUNDLE_ID   remove an app (or long-press it on the home screen)

setup builds tools/guest/qemu-appinstalld.m with the iOS SDK (ad-hoc signed
with tools/guest/entitlements.plist; the SWEET AMFI accepts any signature),
copies it to /usr/local/libexec/qemu-appinstalld on DISK and adds a launchd
job that runs it per connection on 127.0.0.1:62080 in the guest. install and
uninstall reach that port through the guest kernel's mux relay (patch 0100,
host 127.0.0.1:62079 via qemu-sweet.py --mux-port) and work on any host OS.
Apps install as user apps (/var/containers/Bundle/Application) and need to
support iOS 16 on arm64 (iPhone X); App Store apps are FairPlay-encrypted and
will not run.
"""
import argparse, os, plistlib, re, shutil, socket, struct, subprocess, sys, tempfile, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUEST_SRC = os.path.join(ROOT, 'tools/guest/qemu-appinstalld.m')
GUEST_ENTS = os.path.join(ROOT, 'tools/guest/entitlements.plist')
GUEST_BIN = os.path.join(ROOT, 'research/guest/qemu-appinstalld')
GUEST_PATH = 'usr/local/libexec/qemu-appinstalld'
GUEST_PORT = 62080
JOB_KEY = '/System/Library/LaunchDaemons/com.ios-qemu.appinstalld.plist'
JOB = {
    'Label': 'com.ios-qemu.appinstalld',
    'ProgramArguments': ['/' + GUEST_PATH],
    'inetdCompatibility': {'Wait': False},
    'Sockets': {'Listener': {'SockNodeName': '127.0.0.1', 'SockServiceName': str(GUEST_PORT),
                             'SockType': 'stream', 'SockFamily': 'IPv4'}},
}
ECONNREFUSED = 61


def run(*cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def build():
    os.makedirs(os.path.dirname(GUEST_BIN), exist_ok=True)
    run('xcrun', '-sdk', 'iphoneos', 'clang', '-arch', 'arm64', '-mios-version-min=16.0', '-fobjc-arc',
        '-Os', '-framework', 'Foundation', '-o', GUEST_BIN, GUEST_SRC)
    run('codesign', '-f', '-s', '-', '--entitlements', GUEST_ENTS, GUEST_BIN, stderr=subprocess.DEVNULL)


def disk_in_use(disk):
    real = os.path.realpath(disk)
    out = subprocess.run(['ps', '-axo', 'command='], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if 'qemu-system' in line:
            m = re.search(r'file=([^,\s]+)', line)
            if m and os.path.realpath(m.group(1)) == real:
                return True
    return False


def setup(disk):
    if sys.platform != 'darwin':
        sys.exit('setup needs macOS (Xcode for the iOS SDK, hdiutil for the disk); '
                 'the VM itself boots without the installer')
    if subprocess.run(['xcrun', '-sdk', 'iphoneos', '--show-sdk-path'], capture_output=True).returncode:
        sys.exit('setup needs Xcode with the iOS SDK (xcrun -sdk iphoneos)')
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
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(GUEST_BIN, dst)
            os.chmod(dst, 0o755)
            # edit launchd.plist in place: same inode keeps its owner and mode
            with open(os.path.join(mnt, 'System/Library/xpc/launchd.plist'), 'r+b') as f:
                plist = plistlib.load(f)
                plist['LaunchDaemons'][JOB_KEY] = JOB
                f.seek(0)
                f.write(plistlib.dumps(plist, fmt=plistlib.FMT_BINARY))
                f.truncate()
            print(f'{disk}: installer added (/{GUEST_PATH}, launchd job {JOB["Label"]} on 127.0.0.1:{GUEST_PORT})')
        finally:
            run('umount', mnt)
    finally:
        run('hdiutil', 'detach', dev, stdout=subprocess.DEVNULL)
        os.rmdir(mnt)


def connect(mux_port):
    try:
        s = socket.create_connection(('127.0.0.1', mux_port), timeout=10)
    except OSError as e:
        sys.exit(f'cannot reach the guest mux relay on 127.0.0.1:{mux_port} ({e}); is the VM running?')
    s.sendall(struct.pack('>H', GUEST_PORT))
    status = s.recv(1)
    if status != b'\0':
        code = status[0] if status else None
        if code == ECONNREFUSED:
            sys.exit('the installer is not on this disk: run `install-app.py setup DISK` on a Mac with the VM stopped')
        sys.exit(f'guest port {GUEST_PORT}: error {code}')
    s.settimeout(None)
    return s


def talk(s, header, payload=b''):
    s.sendall(header.encode() + b'\n' + payload)
    ok = False
    for line in s.makefile('r', encoding='utf-8', errors='replace'):
        line = line.rstrip('\n')
        print(line)
        ok = line == 'OK'
    return 0 if ok else 1


def bundle_id(ipa):
    with zipfile.ZipFile(ipa) as z:
        names = [n for n in z.namelist() if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', n)]
        if not names:
            sys.exit(f'{ipa}: no Payload/*.app/Info.plist')
        info = plistlib.loads(z.read(names[0]))
    minos = info.get('MinimumOSVersion', '0')
    if tuple(int(x) for x in re.findall(r'\d+', minos)[:2]) > (16, 7):
        print(f'warning: MinimumOSVersion {minos}, the guest runs iOS 16.7', file=sys.stderr)
    return info['CFBundleIdentifier']


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--mux-port', type=int, default=62079, help='host port of the guest mux relay')
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('setup').add_argument('disk')
    sub.add_parser('install').add_argument('ipa')
    sub.add_parser('uninstall').add_argument('bundle_id')
    a = ap.parse_args()
    if a.cmd == 'setup':
        setup(a.disk)
        return 0
    if a.cmd == 'install':
        bid = bundle_id(a.ipa)
        with open(a.ipa, 'rb') as f:
            data = f.read()
        print(f'installing {bid} ({len(data)} bytes)')
        return talk(connect(a.mux_port), f'INSTALL {bid} {len(data)}', data)
    return talk(connect(a.mux_port), f'UNINSTALL {a.bundle_id}')


if __name__ == '__main__':
    sys.exit(main())
