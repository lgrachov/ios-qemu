#!/usr/bin/env bash
# Boot the local kernel in QEMU with a live display window.
#
#   ./harness.sh [--secs N] [--no-display] [--hvf] [--ios DISK] [--cpus N] [--bootargs "..."] [--kernel PATH] [-- extra qemu-sweet.py args]
#
# Rebuilds the QEMU ADT and payload when they are missing or older than the
# kernel, then runs tools/qemu-sweet.py. --hvf uses Apple Silicon hardware
# virtualization (its own ADT with the host timer frequency). --ios DISK boots
# the iOS root on DISK (tools/mkiosroot-mac.sh disk.img) over emulated UFS with
# the phone's boot-args (implies --hvf); click/drag in the window = touch,
# typing = a hardware keyboard, Ctrl+Option+P power, Ctrl+Option+H/Esc home,
# Ctrl+Option+Up/Down volume (patches 0084, 0089). --cpus N: vCPUs (default 4
# with --ios, else 1; the kernel needs 0097 for N > 1). Results (fb.png, fb.txt, result.json)
# go to research/qemu-local/run-<timestamp>/ (research/ is not in git).
set -euo pipefail
cd "$(dirname "$0")"

KERNEL=xnu/out-local/kernel.development.sweet
SECS=150
DISPLAY_ARG=--display
HVF=
IOS_DISK=
CPUS=
CMDLINE='debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress'
EXTRA=()
MORE_ARGS=

while [ $# -gt 0 ]; do
	case $1 in
	--secs) SECS=$2; shift 2 ;;
	--kernel) KERNEL=$2; shift 2 ;;
	--bootargs) MORE_ARGS=$2; shift 2 ;;
	--cpus) CPUS=$2; shift 2 ;;
	--no-display) DISPLAY_ARG=; shift ;;
	--hvf) HVF=--hvf; shift ;;
	--ios) IOS_DISK=$2; HVF=--hvf; shift 2 ;;
	--) shift; EXTRA=("$@"); break ;;
	-h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "unknown option: $1 (see --help)" >&2; exit 1 ;;
	esac
done

[ -f "$KERNEL" ] || { echo "no kernel at $KERNEL (download the xnu-kernel CI artifact into xnu/out-local)" >&2; exit 1; }

W=research/qemu-local
ADT=$W/q${HVF:+-hvf}.adt PAYLOAD=$W/payload${HVF:+-hvf}.bin
ADT_ARGS="--qemu $HVF" QEMU_ARGS=()
if [ -n "$IOS_DISK" ]; then
	[ -f "$IOS_DISK" ] || { echo "no disk image at $IOS_DISK" >&2; exit 1; }
	ADT=$W/q-ios.adt PAYLOAD=$W/payload-ios.bin ADT_ARGS="--hvf --qemu-ufs --qemu-fullfb --highmem" QEMU_ARGS=(--ufs "$IOS_DISK" --fullfb)
	# the phone's boot-args (NOTES.md); cpus= follows --cpus
	CMDLINE="$CMDLINE rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30 sweetvinput=1 sweetvnet=1 sweettouch=0"
fi
[ -n "$CPUS" ] || { [ -n "$IOS_DISK" ] && CPUS=4 || CPUS=1; }
ADT_ARGS="$ADT_ARGS --cpus $CPUS" CMDLINE=${CMDLINE/cpus=1/cpus=$CPUS}
QEMU_ARGS+=(--smp "$CPUS")
mkdir -p "$W"
[ -z "$MORE_ARGS" ] || CMDLINE="$CMDLINE $MORE_ARGS"
if [ ! -f "$ADT" ] || [ tools/mkadt.py -nt "$ADT" ] || [ "$(cat "$ADT.args" 2>/dev/null)" != "$ADT_ARGS" ]; then
	python3 tools/mkadt.py "$ADT" $ADT_ARGS
	echo "$ADT_ARGS" > "$ADT.args"
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
