#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 htjulia
#
# Runs INSIDE the debian:bookworm (linux/amd64) container started by ../build.sh.
# Mounts: /k = fresh kernel tree (rw), /tc = toolchain (ro), /p = patches for this kernel
#         series (ro), /cfg = config fragment (ro), /o = output dir (rw).
# Env:    PLATFORM, TOOLCHAIN_PREFIX
set -euo pipefail

export PATH=/tc/$TOOLCHAIN_PREFIX/bin:$PATH
P=$TOOLCHAIN_PREFIX-
M=(ARCH=x86_64 "CROSS_COMPILE=$P" HOSTCFLAGS=-fcommon)   # -fcommon: newer host gcc breaks arch/x86/tools/relocs
J=$(nproc)

cd /k

# --- 1. Patches -------------------------------------------------------------
shopt -s nullglob
patches=(/p/*.patch)
[ ${#patches[@]} -gt 0 ] || echo "WARN no patches for this kernel series"
for f in "${patches[@]}"; do
	patch -p1 --forward --batch < "$f" >/dev/null || { echo "FAIL: patch $(basename "$f") does not apply"; exit 1; }
	echo "OK   patch $(basename "$f")"
done

# --- 2. Config ----------------------------------------------------------------
cp "synoconfigs/$PLATFORM" .config
grep -E '^CONFIG_[A-Z0-9_]+=' /cfg/fragment | while IFS='=' read -r key value; do
	./scripts/config --file .config --set-val "${key#CONFIG_}" "$value"
done
make "${M[@]}" olddefconfig >/dev/null
grep -E '^CONFIG_[A-Z0-9_]+=' /cfg/fragment | while read -r line; do
	grep -qx "$line" .config || { echo "FAIL: '$line' did not survive olddefconfig"; exit 1; }
	echo "OK   $line"
done

# --- 3. Build -----------------------------------------------------------------
make "${M[@]}" modules_prepare -j"$J"
make "${M[@]}" M=drivers/block modules -j"$J"

# --- 4. Output ----------------------------------------------------------------
"${P}strip" --strip-debug -o /o/nvme.ko drivers/block/nvme.ko
"${P}nm" -u /o/nvme.ko | awk '{print $2}' | LC_ALL=C sort -u > /o/nvme.undef.txt

# Facts for the host-side checks
"${P}readelf" -S -W /o/nvme.ko \
	| awk '{for (i = 1; i <= NF; i++) if ($i == ".gnu.linkonce.this_module") print "0x" $(i + 4)}' \
	| sed 's/0x0*/0x/' > /o/.modsize
grep -a -o 'vermagic=[^[:cntrl:]]*' /o/nvme.ko | head -1 | sed 's/^vermagic=//; s/ *$//' > /o/.vermagic
echo "OK   build finished"
