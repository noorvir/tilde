#!/bin/sh
# Builds tproxy for every node type into proxy/dist/, which scripts/build-app.sh puts in
# Tilde.app: the same bytes on any machine, as GOTOOLCHAIN fixes the Go version.
set -eu
export GOTOOLCHAIN=go1.27.3
cd "$(dirname "$0")"
rm -rf dist
mkdir dist
for target in darwin/arm64 darwin/amd64 linux/amd64 linux/arm64; do
    os=${target%/*} arch=${target#*/}
    CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -buildvcs=false -ldflags="-s -w -buildid=" -o "dist/tproxy-$os-$arch" .
done
