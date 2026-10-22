#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 htjulia <htjulia1@gmail.com>
#
# package.sh <ver> — bundle a built module with the NAS scripts into
# out/<ver>/synology-avoton-nvme-<ver>.tar.gz (the release asset).
# Run ./build.sh <ver> first.
set -euo pipefail

cd "$(dirname "$0")/.."
VER=${1:?usage: scripts/package.sh <dsm-version>}
OUT=out/$VER
[ -s "$OUT/nvme.ko" ] && [ -s "$OUT/nvme.ko.sha256" ] || { echo "FAIL: build $VER first (./build.sh $VER)" >&2; exit 1; }

NAME=synology-avoton-nvme-$VER
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$NAME"
cp "$OUT/nvme.ko" "$OUT/nvme.ko.sha256" "$OUT/nvme.undef.txt" "$STAGE/$NAME/"
cp nas/nvme-start.sh nas/nvme-stop.sh nas/nvme.conf.example nas/README.md tools/modsize.py LICENSE "$STAGE/$NAME/"
chmod +x "$STAGE/$NAME/nvme-start.sh" "$STAGE/$NAME/nvme-stop.sh"

# Deterministic archive: fixed order, owner and mtime.
tar -C "$STAGE" --sort=name --owner=0 --group=0 --numeric-owner --mtime='2000-01-01 00:00:00Z' \
	-czf "$OUT/$NAME.tar.gz" "$NAME" 2>/dev/null \
	|| tar -C "$STAGE" -czf "$OUT/$NAME.tar.gz" "$NAME"   # BSD tar (macOS) has no --sort
echo "$OUT/$NAME.tar.gz"
