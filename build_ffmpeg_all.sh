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
#   ./build_ffmpeg_all.sh                     # full matrix, then hashes.md5
#   ./build_ffmpeg_all.sh ubuntu_20           # all versions for one distro
#   ./build_ffmpeg_all.sh ubuntu_20 8.1       # a single (distro, version) pair
#   ./build_ffmpeg_all.sh hashes              # (re)generate out/hashes.md5 only
#   ./build_ffmpeg_all.sh --print-matrix      # emit the CI matrix as JSON
#   FORCE=1 ./build_ffmpeg_all.sh ...         # rebuild even if the asset exists
# ──────────────────────────────────────────────────────────────────────────────

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/logs}"
DOCKERFILE="$ROOT_DIR/docker/Dockerfile"
FORCE="${FORCE:-0}"

# ── Build matrix — single source of truth (versions.json mirrors this) ─────────
# Panel label -> ffmpeg release tarball version.
declare -A FFMPEG_VERSIONS=(
    [4.0]="4.4.5"   # legacy DTS-HD bucket — see README caveat (modern codec set)
    [7.1]="7.1"
    [8.1]="8.1"
)
# Distro tag -> docker base image.
declare -A DISTROS=(
    [debian_11]="debian:11"
    [debian_12]="debian:12"
    [debian_13]="debian:13"
    [ubuntu_20]="ubuntu:20.04"
    [ubuntu_22]="ubuntu:22.04"
    [ubuntu_24]="ubuntu:24.04"
)
# Deterministic ordering (assoc arrays are unordered).
DISTRO_ORDER=(debian_11 debian_12 debian_13 ubuntu_20 ubuntu_22 ubuntu_24)
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
    step "BUILD $asset (ffmpeg $tarball on ${DISTROS[$distro]})"
    docker run --rm \
        -v "$OUT_DIR:/out" \
        -e "V_FFMPEG=$tarball" \
        -e "FF_LABEL=$label" \
        -e "FF_DISTRO=$distro" \
        "xcvm-ffmpeg:$distro" 2>&1 | tee "$logfile"
    [[ -f "$OUT_DIR/$asset" ]] || die "expected $asset was not produced"
}

# gen_hashes — md5 of every asset, named exactly as uploaded (panel getAssetHash).
gen_hashes() {
    step "Generating out/hashes.md5"
    ( cd "$OUT_DIR" && md5sum ffmpeg_*.tar.gz 2>/dev/null > hashes.md5 ) || die "no assets to hash"
    msg "hashes.md5:"; cat "$OUT_DIR/hashes.md5"
}

# print_matrix — GitHub Actions matrix (one job per distro×version pair).
print_matrix() {
    local first=1
    printf '{"include":['
    local d v
    for d in "${DISTRO_ORDER[@]}"; do
        for v in "${VERSION_ORDER[@]}"; do
            [[ $first -eq 1 ]] || printf ','
            first=0
            printf '{"distro":"%s","base":"%s","label":"%s","tarball":"%s"}' \
                "$d" "${DISTROS[$d]}" "$v" "${FFMPEG_VERSIONS[$v]}"
        done
    done
    printf ']}\n'
}

build_distro() { local d="$1" v; build_image "$d"; for v in "${VERSION_ORDER[@]}"; do build_pair "$d" "$v"; done; }

case "${1:-all}" in
    --print-matrix) print_matrix ;;
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
