#!/bin/bash
# Puts the engine xcframeworks into Vendor/Frameworks.
# Prefers this repo's "engine-<engine/VERSION>" release (libmpv with LuaJIT +
# GlassPlayer patches). Falls back to MPVKit's stock GPL release (no Lua) so
# the app can still be built while a new engine is being produced.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${GITHUB_REPOSITORY:-0xSilentNeo/GlassPlayer}"
TAG="engine-$(tr -d '[:space:]' < engine/VERSION)"
mkdir -p Vendor
rm -rf Vendor/Frameworks
# ENGINE=stock forces MPVKit's frameworks (they carry simulator slices; ours are device-only).
if [ "${ENGINE:-}" != "stock" ] && curl -fsSL -o /tmp/engine.zip "https://github.com/$REPO/releases/download/$TAG/GlassPlayerEngine.zip"; then
  ditto -x -k /tmp/engine.zip Vendor/
  # Older engine zips shipped without FFmpeg: add MPVKit's GPL FFmpeg (same n9.0.2).
  for lib in avcodec avdevice avfilter avformat avutil swresample swscale; do
    [ -d "Vendor/Frameworks/Lib$lib.xcframework" ] && continue
    echo "adding Lib$lib from MPVKit"
    curl -fsSL -o "/tmp/Lib$lib.zip" "https://github.com/mpvkit/MPVKit/releases/download/1.1.0-n9.0.2/Lib$lib-GPL.xcframework.zip"
    ditto -x -k "/tmp/Lib$lib.zip" Vendor/Frameworks/
  done
  echo "ENGINE=$TAG" | tee Vendor/engine.txt
else
  echo "::warning::Engine release $TAG not found; using stock MPVKit frameworks (no Lua scripting)"
  mkdir -p Vendor/Frameworks
  BASE=https://github.com/mpvkit
  for url in \
    $BASE/MPVKit/releases/download/1.1.0-n9.0.2/Libmpv-GPL.xcframework.zip \
    $BASE/MPVKit/releases/download/1.1.0-n9.0.2/Libavcodec-GPL.xcframework.zip \
    $BASE/MPVKit/releases/download/1.1.0-n9.0.2/Libavdevice-GPL.xcframework.zip \
    $BASE/MPVKit/releases/download/1.1.0-n9.0.2/Libavformat-GPL.xcframework.zip \
    $BASE/MPVKit/releases/download/1.1.0-n9.0.2/Libavfilter-GPL.xcframework.zip \
    $BASE/MPVKit/releases/download/1.1.0-n9.0.2/Libavutil-GPL.xcframework.zip \
    $BASE/MPVKit/releases/download/1.1.0-n9.0.2/Libswresample-GPL.xcframework.zip \
    $BASE/MPVKit/releases/download/1.1.0-n9.0.2/Libswscale-GPL.xcframework.zip \
    $BASE/openssl-build/releases/download/3.3.5/Libcrypto.xcframework.zip \
    $BASE/openssl-build/releases/download/3.3.5/Libssl.xcframework.zip \
    $BASE/gnutls-build/releases/download/3.8.11/gmp.xcframework.zip \
    $BASE/gnutls-build/releases/download/3.8.11/nettle.xcframework.zip \
    $BASE/gnutls-build/releases/download/3.8.11/hogweed.xcframework.zip \
    $BASE/gnutls-build/releases/download/3.8.11/gnutls.xcframework.zip \
    $BASE/libass-build/releases/download/0.17.5/Libunibreak.xcframework.zip \
    $BASE/libass-build/releases/download/0.17.5/Libfreetype.xcframework.zip \
    $BASE/libass-build/releases/download/0.17.5/Libfribidi.xcframework.zip \
    $BASE/libass-build/releases/download/0.17.5/Libharfbuzz.xcframework.zip \
    $BASE/libass-build/releases/download/0.17.5/Libass.xcframework.zip \
    $BASE/libsmbclient-build/releases/download/4.15.13-2512/Libsmbclient.xcframework.zip \
    $BASE/libbluray-build/releases/download/1.4.0/Libbluray.xcframework.zip \
    $BASE/libuavs3d-build/releases/download/1.2.1-fix/Libuavs3d.xcframework.zip \
    $BASE/libdovi-build/releases/download/3.3.2/Libdovi.xcframework.zip \
    $BASE/moltenvk-build/releases/download/1.4.2/MoltenVK.xcframework.zip \
    $BASE/libshaderc-build/releases/download/2025.5.0/Libshaderc_combined.xcframework.zip \
    $BASE/lcms2-build/releases/download/2.17.0/lcms2.xcframework.zip \
    $BASE/libplacebo-build/releases/download/7.360.1/Libplacebo.xcframework.zip \
    $BASE/libdav1d-build/releases/download/1.5.3/Libdav1d.xcframework.zip \
    $BASE/libuchardet-build/releases/download/0.0.8/Libuchardet.xcframework.zip ; do
    n=$(basename "$url")
    curl -fsSL -o "/tmp/$n" "$url"
    ditto -x -k "/tmp/$n" Vendor/Frameworks/
  done
  echo "ENGINE=mpvkit-stock" | tee Vendor/engine.txt
fi
ls -1 Vendor/Frameworks
bash scripts/engine-xcconfig.sh
