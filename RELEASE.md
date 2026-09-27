# Releasing XC_VM_FFMPEG

Releases carry a per-distro static FFmpeg build for every panel version. Assets
are named `ffmpeg_<label>_<distro>.tar.gz` and accompanied by `hashes.md5`, which
the panel reads (`GitHubReleases::getAssetHash`) to verify downloads.

Tags are **bare semver** — `1.0.0`, not `v1.0.0`. The panel's
`GitHubReleases::isValidVersion()` rejects a `v` prefix, and the CI workflow
guards against it.

## Option A — GitHub Actions (recommended)

1. Go to **Actions → Build & Release FFmpeg → Run workflow**.
2. Fill in:
   - **version_tag** — the release tag (bare semver, e.g. `1.0.0`).
   - **draft** — leave checked to review before publishing; uncheck to release
     immediately.
3. The workflow derives the matrix from `builds/build_ffmpeg_all.sh --print-matrix`,
   builds every `(version × distro)` pair in parallel (each is a full from-source
   compile — expect a long run), then creates the release with all
   `ffmpeg_*.tar.gz` assets plus `hashes.md5`.
4. If you left it as a draft, review the assets and **publish** the release.

## Option B — Local build + manual upload

Requires Docker.

```bash
make build                 # builds out/ffmpeg_*.tar.gz + out/hashes.md5
make check                 # sanity-check the asset list and hashes

gh release create 1.0.0 \
  --title "FFmpeg 1.0.0" \
  --notes "Per-distro static FFmpeg builds." \
  out/ffmpeg_*.tar.gz out/hashes.md5
```

Rebuild a single target without redoing the whole matrix:

```bash
FORCE=1 ./builds/build_ffmpeg_all.sh ubuntu_20 8.1
./builds/build_ffmpeg_all.sh hashes        # regenerate hashes.md5 over out/
```

## Notes

- Assets are self-contained (codecs static, glibc dynamic-and-matched). The
  builder aborts if a binary ends up needing any non-glibc shared library.
- `hashes.md5` lists filenames exactly as uploaded — do not rename assets after
  hashing, or the panel's lookup will miss.
- Bumping a codec or FFmpeg version: edit the matrix / versions in
  `build_ffmpeg_all.sh` (and mirror `versions.json`), then cut a new release.
