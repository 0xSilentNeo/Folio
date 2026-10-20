#!/bin/bash
# Gathers every static xcframework the app links into one zip:
# the ones built here (libmpv, FFmpeg) plus MPVKit's prebuilt dependencies.
set -euo pipefail
MPVKIT="$1"; OUT="$2"
mkdir -p "$OUT/Frameworks"
BUILT="$MPVKIT/dist/release/xcframework"
ls "$BUILT"
cp -R "$BUILT"/*.xcframework "$OUT/Frameworks/"

# Dependencies published by MPVKit (iOS slices included); skip anything we built.
grep -o 'url: "[^"]*\.xcframework\.zip"' "$MPVKIT/Package.swift" | sed 's/url: "//; s/"$//' | sort -u | while read -r url; do
  name=$(basename "$url" .xcframework.zip)
  case "$name" in
    Libmpv*|Libav*|Libsw*) continue ;;   # built from source with our patches
  esac
  [ -d "$OUT/Frameworks/$name.xcframework" ] && continue
  echo "fetch $name"
  curl -fsSL -o "/tmp/$name.zip" "$url"
  ditto -x -k "/tmp/$name.zip" "$OUT/Frameworks/"
done
ls -1 "$OUT/Frameworks"
(cd "$OUT" && zip -qry ../GlassPlayerEngine.zip Frameworks)
ls -lh GlassPlayerEngine.zip
