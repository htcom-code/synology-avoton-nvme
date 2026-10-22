#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 htjulia <htjulia1@gmail.com>
#
# build.sh — build nvme.ko for a Synology DSM release on the avoton platform.
#
# Usage:   ./build.sh                 # newest file in versions/
#          ./build.sh 7.2-72806       # a specific DSM release (versions/<ver>.env)
# Needs:   Docker (linux/amd64), curl, internet access on the first run of a release.
# Result:  out/<ver>/nvme.ko, nvme.ko.sha256, nvme.undef.txt, inputs.env, build.log
#
# The same script runs locally and in GitHub Actions.
set -euo pipefail

cd "$(dirname "$0")"
BASE=$(pwd)

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

list_versions() { for f in versions/*.env; do f=${f#versions/}; echo "${f%.env}"; done | sort -V; }
DSM_VER=${1:-$(list_versions | tail -1)}
[ -n "$DSM_VER" ] && [ -f "versions/$DSM_VER.env" ] \
	|| fail "no versions/${DSM_VER:-<ver>}.env (available: $(list_versions | tr '\n' ' '))"
KERNEL_SHA256='' TOOLCHAIN_SHA256='' VERIFIED_SHA256=''
# shellcheck source=versions/7.2-72806.env
. "versions/$DSM_VER.env"
IMAGE=${IMAGE:-debian:bookworm}

DL_DIR=$BASE/synology/dl/$DSM_VER
TC_DIR=$BASE/synology/toolchain/$DSM_VER
SRC_DIR=$BASE/synology/src/$DSM_VER
OUT=$BASE/out/$DSM_VER
PATCH_DIR=$BASE/patches/linux-$KERNEL_SERIES
FRAGMENT=$BASE/config/$PLATFORM.fragment

step "DSM $DSM_VER / $PLATFORM / kernel series $KERNEL_SERIES"
echo "  kernel    : $KERNEL_URL"
echo "  toolchain : $TOOLCHAIN_URL"
echo "  patches   : $(for f in "$PATCH_DIR"/*.patch; do [ -e "$f" ] && printf '%s ' "${f##*/}"; done)"
[ -f "$FRAGMENT" ] || fail "missing $FRAGMENT"

# --- 0. Docker ------------------------------------------------------------------
command -v docker >/dev/null || fail "docker not found."
docker info >/dev/null 2>&1 || fail "Docker is not running."

# --- 1. Download (cached under synology/, never committed) ------------------------
mkdir -p "$DL_DIR"
fetch() {   # fetch <url> <file> <expected-sha256-or-empty>
	if ! { [ -s "$2" ] && tar -tJf "$2" >/dev/null 2>&1; }; then
		echo "  downloading $(basename "$2") ..."
		curl -fsSL --retry 3 -o "$2.part" "$1" || fail "download failed: $1"
		tar -tJf "$2.part" >/dev/null 2>&1 || fail "not a valid .txz: $1"
		mv "$2.part" "$2"
	fi
	local have; have=$(sha256 "$2")
	if [ -n "$3" ]; then
		[ "$have" = "$3" ] || fail "$(basename "$2") sha256 $have does not match the pinned $3"
		echo "  ok   $(basename "$2") (sha256 pinned)"
	else
		echo "  WARN $(basename "$2") sha256 $have is not pinned in versions/$DSM_VER.env"
	fi
	printf '%s' "$have"  > "$2.sha256"
}
step "Download"
fetch "$KERNEL_URL"    "$DL_DIR/kernel.txz"    "$KERNEL_SHA256"
fetch "$TOOLCHAIN_URL" "$DL_DIR/toolchain.txz" "$TOOLCHAIN_SHA256"

# --- 2. Toolchain (extract once) --------------------------------------------------
step "Toolchain"
GCC=$TC_DIR/$TOOLCHAIN_PREFIX/bin/$TOOLCHAIN_PREFIX-gcc
if [ ! -x "$GCC" ]; then mkdir -p "$TC_DIR"; tar -xJf "$DL_DIR/toolchain.txz" -C "$TC_DIR"; fi
[ -x "$GCC" ] || fail "toolchain layout unexpected under $TC_DIR (TOOLCHAIN_PREFIX=$TOOLCHAIN_PREFIX?)"
echo "  ok"

# --- 3. Fresh kernel tree every run (patches always apply to clean source) --------
step "Kernel source (fresh copy)"
if [ -d "$SRC_DIR" ]; then chmod -R u+w "$SRC_DIR"; rm -rf "$SRC_DIR"; fi
mkdir -p "$SRC_DIR"
tar -xJf "$DL_DIR/kernel.txz" -C "$SRC_DIR"
[ -f "$SRC_DIR/$KERNEL_DIR_NAME/synoconfigs/$PLATFORM" ] || fail "no $KERNEL_DIR_NAME/synoconfigs/$PLATFORM in the kernel archive"
echo "  ok"

# --- 4. Build in Docker -------------------------------------------------------------
step "Build (Docker $IMAGE, linux/amd64)"
mkdir -p "$OUT" "$PATCH_DIR"
rm -f "$OUT"/nvme.ko "$OUT"/nvme.ko.sha256 "$OUT"/nvme.undef.txt "$OUT"/inputs.env "$OUT"/.modsize "$OUT"/.vermagic
docker run --rm --platform linux/amd64 \
	-e PLATFORM="$PLATFORM" -e TOOLCHAIN_PREFIX="$TOOLCHAIN_PREFIX" \
	-v "$SRC_DIR/$KERNEL_DIR_NAME":/k \
	-v "$TC_DIR":/tc:ro \
	-v "$PATCH_DIR":/p:ro \
	-v "$FRAGMENT":/cfg/fragment:ro \
	-v "$OUT":/o \
	-v "$BASE/scripts":/s:ro \
	"$IMAGE" bash -c '
		set -e
		apt-get update -qq >/dev/null
		apt-get install -y -qq make bc perl gcc libc6-dev patch >/dev/null 2>&1
		bash /s/build-in-container.sh
	' 2>&1 | tee "$OUT/build.log"
[ "${PIPESTATUS[0]}" -eq 0 ] || fail "build failed — see $OUT/build.log"
[ -s "$OUT/nvme.ko" ] || fail "nvme.ko was not produced — see $OUT/build.log"

# --- 5. Checks ------------------------------------------------------------------------
step "Checks"
ok=1
modsize=$(cat "$OUT/.modsize"); vermagic=$(cat "$OUT/.vermagic")
if [ "$modsize" = "$EXPECT_MODSIZE" ]; then echo "  OK   struct module size $modsize"
else echo "  FAIL struct module size $modsize (expected $EXPECT_MODSIZE — config fragment out of date?)"; ok=0; fi
if [ "$vermagic" = "$EXPECT_VERMAGIC" ]; then echo "  OK   vermagic '$vermagic'"
else echo "  FAIL vermagic '$vermagic' (expected '$EXPECT_VERMAGIC')"; ok=0; fi
for sym in $EXPECT_IMPORTS; do
	if grep -qx "$sym" "$OUT/nvme.undef.txt"; then echo "  OK   imports $sym"
	else echo "  FAIL does not import $sym — a patch is missing. Do NOT use this module for databases"; ok=0; fi
done
[ "$ok" -eq 1 ] || fail "checks failed; module kept at $OUT/nvme.ko for inspection only"

built=$(sha256 "$OUT/nvme.ko")
( cd "$OUT" && printf '%s  nvme.ko\n' "$built" > nvme.ko.sha256 )
{
	echo "DSM_VER=$DSM_VER"
	echo "KERNEL_SHA256=$(cat "$DL_DIR/kernel.txz.sha256")"
	echo "TOOLCHAIN_SHA256=$(cat "$DL_DIR/toolchain.txz.sha256")"
	echo "MODULE_SHA256=$built"
	echo "VERMAGIC=\"$vermagic\""
	echo "MODSIZE=$modsize"
} > "$OUT/inputs.env"
rm -f "$OUT"/.modsize "$OUT"/.vermagic

step "Done"
echo "  module : $OUT/nvme.ko"
echo "  sha256 : $built"
if [ -n "$VERIFIED_SHA256" ]; then
	[ "$built" = "$VERIFIED_SHA256" ] \
		|| fail "build does not reproduce the hardware-verified module ($VERIFIED_SHA256). Something in the inputs changed."
	echo "  reproduces the hardware-verified module (verified $VERIFIED_ON)"
else
	echo "  NOT verified on hardware yet for $DSM_VER — see README.md before loading it on a NAS"
fi
