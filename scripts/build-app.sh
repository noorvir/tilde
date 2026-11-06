#!/bin/sh
# Builds build/Tilde.app (menu-bar app plus the tilde-mcp stdio shim) and signs it ad hoc.
# TILDE_BUNDLE_TPROXY=1 (dev builds) puts the tproxy files in it, built with Go, or the ones in
# proxy/dist where there is no Go; without it, Tilde downloads them from its version's release.
# TILDE_UNIVERSAL=1 (the release) builds Tilde and tilde-mcp for Apple silicon and Intel Macs;
# without it, for this Mac only.
set -eu

cd "$(dirname "$0")/.."
configuration="${1:-release}"

archs=$(uname -m)
if [ "${TILDE_UNIVERSAL:-}" = 1 ]; then
    archs="arm64 x86_64"
fi
for arch in $archs; do
    swift build -c "$configuration" --arch "$arch" --product Tilde
    swift build -c "$configuration" --arch "$arch" --product tilde-mcp
    scripts/stamp-sdk.sh "$(swift build -c "$configuration" --arch "$arch" --show-bin-path)/Tilde"
done
swift build -c "$configuration" --product tilde-icon
bin="$(swift build -c "$configuration" --show-bin-path)"

app="build/Tilde.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
for tool in Tilde tilde-mcp; do
    lipo -create -output "$app/Contents/MacOS/$tool" $(for arch in $archs; do echo "$(swift build -c "$configuration" --arch "$arch" --show-bin-path)/$tool"; done)
done
cp Sources/TildeUI/DrawingWeb/* "$app/Contents/Resources/"
if [ "${TILDE_BUNDLE_TPROXY:-}" = 1 ]; then
    if command -v go >/dev/null; then
        proxy/build.sh
    fi
    mkdir "$app/Contents/Resources/tproxy"
    cp proxy/dist/tproxy-* "$app/Contents/Resources/tproxy/"
fi

iconset="build/AppIcon.iconset"
rm -rf "$iconset"
"$bin/tilde-icon" "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.tilde.app</string>
  <key>CFBundleName</key><string>Tilde</string>
  <key>CFBundleDisplayName</key><string>Tilde</string>
  <key>CFBundleExecutable</key><string>Tilde</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>Tilde records the screen of an iPhone connected by cable.</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

# The build number counts the commits, so each build of a newer commit sorts higher.
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
sed -i '' "s/BUILD_NUMBER/$build_number/" "$app/Contents/Info.plist"

# Ad-hoc signatures normally pin macOS privacy permissions to one exact build. An explicit
# designated requirement keeps Screen Recording and Accessibility grants across rebuilds.
codesign --force --sign - --identifier dev.tilde.mcp "$app/Contents/MacOS/tilde-mcp"
codesign --force --sign - --identifier dev.tilde.app -r='designated => identifier "dev.tilde.app"' "$app"
echo "Built $app"
