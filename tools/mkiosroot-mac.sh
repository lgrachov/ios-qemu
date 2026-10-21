#!/bin/bash
# macOS version of tools/mkiosroot.sh + tools/sweet-root-tweaks.py: build the
# SWEET iOS root (case-sensitive journaled HFS+, OS root plus its cryptexes)
# from the IPSW images, then wrap it as a UFS disk for qemu-sweet.py --ufs.
#
#   sudo mkiosroot-mac.sh OS.dmg SYSTEMOS.dmg APPOS.dmg OUT_DIR [SIZE]   (SIZE default 16g)
#
# Writes OUT_DIR/root.hfs (the volume: the same thing mkiosroot.sh makes for
# the phone's userdata) and OUT_DIR/disk.img (4 KiB-sector GPT "userdata"
# around it, tools/mkufsdisk.py). `ipsw info IPSW` names the three images.
# The APFS images mount natively; files are copied with GNU rsync
# (brew install rsync), which reads them decompressed (the SWEET kernel has
# no LZBITMAP decompressor) and keeps owners, modes and hard links.
# See mkiosroot.sh for why each extra step is there.
set -euo pipefail
[[ $# -ge 4 ]] || { sed -n '2,13p' "$0"; exit 2; }
[[ $EUID == 0 ]] || { echo "run as root (sudo): the copy keeps root/mobile/_logd ownership" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
os=$1 sysos=$2 appos=$3 outdir=$4 size=${5:-16g}
RSYNC=/opt/homebrew/bin/rsync
[[ -x $RSYNC ]] || RSYNC=/usr/local/bin/rsync
[[ -x $RSYNC ]] || { echo "GNU rsync not found: brew install rsync" >&2; exit 1; }
mkdir -p "$outdir"
img=$outdir/root.hfs disk=$outdir/disk.img
[[ ! -e $img && ! -e $disk ]] || { echo "refusing to overwrite $img / $disk" >&2; exit 1; }

work=$(mktemp -d /tmp/mkiosroot.XXXXXX)
mounts=() devs=()
cleanup() {
	for m in ${mounts[@]+"${mounts[@]}"}; do umount "$m" 2>/dev/null || true; done
	for d in ${devs[@]+"${devs[@]}"}; do hdiutil detach -force "$d" >/dev/null 2>&1 || true; done
	rmdir "$work"/* "$work" 2>/dev/null || echo "left $work in place" >&2
}
trap cleanup EXIT

attach_ro() {	# DMG NAME
	mkdir "$work/$2"
	local dev
	dev=$(hdiutil attach -readonly -nobrowse -owners on -mountpoint "$work/$2" "$1" | awk 'NR==1{print $1}')
	devs+=("$dev")
}
attach_ro "$os" os
attach_ro "$sysos" sysos
attach_ro "$appos" appos

mkfile -n "$size" "$img"
dev=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$img" | awk 'NR==1{print $1}')
devs=("$dev" ${devs[@]+"${devs[@]}"})
newfs_hfs -s -J -v iOSRoot "$dev"
mkdir "$work/root"
mount -t hfs "$dev" "$work/root"
mounts+=("$work/root")
diskutil enableOwnership "$work/root" >/dev/null
root=$work/root

copy() {
	echo "copying $1 -> ${2#"$root"}"
	mkdir -p "$2"
	"$RSYNC" -aH --numeric-ids "$1/" "$2/"
}
copy "$work/os" "$root"
copy "$work/sysos" "$root/private/preboot/Cryptexes/OS"
copy "$work/appos" "$root/private/preboot/Cryptexes/App"

# Shared cache where dyld looks at ignition level 1: hard links, no extra space.
dsc=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
mkdir -p "$root/System/Library/Caches/com.apple.dyld"
for f in "$root/$dsc"/*; do
	ln "$f" "$root/System/Library/Caches/com.apple.dyld/${f##*/}"
done

# Cryptex files with no counterpart in the OS root: link them to their root path.
for c in OS App; do
	(cd "$root/private/preboot/Cryptexes/$c" && find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*') |
	while IFS= read -r f; do
		f=${f#./}
		if [[ ! -e $root/$f && ! -L $root/$f ]]; then
			mkdir -p "$root/$(dirname "$f")"
			src=$root/private/preboot/Cryptexes/$c/$f
			if [[ -L $src ]]; then cp -P "$src" "$root/$f"; else ln "$src" "$root/$f"; fi
			echo "linked $c:/$f"
		fi
	done
done

# logd's log stores (owner _logd 272) and their .migrated markers.
db=$root/private/var/db
install -d -o 272 -g 272 -m 0751 "$db/diagnostics"
install -d -o 272 -g 272 -m 0755 "$db/uuidtext" "$db/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
	install -o 272 -g 272 -m 0644 /dev/null "$db/$d/.migrated"
done

# System keybag for the built-in AppleKeyStore (no passcode).
install -d -m 0700 -o 0 -g 0 "$root/private/var/keybags"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' >"$root/private/var/keybags/systembag.kb"
chown 0:0 "$root/private/var/keybags/systembag.kb"
chmod 0600 "$root/private/var/keybags/systembag.kb"

python3 -I "$here/sweet-root-tweaks.py" "$root"

stat -f '%Su:%Sg %N' "$root/sbin/launchd" "$root/private/var/mobile" "$db/diagnostics"
df -h "$root"
umount "$root"
mounts=()
fsck_hfs -fn "$dev"
hdiutil detach "$dev" >/dev/null
devs=("${devs[@]:1}")

python3 -I "$here/mkufsdisk.py" "$disk" "$img"
chown "${SUDO_UID:-0}:${SUDO_GID:-0}" "$img" "$disk"
