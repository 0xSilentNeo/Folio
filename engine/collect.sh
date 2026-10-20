#!/bin/bash
# Gathers every static xcframework the app links into one zip:
# the ones built here (libmpv, FFmpeg) plus MPVKit's prebuilt dependencies.
set -euo pipefail
MPVKIT="$1"; OUT="$2"
mkdir -p "$OUT/Frameworks"
BUILT="$MPVKIT/dist/release/xcframework"
ls "$BUILT"
cp -R "$BUILT"/*.xcframework "$OUT/Frameworks/"

# FFmpeg: wrap the thin static libs built here (they include our extra
# demuxers) if the build didn't emit xcframeworks for them.
for lib in avcodec avdevice avfilter avformat avutil swresample swscale; do
  name="Lib$lib"
  [ -d "$OUT/Frameworks/$name.xcframework" ] && continue
  a=$(find "$MPVKIT/dist" -path "*ios/thin/arm64*" -name "lib$lib.a" 2>/dev/null | head -1 || true)
  if [ -n "$a" ]; then
    echo "wrap $a"
    xcodebuild -create-xcframework -library "$a" -output "$OUT/Frameworks/$name.xcframework" >/dev/null
  fi
done

# Dependencies published by MPVKit (iOS slices included); skip anything we built.
grep -o 'url: "[^"]*\.xcframework\.zip"' "$MPVKIT/Package.swift" | sed 's/url: "//; s/"$//' | sort -u | while read -r url; do
  name=$(basename "$url" .xcframework.zip)
  case "$name" in
    Libmpv*) continue ;;                  # built from source with our patches
    Libav*|Libsw*) [[ "$name" == *-GPL ]] || continue ;;  # GPL FFmpeg only as fallback
  esac
  base="${name%-GPL}"
  [ -d "$OUT/Frameworks/$base.xcframework" ] && continue
  [ -d "$OUT/Frameworks/$name.xcframework" ] && continue
  echo "fetch $name"
  curl -fsSL -o "/tmp/$name.zip" "$url"
  ditto -x -k "/tmp/$name.zip" "$OUT/Frameworks/"
done
ls -1 "$OUT/Frameworks"
(cd "$OUT" && zip -qry ../GlassPlayerEngine.zip Frameworks)
ls -lh GlassPlayerEngine.zip
