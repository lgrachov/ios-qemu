#!/bin/sh
# Build VTTest as research/guest/VTTest.ipa (macOS + Xcode iOS SDK): a guest app
# that reports which video decoders work (tools/guest/vttest/main.m), with
# test clips made on the Mac by mkclips.m.
set -e
cd "$(dirname "$0")"
OUT=../../../research/guest
APP=$OUT/Payload/VTTest.app
rm -rf "$OUT/Payload" && mkdir -p "$APP"
xcrun clang -fobjc-arc -framework AVFoundation -framework CoreVideo -framework CoreMedia -framework Foundation \
	mkclips.m -o "$OUT/mkclips"
"$OUT/mkclips" "$APP"
xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -fobjc-arc -Os -Wall \
	-framework UIKit -framework Foundation -framework AVFoundation -framework VideoToolbox \
	-framework CoreMedia -framework CoreVideo -framework CoreGraphics -framework IOSurface -o "$APP/VTTest" main.m
cp Info.plist "$APP/"
codesign -f -s - "$APP"
(cd "$OUT" && rm -f VTTest.ipa && zip -qr VTTest.ipa Payload)
echo "$OUT/VTTest.ipa"
