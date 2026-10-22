#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 htjulia
#
# nvme-stop.sh — before a NAS shutdown or reboot: stop the containers from nvme.conf
# in reverse order, check that nothing still uses the SSD, then unmount it and
# unload the driver.
#
#   sudo -i; cd /volume1/<folder>; ./nvme-stop.sh                 # everything
#   ./nvme-stop.sh --keep-mounted                                  # containers only
#
# Stops at the first problem and leaves the SSD mounted, so nothing is cut off mid-write.
set -euo pipefail

cd "$(dirname "$0")"
[ -f nvme.conf ] || { echo "FAIL: nvme.conf not found" >&2; exit 1; }
# shellcheck source-path=SCRIPTDIR source=nvme.conf.example
. ./nvme.conf

KEEP_MOUNTED=0
[ "${1:-}" = "--keep-mounted" ] && KEEP_MOUNTED=1

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '  OK   %s\n' "$*"; }
warn() { printf '  WARN %s\n' "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "run as root (sudo -i)"

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

# --- 1. Containers, reverse of the start order -------------------------------------
for ((i = ${#SERVICES[@]} - 1; i >= 0; i--)); do
	IFS='|' read -r name wait _ stop_timeout <<<"${SERVICES[$i]}"
	stop_timeout=${stop_timeout:-120}
	step "Stop $name"
	if running "$name"; then docker stop -t "$stop_timeout" "$name" >/dev/null; ok "stopped"; else ok "not running"; fi
	if [ "$wait" = pg_isready ]; then
		if docker logs --tail 20 "$name" 2>&1 | grep -q 'database system is shut down'; then
			ok "clean PostgreSQL shutdown"
		else
			warn "no 'database system is shut down' in the last log lines; check: docker logs --tail 30 $name"
		fi
	fi
done

[ "$KEEP_MOUNTED" -eq 1 ] && { step "Done (SSD left mounted)"; exit 0; }

# --- 2. Nothing may still use the SSD -----------------------------------------------
step "Check that no running container uses $MOUNTPOINT"
users=""
for id in $(docker ps -q); do
	sources=$(docker inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$id")
	if grep -q "^$MOUNTPOINT/" <<<"$sources"; then
		users="$users $(docker inspect -f '{{.Name}}' "$id" | sed 's#^/##')"
	fi
done
[ -z "$users" ] || fail "still running on $MOUNTPOINT:$users. Add them to SERVICES in nvme.conf or stop them, then re-run."
ok "none"

# --- 3. Unmount and unload ------------------------------------------------------------
step "Unmount $MOUNTPOINT"
if grep -q " $MOUNTPOINT " /proc/mounts; then
	sync
	umount "$MOUNTPOINT" || fail "umount failed (something still uses it: fuser -vm $MOUNTPOINT)"
	ok "unmounted"
else
	ok "not mounted"
fi

step "Unload nvme driver"
if grep -q '^nvme ' /proc/modules; then rmmod nvme; ok "rmmod done"; else ok "not loaded"; fi

step "Done — safe to shut down or reboot the NAS"
