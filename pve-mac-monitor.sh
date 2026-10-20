#!/usr/bin/env bash
# pve-mac-monitor.sh — Hetzner MAC-limit sampler for Proxmox VE.
#
# Counts active unicast MACs of running guests on bridges that have a physical
# uplink (bridge FDB), keeps a history ring and publishes state.json for the
# Node Summary patch (see install.sh).
#
# History: /var/lib/pve-mac-monitor/history.json, a JSON array of
# {"t": <epoch seconds>, "v": <mac count>} points, one per run, trimmed to
# MAC_RETENTION_HOURS. Points older than 24h are compacted into 5-minute
# averages, so long retention stays cheap to read.
#
# Deployed as /usr/local/bin/pve-mac-monitor and run from cron
# (/etc/cron.d/pve-mac-monitor, every minute).
# Env overrides: MAC_STATE_DIR, MAC_LIMIT, MAC_WARN, MAC_RETENTION_HOURS,
#                MAC_MAX_POINTS, MAC_SAMPLE_INTERVAL, MAC_VERBOSE=1
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

STATE_DIR="${MAC_STATE_DIR:-/var/lib/pve-mac-monitor}"
STATE_FILE="${STATE_DIR}/state.json"
HISTORY_FILE="${STATE_DIR}/history.json"
LOCK_FILE="${STATE_DIR}/.lock"
MAC_LIMIT="${MAC_LIMIT:-32}"
MAC_WARN="${MAC_WARN:-28}"
RETENTION_HOURS="${MAC_RETENTION_HOURS:-24}"
SAMPLE_INTERVAL="${MAC_SAMPLE_INTERVAL:-60}"
VERBOSE="${MAC_VERBOSE:-0}"

case "$RETENTION_HOURS" in
    ''|*[!0-9]*) echo "pve-mac-monitor: invalid MAC_RETENTION_HOURS='$RETENTION_HOURS'" >&2; exit 1 ;;
esac
if ((RETENTION_HOURS < 1 || RETENTION_HOURS > 8760)); then
    echo "pve-mac-monitor: MAC_RETENTION_HOURS must be 1..8760" >&2
    exit 1
fi
case "$SAMPLE_INTERVAL" in
    ''|*[!0-9]*|0) SAMPLE_INTERVAL=60 ;;
esac

# Full-resolution points for the last 24h, 5-minute buckets before that.
if ((RETENTION_HOURS <= 24)); then
    DEFAULT_MAX_POINTS=$((RETENTION_HOURS * 3600 / SAMPLE_INTERVAL + 10))
else
    DEFAULT_MAX_POINTS=$((86400 / SAMPLE_INTERVAL + (RETENTION_HOURS - 24) * 12 + 50))
fi
MAX_POINTS="${MAC_MAX_POINTS:-$DEFAULT_MAX_POINTS}"
case "$MAX_POINTS" in
    ''|*[!0-9]*|0) MAX_POINTS=$DEFAULT_MAX_POINTS ;;
esac

umask 022
if ! mkdir -p "$STATE_DIR"; then
    echo "pve-mac-monitor: cannot create $STATE_DIR" >&2
    exit 1
fi

# Never let overlapping cron runs corrupt the history ring.
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE" || exit 1
    flock -n 9 || exit 0
fi

TMP_FDB="$(mktemp "${TMPDIR:-/var/tmp}/pve-mac-fdb.XXXXXX")" || exit 1
trap 'rm -f "$TMP_FDB"' EXIT INT TERM

# 1. Running guests (one call per type).
RUNNING_VMS="$(qm list 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $3 == "running" { print $1 }' || true)"
RUNNING_LXCS="$(pct list 2>/dev/null | awk '$1 ~ /^[0-9]+$/ { for (i = 2; i <= NF; i++) if ($i == "running") { print $1; break } }' || true)"

RUNNING_IDS=" ${RUNNING_VMS} ${RUNNING_LXCS} "

# 2. Extract VMID from a guest port name.
port_to_vmid() {
    local port=$1 vmid=""
    case "$port" in
        tap*)  vmid=${port#tap};  vmid=${vmid%%i*} ;;
        veth*) vmid=${port#veth}; vmid=${vmid%%i*} ;;
        fwpr*) vmid=${port#fwpr}; vmid=${vmid%%p*} ;;
        *) return 1 ;;
    esac
    printf '%s' "$vmid"
}

# 3. Single sysfs pass: external bridges + active guest ports.
declare -a EXT_BRIDGES=()
GUEST_PORTS=""
GUEST_COUNT=0

for brif_dir in /sys/class/net/vmbr*/brif; do
    [[ -d "$brif_dir" ]] || continue
    br="$(basename "$(dirname "$brif_dir")")"
    has_uplink=0

    for port_path in "$brif_dir"/*; do
        [[ -e "$port_path" ]] || continue
        port="$(basename "$port_path")"

        if [[ "$has_uplink" -eq 0 ]]; then
            case "$port" in
                en*|eth*|bond*) has_uplink=1; EXT_BRIDGES+=("$br") ;;
            esac
        fi

        case "$port" in
            tap*|veth*|fwpr*)
                vmid="$(port_to_vmid "$port" || true)"
                if [[ -n "$vmid" && "$RUNNING_IDS" == *" $vmid "* ]]; then
                    GUEST_PORTS="${GUEST_PORTS} ${port}"
                    GUEST_COUNT=$((GUEST_COUNT + 1))
                fi
                ;;
        esac
    done
done

# 4. Query FDB once per external bridge; keep dynamic unicast entries that
#    belong to a running guest port.
if ((${#EXT_BRIDGES[@]} > 0 && GUEST_COUNT > 0)); then
    guest_ports="$GUEST_PORTS"
    for br in "${EXT_BRIDGES[@]}"; do
        bridge fdb show br "$br" 2>/dev/null || true
    done | awk -v ports="$guest_ports" '
        BEGIN {
            n = split(ports, a, " ")
            for (i = 1; i <= n; i++) if (a[i] != "") guest[a[i]] = 1
        }
        $1 ~ /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/ &&
        $2 == "dev" &&
        $0 !~ /permanent/ &&
        ($3 in guest) &&
        substr($1, 2, 1) ~ /^[02468aceACE]$/ {
            print tolower($1)
        }
    ' | sort -u > "$TMP_FDB" || true
fi

TOTAL=0
if [[ -s "$TMP_FDB" ]]; then
    TOTAL="$(wc -l < "$TMP_FDB" | tr -d ' ')"
fi
case "$TOTAL" in ''|*[!0-9]*) TOTAL=0 ;; esac

# 5. Update history ring + state.json atomically (single python pass, no jq).
NOW="$(date +%s)"
PEAKS="$(python3 - "$HISTORY_FILE" "$STATE_FILE" "$NOW" "$TOTAL" \
                        "$MAC_LIMIT" "$MAC_WARN" "$MAX_POINTS" "$SAMPLE_INTERVAL" \
                        "$RETENTION_HOURS" <<'PY'
import json
import os
import socket
import sys
from datetime import datetime

hist_path, state_path = sys.argv[1], sys.argv[2]
now = int(sys.argv[3])
total = int(sys.argv[4])
limit = int(sys.argv[5])
warn = int(sys.argv[6])
max_points = int(sys.argv[7])
interval = int(sys.argv[8])
retention_hours = int(sys.argv[9])

RECENT_SECONDS = 86400
OLD_BUCKET_SECONDS = 300


def load_ring(path):
    try:
        with open(path) as fh:
            data = json.load(fh)
        return data if isinstance(data, list) else []
    except Exception:
        return []


def as_num(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value


ring = []
for point in load_ring(hist_path):
    if not isinstance(point, dict):
        continue
    t = as_num(point.get("t"))
    v = as_num(point.get("v"))
    if t is not None and v is not None:
        ring.append({"t": int(t), "v": int(v)})

if ring and ring[-1]["t"] == now:
    ring[-1] = {"t": now, "v": total}
else:
    ring.append({"t": now, "v": total})

cutoff = now - retention_hours * 3600
ring = [p for p in ring if p["t"] >= cutoff]

# Keep the last 24h at full resolution; compact older points into 5-minute
# averages so week/month/year retention does not balloon the file.
if retention_hours > 24:
    recent_start = now - RECENT_SECONDS
    recent = [p for p in ring if p["t"] >= recent_start]
    buckets = {}
    for p in ring:
        if p["t"] >= recent_start:
            continue
        key = p["t"] // OLD_BUCKET_SECONDS
        buckets.setdefault(key, []).append(p["v"])
    older = [
        {"t": key * OLD_BUCKET_SECONDS, "v": int(round(sum(vals) / len(vals)))}
        for key, vals in sorted(buckets.items())
    ]
    ring = older + recent

if len(ring) > max_points:
    ring = ring[-max_points:]


def peak(seconds):
    since = now - seconds
    values = [p["v"] for p in ring if p["t"] >= since]
    return max(values) if values else 0


state = {
    "node": socket.gethostname(),
    "current": total,
    "limit": limit,
    "warn": warn,
    "max_15min": peak(900),
    "max_1h": peak(3600),
    "max_24h": peak(86400),
    "samples": len(ring),
    "interval": interval,
    "retention_hours": retention_hours,
    "timestamp": datetime.fromtimestamp(now).astimezone().isoformat(timespec="seconds"),
    "timestamp_unix": now,
}


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(obj, fh, separators=(",", ":"))
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o644)
    except OSError:
        pass


write_json(hist_path, ring)
write_json(state_path, state)
print("{} {} {}".format(state["max_15min"], state["max_1h"], state["max_24h"]))
PY
)" || {
    if command -v logger >/dev/null 2>&1; then
        logger -t pve-mac-monitor "collector failed to update ${STATE_FILE}"
    fi
    exit 1
}
read -r MAX_15MIN MAX_1H MAX_24H <<< "$PEAKS"

# 6. Journal summary; stdout only when run manually with MAC_VERBOSE=1.
if command -v logger >/dev/null 2>&1; then
    logger -t pve-mac-monitor "MAC: ${TOTAL}/${MAC_LIMIT} | max 15m:${MAX_15MIN} 1h:${MAX_1H} 24h:${MAX_24H}"
fi

if [[ "$VERBOSE" == "1" ]]; then
    echo "=== FDB live MACs (external bridges, unicast) ==="
    cat "$TMP_FDB"
    echo "total: ${TOTAL} / limit ${MAC_LIMIT}"
    echo "peaks: 15m:${MAX_15MIN} 1h:${MAX_1H} 24h:${MAX_24H}"
fi
