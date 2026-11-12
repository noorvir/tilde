#!/bin/sh
# Prints the Sparkle appcast for one release: the feed that installed copies read to find it.
#   scripts/appcast.sh <version> <build number> <zip URL> '<sign_update output>'
# The last argument is what Sparkle's sign_update prints for the zip:
#   sparkle:edSignature="..." length="..."
set -eu
version=$1
build=$2
url=$3
signature=$4
date=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Tilde</title>
    <item>
      <title>Tilde $version</title>
      <pubDate>$date</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="$url" type="application/octet-stream" $signature/>
    </item>
  </channel>
</rss>
XML
