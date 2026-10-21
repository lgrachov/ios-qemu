#!/usr/bin/env bash
# Boot the local kernel in QEMU with a live display window.
#
#   ./harness.sh [--secs N] [--no-display] [--hvf] [--ios DISK] [--kernel PATH] [-- extra qemu-sweet.py args]
#
# Rebuilds the QEMU ADT and payload when they are missing or older than the
# kernel, then runs tools/qemu-sweet.py. --hvf uses Apple Silicon hardware
# virtualization (its own ADT with the host timer frequency). --ios DISK boots
# the iOS root on DISK (tools/mkiosroot-mac.sh disk.img) over emulated UFS with
# the phone's boot-args (implies --hvf). Results (fb.png, fb.txt, result.json)
# go to research/qemu-local/run-<timestamp>/ (research/ is not in git).
set -euo pipefail
cd "$(dirname "$0")"

KERNEL=xnu/out-local/kernel.development.sweet
SECS=150
DISPLAY_ARG=--display
HVF=
IOS_DISK=
CMDLINE='debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress'
EXTRA=()

while [ $# -gt 0 ]; do
	case $1 in
	--secs) SECS=$2; shift 2 ;;
	--kernel) KERNEL=$2; shift 2 ;;
	--no-display) DISPLAY_ARG=; shift ;;
	--hvf) HVF=--hvf; shift ;;
	--ios) IOS_DISK=$2; HVF=--hvf; shift 2 ;;
	--) shift; EXTRA=("$@"); break ;;
	-h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "unknown option: $1 (see --help)" >&2; exit 1 ;;
	esac
done

[ -f "$KERNEL" ] || { echo "no kernel at $KERNEL (download the xnu-kernel CI artifact into xnu/out-local)" >&2; exit 1; }

W=research/qemu-local
ADT=$W/q${HVF:+-hvf}.adt PAYLOAD=$W/payload${HVF:+-hvf}.bin
ADT_ARGS="--qemu $HVF" QEMU_ARGS=()
if [ -n "$IOS_DISK" ]; then
	[ -f "$IOS_DISK" ] || { echo "no disk image at $IOS_DISK" >&2; exit 1; }
	ADT=$W/q-ios.adt PAYLOAD=$W/payload-ios.bin ADT_ARGS="--hvf --qemu-ufs --highmem" QEMU_ARGS=(--ufs "$IOS_DISK")
	# the phone's boot-args (NOTES.md), cpus=1
	CMDLINE="$CMDLINE rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1"
fi
mkdir -p "$W"
if [ ! -f "$ADT" ] || [ tools/mkadt.py -nt "$ADT" ]; then
	python3 tools/mkadt.py "$ADT" $ADT_ARGS
fi
if [ ! -f "$PAYLOAD" ] || [ "$KERNEL" -nt "$PAYLOAD" ] || [ "$ADT" -nt "$PAYLOAD" ] \
	|| [ "$(cat "$PAYLOAD.kernel" 2>/dev/null)" != "$KERNEL $CMDLINE" ]; then
	python3 tools/mkpayload.py "$KERNEL" "$ADT" "$PAYLOAD" --cmdline "$CMDLINE" >/dev/null
	echo "$KERNEL $CMDLINE" > "$PAYLOAD.kernel"
fi

# llvm-nm (for decoding the screen into fb.txt): Homebrew llvm, else Xcode's
for d in /opt/homebrew/opt/llvm/bin /usr/local/opt/llvm/bin \
	"$(dirname "$(xcrun -f llvm-nm 2>/dev/null || echo /nonexistent/x)")"; do
	[ -x "$d/llvm-nm" ] && { PATH=$d:$PATH; break; }
done

OUT=$W/run-$(date +%Y%m%d-%H%M%S)
echo "running $KERNEL for ${SECS}s -> $OUT"
python3 tools/qemu-sweet.py "$PAYLOAD" "$OUT" --secs "$SECS" --kernel "$KERNEL" \
	$DISPLAY_ARG $HVF ${QEMU_ARGS[@]+"${QEMU_ARGS[@]}"} ${EXTRA[@]+"${EXTRA[@]}"}
