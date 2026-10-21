#!/usr/bin/env bash
# Boot the local kernel in QEMU with a live display window.
#
#   ./harness.sh [--secs N] [--no-display] [--hvf] [--kernel PATH] [-- extra qemu-sweet.py args]
#
# Rebuilds the QEMU ADT and payload when they are missing or older than the
# kernel, then runs tools/qemu-sweet.py. --hvf uses Apple Silicon hardware
# virtualization (its own ADT with the host timer frequency). Results (fb.png, fb.txt, result.json)
# go to research/qemu-local/run-<timestamp>/ (research/ is not in git).
set -euo pipefail
cd "$(dirname "$0")"

KERNEL=xnu/out-local/kernel.development.sweet
SECS=150
DISPLAY_ARG=--display
HVF=
CMDLINE='debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress'
EXTRA=()

while [ $# -gt 0 ]; do
	case $1 in
	--secs) SECS=$2; shift 2 ;;
	--kernel) KERNEL=$2; shift 2 ;;
	--no-display) DISPLAY_ARG=; shift ;;
	--hvf) HVF=--hvf; shift ;;
	--) shift; EXTRA=("$@"); break ;;
	-h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "unknown option: $1 (see --help)" >&2; exit 1 ;;
	esac
done

[ -f "$KERNEL" ] || { echo "no kernel at $KERNEL (download the xnu-kernel CI artifact into xnu/out-local)" >&2; exit 1; }

W=research/qemu-local
ADT=$W/q${HVF:+-hvf}.adt PAYLOAD=$W/payload${HVF:+-hvf}.bin
mkdir -p "$W"
if [ ! -f "$ADT" ] || [ tools/mkadt.py -nt "$ADT" ]; then
	python3 tools/mkadt.py "$ADT" --qemu $HVF
fi
if [ ! -f "$PAYLOAD" ] || [ "$KERNEL" -nt "$PAYLOAD" ] || [ "$ADT" -nt "$PAYLOAD" ] \
	|| [ "$(cat "$PAYLOAD.kernel" 2>/dev/null)" != "$KERNEL" ]; then
	python3 tools/mkpayload.py "$KERNEL" "$ADT" "$PAYLOAD" --cmdline "$CMDLINE" >/dev/null
	echo "$KERNEL" > "$PAYLOAD.kernel"
fi

# llvm-nm (for decoding the screen into fb.txt): Homebrew llvm, else Xcode's
for d in /opt/homebrew/opt/llvm/bin /usr/local/opt/llvm/bin \
	"$(dirname "$(xcrun -f llvm-nm 2>/dev/null || echo /nonexistent/x)")"; do
	[ -x "$d/llvm-nm" ] && { PATH=$d:$PATH; break; }
done

OUT=$W/run-$(date +%Y%m%d-%H%M%S)
echo "running $KERNEL for ${SECS}s -> $OUT"
python3 tools/qemu-sweet.py "$PAYLOAD" "$OUT" --secs "$SECS" --kernel "$KERNEL" \
	$DISPLAY_ARG $HVF ${EXTRA[@]+"${EXTRA[@]}"}
