#!/usr/bin/env bash
# uninstall.sh — remove pve-mac-monitor patch and collector.
#
# Default: remove only the marked blocks from Nodes.pm / pvemanagerlib.js.
#          Safe after a pve-manager upgrade (does not touch package code).
# --from-backup: restore the most recent full backup instead. Use only if
#          pve-manager has NOT been upgraded since install, otherwise this
#          would downgrade the package files.
#
# Works from the repo checkout and from the copy installed by install.sh at
# /usr/local/sbin/pve-mac-monitor-uninstall (patchers then come from
# /usr/local/lib/pve-mac-monitor).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="/usr/local/lib/pve-mac-monitor"
# Paths are overridable for dry-run testing against copies of the PVE files.
NODES_PM="${PVE_NODES_PM:-/usr/share/perl5/PVE/API2/Nodes.pm}"
PVE_JS="${PVE_MGR_JS:-/usr/share/pve-manager/js/pvemanagerlib.js}"
CRON_FILE="/etc/cron.d/pve-mac-monitor"
CRON_BEGIN="# >>> pve-mac-monitor BEGIN"
CRON_END="# <<< pve-mac-monitor END"
UNIT_DIR="/etc/systemd/system"
COLLECTOR_DST="/usr/local/bin/pve-mac-monitor"
UNINSTALL_DST="/usr/local/sbin/pve-mac-monitor-uninstall"

MODE="clean"
for arg in "$@"; do
    case "$arg" in
        --from-backup) MODE="backup" ;;
        --clean) MODE="clean" ;;
        -h|--help)
            cat <<'EOF'
Usage: uninstall.sh [--clean|--from-backup]

  --clean        (default) remove only the pve-mac-monitor marker blocks
  --from-backup  restore the most recent /var/backups/pve-mac-monitor-* copy
                 (only if pve-manager has not been upgraded since install)
EOF
            exit 0
            ;;
        *)
            echo "unknown argument: $arg (try --help)" >&2
            exit 2
            ;;
    esac
done

if [[ "$(id -u)" -ne 0 ]]; then
    echo "run as root" >&2
    exit 1
fi

# Locate the patchers: repo checkout first, then the installed copy.
PATCH_DIR=""
for candidate in "${REPO_DIR}/src" "$LIB_DIR"; do
    if [[ -f "${candidate}/patch-mac-backend.py" && -f "${candidate}/patch-mac-frontend.py" ]]; then
        PATCH_DIR="$candidate"
        break
    fi
done
if [[ -z "$PATCH_DIR" ]]; then
    echo "ABORT: patch-mac-backend.py / patch-mac-frontend.py not found." >&2
    echo "       Looked in ${REPO_DIR}/src and ${LIB_DIR}." >&2
    echo "       Re-run the installer from the repo, or run this script from a checkout." >&2
    exit 4
fi

if [[ "$MODE" == "backup" ]]; then
    LATEST="$(ls -dt /var/backups/pve-mac-monitor-* 2>/dev/null | head -n1 || true)"
    if [[ -z "$LATEST" ]]; then
        echo "no backup found at /var/backups/pve-mac-monitor-*" >&2
        exit 2
    fi
    echo "restoring from ${LATEST}"
    if [[ -f "${LATEST}${NODES_PM}" ]]; then
        cp -a "${LATEST}${NODES_PM}" "$NODES_PM"
        echo "restored $NODES_PM"
    else
        echo "WARN: ${NODES_PM} missing in backup" >&2
    fi
    if [[ -f "${LATEST}${PVE_JS}" ]]; then
        cp -a "${LATEST}${PVE_JS}" "$PVE_JS"
        echo "restored $PVE_JS"
    else
        echo "WARN: ${PVE_JS} missing in backup" >&2
    fi
else
    PVE_NODES_PM="$NODES_PM" python3 "${PATCH_DIR}/patch-mac-backend.py" --remove
    PVE_MGR_JS="$PVE_JS" python3 "${PATCH_DIR}/patch-mac-frontend.py" --remove
fi

# Remove only our marked block; keep any other schedules in the same file.
if [[ -f "$CRON_FILE" ]]; then
    CRON_BEGIN="$CRON_BEGIN" CRON_END="$CRON_END" python3 - "$CRON_FILE" <<'PY'
import os
import sys

path = sys.argv[1]
begin, end = os.environ["CRON_BEGIN"], os.environ["CRON_END"]
raw = open(path).read().splitlines()

out, inside = [], False
for line in raw:
    stripped = line.strip()
    if stripped == begin:
        inside = True
        continue
    if stripped == end:
        inside = False
        continue
    if inside:
        continue
    out.append(line)

while out and not out[-1].strip():
    out.pop()

# Only the auto-generated header/comment left: drop the file entirely.
meaningful = [line for line in out if line.strip() and not line.lstrip().startswith("#")]
if meaningful:
    tmp = path + ".tmp"
    open(tmp, "w").write("\n".join(out) + "\n")
    os.replace(tmp, path)
    print("kept other schedules in {} (pve-mac-monitor block removed)".format(path))
else:
    os.unlink(path)
    print("removed {}".format(path))
PY
fi

systemctl disable --now pve-mac-monitor.timer 2>/dev/null || true
systemctl disable --now pve-mac-monitor.service 2>/dev/null || true
rm -f "${UNIT_DIR}/pve-mac-monitor.service" "${UNIT_DIR}/pve-mac-monitor.timer" "$COLLECTOR_DST"
# Remove the installed copy of the patchers/uninstaller. Only when we are
# running from the installed copy (a repo checkout does not own LIB_DIR).
if [[ "$PATCH_DIR" == "$LIB_DIR" ]]; then
    rm -f "$UNINSTALL_DST"
    rm -rf "$LIB_DIR"
fi
systemctl daemon-reload 2>/dev/null || true
systemctl restart pvedaemon.service
systemctl restart pveproxy.service

echo "done. State kept at /var/lib/pve-mac-monitor (remove manually if desired)."
echo "Hard-refresh the browser (Ctrl+Shift+R)."
