#!/bin/sh
# Builds build/Tilde.app (menu-bar app plus the tilde-mcp stdio shim) and signs it ad hoc, or
# with the identity in TILDE_SIGN_IDENTITY, such as "Developer ID Application: Name (TEAMID)".
# A real identity signs every executable with the hardened runtime, and a Developer ID one also
# with a secure timestamp, as notarization needs (see scripts/release.sh).
# The app icon is Resources/AppIcon.icon (Icon Composer), compiled by Xcode 26 or later; with
# only the Command Line Tools, the build has the flat Resources/AppIcon.icns.
# It holds tproxy for every node type, built with Go, or the ones in proxy/dist where there is
# no Go.
# TILDE_UNIVERSAL=1 (the release) builds Tilde and tilde-mcp for Apple silicon and Intel Macs;
# without it, for this Mac only.
set -eu

cd "$(dirname "$0")/.."
configuration="${1:-release}"
# scripts/release.sh changes this line.
version=0.2.0
identity="${TILDE_SIGN_IDENTITY:--}"
# The public half of the EdDSA key that signs updates (Sparkle's generate_keys prints it). An
# update that this key did not sign is refused. TILDE_UPDATE_PUBLIC_KEY replaces it for tests.
update_key="${TILDE_UPDATE_PUBLIC_KEY:-xiw+Yz3U0QaRnLRWa50R4xKdxMxiZIfR6f/MlvyyGX0=}"

archs=$(uname -m)
if [ "${TILDE_UNIVERSAL:-}" = 1 ]; then
    archs="arm64 x86_64"
fi
# Each architecture's binaries are copied out at once: newer toolchains put every architecture
# in the same products folder, so the next build replaces them.
stage=".build/app-binaries"
rm -rf "$stage"
for arch in $archs; do
    swift build -c "$configuration" --arch "$arch" --product Tilde
    swift build -c "$configuration" --arch "$arch" --product tilde-mcp
    bin="$(swift build -c "$configuration" --arch "$arch" --show-bin-path)"
    mkdir -p "$stage/$arch"
    cp "$bin/Tilde" "$bin/tilde-mcp" "$stage/$arch/"
    scripts/stamp-sdk.sh "$stage/$arch/Tilde"
done

app="build/Tilde.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
for tool in Tilde tilde-mcp; do
    lipo -create -output "$app/Contents/MacOS/$tool" $(for arch in $archs; do echo "$stage/$arch/$tool"; done)
done
cp Sources/TildeUI/DrawingWeb/* "$app/Contents/Resources/"
# Sparkle, without the XPC services that only sandboxed apps use.
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$app/Contents/Frameworks/Sparkle.framework/XPCServices"
if command -v go >/dev/null; then
    proxy/build.sh
fi
mkdir "$app/Contents/Resources/tproxy"
cp proxy/dist/tproxy-* "$app/Contents/Resources/tproxy/"

# actool makes Assets.car, with the layered icon of macOS 26 and later and flat images for older
# versions, and AppIcon.icns.
developer=$(xcode-select -p)
case "$developer" in
    */CommandLineTools) developer=/Applications/Xcode.app/Contents/Developer ;;
esac
if DEVELOPER_DIR="$developer" xcrun actool Resources/AppIcon.icon --compile "$app/Contents/Resources" \
    --app-icon AppIcon --platform macosx --target-device mac --minimum-deployment-target 14.0 \
    --output-partial-info-plist build/AppIcon.plist >/dev/null 2>&1; then
    icon_name=AppIcon
else
    echo "No actool of Xcode 26 or later: the app has the flat icon only." >&2
    icon_name=
    cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
fi

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
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>VERSION</string>
  <key>CFBundleVersion</key><string>BUILD_NUMBER</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © YEAR The Tilde authors.</string>
  <key>NSCameraUsageDescription</key><string>Tilde records the screen of an iPhone connected by cable.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Tilde connects to the machines that you link, and opens pages from your local network in its browser.</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

# The build number counts the commits, so each build of a newer commit sorts higher.
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
sed -i '' "s/BUILD_NUMBER/$build_number/; s/VERSION/$version/; s/YEAR/$(date +%Y)/" "$app/Contents/Info.plist"
if [ -n "$icon_name" ]; then
    plutil -insert CFBundleIconName -string "$icon_name" "$app/Contents/Info.plist"
fi
if [ -n "$update_key" ]; then
    plutil -insert SUPublicEDKey -string "$update_key" "$app/Contents/Info.plist"
fi

# Inside out: each bundle is signed after the code in it.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
if [ "$identity" = - ]; then
    sign() { codesign --force --sign - "$@"; }
else
    case "$identity" in
        "Developer ID Application"*) sign() { codesign --force --sign "$identity" --options runtime --timestamp "$@"; } ;;
        *) sign() { codesign --force --sign "$identity" --options runtime "$@"; } ;;
    esac
fi
for proxy in "$app"/Contents/Resources/tproxy/tproxy-darwin-*; do
    sign "$proxy"
done
sign "$sparkle/Versions/B/Autoupdate"
sign "$sparkle/Versions/B/Updater.app"
sign "$sparkle"
sign --identifier dev.tilde.mcp "$app/Contents/MacOS/tilde-mcp"
if [ "$identity" = - ]; then
    # Ad-hoc signatures normally pin macOS privacy permissions to one exact build. An explicit
    # designated requirement keeps Screen Recording and Accessibility grants across rebuilds.
    sign --identifier dev.tilde.app -r='designated => identifier "dev.tilde.app"' "$app"
else
    # The identity's own requirement: the same identifier, signed by the same certificate, so
    # the grants stay across updates and no other app can claim them.
    sign --identifier dev.tilde.app --entitlements Resources/Tilde.entitlements "$app"
fi
echo "Built $app"
