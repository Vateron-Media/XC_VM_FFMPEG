#!/bin/bash
set -euo pipefail
# Build toolchain for build_ffmpeg.sh (Debian/Ubuntu, run as root).
#
# Baked into the per-distro image by docker/Dockerfile (its own layer, so apt runs
# once per image — not once per ffmpeg version — and edits to build_ffmpeg.sh don't
# invalidate it). build_ffmpeg.sh calls it only when the marker below is missing,
# i.e. when run standalone on a bare host.
MARKER=/etc/xcvm-build-tools

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential yasm nasm cmake git pkg-config \
    autoconf automake libtool gperf texinfo \
    wget tar xz-utils unzip ca-certificates \
    python3 python3-pip ninja-build perl ccache
# Older distros ship an old meson; some recent libs want newer — use a fresh pip one.
# Newer distros (ubuntu 24, debian 12+) mark the system Python externally-managed
# (PEP 668), so a plain pip install errors out — fall back to --break-system-packages.
pip3 install --quiet --no-cache-dir --upgrade meson ninja 2>/dev/null \
    || pip3 install --quiet --no-cache-dir --upgrade --break-system-packages meson ninja
touch "$MARKER"
