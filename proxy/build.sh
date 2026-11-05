#!/bin/sh
# Builds tproxy for every node type into proxy/dist/: the same bytes on any machine, as
# GOTOOLCHAIN fixes the Go version. --check compares them with SHA256SUMS, the hashes that
# Tilde has built in (TProxy in Sources/TildeCore/TProxy.swift); --update writes SHA256SUMS.
set -eu
export GOTOOLCHAIN=go1.27.3
cd "$(dirname "$0")"
rm -rf dist
mkdir dist
for target in darwin/arm64 darwin/amd64 linux/amd64 linux/arm64; do
    os=${target%/*} arch=${target#*/}
    CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -buildvcs=false -ldflags="-s -w -buildid=" -o "dist/tproxy-$os-$arch" .
done
(cd dist && shasum -a 256 tproxy-*) > dist/SHA256SUMS
case "${1:-}" in
--update) cp dist/SHA256SUMS SHA256SUMS ;;
--check) diff SHA256SUMS dist/SHA256SUMS ;;
esac
