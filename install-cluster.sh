#!/usr/bin/env bash
# install-cluster.sh — run install.sh on every node, clustered or standalone.
#
# The monitor is per-node by design: the MAC count comes from the local bridge
# FDB, each Hetzner server has its own 32-MAC limit, and the Node Summary API
# is served by the node that owns it (proxyto => 'node'). The GUI JavaScript
# is served by whichever node you connect to, so every node needs the patch.
# This script just drives install.sh on each node over ssh.
#
# Usage: ./install-cluster.sh [--check-only] [--force] [--retention HOURS]
#                             [--ref REF] [--nodes "n1 n2"] [--yes] [--no-verify]
#
# Node discovery: --nodes, else /etc/pve/nodes (cluster), else pvecm, else the
# local host. Standalone servers (no cluster) work too: list them with
# --nodes and make sure root ssh to them is possible.
set -euo pipefail

REPO_SLUG="${MAC_REPO:-ocaflash/proxmox-summary-enhancement}"
REPO_REF="${MAC_REF:-main}"
# BASH_SOURCE is unset when this script is piped through bash (curl | bash).
SCRIPT_SRC="${BASH_SOURCE[0]:-}"
PIPED=0
if [[ -n "$SCRIPT_SRC" && -f "$SCRIPT_SRC" ]]; then
    SELF_DIR="$(cd "$(dirname "$SCRIPT_SRC")" && pwd)"
else
    SELF_DIR="$(pwd)"
    PIPED=1
fi

PASS_ARGS=()
CHECK_ONLY=0
ASSUME_YES=0
VERIFY=1
NODE_LIST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-only) CHECK_ONLY=1; PASS_ARGS+=("--check-only") ;;
        --force) PASS_ARGS+=("--force") ;;
        --no-verify) VERIFY=0 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --retention)
            [[ $# -lt 2 ]] && { echo "--retention requires a value" >&2; exit 2; }
            PASS_ARGS+=("--retention" "$2"); shift
            ;;
        --retention=*) PASS_ARGS+=("$1") ;;
        --ref)
            [[ $# -lt 2 ]] && { echo "--ref requires a value" >&2; exit 2; }
            REPO_REF="$2"; shift
            ;;
        --ref=*) REPO_REF="${1#*=}" ;;
        --nodes)
            [[ $# -lt 2 ]] && { echo "--nodes requires a space separated list" >&2; exit 2; }
            NODE_LIST="$2"; shift
            ;;
        --nodes=*) NODE_LIST="${1#*=}" ;;
        -h|--help)
            cat <<'EOF'
Usage: ./install-cluster.sh [options]

Installs pve-mac-monitor on every node: cluster members are detected
automatically, standalone servers are listed with --nodes.

  --check-only       dry run on each node (no changes)
  --force            bypass the pve-manager version guard
  --retention HOURS  history retention per node (1..8760, default 24)
  --ref REF          branch/tag/commit of the project to install
  --nodes "a b c"    explicit node list instead of cluster detection
  --yes, -y          do not ask for confirmation
  --no-verify        skip the post-install pvesh check

Uninstall everywhere: ./install-cluster.sh --nodes ... (then run
pve-mac-monitor-uninstall on each node), or loop manually:
  for n in $(ls /etc/pve/nodes); do ssh root@$n pve-mac-monitor-uninstall; done
EOF
            exit 0
            ;;
        *)
            echo "unknown argument: $1 (try --help)" >&2
            exit 2
            ;;
    esac
    shift
done

if [[ "$(id -u)" -ne 0 ]]; then
    echo "run as root" >&2
    exit 1
fi

LOCAL_NODE="$(pvecm nodename 2>/dev/null || hostname -s)"
LOCAL_HOSTNAME="$(hostname -s)"

# Run a pvesh query on a node: locally for this host, over ssh otherwise.
# Works for clustered nodes AND for standalone servers listed with --nodes
# (in a cluster the local pvesh could proxy, but ssh works in both setups).
node_pvesh() {
    local node="$1" path="$2"
    shift 2
    if [[ "$node" == "$LOCAL_NODE" || "$node" == "$LOCAL_HOSTNAME" ]]; then
        pvesh get "$path" --output-format json "$@" 2>/dev/null
    else
        ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
            "root@${node}" "pvesh get $(printf '%q' "$path") --output-format json $*" 2>/dev/null
    fi
}

node_is_local() {
    [[ "$1" == "$LOCAL_NODE" || "$1" == "$LOCAL_HOSTNAME" ]]
}

# Standalone PVE also ships pvecm, but 'pvecm status' then prints an error.
# A cluster only exists when corosync.conf is present.
cluster_present() {
    [[ -f /etc/pve/corosync.conf ]] && return 0
    pvecm status 2>/dev/null | grep -q '^Cluster information' && return 0
    return 1
}

detect_nodes() {
    if [[ -n "$NODE_LIST" ]]; then
        printf '%s\n' $NODE_LIST
        return
    fi
    if [[ -d /etc/pve/nodes ]]; then
        ls -1 /etc/pve/nodes 2>/dev/null
        return
    fi
    if command -v pvecm >/dev/null 2>&1; then
        pvecm nodes 2>/dev/null | awk 'NR > 1 && NF >= 3 { print $3 }'
        return
    fi
    printf '%s\n' "$LOCAL_NODE"
}

NODES="$(detect_nodes | awk 'NF' | sort -u)"
if [[ -z "$NODES" ]]; then
    echo "ABORT: no nodes detected (not a cluster and pvecm unavailable?)" >&2
    echo "       Pass --nodes \"node1 node2\"" >&2
    exit 3
fi

# One installer copy for every node: local file when present, else downloaded.
INSTALLER=""
TMP_INSTALLER=""
# End with `true`: an EXIT trap whose last command fails would override
# the script exit status.
cleanup() { [[ -n "$TMP_INSTALLER" ]] && rm -f "$TMP_INSTALLER"; true; }
trap cleanup EXIT INT TERM

if [[ "$PIPED" -eq 0 && -f "${SELF_DIR}/install.sh" ]]; then
    INSTALLER="${SELF_DIR}/install.sh"
else
    TMP_INSTALLER="$(mktemp "${TMPDIR:-/var/tmp}/pve-mac-install.XXXXXX")"
    URL="https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_REF}/install.sh"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 "$URL" -o "$TMP_INSTALLER"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=60 -O "$TMP_INSTALLER" "$URL"
    else
        echo "need curl or wget to download install.sh" >&2
        exit 4
    fi
    INSTALLER="$TMP_INSTALLER"
fi

echo "== pve-mac-monitor cluster install =="
echo "local node: ${LOCAL_NODE}"
echo "nodes:      $(echo "$NODES" | tr '\n' ' ')"
echo "installer:  ${REPO_SLUG}@${REPO_REF}"
echo "options:    ${PASS_ARGS[*]:-<none>}"
echo

if [[ "$ASSUME_YES" -eq 0 && "$CHECK_ONLY" -eq 0 ]]; then
    if [[ ! -t 0 ]]; then
        echo "ABORT: non-interactive and no --yes given" >&2
        exit 2
    fi
    read -r -p "Patch all listed nodes now? [y/N] " answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) echo "aborted"; exit 0 ;;
    esac
fi

# ---------- pre-flight: nothing is patched unless every node is reachable ----
echo "== pre-flight =="
UNREACHABLE=()
for node in $NODES; do
    if node_is_local "$node"; then
        printf '%-16s local (%s)\n' "$node" "$(pveversion 2>/dev/null | head -n1)"
        continue
    fi
    remote_ver="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
                    "root@${node}" "pveversion 2>/dev/null | head -n1" 2>/dev/null || true)"
    if [[ -z "$remote_ver" ]]; then
        printf '%-16s UNREACHABLE\n' "$node"
        UNREACHABLE+=("$node")
    else
        printf '%-16s %s\n' "$node" "$remote_ver"
    fi
done
if ((${#UNREACHABLE[@]})); then
    echo >&2
    echo "ABORT: unreachable over ssh: ${UNREACHABLE[*]}" >&2
    echo "       Nothing was changed. Fix root ssh access (or pass --nodes) and retry." >&2
    exit 3
fi

# A degraded cluster is not a reason to refuse, but restarting services on a
# node that has lost quorum should be a conscious decision.
if cluster_present; then
    if pvecm status 2>/dev/null | grep -q 'Quorate:.*Yes'; then
        echo "cluster: quorate"
    else
        echo "WARN: cluster is not quorate; patching one node is still safe (no" >&2
        echo "      cluster config is touched), but check 'pvecm status' first." >&2
    fi
else
    echo "cluster: none detected (standalone node(s), ssh-based rollout)"
fi
echo

FAILED=()
for node in $NODES; do
    echo "---- ${node} ----"
    if node_is_local "$node"; then
        if ! MAC_REF="$REPO_REF" bash "$INSTALLER" "${PASS_ARGS[@]+"${PASS_ARGS[@]}"}"; then
            FAILED+=("$node")
        fi
    else
        # Stream the installer over ssh: no shared filesystem needed, and each
        # node fetches the project archive itself.
        remote_cmd="MAC_REF=$(printf '%q' "$REPO_REF") bash -s --"
        for arg in ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}; do
            remote_cmd+=" $(printf '%q' "$arg")"
        done
        if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
                 "root@${node}" "$remote_cmd" < "$INSTALLER"; then
            FAILED+=("$node")
        fi
    fi
    echo
done

if [[ "$VERIFY" -eq 1 && "$CHECK_ONLY" -eq 0 ]]; then
    echo "== verification =="
    printf '%-16s %-10s %-8s %s\n' NODE MAC API HISTORY
    for node in $NODES; do
        status_json="$(node_pvesh "$node" "/nodes/${node}/status" || true)"
        mac_field="$(tr -d ' \n' <<<"$status_json" | grep -o '"mac":{[^}]*}' | head -n1 || true)"
        used="$(grep -o '"used":[0-9]*' <<<"$mac_field" | head -n1 | cut -d: -f2)"
        total="$(grep -o '"total":[0-9]*' <<<"$mac_field" | head -n1 | cut -d: -f2)"
        hist_json="$(node_pvesh "$node" "/nodes/${node}/mac-history" --timeframe hour --cf AVERAGE || true)"
        points="$(grep -o '"time"' <<<"$hist_json" | wc -l | tr -d ' ')"
        printf '%-16s %-10s %-8s %s\n' "$node" \
            "${used:-?}/${total:-?}" "${used:+ok}" "${points} points (last hour)"
    done
    echo
    echo "Each node reports its own count. Open Node -> Summary and hard-refresh"
    echo "(Ctrl+Shift+R) once per node."
fi

if cluster_present; then
    echo "== cluster health =="
    if pvecm status 2>/dev/null | grep -q 'Quorate:.*Yes'; then
        echo "quorate: yes"
    else
        echo "WARN: cluster reports no quorum — check 'pvecm status'" >&2
    fi
    if pvecm status 2>/dev/null | grep -q '\b(online)\b'; then
        offline="$(pvecm status 2>/dev/null | awk '/^Nodes:/{f=1;next} f && /^[0-9]/{print}' | grep -v online || true)"
        if [[ -n "$offline" ]]; then
            echo "WARN: nodes not online:" >&2
            echo "$offline" >&2
        fi
    fi
    echo
fi

if ((${#FAILED[@]})); then
    echo "FAILED nodes: ${FAILED[*]}" >&2
    echo "Each node is idempotent and rolls back on its own; re-run this script" >&2
    echo "to retry, or restore with: ssh root@<node> pve-mac-monitor-uninstall --from-backup" >&2
    exit 5
fi
echo "all nodes done"
