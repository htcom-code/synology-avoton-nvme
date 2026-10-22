#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 htjulia
#
# nvme-start.sh — after a NAS boot: load nvme.ko, mount the NVMe SSD, check that
# flush reaches the SSD, then start the containers listed in nvme.conf in order.
#
#   sudo -i; cd /volume1/<folder>; ./nvme-start.sh
#
# Stops at the first failed check, so nothing that uses the SSD starts while the SSD
# is missing, read-only or not flushing. Safe to re-run: finished steps are skipped.
set -euo pipefail

cd "$(dirname "$0")"
[ -f nvme.conf ] || { echo "FAIL: nvme.conf not found (copy nvme.conf.example and edit it)" >&2; exit 1; }
# shellcheck source-path=SCRIPTDIR source=nvme.conf.example
. ./nvme.conf

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '  OK   %s\n' "$*"; }
warn() { printf '  WARN %s\n' "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "run as root (sudo -i)"

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
exists()  { docker inspect "$1" >/dev/null 2>&1; }

# --- 1. Module --------------------------------------------------------------------
step "1. NVMe driver"
if grep -q '^nvme ' /proc/modules; then
	ok "nvme module already loaded"
else
	[ -f "$NVME_KO" ] || fail "$NVME_KO not found in $(pwd)"
	sha256sum -c "$NVME_KO_SHA" >/dev/null || fail "$NVME_KO does not match $NVME_KO_SHA"
	ok "sha256 matches"

	set -- /lib/modules/*.ko; dsm_mod=$1
	want_vm=$(grep -a -o -m1 'vermagic=[^[:cntrl:]]*' "$dsm_mod" | sed 's/ *$//')
	have_vm=$(grep -a -o -m1 'vermagic=[^[:cntrl:]]*' "$NVME_KO" | sed 's/ *$//')
	[ "$want_vm" = "$have_vm" ] || fail "vermagic mismatch: kernel '$want_vm', module '$have_vm'. This module is for another DSM release."
	ok "$have_vm"

	sizes=$(python3 modsize.py "$dsm_mod" "$NVME_KO" | awk '{print $2}' | sort -u)
	[ "$sizes" = "$EXPECT_MODSIZE" ] || fail "struct module size differs (${sizes//$'\n'/ }); expected $EXPECT_MODSIZE for both. Do not load this module."
	ok "struct module size $EXPECT_MODSIZE"

	insmod "$NVME_KO"
	ok "insmod done"
fi
for _ in $(seq 1 20); do [ -b "$NVME_DEV" ] && break; sleep 0.5; done
[ -b "$NVME_DEV" ] || fail "$NVME_DEV did not appear (dmesg | grep -i nvme). Is the SSD seated? lspci should show Class 0108."
ls -d /sys/bus/pci/drivers/nvme/0000:* >/dev/null 2>&1 || fail "nvme driver is not bound to any device (struct module mismatch?)"
ok "$NVME_DEV present, driver bound"

# --- 2. Mount ---------------------------------------------------------------------
step "2. Mount $MOUNTPOINT"
if grep -q " $MOUNTPOINT " /proc/mounts; then
	ok "already mounted"
else
	[ -d "$MOUNTPOINT" ] || fail "$MOUNTPOINT does not exist"
	attrs=$(lsattr -d "$MOUNTPOINT" 2>/dev/null | awk '{print $1}' || true)
	case "$attrs" in *i*) ;; *) warn "$MOUNTPOINT is not immutable (chattr +i $MOUNTPOINT while unmounted is recommended)" ;; esac
	uuid=$(blkid "$NVME_DEV" 2>/dev/null | sed -n 's/.* UUID="\([^"]*\)".*/\1/p' || true)
	[ "$uuid" = "$NVME_UUID" ] || fail "$NVME_DEV has UUID '$uuid', expected '$NVME_UUID' (different SSD? update nvme.conf)"
	mount "$NVME_DEV" "$MOUNTPOINT"
	ok "mounted $NVME_DEV"
fi
opts=$(awk -v m="$MOUNTPOINT" '$2 == m {print $4}' /proc/mounts)
case ",$opts," in *,rw,*) ok "rw ($opts)" ;; *) fail "$MOUNTPOINT is not mounted rw ($opts)" ;; esac
dev=$(awk -v m="$MOUNTPOINT" '$2 == m {print $1}' /proc/mounts)
[ "$dev" = "$NVME_DEV" ] || fail "$MOUNTPOINT is backed by $dev, not $NVME_DEV"

# --- 3. Flush check ---------------------------------------------------------------
step "3. Flush check (200 x 8KB dsync)"
t=$(dd if=/dev/zero of="$MOUNTPOINT/.flushtest" bs=8k count=200 oflag=dsync 2>&1 \
	| sed -n 's/.* copied, \([0-9.]*\) s,.*/\1/p')
rm -f "$MOUNTPOINT/.flushtest"
[ -n "$t" ] || fail "could not parse dd output"
ms=$(awk -v t="$t" 'BEGIN { printf "%.2f", t * 1000 / 200 }')
awk -v ms="$ms" -v min="$FLUSH_MIN_MS" 'BEGIN { exit !(ms >= min) }' \
	|| fail "dsync write took ${ms} ms (< ${FLUSH_MIN_MS} ms): flush is probably not reaching the SSD. Do NOT start databases on it."
ok "${ms} ms per dsync write"

# --- 4. Containers ----------------------------------------------------------------
n=0
for entry in "${SERVICES[@]}"; do
	n=$((n + 1))
	IFS='|' read -r name wait timeout _ <<<"$entry"
	timeout=${timeout:-300}
	step "$((n + 3)). $name (wait: $wait)"
	exists "$name" || fail "container $name does not exist. Recreate it (docker compose up -d in its folder), then re-run."
	if running "$name"; then ok "already running"; else docker start "$name" >/dev/null; ok "started"; fi

	deadline=$((SECONDS + timeout))
	until case "$wait" in
		none)       true ;;
		pg_isready) docker exec "$name" pg_isready -q 2>/dev/null ;;
		healthy)    [ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name")" = healthy ] ;;
		http:*)     [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${wait#http:}" 2>/dev/null || true)" != 000 ] ;;
		*)          fail "unknown wait '$wait' for $name" ;;
	esac; do
		running "$name" || fail "$name exited during startup (docker logs --tail 40 $name)"
		[ $SECONDS -lt $deadline ] || fail "$name not ready ($wait) after ${timeout}s"
		sleep 5
	done
	ok "ready"
done

step "Done"
docker ps --format '  {{.Names}}\t{{.Status}}'
echo
echo "  Before shutting down or rebooting the NAS, run ./nvme-stop.sh"
