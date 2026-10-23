#!/usr/bin/env bash
# Metal remoting self-test on the Mac (no VM): builds the guest bundle's code
# for macOS (-DQMTL_HOST_TEST), the host helper and a test shader, runs the
# helper on a scratch file laid out like guest RAM and renders through it
# (tools/host/qmtl-selftest.m). Prints PASS or FAIL.
set -euo pipefail
cd "$(dirname "$0")/../.."
T=$(mktemp -d)
HOST_PID=
trap 'kill $HOST_PID 2>/dev/null || true; rm -rf "$T"' EXIT
xcrun clang -fobjc-arc -O2 -Wall -framework Foundation -framework Metal tools/host/qemu-metal-host.m -o "$T/host"
xcrun clang -fobjc-arc -O1 -g -DQMTL_HOST_TEST -framework Foundation -framework Metal -framework IOKit -framework IOSurface \
	tools/guest/qemu-metal/QEMUMetal.m tools/guest/qemu-metal/QMTLObjects.m tools/host/qmtl-selftest.m -o "$T/selftest"
# the draw step needs Xcode's Metal toolchain (xcodebuild -downloadComponent MetalToolchain)
LIB=()
if xcrun -sdk macosx metal tools/host/qmtl-selftest.metal -o "$T/selftest.metallib" 2>/dev/null; then
	LIB=("$T/selftest.metallib")
else
	echo "no Metal toolchain: testing clear + blit only"
fi
# guest RAM 0x40000000.., Metal region at 0xa0000000 and the IOSurface pool
# up to 0x100000000 (qmtl.h): a sparse 3 GiB file
mkfile -n 3072m "$T/ram"
"$T/host" "$T/ram" > "$T/host.log" 2>&1 &
HOST_PID=$!
QMTL_TEST_FILE=$T/ram "$T/selftest" ${LIB[@]+"${LIB[@]}"} || { echo "--- host log"; cat "$T/host.log"; exit 1; }
