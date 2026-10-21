#!/usr/bin/env bash
# Boot the local kernel in QEMU with a live display window.
#
#   ./harness.sh [--secs N] [--no-display] [--kernel PATH] [-- extra qemu-sweet.py args]
#
# Rebuilds the QEMU ADT and payload when they are missing or older than the
# kernel, then runs tools/qemu-sweet.py. Results (fb.png, fb.txt, result.json)
# go to research/qemu-local/run-<timestamp>/ (research/ is not in git).
set -euo pipefail
cd "$(dirname "$0")"

KERNEL=xnu/out-local/kernel.development.sweet
SECS=150
DISPLAY_ARG=--display
CMDLINE='debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress'
EXTRA=()

while [ $# -gt 0 ]; do
	case $1 in
	--secs) SECS=$2; shift 2 ;;
	--kernel) KERNEL=$2; shift 2 ;;
	--no-display) DISPLAY_ARG=; shift ;;
	--) shift; EXTRA=("$@"); break ;;
	-h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "unknown option: $1 (see --help)" >&2; exit 1 ;;
	esac
done

[ -f "$KERNEL" ] || { echo "no kernel at $KERNEL (download the xnu-kernel CI artifact into xnu/out-local)" >&2; exit 1; }

W=research/qemu-local
mkdir -p "$W"
if [ ! -f "$W/q.adt" ] || [ tools/mkadt.py -nt "$W/q.adt" ]; then
	python3 tools/mkadt.py "$W/q.adt" --qemu
fi
if [ ! -f "$W/payload.bin" ] || [ "$KERNEL" -nt "$W/payload.bin" ] || [ "$W/q.adt" -nt "$W/payload.bin" ] \
	|| [ "$(cat "$W/payload.kernel" 2>/dev/null)" != "$KERNEL" ]; then
	python3 tools/mkpayload.py "$KERNEL" "$W/q.adt" "$W/payload.bin" --cmdline "$CMDLINE" >/dev/null
	echo "$KERNEL" > "$W/payload.kernel"
fi

# llvm-nm (for decoding the screen into fb.txt): Homebrew llvm, else Xcode's
for d in /opt/homebrew/opt/llvm/bin /usr/local/opt/llvm/bin \
	"$(dirname "$(xcrun -f llvm-nm 2>/dev/null || echo /nonexistent/x)")"; do
	[ -x "$d/llvm-nm" ] && { PATH=$d:$PATH; break; }
done

OUT=$W/run-$(date +%Y%m%d-%H%M%S)
echo "running $KERNEL for ${SECS}s -> $OUT"
python3 tools/qemu-sweet.py "$W/payload.bin" "$OUT" --secs "$SECS" --kernel "$KERNEL" \
	$DISPLAY_ARG ${EXTRA[@]+"${EXTRA[@]}"}
