#!/bin/sh
set -eu
cd "$(dirname "$0")"
npm install --silent
node build.mjs
