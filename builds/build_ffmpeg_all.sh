#!/bin/bash
set -euo pipefail
# ──────────────────────────────────────────────────────────────────────────────
# XC_VM_FFMPEG — matrix driver
#
# Builds a static FFmpeg for every (panel version × distro) pair by running
# build_ffmpeg.sh inside each distro's own container (docker/Dockerfile, chosen
# via BASE_IMAGE). Each pair yields a flat release asset:
#
#     out/ffmpeg_<label>_<distro>.tar.gz    (+ out/hashes.md5)
#
# The distro's glibc is baked in, so a node downloads the archive matching ITS
# distro and the binary always starts (fixes "FFmpeg 8.x needs glibc 2.34 but
# the node has 2.31").
#
# Usage:
#   ./builds/build_ffmpeg_all.sh                     # full matrix, then hashes.md5
#   ./builds/build_ffmpeg_all.sh ubuntu_20           # all versions for one distro
#   ./builds/build_ffmpeg_all.sh ubuntu_20 8.1       # a single (distro, version) pair
#   ./builds/build_ffmpeg_all.sh hashes              # (re)generate out/hashes.md5 only
#   ./builds/build_ffmpeg_all.sh release 1.0.0       # publish out/ as a GitHub release (DRAFT=0 → public)
#   FORCE=1 ./builds/build_ffmpeg_all.sh ...         # rebuild even if the asset exists
# ──────────────────────────────────────────────────────────────────────────────

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # scripts live in builds/
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/logs}"
DOCKERFILE="$ROOT_DIR/docker/Dockerfile"
FORCE="${FORCE:-0}"

# Per-distro build cache: codec deps (/opt/ffmpeg_deps) are identical across the ffmpeg
# versions of ONE distro (same container/glibc), so we mount a distro-keyed cache — the
# ~19 codecs compile once per distro, then 7.1/8.1 reuse them (only ffmpeg itself
# rebuilds). NEVER shared between distros (ABI/glibc).
# Disable with NO_CACHE=1. Cache files are root-owned (docker) → `make clean-cache`.
CACHE_DIR="${CACHE_DIR:-$ROOT_DIR/.cache}"
# Source archives are distro-independent → one project dir, mounted into every build
# (always, even with NO_CACHE). build_ffmpeg.sh reuses them and drops superseded versions.
DL_CACHE="${DL_CACHE:-$ROOT_DIR/downloads}"
USE_CACHE=1; [[ -n "${NO_CACHE:-}" ]] && USE_CACHE=0

# ── Build matrix — single source of truth (versions.json mirrors this) ─────────
# Panel label -> ffmpeg release tarball version.
# The "4.0" bucket is rebuilt from FFmpeg 4.4.5 (last 4.x) with GPU enabled and
# native DTS decode. Caveat: the XUI custom "-nofix_dts" flag does NOT exist in
# stock ffmpeg, so the panel must stop sending it to the 4.0 binary
# (StreamProcess dts_legacy_ffmpeg path) — native `dca` decode still works.
declare -A FFMPEG_VERSIONS=(
    [4.0]="4.4.5"
    [7.1]="7.1.5"
    [8.1]="8.1"
)
# Panel label -> nv-codec-headers tag (must match the ffmpeg major; n12 is too
# new for 4.x). Passed to the builder as V_NVHEADERS.
declare -A NVHEADERS=(
    [4.0]="n11.1.5.3"
    [7.1]="n12.2.72.0"
    [8.1]="n12.2.72.0"
)
# Distro tag -> docker base image.
declare -A DISTROS=(
    [debian_12]="debian:12"
    [debian_13]="debian:13"
    [ubuntu_20]="ubuntu:20.04"
    [ubuntu_22]="ubuntu:22.04"
    [ubuntu_24]="ubuntu:24.04"
)
# Deterministic ordering (assoc arrays are unordered).
DISTRO_ORDER=(debian_12 debian_13 ubuntu_20 ubuntu_22 ubuntu_24)
VERSION_ORDER=(4.0 7.1 8.1)

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
msg()  { echo -e "${GREEN}>>>${NC} $*"; }
step() { echo -e "${CYAN}===${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

mkdir -p "$OUT_DIR" "$LOG_DIR"
# docker -v treats a relative path as a named volume — always mount an absolute one.
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# build_image <distro> — build the per-distro image once (reused for every version).
build_image() {
    # NB: separate declarations — `local a=$1 b=${arr[$a]}` expands b before a is
    # assigned (all args to `local` are expanded first), which trips `set -u`.
    local distro="$1"
    local base="${DISTROS[$distro]}"
    [[ -n "$base" ]] || die "unknown distro: $distro"
    local logfile="$LOG_DIR/image_${distro}.log"
    step "IMAGE xcvm-ffmpeg:$distro (base=$base)"
    docker build \
        -t "xcvm-ffmpeg:$distro" \
        --build-arg BASE_IMAGE="$base" \
        -f "$DOCKERFILE" \
        "$ROOT_DIR" 2>&1 | tee "$logfile"
}

# build_pair <distro> <label> — compile ffmpeg <label> inside <distro>.
build_pair() {
    local distro="$1" label="$2"
    local tarball="${FFMPEG_VERSIONS[$label]}"
    [[ -n "$tarball" ]] || die "unknown version label: $label"
    local asset="ffmpeg_${label}_${distro}.tar.gz"
    if [[ -f "$OUT_DIR/$asset" && "$FORCE" != 1 ]]; then
        msg "SKIP $asset (exists; FORCE=1 to rebuild)"
        return 0
    fi
    local logfile="$LOG_DIR/${distro}_${label}.log"

    # Shared downloads + distro-keyed deps cache (shared by that distro's ffmpeg versions)
    # + one ccache for all distros (its key includes the compiler, so distros never mix).
    mkdir -p "$DL_CACHE"
    local cache_args=(-v "$DL_CACHE:/tmp/ffmpeg_dl") ctag=""
    if [[ "$USE_CACHE" == 1 ]]; then
        local cdeps="$CACHE_DIR/$distro/deps"
        mkdir -p "$cdeps" "$CACHE_DIR/ccache"
        cache_args+=(-v "$cdeps:/opt/ffmpeg_deps"
                     -v "$CACHE_DIR/ccache:/ccache" -e CCACHE_DIR=/ccache -e CCACHE_MAXSIZE=10G)
        ctag=", cached"
    fi

    step "BUILD $asset (ffmpeg $tarball on ${DISTROS[$distro]}${ctag})"
    docker run --rm \
        -v "$OUT_DIR:/out" \
        "${cache_args[@]}" \
        -e "V_FFMPEG=$tarball" \
        -e "FF_LABEL=$label" \
        -e "FF_DISTRO=$distro" \
        -e "V_NVHEADERS=${NVHEADERS[$label]}" \
        "xcvm-ffmpeg:$distro" 2>&1 | tee "$logfile"
    [[ -f "$OUT_DIR/$asset" ]] || die "expected $asset was not produced"
}

# gen_hashes — md5 of every asset, named exactly as uploaded (panel getAssetHash).
gen_hashes() {
    step "Generating out/hashes.md5"
    ( cd "$OUT_DIR" && md5sum ffmpeg_*.tar.gz 2>/dev/null > hashes.md5 ) || die "no assets to hash"
    msg "hashes.md5:"; cat "$OUT_DIR/hashes.md5"
}

# release <tag> — publish the locally built matrix as a GitHub release (assets are
# built on this PC, never in CI). Refuses a partial matrix; uploads exactly the
# matrix assets (stray files in out/ stay local) + a hashes.md5 over them.
release() {
    local tag="${1:-}" d v assets=() missing=()
    [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "tag must be bare semver, e.g. 1.0.0 — the panel rejects a 'v' prefix (got: '${tag}')"
    for d in "${DISTRO_ORDER[@]}"; do
        for v in "${VERSION_ORDER[@]}"; do
            assets+=("ffmpeg_${v}_${d}.tar.gz")
            [[ -f "$OUT_DIR/ffmpeg_${v}_${d}.tar.gz" ]] || missing+=("ffmpeg_${v}_${d}.tar.gz")
        done
    done
    (( ${#missing[@]} == 0 )) || die "matrix incomplete, missing: ${missing[*]} (run: make build)"
    command -v gh >/dev/null 2>&1 || die "gh CLI not found (https://cli.github.com)"

    ( cd "$OUT_DIR" && md5sum "${assets[@]}" > hashes.md5 )
    msg "hashes.md5:"; cat "$OUT_DIR/hashes.md5"
    local draft=(--draft); [[ "${DRAFT:-1}" == 0 ]] && draft=()
    step "Creating release $tag (${draft[*]:-public}) with ${#assets[@]} assets"
    ( cd "$OUT_DIR" && gh release create "$tag" "${draft[@]}" \
        --title "FFmpeg $tag" \
        --notes "Per-distro static FFmpeg builds. Each asset is ffmpeg_<label>_<distro>.tar.gz (ffmpeg+ffprobe, codecs static, glibc matched to the distro). Verify with hashes.md5." \
        "${assets[@]}" hashes.md5 )
}

build_distro() { local d="$1" v; build_image "$d"; for v in "${VERSION_ORDER[@]}"; do build_pair "$d" "$v"; done; }

case "${1:-all}" in
    release)        release "${2:-}" ;;
    hashes)         gen_hashes ;;
    all|"")
        for d in "${DISTRO_ORDER[@]}"; do build_distro "$d"; done
        gen_hashes ;;
    debian_*|ubuntu_*)
        [[ -n "${DISTROS[$1]:-}" ]] || die "unknown distro: $1"
        if [[ -n "${2:-}" ]]; then
            build_image "$1"; build_pair "$1" "$2"; gen_hashes
        else
            build_distro "$1"; gen_hashes
        fi ;;
    -h|--help)
        grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
esac
