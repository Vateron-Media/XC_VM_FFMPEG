#!/bin/bash
set -euo pipefail
# ──────────────────────────────────────────────────────────────────────────────
# XC_VM FFmpeg static builder — one distro per run
#
# Builds a *portable* FFmpeg + ffprobe where every codec/library is compiled
# from source as a static .a and linked INTO the binary. The only dynamic
# dependencies left are the glibc family (libc/libm/libpthread/libdl/librt) plus
# libgcc_s — present on every Linux host. No libx264.so / libx265.so / etc. is
# ever looked up on the target system.
#
# Why this exists: the previous version installed distro -dev packages (which on
# Debian/Ubuntu ship only shared .so) and relied on --pkg-config-flags=--static.
# With no .a available the linker silently fell back to .so, producing a binary
# that needed libx264.so & friends at runtime — libraries absent on the deploy
# host. This rewrite removes that failure mode entirely and verifies the result.
#
# Per-distro build (NOT "oldest glibc → forward compatible"). We deliberately run
# this INSIDE each target distro's container (debian 11/12/13, ubuntu 20/22/24),
# so the codecs stay static but glibc is linked against that exact distro. A node
# then downloads the archive built for ITS distro — guaranteeing the glibc it
# needs is present. This is what the single-Debian-11 build could not promise:
# FFmpeg 8.x wants glibc ≥ 2.34, which Debian 11 (2.31) does not have, so an
# 8.x binary built there fails to start on Debian 11 / Ubuntu 20.04 nodes.
# The build image / base is chosen by docker/Dockerfile's BASE_IMAGE arg; see
# build_ffmpeg_all.sh for the (version × distro) matrix driver.
#
# Env overrides:
#   V_FFMPEG   — ffmpeg release tarball version to build (e.g. 7.1, 8.1)
#   FF_LABEL   — panel bucket / asset label (e.g. 4.0, 7.1, 8.1); defaults to V_FFMPEG
#   FF_DISTRO  — distro tag baked into the asset name & BUILD_INFO (e.g. ubuntu_20)
#   OUT_DIR    — output directory (default: ./out)
#
# Output: $OUT_DIR/ffmpeg_<label>[_<distro>].tar.gz  (binaries staged privately
#         and packed in; out/ stays clean — only archives + hashes.md5)
# ──────────────────────────────────────────────────────────────────────────────

# ── Versions (single place to bump; kept here rather than versions.json because
#    none of these are tracked by check_versions.sh) ───────────────────────────
V_ZLIB="1.3.1"
V_BZIP2="1.0.8"
V_OPENSSL="3.4.1"
V_EXPAT="2.6.4"          # tag R_2_6_4
V_FREETYPE="2.13.3"
V_FRIBIDI="1.0.16"
V_HARFBUZZ="10.2.0"
V_FONTCONFIG="2.16.0"
V_LIBASS="0.17.3"
# apt's nasm on older distros (e.g. ubuntu 20.04 → 2.14.02) can't parse FFmpeg
# 8.x's x86inc.asm (ALLOC_STACK macro syntax) — build a known-good one instead.
V_NASM="2.16.01"
V_X265="4.1"
V_VPX="1.15.0"
V_OPUS="1.5.2"
V_LAME="3.100"
V_FDKAAC="2.0.3"
# nv-codec-headers git tag (nvenc/cuvid). MUST roughly match the FFmpeg version:
# n12.x fits FFmpeg 7.x/8.x but is too new for 4.x (configure rejects it). The
# matrix driver sets this per build (4.0 → n11.x). Overridable via env.
V_NVHEADERS="${V_NVHEADERS:-n12.2.72.0}"
V_LIBRTMP="master"       # rtmpdump/librtmp — no releases, track master
V_OGG="1.3.5"
V_VORBIS="1.3.7"
V_THEORA="1.1.1"
V_FFMPEG="${V_FFMPEG:-8.1}"   # release tarball (== git tag nX.Y); override: V_FFMPEG=7.1
# Label for the output archive / release asset (the panel's ffmpeg_bin/<label> dir).
# Defaults to the built version; override when the panel dir name differs, e.g.
# FF_LABEL=8.0 while building FFmpeg 8.1.
FF_LABEL="${FF_LABEL:-$V_FFMPEG}"
# Distro tag folded into the asset name (ffmpeg_<label>_<distro>.tar.gz) so the
# panel can fetch the build matching its own glibc. Empty → no suffix (legacy
# single-build behaviour). Set by the matrix driver, e.g. FF_DISTRO=ubuntu_20.
FF_DISTRO="${FF_DISTRO:-}"

# ── Paths ─────────────────────────────────────────────────────────────────────
DEPS_PREFIX="/opt/ffmpeg_deps"          # static libs land here
FF_PREFIX="/opt/ffmpeg_build"           # ffmpeg install prefix
SRC_DIR="/tmp/ffmpeg_src"               # extracted sources
DL_DIR="/tmp/ffmpeg_dl"                 # downloaded archives (cache)
OUT_DIR="${OUT_DIR:-$(cd "$(dirname "$0")" && pwd)/out}"
NPROC="$(nproc)"
JOBS="-j${NPROC}"

# ── Logging ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
msg()  { echo -e "${GREEN}[*]${NC} $*"; }
step() { echo -e "${CYAN}[==]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

# ── Build environment: make every tool prefer our static prefix ────────────────
export PATH="$DEPS_PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig:$DEPS_PREFIX/lib64/pkgconfig"
export CFLAGS="-I$DEPS_PREFIX/include -O2 -fPIC"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-L$DEPS_PREFIX/lib -L$DEPS_PREFIX/lib64"

mkdir -p "$DEPS_PREFIX" "$FF_PREFIX" "$SRC_DIR" "$DL_DIR" "$OUT_DIR"

# ── Helpers ────────────────────────────────────────────────────────────────────
# dl <dest> <url> [mirror...] — download with retries, skip if already cached.
dl() {
    local out="$1"; shift
    if [[ -f "$out" && "$(stat -c%s "$out" 2>/dev/null || echo 0)" -ge 1024 ]]; then
        return 0
    fi
    local u
    for u in "$@"; do
        msg "GET $(basename "$out") <- $u"
        if wget -q --timeout=30 --connect-timeout=15 --tries=2 -O "$out" "$u"; then
            return 0
        fi
        rm -f "$out"
    done
    die "download failed: $(basename "$out")"
}

# fetch <archive-name> <url> [mirror...] — download + extract into $SRC_DIR.
# Sets global SRC to the extracted top-level directory.
fetch() {
    local fname="$1"; shift
    local arch="$DL_DIR/$fname"
    dl "$arch" "$@"
    local top
    # `head -1` closes the pipe early → tar gets SIGPIPE (141) → under pipefail+set -e
    # this standalone assignment would silently kill the script. `|| true` neutralises
    # the false failure; the guard below still catches a genuinely empty result.
    top="$(tar tf "$arch" 2>/dev/null | head -1 | cut -d/ -f1)" || true
    [[ -n "$top" ]] || die "cannot determine top dir of $fname"
    rm -rf "${SRC_DIR:?}/$top"
    tar xf "$arch" -C "$SRC_DIR"
    SRC="$SRC_DIR/$top"
}

# git_fetch <dir> <branch> <url> [mirror...] — shallow clone. Sets global SRC.
git_fetch() {
    local dir="$1" branch="$2"; shift 2
    SRC="$SRC_DIR/$dir"
    [[ -d "$SRC/.git" ]] && { msg "cached clone: $dir"; return 0; }
    rm -rf "$SRC"
    local u
    for u in "$@"; do
        msg "CLONE $dir ($branch) <- $u"
        if git clone --depth 1 --branch "$branch" "$u" "$SRC" 2>/dev/null; then
            return 0
        fi
        rm -rf "$SRC"
    done
    die "clone failed: $dir"
}

# done_stamp / is_done — let the script be re-run on a host without rebuilding
# everything. (In the one-shot container this is a no-op.)
is_done()   { [[ -f "$DEPS_PREFIX/.done-$1" ]]; }
done_stamp(){ touch "$DEPS_PREFIX/.done-$1"; }

# build <name> <body-fn> — wraps stamp handling + section banner.
build() {
    local name="$1" fn="$2"
    if is_done "$name"; then msg "skip $name (already built)"; return 0; fi
    step "Building $name"
    "$fn"
    done_stamp "$name"
}

# ── Build-tool installation (Debian) ───────────────────────────────────────────
install_build_tools() {
    step "Installing build tools (APT)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        build-essential yasm nasm cmake git pkg-config \
        autoconf automake libtool gperf texinfo \
        wget tar xz-utils unzip ca-certificates \
        python3 python3-pip ninja-build perl
    # Debian 11 ships meson 0.56; some recent libs want newer — use a fresh pip one.
    # Newer distros (ubuntu 24, debian 12+) mark the system Python externally-managed
    # (PEP 668), so a plain pip install errors out — fall back to --break-system-packages.
    pip3 install --quiet --upgrade meson ninja 2>/dev/null \
        || pip3 install --quiet --upgrade --break-system-packages meson ninja
    hash -r
    msg "Tool versions: $(gcc -dumpversion) / nasm $(nasm -v | awk '{print $3}') / meson $(meson --version) / cmake $(cmake --version | head -1 | awk '{print $3}')"
}

# ── Generic build recipes ──────────────────────────────────────────────────────
autotools() { ./configure --prefix="$DEPS_PREFIX" --enable-static --disable-shared "$@" && make $JOBS && make install; }
cmake_static() {
    local src="$1"; shift
    mkdir -p build && cd build
    cmake -G "Unix Makefiles" -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        "$@" "$src"
    make $JOBS && make install
}
meson_static() {
    meson setup build --prefix="$DEPS_PREFIX" --libdir=lib --buildtype=release \
        --default-library=static "$@"
    ninja -C build && ninja -C build install
}

# ── Dependency builds (order matters: deps before dependents) ──────────────────
b_nasm() {
    fetch "nasm-${V_NASM}.tar.xz" \
        "https://www.nasm.us/pub/nasm/releasebuilds/${V_NASM}/nasm-${V_NASM}.tar.xz"
    cd "$SRC"; ./configure --prefix="$DEPS_PREFIX"; make $JOBS; make install
}

b_zlib() {
    fetch "zlib-${V_ZLIB}.tar.gz" \
        "https://zlib.net/zlib-${V_ZLIB}.tar.gz" \
        "https://github.com/madler/zlib/releases/download/v${V_ZLIB}/zlib-${V_ZLIB}.tar.gz"
    cd "$SRC"; ./configure --prefix="$DEPS_PREFIX" --static; make $JOBS; make install
}

b_bzip2() {
    fetch "bzip2-${V_BZIP2}.tar.gz" \
        "https://sourceware.org/pub/bzip2/bzip2-${V_BZIP2}.tar.gz"
    cd "$SRC"
    make $JOBS libbz2.a CFLAGS="-fPIC -O2 -D_FILE_OFFSET_BITS=64"
    make install PREFIX="$DEPS_PREFIX"
}

b_openssl() {
    fetch "openssl-${V_OPENSSL}.tar.gz" \
        "https://github.com/openssl/openssl/releases/download/openssl-${V_OPENSSL}/openssl-${V_OPENSSL}.tar.gz"
    cd "$SRC"
    ./Configure no-shared no-tests --prefix="$DEPS_PREFIX" --libdir=lib \
        --openssldir="$DEPS_PREFIX/ssl" linux-x86_64
    make $JOBS; make install_sw
}

b_expat() {
    fetch "expat-${V_EXPAT}.tar.xz" \
        "https://github.com/libexpat/libexpat/releases/download/R_${V_EXPAT//./_}/expat-${V_EXPAT}.tar.xz"
    cd "$SRC"; autotools --without-docbook --without-examples --without-tests
}

b_freetype() {  # first pass: no harfbuzz (breaks the freetype<->harfbuzz cycle)
    fetch "freetype-${V_FREETYPE}.tar.xz" \
        "https://download.savannah.gnu.org/releases/freetype/freetype-${V_FREETYPE}.tar.xz" \
        "https://downloads.sourceforge.net/freetype/freetype-${V_FREETYPE}.tar.xz"
    cd "$SRC"; autotools --with-harfbuzz=no --with-brotli=no --with-png=no
}

b_fribidi() {
    fetch "fribidi-${V_FRIBIDI}.tar.xz" \
        "https://github.com/fribidi/fribidi/releases/download/v${V_FRIBIDI}/fribidi-${V_FRIBIDI}.tar.xz"
    cd "$SRC"; autotools --disable-debug
}

b_harfbuzz() {
    fetch "harfbuzz-${V_HARFBUZZ}.tar.xz" \
        "https://github.com/harfbuzz/harfbuzz/releases/download/${V_HARFBUZZ}/harfbuzz-${V_HARFBUZZ}.tar.xz"
    cd "$SRC"
    meson_static -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled \
        -Dcairo=disabled -Dicu=disabled -Dtests=disabled -Ddocs=disabled -Dutilities=disabled
}

b_fontconfig() {
    fetch "fontconfig-${V_FONTCONFIG}.tar.xz" \
        "https://www.freedesktop.org/software/fontconfig/release/fontconfig-${V_FONTCONFIG}.tar.xz"
    cd "$SRC"; autotools --disable-docs --sysconfdir=/etc --localstatedir=/var
}

b_libass() {
    fetch "libass-${V_LIBASS}.tar.xz" \
        "https://github.com/libass/libass/releases/download/${V_LIBASS}/libass-${V_LIBASS}.tar.xz"
    cd "$SRC"; autotools
}

b_x264() {
    git_fetch "x264" "stable" \
        "https://code.videolan.org/videolan/x264.git" \
        "https://github.com/mirror/x264.git"
    cd "$SRC"
    ./configure --prefix="$DEPS_PREFIX" --enable-static --enable-pic --disable-cli --disable-opencl
    make $JOBS; make install
}

b_x265() {
    fetch "x265_${V_X265}.tar.gz" \
        "https://ftp.videolan.org/pub/videolan/x265/x265_${V_X265}.tar.gz" \
        "https://bitbucket.org/multicoreware/x265_git/downloads/x265_${V_X265}.tar.gz"
    cd "$SRC"
    cmake_static "$SRC/source" -DENABLE_SHARED=OFF -DENABLE_CLI=OFF
}

b_vpx() {
    fetch "libvpx-${V_VPX}.tar.gz" \
        "https://github.com/webmproject/libvpx/archive/refs/tags/v${V_VPX}.tar.gz"
    cd "$SRC"
    ./configure --prefix="$DEPS_PREFIX" --enable-static --disable-shared --enable-pic \
        --enable-vp9-highbitdepth --disable-examples --disable-tools --disable-docs --disable-unit-tests
    make $JOBS; make install
}

# NVIDIA nvenc/cuvid/ffnvcodec: headers only. The actual libnvidia-encode.so /
# libcuda.so are dlopen'd at RUNTIME, so enabling this adds NO runtime dependency
# — on a CPU-only node ffmpeg simply reports no GPU. GPU transcode path in
# StreamProcess (*_cuvid, hevc_nvenc, -hwaccel cuvid) needs this.
b_nv_codec_headers() {
    git_fetch "nv-codec-headers" "${V_NVHEADERS}" \
        "https://github.com/FFmpeg/nv-codec-headers.git"
    cd "$SRC"; make install PREFIX="$DEPS_PREFIX"
}

# librtmp (from rtmpdump). FFmpeg has native rtmp already; librtmp adds
# rtmpe/rtmps and matches the deployed builds. Links against our static openssl.
b_librtmp() {
    git_fetch "rtmpdump" "master" \
        "https://github.com/FFmpeg/rtmpdump.git" \
        "https://git.ffmpeg.org/rtmpdump.git"
    cd "$SRC/librtmp"
    make install SYS=posix prefix="$DEPS_PREFIX" SHARED= CRYPTO=OPENSSL \
        XCFLAGS="-I$DEPS_PREFIX/include" XLDFLAGS="-L$DEPS_PREFIX/lib"
    # rtmpdump's install drops a shared lib too; keep only the static .a so the
    # linker cannot fall back to librtmp.so at runtime.
    rm -f "$DEPS_PREFIX"/lib/librtmp.so* 2>/dev/null || true
}

b_opus() {
    fetch "opus-${V_OPUS}.tar.gz" \
        "https://github.com/xiph/opus/releases/download/v${V_OPUS}/opus-${V_OPUS}.tar.gz" \
        "https://downloads.xiph.org/releases/opus/opus-${V_OPUS}.tar.gz"
    cd "$SRC"; autotools --disable-doc --disable-extra-programs
}

b_lame() {
    fetch "lame-${V_LAME}.tar.gz" \
        "https://downloads.sourceforge.net/lame/lame-${V_LAME}.tar.gz"
    cd "$SRC"; autotools --enable-nasm --disable-frontend
}

b_fdkaac() {
    fetch "fdk-aac-${V_FDKAAC}.tar.gz" \
        "https://github.com/mstorsjo/fdk-aac/archive/refs/tags/v${V_FDKAAC}.tar.gz"
    cd "$SRC"; ./autogen.sh; autotools
}

b_ogg() {
    fetch "libogg-${V_OGG}.tar.gz" \
        "https://downloads.xiph.org/releases/ogg/libogg-${V_OGG}.tar.gz" \
        "https://github.com/xiph/ogg/releases/download/v${V_OGG}/libogg-${V_OGG}.tar.gz"
    cd "$SRC"; autotools
}

b_vorbis() {
    fetch "libvorbis-${V_VORBIS}.tar.gz" \
        "https://downloads.xiph.org/releases/vorbis/libvorbis-${V_VORBIS}.tar.gz"
    cd "$SRC"; autotools --disable-docs --disable-examples --with-ogg="$DEPS_PREFIX"
}

b_theora() {
    fetch "libtheora-${V_THEORA}.tar.gz" \
        "https://downloads.xiph.org/releases/theora/libtheora-${V_THEORA}.tar.gz"
    cd "$SRC"
    autotools --disable-examples --disable-asm --disable-oggtest --disable-vorbistest \
        --disable-spec --with-ogg="$DEPS_PREFIX" --with-vorbis="$DEPS_PREFIX"
}

build_dependencies() {
    build nasm       b_nasm
    build zlib       b_zlib
    build bzip2      b_bzip2
    build openssl    b_openssl
    build expat      b_expat
    build freetype   b_freetype
    build fribidi    b_fribidi
    build harfbuzz   b_harfbuzz
    build fontconfig b_fontconfig
    build libass     b_libass
    build x264       b_x264
    build x265       b_x265
    build vpx        b_vpx
    build opus       b_opus
    build lame       b_lame
    build fdkaac     b_fdkaac
    build nvheaders  b_nv_codec_headers
    build librtmp    b_librtmp
    build ogg        b_ogg
    build vorbis     b_vorbis
    build theora     b_theora
}

# ── FFmpeg ─────────────────────────────────────────────────────────────────────
build_ffmpeg() {
    step "Building FFmpeg ${V_FFMPEG}"
    fetch "ffmpeg-${V_FFMPEG}.tar.xz" \
        "https://ffmpeg.org/releases/ffmpeg-${V_FFMPEG}.tar.xz"
    cd "$SRC"
    make distclean 2>/dev/null || true

    # ffmpeg-level libfribidi/libharfbuzz options only exist from 6.1+; the 4.x
    # bucket (XUI's legacy DTS binary) predates them and configure would abort.
    # libass still links fribidi/harfbuzz internally, so text rendering is intact.
    local ff_major="${V_FFMPEG%%.*}"
    local text_shaping="--enable-libfribidi --enable-libharfbuzz"
    if ! [ "${ff_major:-0}" -ge 5 ] 2>/dev/null; then
        text_shaping=""
        warn "FFmpeg ${V_FFMPEG}: omitting ffmpeg-level libfribidi/libharfbuzz (added in 6.1)"
    fi

    # C++ codecs (x265, …) need libstdc++. An explicit "-lstdc++" links it
    # DYNAMICALLY and defeats -static-libstdc++, leaving a libstdc++.so.6 NEEDED.
    # Link the static archive by full path so the binary stays self-contained.
    local libstdcxx_a
    libstdcxx_a="$(gcc -print-file-name=libstdc++.a)"
    [[ -f "$libstdcxx_a" ]] || die "libstdc++.a not found ($libstdcxx_a) — install g++/libstdc++-dev"

    # C++ deps (x265, …) list a DYNAMIC "-lstdc++" in their .pc Libs.private, which
    # `--pkg-config-flags=--static` would inject → a libstdc++.so.6 NEEDED that
    # defeats the static link. Strip it; libstdc++.a (extra-libs, last on the line)
    # resolves those C++ symbols statically instead.
    find "$DEPS_PREFIX" -name '*.pc' -exec sed -i 's/-lstdc++//g' {} + 2>/dev/null || true

    # NB: we deliberately do NOT pass -static (would static-link glibc → segfaults
    # in getaddrinfo/NSS). Only our prefix has .a files, so all codecs link static
    # automatically; libstdc++/libgcc are folded in via the -static-* flags. glibc
    # stays dynamic. The result is verified afterwards by verify_static().
    ./configure \
        --prefix="$FF_PREFIX" \
        --pkg-config-flags=--static \
        --extra-cflags="-I$DEPS_PREFIX/include" \
        --extra-ldflags="-L$DEPS_PREFIX/lib -L$DEPS_PREFIX/lib64 -static-libgcc" \
        --extra-libs="-lpthread -lm -ldl $libstdcxx_a" \
        --extra-version="XCVM" \
        --enable-static --disable-shared --enable-pic \
        --disable-debug --disable-doc --disable-ffplay \
        --enable-gpl --enable-version3 --enable-nonfree \
        --enable-runtime-cpudetect \
        --enable-openssl --enable-librtmp \
        --enable-nvenc --enable-cuvid --enable-ffnvcodec \
        --enable-zlib --enable-bzlib \
        --enable-libx264 --enable-libx265 --enable-libvpx \
        --enable-libopus --enable-libmp3lame --enable-libfdk-aac \
        --enable-libvorbis --enable-libtheora \
        --enable-libass --enable-libfreetype --enable-fontconfig $text_shaping
    make $JOBS
    make install
}

# ── Verification: fail the build if any non-glibc lib is dynamically needed ─────
# This is the guard that makes "libraries are baked in" a checked invariant
# rather than a hope. Allowed NEEDED entries are the glibc family + libgcc_s,
# which exist on every Linux host.
verify_static() {
    local bin="$1"
    # libmvec = glibc's vectorised-math lib (part of glibc ≥2.22 → present on every
    # target distro); allowed like the rest of the glibc family.
    local allow='^(libc|libm|libmvec|libdl|libpthread|librt|libresolv|libgcc_s|ld-linux.*|linux-vdso.*)\.so'
    step "Verifying $bin has no external library dependencies"
    "$bin" -version >/dev/null 2>&1 || die "$bin does not run"

    local needed bad=()
    needed="$(readelf -d "$bin" 2>/dev/null | awk -F'[][]' '/NEEDED/{print $2}')"
    echo "$needed" | sed 's/^/    NEEDED /'
    local lib
    while read -r lib; do
        [[ -z "$lib" ]] && continue
        if ! [[ "$lib" =~ $allow ]]; then
            bad+=("$lib")
        fi
    done <<< "$needed"

    if [[ ${#bad[@]} -gt 0 ]]; then
        die "NOT self-contained — external dynamic deps remain: ${bad[*]}"
    fi
    msg "✓ self-contained (only glibc/libgcc dynamic deps)"
}

# ── Package ────────────────────────────────────────────────────────────────────
package() {
    local ff="$FF_PREFIX/bin/ffmpeg" fp="$FF_PREFIX/bin/ffprobe"
    [[ -x "$ff" ]] || die "ffmpeg not built"
    [[ -x "$fp" ]] || die "ffprobe not built"

    # Flat per-(version×distro) archive: out/ffmpeg_<label>[_<distro>].tar.gz.
    # The filename IS the release-asset name (GitHub release assets are a flat
    # namespace), so upload needs no rename and md5sum yields the exact name the
    # panel's getAssetHash looks up.
    local suffix=""
    [[ -n "$FF_DISTRO" ]] && suffix="_${FF_DISTRO}"
    local archive="ffmpeg_${FF_LABEL}${suffix}.tar.gz"

    # Stage binaries in a private per-build dir so out/ only ever holds the
    # finished archives + hashes.md5 — never loose ffmpeg/ffprobe/BUILD_INFO that
    # successive matrix builds would overwrite and leave behind.
    local stage="$OUT_DIR/.stage_${FF_LABEL}${suffix}"
    step "Packaging $archive"
    rm -rf "$stage"; mkdir -p "$stage"

    install -m 0755 "$ff" "$stage/ffmpeg"
    install -m 0755 "$fp" "$stage/ffprobe"
    strip --strip-unneeded "$stage/ffmpeg" "$stage/ffprobe" 2>/dev/null || true

    verify_static "$stage/ffmpeg"
    verify_static "$stage/ffprobe"

    cat > "$stage/BUILD_INFO" <<EOF
Built by : XC_VM FFmpeg static builder
FFmpeg   : ${V_FFMPEG}
Label    : ${FF_LABEL}
Distro   : ${FF_DISTRO:-n/a}
Date     : $(date -u '+%Y-%m-%d %H:%M:%S UTC')
OS       : $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -sr)
glibc    : $(ldd --version 2>/dev/null | head -1 | awk '{print $NF}')
Arch     : $(uname -m)
Strategy : all codecs static, glibc dynamic (verified self-contained)
EOF

    # Self-test on this exact glibc BEFORE blessing the archive — a broken build
    # must never be packaged. Runs the full battery in test-ffmpeg.sh.
    local selftest
    selftest="$(cd "$(dirname "$0")" && pwd)/test-ffmpeg.sh"
    if [[ -f "$selftest" ]]; then
        FF="$stage/ffmpeg" FP="$stage/ffprobe" FF_LABEL="$FF_LABEL" \
            bash "$selftest" || die "self-tests failed — not packaging ${FF_LABEL}/${FF_DISTRO:-?}"
    else
        warn "test-ffmpeg.sh not found next to builder — skipping self-tests"
    fi

    ( cd "$stage" && tar czf "$OUT_DIR/$archive" ffmpeg ffprobe BUILD_INFO )
    rm -rf "$stage"
    msg "Archive: $OUT_DIR/$archive ($(du -h "$OUT_DIR/$archive" | cut -f1))"
}

# ── Summary of enabled features ────────────────────────────────────────────────
show_features() {
    local ff="$FF_PREFIX/bin/ffmpeg"   # staged copy is gone; use the install prefix
    step "Enabled features"
    # Config-string flags (note: fontconfig's flag is --enable-fontconfig, not lib-).
    local f
    for f in libx264 libx265 libvpx librtmp libopus libmp3lame libfdk-aac \
             libvorbis libtheora libass libfreetype fontconfig libharfbuzz \
             nvenc cuvid ffnvcodec; do
        if "$ff" -hide_banner -version 2>/dev/null | grep -q -- "--enable-$f"; then
            echo -e "   ${GREEN}✓${NC} $f"
        else
            echo -e "   ${RED}✗${NC} $f"
        fi
    done
    # Actual capability listings — match the name as a whole column token.
    feat() { "$ff" -hide_banner "$1" 2>/dev/null | grep -qE "(^| )$2( |,|\$)" && echo "✓" || echo "✗"; }
    echo -e "   HLS muxer     : $(feat -muxers hls)"
    echo -e "   segment muxer : $(feat -muxers segment)"
    echo -e "   MPEG-TS muxer : $(feat -muxers mpegts)"
    echo -e "   DTS decode    : $(feat -decoders dca)"
    echo -e "   RTMP protocol : $("$ff" -hide_banner -protocols 2>/dev/null | grep -qw rtmp && echo "✓" || echo "✗")"
    echo -e "   TLS (https)   : $("$ff" -hide_banner -protocols 2>/dev/null | grep -qw https && echo "✓" || echo "✗")"
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    [[ "$(id -u)" -eq 0 ]] || die "must run as root"
    step "XC_VM FFmpeg static builder — FFmpeg ${V_FFMPEG}, all codecs baked in"
    command -v apt-get >/dev/null 2>&1 || die "this builder targets Debian (apt-get not found)"

    install_build_tools
    build_dependencies
    build_ffmpeg
    package
    show_features

    msg "✅ DONE — portable FFmpeg in $OUT_DIR"
}

case "${1:-}" in
    -h|--help)
        echo "Usage: OUT_DIR=/path $0"
        echo "Builds a fully static (glibc-dynamic only) FFmpeg ${V_FFMPEG} with all codecs baked in."
        echo "Run as root, ideally inside the Debian 11 container (./build_all.sh ffmpeg)."
        exit 0 ;;
    *) main ;;
esac
