#!/bin/bash
# by zayd/cold @ zayd.wtf
#
# Puts iroh (the transport of Zone Link) where the ZoneLink package expects it:
#
#   ZoneLink/Vendor/Iroh.xcframework      iroh as a static library: iPhone, simulator, Mac
#   ZoneLink/Vendor/IrohLib/IrohLib.swift the generated Swift binding that matches it
#
# The library is Zone's own build of iroh-ffi, made by scripts/build-iroh.sh, not the official
# prebuilt one: the official 1.2.0 library imports SystemConfiguration functions that are
# unavailable on iOS, which App Review rejects. build-iroh.sh says exactly what is built and
# from which revisions.
#
# Where the files come from, in order:
#   1. ZoneLink/Vendor already holds this exact build: nothing to do.
#   2. This Mac's cache (~/Library/Caches/zone-iroh/<key>/) holds it: copy it. No network.
#   3. Otherwise build it from source (10 to 20 minutes, once per Mac), then copy it.
#
# Why the headers sit in Headers/Iroh/ and the official Swift package is not a dependency: its
# xcframework keeps module.modulemap at the top of Headers/, as Moonshine's did before it was removed. Xcode
# copies both to the same Build/Products/<config>/include/module.modulemap and stops with
# "Multiple commands produce". A module map in a folder named after its module is found the
# same way and collides with nothing.
#
# `xcodegen generate` runs this (project.yml, options.preGenCommand). It is safe to run again.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/ZoneLink/Vendor"
BUILD="$ROOT/scripts/build-iroh.sh"

fail() { echo "fetch-iroh: $*" >&2; exit 1; }

KEY="$("$BUILD" --print-key)"
CACHE="$("$BUILD" --print-dir)"

complete() {
    [ -f "$1/.stamp" ] && [ "$(cat "$1/.stamp")" = "$KEY" ] \
        && [ -f "$1/IrohLib/IrohLib.swift" ] && [ -f "$1/Iroh.xcframework/Info.plist" ]
}

if complete "$DEST"; then
    exit 0
fi

if complete "$CACHE"; then
    echo "fetch-iroh: using the iroh build cached on this Mac ($CACHE)"
else
    echo "fetch-iroh: no cached iroh build for $KEY on this Mac, building it from source"
    "$BUILD" || fail "the iroh build failed. Fix what it reported and run scripts/fetch-iroh.sh again."
    complete "$CACHE" || fail "the iroh build finished but $CACHE is incomplete"
fi

rm -rf "$DEST"
mkdir -p "$DEST/IrohLib"
# -c clones on APFS, so each checkout's copy takes no extra disk. Plain copy elsewhere.
cp -c -R "$CACHE/Iroh.xcframework" "$DEST/Iroh.xcframework" 2>/dev/null || cp -R "$CACHE/Iroh.xcframework" "$DEST/Iroh.xcframework"
cp "$CACHE/IrohLib/IrohLib.swift" "$DEST/IrohLib/IrohLib.swift"
cp "$CACHE/BUILD-INFO.txt" "$DEST/BUILD-INFO.txt"
echo "$KEY" > "$DEST/.stamp"
echo "fetch-iroh: ZoneLink/Vendor now holds $KEY"
