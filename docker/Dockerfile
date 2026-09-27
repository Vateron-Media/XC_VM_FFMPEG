# Per-distro static FFmpeg builder.
#
# The base image IS the target distro, so the resulting binary links against that
# distro's glibc and is guaranteed to run on nodes of the same distro:
#     --build-arg BASE_IMAGE=debian:12
#     --build-arg BASE_IMAGE=ubuntu:20.04   ...etc
# One Dockerfile, image selected per build (mirrors the panel's distro bundles).
ARG BASE_IMAGE=debian:12
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /build

# Build script (installs its own apt build-deps and compiles every codec from source)
# + the self-test battery it runs before packaging.
COPY builds/build_ffmpeg.sh /build/build_ffmpeg.sh
COPY builds/test-ffmpeg.sh  /build/test-ffmpeg.sh
RUN chmod +x /build/build_ffmpeg.sh /build/test-ffmpeg.sh

# The script writes ffmpeg/ffprobe/ffmpeg_<label>_<distro>.tar.gz here; mount host out/.
ENV OUT_DIR=/out

ENTRYPOINT ["/build/build_ffmpeg.sh"]
