#!/bin/sh
# Builds build/TildeDriver.app, the input and screenshot driver for real-screen tests.
# Launch it with `open build/TildeDriver.app`; it asks for Accessibility and Screen Recording.
set -eu

cd "$(dirname "$0")/.."
swift build -c release --product tilde-driver
bin="$(swift build -c release --show-bin-path)"

app="build/TildeDriver.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/tilde-driver" "$app/Contents/MacOS/TildeDriver"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.tilde.driver</string>
  <key>CFBundleName</key><string>TildeDriver</string>
  <key>CFBundleExecutable</key><string>TildeDriver</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier dev.tilde.driver "$app"
echo "Built $app"
