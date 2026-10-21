#!/bin/bash
# Re-apply tools/sweet-root-tweaks.py to the iOS root inside a qemu-sweet.py
# --ufs disk, in place (no copy).
#
#   sudo tools/iosroot-tweak.sh research/iosroot/disk.img
#
# Needs the 512-byte GPT from tools/mkufsdisk.py (--add-mac-gpt retrofits
# it). Stop the VM first. A hard-stopped guest leaves "Volume header needs
# minor repair", so the volume is checked and repaired (fsck_hfs -fy) before
# it is mounted with ownership enabled (the tweaks write root/mobile files).
set -euo pipefail
[[ $# == 1 ]] || { sed -n '2,10p' "$0"; exit 2; }
[[ $EUID == 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
disk=$1
if pgrep -f "qemu-system-aarch64.*$(basename "$disk")" >/dev/null; then
	echo "a VM is using $disk: stop it first" >&2
	exit 1
fi
dev=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$disk" | awk '$2 == "Apple_HFS" {print $1}')
[[ -n $dev ]] || { echo "no Apple_HFS partition (mkufsdisk.py --add-mac-gpt?)" >&2; exit 1; }
whole=${dev%s[0-9]*}
mnt=$(mktemp -d /tmp/iosroot.XXXXXX)
cleanup() {
	diskutil unmount "$mnt" >/dev/null 2>&1 || true
	hdiutil detach "$whole" >/dev/null 2>&1 || true
	rmdir "$mnt" 2>/dev/null || true
}
trap cleanup EXIT
fsck_hfs -fy "${dev/disk/rdisk}" | tail -1
diskutil mount -mountPoint "$mnt" "$dev" >/dev/null
diskutil enableOwnership "$mnt" >/dev/null
diskutil info "$mnt" | grep -q "Owners: *Enabled" || { echo "ownership not enabled on $mnt" >&2; exit 1; }
python3 -I "$here/sweet-root-tweaks.py" "$mnt"
stat -f '%Su:%Sg %Sp %N' "$mnt/System/Library/xpc/launchd.plist"
