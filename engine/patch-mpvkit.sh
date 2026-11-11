#!/bin/bash
# Customises an MPVKit checkout for Folio:
#  - Lua (LuaJIT) enabled on iOS so external mpv scripts work
#  - extra raw demuxers (DTS, TrueHD/MLP, W64, PGS .sup)
#  - engine 4: FFmpeg's TLS is Apple's Secure Transport (was GnuTLS)
#  - extra libmpv patches from engine/patches (applied after MPVKit's own):
#    0100 MoltenVK layer resizes reported at once; 0200 (engine 3) gpu-next
#    drawing into buffers Folio hands over (--folio-target), for the Metal
#    renderer on the same video layer as Picture in Picture
set -euo pipefail
MPVKIT="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
F="$MPVKIT/Sources/BuildScripts/XCFrameworkBuild/main.swift"

perl -pi -e 's/array\.append\("-Dlua=disabled"\)/array.append("-Dlua=luajit")/' "$F"
grep -q 'append("-Dlua=disabled")' "$F" && { echo "lua patch failed"; exit 1; }

perl -pi -e 's/"--enable-demuxer=dash", /"--enable-demuxer=dash", "--enable-demuxer=dts", "--enable-demuxer=dtshd", "--enable-demuxer=truehd", "--enable-demuxer=mlp", "--enable-demuxer=w64", "--enable-demuxer=sup", /' "$F"
grep -q 'enable-demuxer=truehd' "$F" || { echo "demuxer patch failed"; exit 1; }

# Engine 4: FFmpeg's HTTPS through Apple's Secure Transport, not GnuTLS.
# The 11 Nov report had mpv's demux thread at 25-30% of a core on a
# 25 Mbit/s HTTPS stream ("tls: Error in the pull function" names GnuTLS
# in the log); Apple's library uses the phone's AES hardware. FFmpeg finds
# Secure Transport by itself once no other TLS library is enabled; it is
# named here so a build without it fails instead of shipping no HTTPS.
# GnuTLS stays in the app for libsmbclient.
perl -pi -e 's/var dependencyLibrary = \[Library\.gmp, \.gnutls, \./var dependencyLibrary = [Library./' "$F"
grep -q 'dependencyLibrary = \[Library.gmp, .gnutls' "$F" && { echo "tls patch failed (gnutls still a dependency)"; exit 1; }
perl -pi -e 's/"--enable-cross-compile", "--enable-libxml2",/"--enable-cross-compile", "--enable-libxml2", "--enable-securetransport",/' "$F"
grep -q 'enable-securetransport' "$F" || { echo "tls patch failed (securetransport not enabled)"; exit 1; }

cp "$HERE"/patches/*.patch "$MPVKIT/Sources/BuildScripts/patch/libmpv/"
echo "MPVKit patched:"
grep -n 'dependencyLibrary = \[\|enable-securetransport' "$F"
grep -n 'Dlua=' "$F"
ls "$MPVKIT/Sources/BuildScripts/patch/libmpv/"
