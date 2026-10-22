#!/bin/sh
# Build the test app as research/guest/HelloQEMU.ipa (macOS + Xcode iOS SDK).
# Its label text comes from an embedded @rpath framework (HelloKit).
set -e
cd "$(dirname "$0")"
OUT=../../../research/guest
APP=$OUT/Payload/HelloQEMU.app
rm -rf "$OUT/Payload" && mkdir -p "$APP"
FW=$APP/Frameworks/HelloKit.framework
CC="xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -fobjc-arc -Os"
mkdir -p "$FW"
$CC -dynamiclib -install_name @rpath/HelloKit.framework/HelloKit \
	-framework Foundation -o "$FW/HelloKit" HelloKit.m
cp HelloKit-Info.plist "$FW/Info.plist"
$CC -framework UIKit -framework Foundation -F "$APP/Frameworks" \
	-Wl,-rpath,@executable_path/Frameworks "$FW/HelloKit" -o "$APP/HelloQEMU" main.m
cp Info.plist "$APP/"
codesign -f -s - "$FW"
codesign -f -s - "$APP"
(cd "$OUT" && rm -f HelloQEMU.ipa && zip -qr HelloQEMU.ipa Payload)
echo "$OUT/HelloQEMU.ipa"
