# Releasing XC_VM_FFMPEG

Releases carry a per-distro static FFmpeg build for every panel version. Assets
are named `ffmpeg_<label>_<distro>.tar.gz` and accompanied by `hashes.md5`, which
the panel reads (`GitHubReleases::getAssetHash`) to verify downloads.

Tags are **bare semver** — `1.0.0`, not `v1.0.0`. The panel's
`GitHubReleases::isValidVersion()` rejects a `v` prefix, and `make release`
refuses one.

Assets are **built on the PC, not in GitHub Actions** — a full matrix is hours of
CPU per release, which the shared GitHub runners can't spare. GitHub only hosts
the result.

## Cutting a release

Requires Docker and an authenticated [`gh`](https://cli.github.com) (`gh auth login`).

```bash
make build                 # builds every out/ffmpeg_<label>_<distro>.tar.gz
make check                 # sanity-check the asset list
make release TAG=1.0.0     # draft release: all matrix assets + hashes.md5
```

`make release`:

- refuses a tag that is not bare semver;
- refuses a **partial matrix** — every `(version × distro)` asset must exist in
  `out/` (it lists the missing ones);
- uploads exactly the matrix assets (stray files in `out/` stay local) plus a
  freshly generated `hashes.md5` over them;
- creates a **draft** — review the assets on GitHub, then publish. `DRAFT=0 make
  release TAG=…` publishes immediately.

Rebuild a single target without redoing the whole matrix:

```bash
FORCE=1 ./builds/build_ffmpeg_all.sh ubuntu_20 8.1
```

## Notes

- Assets are self-contained (codecs static, glibc dynamic-and-matched). The
  builder aborts if a binary ends up needing any non-glibc shared library.
- `hashes.md5` lists filenames exactly as uploaded — do not rename assets after
  hashing, or the panel's lookup will miss.
- Bumping a codec or FFmpeg version: edit the matrix / versions in
  `build_ffmpeg_all.sh` (and mirror `versions.json`), then cut a new release.
