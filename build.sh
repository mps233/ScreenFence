#!/bin/bash
# Build ScreenLock.app into ~/Applications (ad-hoc signed)
set -e
cd "$(dirname "$0")"
APP="${APP:-$HOME/Applications/ScreenLock.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -o "$APP/Contents/MacOS/ScreenLock" main.swift \
  -framework Cocoa -framework Carbon -framework ApplicationServices
codesign --force --deep -s - "$APP"
xattr -cr "$APP"
echo "Built $APP"
