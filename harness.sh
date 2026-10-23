#!/usr/bin/env bash
# Boot the local kernel in QEMU with a live display window.
#
#   ./harness.sh [--secs N] [--no-display] [--no-log] [--hvf] [--ios DISK] [--metal] [--cpus N] [--serial S] [--bootargs "..."] [--kernel PATH] [-- extra qemu-sweet.py args]
#
# Runs until the QEMU window is closed, the guest powers off or Ctrl-C (which
# still saves the screen); --secs N stops after N seconds instead.
# Rebuilds the QEMU ADT and payload when they are missing or older than the
# kernel, then runs tools/qemu-sweet.py. --hvf uses Apple Silicon hardware
# virtualization (its own ADT with the host timer frequency). --ios DISK boots
# the iOS root on DISK (tools/mkiosroot-mac.sh disk.img) over emulated UFS with
# the phone's boot-args (implies --hvf); click/drag in the window = touch,
# typing = a hardware keyboard, Ctrl+Option+P power, Ctrl+Option+H/Esc home,
# Ctrl+Option+Up/Down volume (patches 0084, 0089). --metal (with --ios, macOS,
# experimental): Metal remoting: boot-arg sweetmetal=1, shared memory for the
# guest's QEMUMetal.bundle (tools/metal-plugin.py setup DISK) and the host
# helper tools/host/qemu-metal-host.m, whose output goes to the run's
# metal-host.log (patches 0103/0104). --cpus N: vCPUs (default 4
# with --ios, else 1; the kernel needs 0097 for N > 1). --serial S: the
# device serial number (default QEMU00000001, tools/mkadt.py). The kernel log streams to
# the terminal (qemu-sweet.py --live-log; --no-log turns it off). Results (fb.png, fb.txt, result.json)
# go to research/qemu-local/run-<timestamp>/ (research/ is not in git).
set -euo pipefail
cd "$(dirname "$0")"

KERNEL=xnu/out-local/kernel.development.sweet
SECS=0
DISPLAY_ARG=--display
LOG_ARG=--live-log
HVF=
IOS_DISK=
METAL=
CPUS=
CMDLINE='debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress'
EXTRA=()
MORE_ARGS=
SERIAL=

while [ $# -gt 0 ]; do
	case $1 in
	--secs) SECS=$2; shift 2 ;;
	--kernel) KERNEL=$2; shift 2 ;;
	--bootargs) MORE_ARGS=$2; shift 2 ;;
	--cpus) CPUS=$2; shift 2 ;;
	--serial) SERIAL=$2; shift 2 ;;
	--no-display) DISPLAY_ARG=; shift ;;
	--no-log) LOG_ARG=; shift ;;
	--hvf) HVF=--hvf; shift ;;
	--ios) IOS_DISK=$2; HVF=--hvf; shift 2 ;;
	--metal) METAL=1; shift ;;
	--) shift; EXTRA=("$@"); break ;;
	-h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
	# the phone's boot-args (NOTES.md); cpus= follows --cpus. ml-timeout-global-scale:
	# hardware lock/spin timeouts x20, a vCPU can stall while the host runs
	# something else (pset lock "Ticket spinlock timeout" panic under load).
	CMDLINE="$CMDLINE rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30 sweetvinput=1 sweetvnet=1 sweettouch=0 ml-timeout-global-scale=20"
fi
[ -n "$CPUS" ] || { [ -n "$IOS_DISK" ] && CPUS=4 || CPUS=1; }
ADT_ARGS="$ADT_ARGS --cpus $CPUS" CMDLINE=${CMDLINE/cpus=1/cpus=$CPUS}
[ -z "$SERIAL" ] || ADT_ARGS="$ADT_ARGS --serial $SERIAL"
QEMU_ARGS+=(--smp "$CPUS")
mkdir -p "$W"
if [ -n "$METAL" ]; then
	[ -n "$IOS_DISK" ] || { echo "--metal needs --ios DISK" >&2; exit 1; }
	CMDLINE="$CMDLINE sweetmetal=1 sweetmetal_pa=0xa0000000"
fi
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
if [ -n "$METAL" ]; then
	HOST=$W/qemu-metal-host
	if [ ! -x "$HOST" ] || [ tools/host/qemu-metal-host.m -nt "$HOST" ] || [ tools/guest/qemu-metal/qmtl.h -nt "$HOST" ]; then
		xcrun clang -fobjc-arc -O2 -Wall -framework Foundation -framework Metal tools/host/qemu-metal-host.m -o "$HOST"
	fi
	mkdir -p "$OUT"
	SHM=$OUT/guest-ram	# all of guest RAM (sparse); deleted after the run
	"$HOST" "$SHM" > "$OUT/metal-host.log" 2>&1 &
	HOST_PID=$!
	trap 'kill $HOST_PID 2>/dev/null || true; rm -f "$SHM"' EXIT
	QEMU_ARGS+=(--metal "$SHM")
	echo "Metal host helper pid $HOST_PID, log $OUT/metal-host.log"
fi
if [ "$SECS" = 0 ]; then LIMIT="until Ctrl-C or the window closes"; else LIMIT="for ${SECS}s"; fi
echo "running $KERNEL $LIMIT -> $OUT"
python3 tools/qemu-sweet.py "$PAYLOAD" "$OUT" --secs "$SECS" --kernel "$KERNEL" \
	$DISPLAY_ARG $LOG_ARG $HVF ${QEMU_ARGS[@]+"${QEMU_ARGS[@]}"} ${EXTRA[@]+"${EXTRA[@]}"}
