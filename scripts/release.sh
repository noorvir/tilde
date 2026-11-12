#!/bin/sh
# Makes a release of Tilde in build/release/<version>/: the app for Apple silicon and Intel,
# zipped and signed for Sparkle, and the appcast that installed copies read. It commits the new
# version number, and publishes nothing: at the end it prints the commands that do.
#   TILDE_SIGN_IDENTITY="Apple Development: Name (TEAMID)" scripts/release.sh 0.3.0
# TILDE_SIGN_IDENTITY: the code signing identity (security find-identity -v -p codesigning).
#   The same identity in every release keeps the Screen Recording and Accessibility grants.
#   "-" signs ad hoc.
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
    echo "Set TILDE_SIGN_IDENTITY to the signing identity, such as \"Apple Development: Name (TEAMID)\"." >&2
    exit 2
fi
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
if ! /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$app/Contents/Info.plist" >/dev/null 2>&1; then
    echo "The app has no SUPublicEDKey, so it could not check updates: set update_key in scripts/build-app.sh." >&2
    exit 1
fi
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Contents/Info.plist")

out="build/release/$version"
rm -rf "$out"
mkdir -p "$out"
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

Tilde $version ($build) is in $out, signed by "$TILDE_SIGN_IDENTITY".
Nothing is published. To publish it, push the release commit, then make the GitHub release; the
newest release's appcast.xml is the feed:
  git push origin HEAD
  gh release create v$version "$zip" "$out/appcast.xml" --repo $repo --target "$(git rev-parse HEAD)" --title "Tilde $version" --notes "Tilde $version"
DONE
