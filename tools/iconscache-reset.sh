#!/bin/bash
# Move the guest's icon cache aside so iconservicesagent renders every icon
# again (it serves cached results, including blank icons from boots where
# rendering failed: iOS 18 Settings rows stayed blank after the fixes).
#
#   sudo tools/iconscache-reset.sh research/iosroot-xs18/disk.img
#
# The cache (systemgroup.com.apple.lsd.iconscache) is mode 000 with an ACL
# for the guest's _iconservices group, hence root. Its contents go to
# com.apple.IconsCache.old/<date-time> next to it (undo: move them back).
# Stop the VM first.
set -euo pipefail
[[ $# == 1 ]] || { sed -n '2,11p' "$0"; exit 2; }
[[ $EUID == 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
[[ -f $1 ]] || { echo "no such disk image: $1" >&2; exit 1; }
disk=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
if pgrep -f "qemu-system-aarch64.*file=$disk" >/dev/null; then
	echo "a VM is using $disk: stop it first" >&2
	exit 1
fi
dev=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$disk" | awk 'NR == 1 {print $1}')
mnt=$(mktemp -d /tmp/iosroot.XXXXXX)
cleanup() {
	umount "$mnt" 2>/dev/null || true
	hdiutil detach "$dev" >/dev/null 2>&1 || true
	rmdir "$mnt" 2>/dev/null || true
}
trap cleanup EXIT
fsck_hfs -fy "${dev/disk/rdisk}s1" | tail -1
mount -t hfs "${dev}s1" "$mnt"
cache=$mnt/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.lsd.iconscache/Library/Caches/com.apple.IconsCache
[[ -d $cache ]] || { echo "no icon cache on $disk" >&2; exit 1; }
echo "$(find "$cache" -type f | wc -l | tr -d ' ') files, $(du -sh "$cache" | cut -f1)"
old=$cache.old/$(date +%Y%m%d-%H%M%S)
mkdir -p "$old"
find "$cache" -mindepth 1 -maxdepth 1 -exec mv {} "$old/" \;
echo "moved to com.apple.IconsCache.old/$(basename "$old")"
