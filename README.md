# XC_VM_FFMPEG

Per-distro static **FFmpeg + ffprobe** builds for [XC_VM](https://github.com/Vateron-Media/XC_VM) nodes.

Extracted from `XC_VM_Binaries` into its own repository so FFmpeg has an
independent release cadence, and — more importantly — so it can be built **once
per target distribution** instead of once for all of them.

## Why per-distro

The binaries are self-contained: every codec (x264, x265, VP9, AV1, dav1d, opus,
lame, fdk-aac, vorbis, theora, libass…) is compiled from source as a static `.a`
and linked *into* the binary. The only dynamic dependency left is the **glibc**
family — and that is exactly the catch.

The old builder compiled once on Debian 11 (the oldest glibc we ship) betting it
would be "forward compatible" with everything newer. That bet breaks:

- **FFmpeg 8.x is built with a toolchain that needs glibc ≥ 2.34.** Debian 11 /
  Ubuntu 20.04 ship glibc **2.31**, so an 8.x binary produced on — or requiring —
  a newer glibc fails to start on those nodes:
  `ffprobe: /lib/x86_64-linux-gnu/libc.so.6: version 'GLIBC_2.35' not found`.

Building **inside each distro's own container** keeps the codecs static while
linking glibc against that exact distro. A node downloads the archive matching
**its** distro, so the glibc it needs is always present. No forward-compat
guessing.

## Build matrix

`(panel version) × (distro)` → one release asset each. All are GPU-enabled:

| Label | FFmpeg tarball | nv-codec-headers | Note |
|-------|----------------|------------------|------|
| `4.0` | 4.4.5          | n11.1.5.3        | last 4.x; see `-nofix_dts` caveat |
| `7.1` | 7.1            | n12.2.72.0       | |
| `8.1` | 8.1            | n12.2.72.0       | |

> **`4.0` and `-nofix_dts`.** The panel's `4.0` bucket historically shipped
> XUI.one's 2018 binary (`extra-version=XUI10FFMPEG`), which carries a **custom
> `-nofix_dts` flag that does not exist in stock FFmpeg**. Rebuilding `4.0` from
> the 4.4.5 tarball gives GPU + native DTS decode (`dca`), but that flag is gone,
> so the panel must **stop passing `-nofix_dts`** to the `4.0` binary
> (`StreamProcess` `dts_legacy_ffmpeg` path, ~line 947). DTS audio still decodes
> natively; only the XUI-specific timestamp quirk is dropped.

| Distro tag  | Base image     | glibc |
|-------------|----------------|-------|
| `debian_12` | `debian:12`    | 2.36  |
| `debian_13` | `debian:13`    | 2.41  |
| `ubuntu_20` | `ubuntu:20.04` | 2.31  |
| `ubuntu_22` | `ubuntu:22.04` | 2.35  |
| `ubuntu_24` | `ubuntu:24.04` | 2.39  |

**Asset name:** `ffmpeg_<label>_<distro>.tar.gz`
(e.g. `ffmpeg_8.1_ubuntu_20.tar.gz`). Each archive contains `ffmpeg`, `ffprobe`
and a `BUILD_INFO` file. Every release also ships `hashes.md5` — the panel's
`GitHubReleases::getAssetHash()` reads it to verify downloads.

## Codec set

Chosen from what XC_VM code **actually invokes** (grep of `StreamProcess` /
`ProfileService`), not the union of the deployed builds:

- **Video encode:** `libx264`, `libx265`, and **`nvenc` + `cuvid` + `ffnvcodec`**
  (GPU). The NVIDIA libs are `dlopen`'d at runtime, so enabling them adds no
  runtime dependency — a CPU-only node just reports no GPU. The GPU transcode
  path (`*_cuvid`, `hevc_nvenc`, `-hwaccel cuvid`) requires this.
- **Audio:** native `aac` + `aac_adtstoasc`, `libmp3lame`, `libfdk-aac`,
  `libopus`, `libvorbis`; **DTS decode** via the native `dca` decoder (built-in,
  no lib, present in every version incl. the rebuilt 4.0).
- **GPU:** all three versions are built with `nvenc`/`cuvid`/`ffnvcodec`. Note the
  currently-deployed 7.1 (mardock's build) has **no** GPU support — this build
  fixes that. nv-codec-headers is pinned per ffmpeg version (n12 is too new for 4.x).
- **Subtitles/text:** `libass`, `libfreetype`, `fontconfig`, `libfribidi`,
  `libharfbuzz`, native `subrip`.
- **Net/TLS:** `openssl`, `librtmp` (native rtmp already covers `-f flv rtmp://`;
  librtmp adds rtmpe/rtmps and matches the deployed builds), native
  http/https/udp/rtp/hls.
- **Dropped** (no code reference): AV1 (`libaom`/`libdav1d` — also the slowest to
  build), `libsrt` (the `srt` in code is SubRip subtitles, not the protocol),
  `libxavs`, `libxvid`, `libwebp`, `libvidstab`, `libopenjpeg`, `libxml2`,
  `opencore-amr`, `libspeex`, `libbluray`.

> **Rocky Linux is TODO.** `build_ffmpeg.sh` installs its build tools via `apt`.
> Adding `rocky_9` needs a dnf/yum port of `install_build_tools()`
> (`build-essential` → `gcc-toolset`, different `-devel` package names).

## Usage (local, Docker required)

```bash
make build                     # full matrix → out/ffmpeg_*.tar.gz + out/hashes.md5
make ubuntu_20                 # all versions for one distro
./builds/build_ffmpeg_all.sh ubuntu_20 8.1   # a single (distro, version) pair
make matrix                    # print the CI matrix JSON
make check                     # list built assets + hashes
FORCE=1 make ubuntu_20         # rebuild even if the asset exists
```

The build matrix lives in **`build_ffmpeg_all.sh`** (bash arrays — the source of
truth). `versions.json` mirrors it for humans/CI; keep the two in sync.

## Testing

Every build **self-tests before it is packaged**: `build_ffmpeg.sh` runs
`test-ffmpeg.sh` inside the distro container, so the binary is checked on the
exact glibc it was built for. Any failure aborts the build and no archive is
produced — a broken ffmpeg never reaches a release.

`test-ffmpeg.sh` asserts (version-aware for 4.0 / 7.1 / 8.1):

- **runs** — `ffmpeg`/`ffprobe -version` exit 0 (the glibc guarantee)
- **self-contained** — no non-glibc dynamic deps (`readelf -d`)
- **codecs** — encoders (x264/x265/aac/ac3/eac3/mp3lame, fdk soft), decoders
  (dca/DTS, ac3/eac3, h264/hevc), muxers (hls/segment/mpegts/flv/mp4), protocols
  (file/http/https/rtmp/udp), `--enable-librtmp`
- **GPU** — `h264_nvenc`/`hevc_nvenc` + `h264_cuvid`/`hevc_cuvid` compiled in
  (`av1_nvenc` soft on 8.x); `libharfbuzz`/`libfribidi` only on ≥5, forbidden on 4.x
- **functional** — real transcodes: lavfi → segment muxer (mpegts, ≥2 segments),
  HLS muxer, ac3 encode+remux roundtrip; ffprobe reads the output back

Run it standalone against a built archive or an extracted dir (host glibc must
match the archive's distro):

```bash
./builds/test-ffmpeg.sh out/ffmpeg_7.1_ubuntu_20.tar.gz
make test ASSET=out/ffmpeg_8.1_ubuntu_22.tar.gz
FF=/home/xc_vm/bin/ffmpeg_bin/7.1/ffmpeg FP=.../ffprobe FF_LABEL=7.1 ./builds/test-ffmpeg.sh
```

## Files

| Path | Role |
|------|------|
| `builds/build_ffmpeg.sh` | the actual builder — one distro per run (env: `V_FFMPEG`, `FF_LABEL`, `FF_DISTRO`, `OUT_DIR`). Compiles every codec static, verifies the result is self-contained (only glibc/libgcc dynamic), self-tests before packaging. |
| `builds/test-ffmpeg.sh` | pre-publish test battery — codecs/GPU/functional; run in-container at build time and standalone in CI/manual. |
| `builds/build_ffmpeg_all.sh` | matrix driver: builds the per-distro image, runs the builder per version, writes flat assets + `hashes.md5`. |
| `docker/Dockerfile` | one Dockerfile, distro selected via `--build-arg BASE_IMAGE=…`. |
| `versions.json` | matrix mirror. |
| `Makefile` | wrapper over the driver. |
| `.github/workflows/build-release.yml` | `workflow_dispatch` → parallel matrix build → draft release with all assets + `hashes.md5`. |
| `RELEASE.md` | how to cut a release. |

## Caveats

- **`drawtext` filter:** the panel's `xc_fanout` "send message" overlay re-encodes a
  viewer's segment with the `drawtext` filter, which requires FFmpeg to be built
  **with libfreetype**. `build_ffmpeg.sh` keeps `--enable-libfreetype` on and its
  `show_features` report asserts `drawtext` is present — if that line is ✗, do not
  ship the build for overlay use.
- **FFmpeg 4.0 (`4.4.5`) uses the modern codec set** (x265 4.1, dav1d 1.5.1,
  aom 3.11…). Some of those APIs are newer than FFmpeg 4.x expects; if a 4.0
  build fails to link, pin older codec versions for that build (a per-version
  codec-override hook can be added to `build_ffmpeg.sh`). Confirm the exact 4.x
  patch against the binary currently deployed as the panel's `4.0` bucket.

## Panel integration (separate task — not in this repo yet)

To consume these builds the panel side (`XC_VM`) needs, mirroring the
MaxMind/proxy pattern:

1. `bin/install/update_binaries.sh` (or a dedicated fetch) to detect the node's
   distro and download `ffmpeg_<label>_<distro>.tar.gz` for each configured
   version into `ffmpeg_bin/<label>/`, verifying against `hashes.md5`.
2. A `version.json` index + a MaxMind-style cron to refresh builds.
3. `FfmpegPaths` still resolves the label → dir; note it currently maps the
   setting `8.0` → `FFMPEG_BIN_80`, while this repo labels the modern build
   `8.1` — reconcile the label when wiring the fetch.
4. Drop the `ffmpeg_bin/*` binaries from Git LFS once fetched at install.
