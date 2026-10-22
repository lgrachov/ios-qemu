#!/bin/sh
# Build the test app as research/guest/HelloQEMU.ipa (macOS + Xcode iOS SDK).
set -e
cd "$(dirname "$0")"
OUT=../../../research/guest
APP=$OUT/Payload/HelloQEMU.app
rm -rf "$OUT/Payload" && mkdir -p "$APP"
xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -fobjc-arc -Os \
	-framework UIKit -framework Foundation -o "$APP/HelloQEMU" main.m
cp Info.plist "$APP/"
codesign -f -s - "$APP"
(cd "$OUT" && rm -f HelloQEMU.ipa && zip -qr HelloQEMU.ipa Payload)
echo "$OUT/HelloQEMU.ipa"
