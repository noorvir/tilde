#!/bin/sh
# Builds tilde-proxy for every node type into proxy/dist/, the same bytes on any machine, as
# GOTOOLCHAIN fixes the Go version, and checks them against SHA256SUMS, which Tilde also has
# built in (Sources/TildeCore/Proxy.swift). --update writes SHA256SUMS instead.
set -eu
export GOTOOLCHAIN=go1.27.3
cd "$(dirname "$0")"
rm -rf dist
mkdir dist
for target in darwin/arm64 darwin/amd64 linux/amd64 linux/arm64; do
    os=${target%/*} arch=${target#*/}
    CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -buildvcs=false -ldflags="-s -w -buildid=" -o "dist/tilde-proxy-$os-$arch" .
done
(cd dist && shasum -a 256 tilde-proxy-*) > dist/SHA256SUMS
if [ "${1:-}" = --update ]; then
    cp dist/SHA256SUMS SHA256SUMS
fi
diff SHA256SUMS dist/SHA256SUMS
