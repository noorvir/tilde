#!/bin/sh
# Builds the drawing canvas into Sources/TildeUI/DrawingWeb. The result is committed: building
# the app needs no Node.
set -eu
cd "$(dirname "$0")"
npm install --silent
npx esbuild draw.jsx --bundle --minify --loader:.woff2=dataurl --define:process.env.NODE_ENV=\"production\" --outfile=../../Sources/TildeUI/DrawingWeb/draw.js
