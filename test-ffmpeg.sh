#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# test-ffmpeg.sh — verify a built ffmpeg/ffprobe pair before it is published.
#
# Runs the binaries ON THIS HOST — so when invoked at the end of build_ffmpeg.sh
# (inside the distro container) it proves the binary starts on that exact glibc,
# has the required codec/feature set, and can actually transcode. A failure here
# aborts the build so a broken artifact is never packaged.
#
# Usage:
#   ./test-ffmpeg.sh <dir>                 # dir containing ffmpeg + ffprobe
#   ./test-ffmpeg.sh <archive.tar.gz>      # extracts, then tests
#   FF=/path/ffmpeg FP=/path/ffprobe FF_LABEL=7.1 ./test-ffmpeg.sh
#
# The panel bucket label (4.0 | 7.1 | 8.1) gates version-specific expectations.
# Taken from $FF_LABEL, else the archive/dir BUILD_INFO, else inferred.
#
# Exit: 0 = all hard checks passed, 1 = at least one failed.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail   # NOT -e: we run every check and count failures

# ── Resolve binaries ───────────────────────────────────────────────────────────
FF="${FF:-}"; FP="${FP:-}"; FF_LABEL="${FF_LABEL:-}"
CLEANUP_DIR=""
if [[ -z "$FF" ]]; then
    arg="${1:?Usage: test-ffmpeg.sh <dir|archive.tar.gz>  (or set FF=/path/ffmpeg FP=...)}"
    if [[ -f "$arg" && "$arg" == *.tar.gz ]]; then
        CLEANUP_DIR="$(mktemp -d)"
        tar xzf "$arg" -C "$CLEANUP_DIR"
        FF="$CLEANUP_DIR/ffmpeg"; FP="$CLEANUP_DIR/ffprobe"
        [[ -f "$CLEANUP_DIR/BUILD_INFO" ]] && SRCINFO="$CLEANUP_DIR/BUILD_INFO"
    elif [[ -d "$arg" ]]; then
        FF="$arg/ffmpeg"; FP="$arg/ffprobe"
        [[ -f "$arg/BUILD_INFO" ]] && SRCINFO="$arg/BUILD_INFO"
    else
        echo "not a dir or .tar.gz: $arg"; exit 2
    fi
fi
trap '[[ -n "$CLEANUP_DIR" ]] && rm -rf "$CLEANUP_DIR"' EXIT

# Label: env → BUILD_INFO → ffmpeg -version banner (n7.1/4.4 → 7.1/4.0…)
if [[ -z "$FF_LABEL" ]]; then
    if [[ -n "${SRCINFO:-}" ]]; then FF_LABEL="$(sed -n 's/^Label *: *//p' "$SRCINFO" | head -1)"; fi
fi
if [[ -z "$FF_LABEL" ]]; then
    ver="$("$FF" -hide_banner -version 2>/dev/null | head -1)"
    case "$ver" in
        *ersion\ 4.*|*-4.*) FF_LABEL="4.0" ;;
        *ersion\ n7.*|*\ 7.*) FF_LABEL="7.1" ;;
        *ersion\ 8.*|*ersion\ n8.*) FF_LABEL="8.1" ;;
        *) FF_LABEL="?" ;;
    esac
fi
FF_MAJOR="${FF_LABEL%%.*}"

# ── Reporting ──────────────────────────────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; N=$'\e[0m'; else G=; R=; Y=; N=; fi
fails=0; passes=0; warns=0
ok()   { printf "  ${G}✓${N} %s\n" "$1"; passes=$((passes + 1)); }
bad()  { printf "  ${R}✗ %s${N}\n" "$1"; fails=$((fails + 1)); }
warn() { printf "  ${Y}! %s${N}\n" "$1"; warns=$((warns + 1)); }

ver_out="$("$FF" -hide_banner -version 2>/dev/null)"
enc="$("$FF" -hide_banner -encoders 2>/dev/null)"
dec="$("$FF" -hide_banner -decoders 2>/dev/null)"
mux="$("$FF" -hide_banner -muxers 2>/dev/null)"
prot="$("$FF" -hide_banner -protocols 2>/dev/null)"

have() { grep -q -- "$1" <<<"$2"; }              # substring in a listing
listed() { grep -qE "^ *[A-Z.]+ +$1 " <<<"$2"; } # exact codec/format token in -encoders/-decoders/-muxers

want_enc()   { listed "$1" "$enc"  && ok "encoder $1"  || { [[ "${2:-hard}" == soft ]] && warn "encoder $1 missing"  || bad "encoder $1 MISSING"; }; }
want_dec()   { listed "$1" "$dec"  && ok "decoder $1"  || { [[ "${2:-hard}" == soft ]] && warn "decoder $1 missing"  || bad "decoder $1 MISSING"; }; }
want_mux()   { listed "$1" "$mux"  && ok "muxer $1"    || bad "muxer $1 MISSING"; }
want_proto() { grep -qE "^ *$1$" <<<"$prot" && ok "protocol $1" || bad "protocol $1 MISSING"; }
want_cfg()   { have "$1" "$ver_out" && ok "config $1"  || { [[ "${2:-hard}" == soft ]] && warn "config $1 missing" || bad "config $1 MISSING"; }; }

echo "=== testing ffmpeg (label=${FF_LABEL}) ==="

# 1) Binaries run (glibc compatibility — the whole reason this repo exists)
"$FF" -hide_banner -version >/dev/null 2>&1 && ok "ffmpeg runs" || bad "ffmpeg does NOT run (glibc?)"
"$FP" -hide_banner -version >/dev/null 2>&1 && ok "ffprobe runs" || bad "ffprobe does NOT run (glibc?)"
printf "     %s\n" "$(head -1 <<<"$ver_out")"

# 2) Self-contained: no non-glibc dynamic deps
allow='^(libc|libm|libmvec|libdl|libpthread|librt|libresolv|libgcc_s|ld-linux.*|linux-vdso.*)\.so'
badlibs="$(readelf -d "$FF" 2>/dev/null | awk -F'[][]' '/NEEDED/{print $2}' | grep -vE "$allow")"
[[ -z "$badlibs" ]] && ok "self-contained (glibc-only)" || bad "external deps: $(tr '\n' ' ' <<<"$badlibs")"

# 3) Required codecs / formats / protocols
want_enc libx264;  want_enc libx265
want_enc aac;      want_enc ac3;    want_enc eac3;   want_enc libmp3lame
want_enc libfdk_aac soft
want_dec dca;      want_dec ac3;    want_dec eac3;   want_dec h264;  want_dec hevc
want_mux hls;      want_mux segment; want_mux mpegts; want_mux flv;  want_mux mp4
want_proto file;   want_proto http; want_proto https; want_proto rtmp; want_proto udp
want_cfg --enable-librtmp

# 4) GPU — nvenc/cuvid must be COMPILED IN (listed even without a card present)
want_enc h264_nvenc; want_enc hevc_nvenc
want_dec h264_cuvid; want_dec hevc_cuvid
[[ "$FF_MAJOR" -ge 8 ]] 2>/dev/null && want_enc av1_nvenc soft

# 5) Version-gated text shaping (ffmpeg options exist only from 6.1)
if [[ "$FF_MAJOR" -ge 5 ]] 2>/dev/null; then
    want_cfg --enable-libharfbuzz soft
    want_cfg --enable-libfribidi  soft
else
    have --enable-libharfbuzz "$ver_out" && bad "4.x should NOT enable libharfbuzz" || ok "4.x correctly without libharfbuzz"
fi

# probe_has <file> <codec> — true if <codec> appears among the file's stream codecs.
probe_has() { "$FP" -v error -show_entries stream=codec_name -of csv=p=0 "$1" 2>/dev/null | tr '\n' ' ' | grep -qw "$2"; }

# 6) Functional: real transcode → segment muxer (mpegts), then ffprobe reads it back.
#    -g 25 forces a keyframe every second so 1s segments can actually split.
T="$(mktemp -d)"
if "$FF" -hide_banner -v error -f lavfi -i "testsrc2=size=320x240:rate=25" \
        -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 4 \
        -c:v libx264 -preset ultrafast -g 25 -c:a aac \
        -f segment -segment_format mpegts -segment_time 1 \
        -segment_list "$T/out.m3u8" -segment_list_type m3u8 "$T/seg_%03d.ts" 2>"$T/seg.log"; then
    nseg=$(ls "$T"/seg_*.ts 2>/dev/null | wc -l)
    [[ -s "$T/out.m3u8" && "$nseg" -ge 2 ]] && ok "segment transcode ($nseg segments + m3u8)" || bad "segment transcode: m3u8/segments missing (nseg=$nseg)"
    { probe_has "$T/seg_000.ts" h264 && probe_has "$T/seg_000.ts" aac; } \
        && ok "ffprobe reads back h264 + aac" || bad "ffprobe read-back missing h264/aac"
else
    bad "segment transcode FAILED ($(tail -1 "$T/seg.log" 2>/dev/null))"
fi

# 7) Functional: HLS muxer (the current production path)
"$FF" -hide_banner -v error -f lavfi -i "testsrc2=size=320x240:rate=25" \
    -f lavfi -i "sine=r=48000" -t 3 -c:v libx264 -preset ultrafast -g 25 -c:a aac \
    -f hls -hls_time 1 -hls_segment_type mpegts -hls_segment_filename "$T/h_%d.ts" "$T/h.m3u8" 2>"$T/hls.log" \
    && [[ -s "$T/h.m3u8" ]] && ok "hls transcode" || bad "hls transcode FAILED ($(tail -1 "$T/hls.log" 2>/dev/null))"

# 8) Functional: ac3 encode roundtrip in mpegts (DTS/AC3 legacy audio path). 2ch: ac3
#    at 448k is a 5.1/stereo bitrate — mono would warn.
if "$FF" -hide_banner -v error -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2" \
        -ac 2 -c:a ac3 -b:a 448k -f mpegts "$T/a.ts" 2>"$T/ac3.log" && [[ -s "$T/a.ts" ]] \
        && probe_has "$T/a.ts" ac3; then
    ok "ac3 encode+remux roundtrip"
else
    bad "ac3 roundtrip FAILED ($(tail -1 "$T/ac3.log" 2>/dev/null))"
fi
rm -rf "$T"

# ── Summary ────────────────────────────────────────────────────────────────────
echo "=== ${passes} passed, ${warns} warnings, ${fails} failed ==="
[[ "$fails" -eq 0 ]] || exit 1
