# XC_VM_FFMPEG — per-distro static FFmpeg builder.
# Thin wrapper over build_ffmpeg_all.sh (Docker required).

SHELL   := /bin/bash
OUT_DIR ?= out
DRIVER  := ./builds/build_ffmpeg_all.sh

DISTROS := debian_12 debian_13 ubuntu_20 ubuntu_22 ubuntu_24

.PHONY: build hashes matrix clean clean-cache clean-ccache check test help $(DISTROS)

help:
	@echo "XC_VM_FFMPEG targets:"
	@echo "  make build         - build the full (version x distro) matrix + hashes.md5"
	@echo "  make <distro>      - build all versions for one distro ($(DISTROS))"
	@echo "  make hashes        - (re)generate $(OUT_DIR)/hashes.md5"
	@echo "  make matrix        - print the CI matrix JSON"
	@echo "  make test ASSET=.. - run test-ffmpeg.sh on one built archive (host glibc must match)"
	@echo "  make check         - list built assets"
	@echo "  make clean         - remove $(OUT_DIR)/ and logs/"
	@echo "  make clean-cache   - remove the per-distro codec cache (keeps .cache/ccache, so the rebuild is fast)"
	@echo "  make clean-ccache  - remove the compiler cache (.cache/ccache)"
	@echo "  FORCE=1 make ...   - rebuild even if an asset already exists"
	@echo "  NO_CACHE=1 make .. - disable codec cache + ccache (a truly clean build)"
	@echo "  (source archives are reused from downloads/ by every distro; codec deps are cached per distro in .cache/;"
	@echo "   every build self-tests before packaging)"

build:
	OUT_DIR=$(OUT_DIR) $(DRIVER) all

$(DISTROS):
	OUT_DIR=$(OUT_DIR) $(DRIVER) $@

hashes:
	OUT_DIR=$(OUT_DIR) $(DRIVER) hashes

matrix:
	@$(DRIVER) --print-matrix

test:
	@test -n "$(ASSET)" || { echo "usage: make test ASSET=$(OUT_DIR)/ffmpeg_7.1_ubuntu_20.tar.gz  (host glibc must match the archive's distro)"; exit 2; }
	./builds/test-ffmpeg.sh "$(ASSET)"

check:
	@ls -lh $(OUT_DIR)/ffmpeg_*.tar.gz 2>/dev/null || echo "no assets in $(OUT_DIR)/"
	@echo "---"; cat $(OUT_DIR)/hashes.md5 2>/dev/null || echo "no hashes.md5 yet"

clean:
	rm -rf $(OUT_DIR) logs

# Per-distro codec caches only — .cache/ccache survives, so the next build is mostly cache hits.
clean-cache:
	@rm -rf $(filter-out .cache/ccache,$(wildcard .cache/*)) 2>/dev/null || { echo "cache is root-owned (docker) — run: sudo make clean-cache"; exit 1; }

clean-ccache:
	@rm -rf .cache/ccache 2>/dev/null || { echo "cache is root-owned (docker) — run: sudo make clean-ccache"; exit 1; }
