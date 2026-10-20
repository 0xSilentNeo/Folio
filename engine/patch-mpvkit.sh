#!/bin/bash
# Customises an MPVKit checkout for GlassPlayer:
#  - Lua (LuaJIT) enabled on iOS so external mpv scripts work
#  - extra raw demuxers (DTS, TrueHD/MLP, W64, PGS .sup)
#  - extra libmpv patches from engine/patches (applied after MPVKit's own)
set -euo pipefail
MPVKIT="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
F="$MPVKIT/Sources/BuildScripts/XCFrameworkBuild/main.swift"

perl -pi -e 's/array\.append\("-Dlua=disabled"\)/array.append("-Dlua=luajit")/' "$F"
grep -q 'append("-Dlua=disabled")' "$F" && { echo "lua patch failed"; exit 1; }

perl -pi -e 's/"--enable-demuxer=dash", /"--enable-demuxer=dash", "--enable-demuxer=dts", "--enable-demuxer=dtshd", "--enable-demuxer=truehd", "--enable-demuxer=mlp", "--enable-demuxer=w64", "--enable-demuxer=sup", /' "$F"
grep -q 'enable-demuxer=truehd' "$F" || { echo "demuxer patch failed"; exit 1; }

cp "$HERE"/patches/*.patch "$MPVKIT/Sources/BuildScripts/patch/libmpv/"
echo "MPVKit patched:"
grep -n 'Dlua=' "$F"
ls "$MPVKIT/Sources/BuildScripts/patch/libmpv/"
