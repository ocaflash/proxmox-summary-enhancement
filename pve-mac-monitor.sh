#!/usr/bin/env bash
# pve-mac-monitor.sh — Hetzner MAC-limit sampler for Proxmox VE.
#
# MAC counting logic is unchanged from pve-mac-monitor-orig.sh: running guests
# from qm/pct, external bridges (vmbr* with an en*/eth*/bond* port), guest ports
# (tap*/veth*/fwpr*), then `bridge fdb show` filtered to dynamic unicast entries
# of those ports. Only the bookkeeping around it is new:
#   - state.json + history.json ring (needed by the Summary UI)
#   - configurable retention, atomic writes, flock, diagnostics
#
# Deployed as /usr/local/bin/pve-mac-monitor and run from cron
# (/etc/cron.d/pve-mac-monitor, every minute).
#
# Env: MAC_STATE_DIR, MAC_LIMIT (32), MAC_WARN (28), MAC_RETENTION_HOURS (24),
#      MAC_MAX_POINTS, MAC_SAMPLE_INTERVAL (60),
#      MAC_VERBOSE=1 (diagnostics on stdout), MAC_DEBUG=1 (also dump FDB)
set -euo pipefail
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
DEBUG="${MAC_DEBUG:-0}"

case "$RETENTION_HOURS" in
    ''|*[!0-9]*) echo "pve-mac-monitor: invalid MAC_RETENTION_HOURS='$RETENTION_HOURS'" >&2; exit 1 ;;
esac
if ((RETENTION_HOURS < 1 || RETENTION_HOURS > 8760)); then
    echo "pve-mac-monitor: MAC_RETENTION_HOURS must be 1..8760" >&2
    exit 1
fi
case "$SAMPLE_INTERVAL" in ''|*[!0-9]*|0) SAMPLE_INTERVAL=60 ;; esac

mkdir -p "$STATE_DIR"
TMP_FDB=$(mktemp "${TMPDIR:-/var/tmp}/pve_fdb_live.XXXXXX")
TMP_FDB_RAW=$(mktemp "${TMPDIR:-/var/tmp}/pve_fdb_raw.XXXXXX")
trap 'rm -f "$TMP_FDB" "$TMP_FDB_RAW"' EXIT SIGINT SIGTERM

# Do not let two cron runs interleave their state/history writes.
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 0
fi

# 1. Running guests — one call per type (unchanged).
RUNNING_VMS=$(qm list 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $3 == "running" { print $1 }' || true)
RUNNING_LXCS=$(pct list 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {for(i=2;i<=NF;i++) if($i=="running") {print $1; break}}' || true)

declare -A RUNNING_MAP=()
RUNNING_COUNT=0
for id in $RUNNING_VMS $RUNNING_LXCS; do
    if [[ -n "$id" ]]; then RUNNING_MAP[$id]=1; RUNNING_COUNT=$((RUNNING_COUNT + 1)); fi
done

# 2. Extract the VMID from a port name (unchanged).
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

# 3. One sysfs pass: external bridges + guest ports of running guests.
declare -a EXT_BRIDGES_ARR=()
declare -A GUEST_PORT_SET=()
BRIDGES_TOTAL=0
UPLINKS=""
ALL_GUEST_COUNT=0

for brif_dir in /sys/class/net/vmbr*/brif; do
    [[ -d "$brif_dir" ]] || continue
    br=$(basename "$(dirname "$brif_dir")")
    BRIDGES_TOTAL=$((BRIDGES_TOTAL + 1))
    uplink=""

    for port_path in "$brif_dir"/*; do
        [[ -e "$port_path" ]] || continue
        port=$(basename "$port_path")

        # Physical uplink marks the bridge as external.
        if [[ -z "$uplink" ]]; then
            case "$port" in
                en*|eth*|bond*)
                    uplink="$port"
                    EXT_BRIDGES_ARR+=("$br")
                    UPLINKS="${UPLINKS} ${br}:${port}"
                    ;;
            esac
        fi

        # Guest ports of running guests only.
        case "$port" in
            tap*|veth*|fwpr*)
                ALL_GUEST_COUNT=$((ALL_GUEST_COUNT + 1))
                vmid=$(port_to_vmid "$port")
                if [[ -n "$vmid" && -n "${RUNNING_MAP[$vmid]:-}" ]]; then
                    GUEST_PORT_SET["$port"]=1
                fi
                ;;
        esac
    done
done

# 4. Bridge FDB, filtered to dynamic unicast entries of those guest ports.
HAVE_BRIDGE=0
command -v bridge >/dev/null 2>&1 && HAVE_BRIDGE=1
FDB_RAW_LINES=0

if ((${#EXT_BRIDGES_ARR[@]} > 0 && ${#GUEST_PORT_SET[@]} > 0)); then
    guest_ports="${!GUEST_PORT_SET[*]}"

    # Capture the raw output once (same command the original piped into awk);
    # this gives the debug dump and the "entries seen" counter for free.
    for br in "${EXT_BRIDGES_ARR[@]}"; do
        bridge fdb show br "$br" 2>/dev/null >> "$TMP_FDB_RAW" || true
    done
    FDB_RAW_LINES=$(wc -l < "$TMP_FDB_RAW" | awk '{ print $1 + 0 }')

    awk -v ports="$guest_ports" '
        BEGIN { n = split(ports, a, " "); for (i=1; i<=n; i++) if (a[i] != "") guest[a[i]] = 1 }
        $1 ~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/ && $0 !~ /permanent/ && $3 in guest && substr($1, 2, 1) ~ /^[02468ace]$/ {
            print tolower($1)
        }
    ' "$TMP_FDB_RAW" >> "$TMP_FDB" || true
fi

TOTAL=$(sort -u "$TMP_FDB" | awk 'END { print NR + 0 }')

# 5. Verbose / debug output (stdout only; cron discards it).
if [[ "$VERBOSE" == "1" ]]; then
    echo "=== pve-mac-monitor ==="
    echo "bridges (vmbr*)      : ${BRIDGES_TOTAL}"
    echo "external (with uplink): ${#EXT_BRIDGES_ARR[@]}${UPLINKS:+ ->${UPLINKS}}"
    echo "running guests       : ${RUNNING_COUNT}${RUNNING_VMS:+ (vms:${RUNNING_VMS//$'\n'/ })}${RUNNING_LXCS:+ (cts:${RUNNING_LXCS//$'\n'/ })}"
    echo "guest ports (sysfs)  : ${ALL_GUEST_COUNT} total, ${#GUEST_PORT_SET[@]} of running guests"
    echo "fdb lines read       : ${FDB_RAW_LINES}"
    echo "bridge command       : $([[ "$HAVE_BRIDGE" -eq 1 ]] && echo yes || echo NO)"
    echo
    echo "=== FDB live MAC addresses (external unicast) ==="
    sort -u "$TMP_FDB"
    echo "total unique: ${TOTAL}"

    if [[ "$DEBUG" == "1" && -s "$TMP_FDB_RAW" ]]; then
        echo
        echo "=== raw bridge fdb output ==="
        cat "$TMP_FDB_RAW"
    fi

    if [[ "$DEBUG" == "1" && ${#GUEST_PORT_SET[@]} -gt 0 ]]; then
        echo
        echo "=== fdb entries per guest port ==="
        for p in "${!GUEST_PORT_SET[@]}"; do
            n=$(awk -v p="$p" '$2 == "dev" && $3 == p { c++ } END { print c + 0 }' "$TMP_FDB_RAW")
            echo "  ${p}: ${n}"
        done
    fi

    if [[ "$TOTAL" -eq 0 ]]; then
        echo
        echo "0 MACs collected. Checks, in order:"
        echo "  1) running guests:      qm list; pct list"
        echo "  2) bridges with uplink: ip -br link | grep vmbr"
        echo "  3) guest ports:         ls /sys/class/net/vmbr0/brif"
        echo "  4) fdb has them:        bridge fdb show br vmbr0 | grep -E 'tap|veth|fwpr'"
        echo "  5) dynamic unicast:     entries marked 'permanent' or multicast are excluded"
        echo "See MAC_DEBUG=1 for the raw fdb dump."
    fi
fi

# 6. History ring + state.json, written atomically.
NOW=$(date +%s)
DIAG="bridges=${BRIDGES_TOTAL};external=${#EXT_BRIDGES_ARR[@]};uplinks=${UPLINKS# };running=${RUNNING_COUNT};guest_ports=${#GUEST_PORT_SET[@]};all_guest_ports=${ALL_GUEST_COUNT};fdb_lines=${FDB_RAW_LINES};bridge_cmd=${HAVE_BRIDGE}"

# Older installs kept a JSONL file; start clean instead of failing to parse it.
if [[ -f "$HISTORY_FILE" ]] && ! head -c 1 "$HISTORY_FILE" 2>/dev/null | grep -q '\['; then
    mv -f "$HISTORY_FILE" "${HISTORY_FILE}.jsonl.old" 2>/dev/null || true
fi

PEAKS=$(python3 - "$HISTORY_FILE" "$STATE_FILE" "$NOW" "$TOTAL" \
                      "$MAC_LIMIT" "$MAC_WARN" "$RETENTION_HOURS" "$SAMPLE_INTERVAL" \
                      "$DIAG" <<'PY'
import json
import os
import socket
import sys
from datetime import datetime

hist_path, state_path = sys.argv[1], sys.argv[2]
now, total, limit, warn = (int(sys.argv[i]) for i in (3, 4, 5, 6))
retention_hours, interval = int(sys.argv[7]), int(sys.argv[8])
diag = {}
for item in sys.argv[9].split(";"):
    key, sep, value = item.partition("=")
    if sep:
        diag[key] = value

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
    t, v = as_num(point.get("t")), as_num(point.get("v"))
    if t is not None and v is not None:
        ring.append({"t": int(t), "v": int(v)})

if ring and ring[-1]["t"] == now:
    ring[-1] = {"t": now, "v": total}
else:
    ring.append({"t": now, "v": total})

cutoff = now - retention_hours * 3600
ring = [p for p in ring if p["t"] >= cutoff]

# Full resolution for the last 24h, 5-minute averages before that.
if retention_hours > 24:
    recent_start = now - RECENT_SECONDS
    recent = [p for p in ring if p["t"] >= recent_start]
    buckets = {}
    for p in ring:
        if p["t"] < recent_start:
            buckets.setdefault(p["t"] // OLD_BUCKET_SECONDS, []).append(p["v"])
    older = [{"t": k * OLD_BUCKET_SECONDS, "v": int(round(sum(v) / len(v)))}
             for k, v in sorted(buckets.items())]
    ring = older + recent

max_points = max(10, int(retention_hours * 3600 / max(interval, 1) * 0.75))
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
    "diag": diag,
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
) || {
    logger -t pve-mac-monitor "collector failed to write ${STATE_FILE}" 2>/dev/null || true
    exit 1
}

read -r MAX_15MIN MAX_1H MAX_24H <<< "$PEAKS"

logger -t pve-mac-monitor "MAC: $TOTAL | max 15m:$MAX_15MIN 1h:$MAX_1H 24h:$MAX_24H" 2>/dev/null || true
