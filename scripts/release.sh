#!/bin/sh
# Makes a release of Tilde in build/release/<version>/: the app for Apple silicon and Intel,
# notarized, as a disk image for the first install and as a zip signed for Sparkle, and the
# appcast that installed copies read. It commits the new version number, and publishes nothing:
# at the end it prints the commands that do.
#   TILDE_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" TILDE_NOTARY_PROFILE=tilde \
#   scripts/release.sh 0.3.0
# TILDE_SIGN_IDENTITY: the code signing identity (security find-identity -v -p codesigning).
#   The same identity in every release keeps the Screen Recording and Accessibility grants.
#   Only a "Developer ID Application" identity, notarized, opens without a Gatekeeper warning
#   after a download. Another identity, or "-" (ad hoc), makes a build for tests only.
# TILDE_NOTARY_PROFILE: the notarytool Keychain profile, made once with
#   xcrun notarytool store-credentials tilde --apple-id <Apple ID> --team-id <TEAMID>
#   It is required with a Developer ID identity.
# The EdDSA private key: TILDE_UPDATE_PRIVATE_KEY (as Sparkle's generate_keys -x writes it), or
#   else the login Keychain, where generate_keys keeps it. It never goes in the repository.
set -eu
cd "$(dirname "$0")/.."

version="${1:-}"
case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *)
        echo "usage: scripts/release.sh <version, such as 0.3.0>" >&2
        exit 2
        ;;
esac
if [ -z "${TILDE_SIGN_IDENTITY:-}" ]; then
    echo "Set TILDE_SIGN_IDENTITY to the signing identity, such as \"Developer ID Application: Name (TEAMID)\"." >&2
    exit 2
fi
case "$TILDE_SIGN_IDENTITY" in
    "Developer ID Application"*)
        if [ -z "${TILDE_NOTARY_PROFILE:-}" ]; then
            echo "Set TILDE_NOTARY_PROFILE to the notarytool Keychain profile: a Developer ID release must be notarized." >&2
            exit 2
        fi
        ;;
    *)
        echo "Warning: \"$TILDE_SIGN_IDENTITY\" is not a Developer ID identity. Gatekeeper blocks this build after a download: use it for tests only." >&2
        ;;
esac
if ! git diff --quiet HEAD; then
    echo "Commit or remove the changes first: the release is built from a commit." >&2
    exit 2
fi
sparkle_bin=.build/artifacts/sparkle/Sparkle/bin
[ -x "$sparkle_bin/sign_update" ] || swift package resolve >/dev/null

# The feed URL in the app names the repository whose releases hold the zips.
repo=$(sed -n 's|.*"https://github.com/\([^/]*/[^/]*\)/releases/latest/download/appcast.xml".*|\1|p' Sources/TildeUI/Update/SparkleUpdates.swift)
if [ -z "$repo" ]; then
    echo "No GitHub feed URL in SparkleUpdates.feedURL." >&2
    exit 1
fi

sed -i '' "s/^version=.*/version=$version/" scripts/build-app.sh
if ! git diff --quiet; then
    git commit -q -m "Release $version" scripts/build-app.sh
fi

TILDE_UNIVERSAL=1 TILDE_STRICT=1 scripts/build-app.sh
app=build/Tilde.app
codesign --verify --deep --strict "$app"
if [ ! -f "$app/Contents/Resources/Assets.car" ]; then
    echo "The app has no Assets.car, so no icon for macOS 26 and later: build with Xcode 26 or later." >&2
    exit 1
fi
if ! /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$app/Contents/Info.plist" >/dev/null 2>&1; then
    echo "The app has no SUPublicEDKey, so it could not check updates: set update_key in scripts/build-app.sh." >&2
    exit 1
fi
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Contents/Info.plist")

out="build/release/$version"
rm -rf "$out"
mkdir -p "$out"
# The download for a first install: a disk image with the app and a link to Applications, so the
# user drags it there and does not open it from Downloads.
dmg="$out/Tilde-$version.dmg"
mkdir "$out/dmg"
ditto "$app" "$out/dmg/Tilde.app"
ln -s /Applications "$out/dmg/Applications"
hdiutil create -quiet -volname Tilde -srcfolder "$out/dmg" -fs HFS+ -format UDZO "$dmg"
rm -rf "$out/dmg"
case "$TILDE_SIGN_IDENTITY" in
    -) ;;
    "Developer ID Application"*) codesign --sign "$TILDE_SIGN_IDENTITY" --timestamp "$dmg" ;;
    *) codesign --sign "$TILDE_SIGN_IDENTITY" "$dmg" ;;
esac
if [ -n "${TILDE_NOTARY_PROFILE:-}" ]; then
    # Apple checks the disk image and the app in it, and returns a ticket for both. Stapled, the
    # ticket lets a first open without a network connection pass Gatekeeper too; the app gets it
    # before it is zipped for updates.
    xcrun notarytool submit "$dmg" --keychain-profile "$TILDE_NOTARY_PROFILE" --wait --timeout 30m
    xcrun stapler staple "$dmg"
    xcrun stapler staple "$app"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
    spctl --assess --type execute --verbose=2 "$app"
fi
# The update that Sparkle downloads.
zip="$out/Tilde-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
if [ -n "${TILDE_UPDATE_PRIVATE_KEY:-}" ]; then
    signature=$(printf '%s' "$TILDE_UPDATE_PRIVATE_KEY" | "$sparkle_bin/sign_update" --ed-key-file - "$zip")
else
    signature=$("$sparkle_bin/sign_update" "$zip")
fi
url="https://github.com/$repo/releases/download/v$version/Tilde-$version.zip"
scripts/appcast.sh "$version" "$build" "$url" "$signature" > "$out/appcast.xml"

cat <<DONE

Tilde $version ($build) is in $out, signed by "$TILDE_SIGN_IDENTITY"${TILDE_NOTARY_PROFILE:+, notarized}.
Nothing is published. To publish it, push the release commit, then make the GitHub release; the
newest release's appcast.xml is the feed:
  git push origin HEAD
  gh release create v$version "$dmg" "$zip" "$out/appcast.xml" --repo $repo --target "$(git rev-parse HEAD)" --title "Tilde $version" --notes "Tilde $version"
DONE
