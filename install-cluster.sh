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

SCRIPT_VERSION="2.4.0"
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
PARTIAL=0
NODE_LIST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-only) CHECK_ONLY=1; PASS_ARGS+=("--check-only") ;;
        --force) PASS_ARGS+=("--force") ;;
        --no-verify) VERIFY=0 ;;
        --partial|--continue-on-error) PARTIAL=1 ;;
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
  --yes, -y          do not ask for confirmation (needed when run without a
                     terminal: cron, CI, or 'curl | bash' with stdin closed)

Without --yes the script asks for the word 'yes'. The question is read from
stdin only, so it works when run from a checkout in a terminal; 'curl | bash'
occupies stdin with the script itself, so there --yes is required.
  --no-verify        skip the post-install pvesh check
  --partial          patch the reachable nodes even if some are unreachable
                     (default: abort before changing anything)

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
            -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
            "root@${node}" "pvesh get $(printf '%q' "$path") --output-format json $*" 2>/dev/null
    fi
}

# Node names are printed and used as ssh targets. Only names made of
# [A-Za-z0-9._-] are accepted; anything else is dropped instead of being
# stripped, so a crafted entry cannot turn into a different, valid-looking
# name. (Names go to a terminal, and escape sequences are not printed.)
valid_node_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

node_is_local() {
    [[ "$1" == "$LOCAL_NODE" || "$1" == "$LOCAL_HOSTNAME" ]]
}

# Standalone PVE also ships pvecm, but 'pvecm status' then prints an error.
# A cluster only exists when corosync.conf is present.
ssh_error_set() {
    SSH_ERROR_NODES="${SSH_ERROR_NODES} $1"
    SSH_ERROR_TEXT="${SSH_ERROR_TEXT}$2"$'\n'
}

ssh_error_get() {
    local want="$1" i=0
    for n in $SSH_ERROR_NODES; do
        if [[ "$n" == "$want" ]]; then
            sed -n "$((i + 1))p" <<<"$SSH_ERROR_TEXT"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

ssh_error_has() { [[ " $SSH_ERROR_NODES " == *" $1 "* ]]; }

# pvecm blocks while it waits for corosync, so every call gets a timeout.
PVECM="pvecm"
if command -v timeout >/dev/null 2>&1; then
    PVECM="timeout 10 pvecm"
fi

pvecm_out() { $PVECM "$@" 2>/dev/null || true; }

cluster_present() {
    [[ -f /etc/pve/corosync.conf ]] && return 0
    pvecm_out status | grep -q '^Cluster information'
}

detect_nodes() {
    if [[ -n "$NODE_LIST" ]]; then
        printf '%s\n' $NODE_LIST
        return
    fi

    # In a cluster, /etc/pve/nodes keeps the directory of every node that was
    # EVER joined, including ones removed with 'pvecm delnode'. Membership from
    # pvecm is the only list of nodes that still exist.
    if cluster_present; then
        members="$(pvecm_out nodes \
                    | awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]/ { print $3 }' \
                    | sed 's/[()]//g')"
        if [[ -n "$members" ]]; then
            echo "$members"
            return
        fi
    fi

    if [[ -d /etc/pve/nodes ]]; then
        ls -1 /etc/pve/nodes 2>/dev/null
        return
    fi
    printf '%s\n' "$LOCAL_NODE"
}

# /etc/pve/nodes entries that are not cluster members any more.
stale_node_dirs() {
    local member
    [[ -d /etc/pve/nodes ]] || return 0
    for dir in /etc/pve/nodes/*; do
        [[ -d "$dir" ]] || continue
        # The local node and the GUI's 'localhost' entry are never "leftovers",
        # even when --nodes lists only remote hosts.
        [[ "$(basename "$dir")" == "localhost" ]] && continue
        [[ "$(basename "$dir")" == "$LOCAL_NODE" ]] && continue
        [[ "$(basename "$dir")" == "$LOCAL_HOSTNAME" ]] && continue
        member=0
        for n in $NODES; do
            if [[ "$(basename "$dir")" == "$n" ]]; then member=1; break; fi
        done
        if [[ "$member" -eq 0 ]]; then echo "$(basename "$dir")"; fi
    done
}

RAW_NODES="$(detect_nodes | awk 'NF')"
NODES=""
DROPPED_NODES=0
while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    if valid_node_name "$n"; then
        NODES="${NODES}${n}"$'\n'
    else
        DROPPED_NODES=$((DROPPED_NODES + 1))
    fi
done <<<"$RAW_NODES"
NODES="$(printf '%s' "$NODES" | awk 'NF' | sort -u)"
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

echo "== pve-mac-monitor cluster install (script ${SCRIPT_VERSION}) =="
echo "local node: ${LOCAL_NODE}"
echo "nodes:      $(echo "$NODES" | tr '\n' ' ')"
STALE="$(stale_node_dirs | while IFS= read -r d; do valid_node_name "$d" && echo "$d"; done | tr '\n' ' ')"
if [[ "$DROPPED_NODES" -gt 0 ]]; then
    echo "WARN: ignored ${DROPPED_NODES} node entr(y/ies) with unusual characters" >&2
fi
if [[ -n "${STALE// /}" ]]; then
    echo "skipped /etc/pve/nodes entries that are not cluster members: ${STALE% }"
    echo "  (their directories stay untouched; nothing is changed outside this install)"
fi
echo "installer:  ${REPO_SLUG}@${REPO_REF}"
echo "options:    ${PASS_ARGS[*]:-<none>}"

LOCAL_IN_LIST=0
for n in $NODES; do
    if node_is_local "$n"; then LOCAL_IN_LIST=1; break; fi
done
if [[ "$LOCAL_IN_LIST" -eq 0 ]]; then
    echo
    echo "NOTE: ${LOCAL_NODE} (this node) is NOT in the list, so it will not be patched."
    echo "      Add it if you want both servers:  --nodes \"${LOCAL_NODE} ${NODES%% *}\""
fi
echo

if [[ "$ASSUME_YES" -eq 0 && "$CHECK_ONLY" -eq 0 ]]; then
    # Only stdin is used for confirmation: 'curl | bash' ties stdin to the
    # script, and /dev/tty is deliberately not used at all (a prompt can land
    # in a terminal nobody is watching, misfire on stale keystrokes, or stop a
    # background job with SIGTTIN). Run from a checkout in a real terminal, or
    # pass --yes.
    node_count="$(echo "$NODES" | wc -l | tr -d ' ')"
    node_list="$(echo "$NODES" | tr '\n' ' ' | sed 's/ *$//')"

    if [[ ! -t 0 ]]; then
        echo "ABORT: confirmation needs an interactive shell, and stdin is not a terminal." >&2
        echo "       About to patch ${node_count} node(s) as $(id -un): ${node_list}" >&2
        echo "       Re-run with --yes to confirm:" >&2
        echo "         curl -fsSL https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_REF}/install-cluster.sh \\" >&2
        echo "           | bash -s -- --nodes \"${node_list}\" --yes" >&2
        exit 2
    fi

    printf 'pve-mac-monitor: about to patch %s node(s) as %s: %s\n' \
        "$node_count" "$(id -un)" "$node_list"
    read -r -p "pve-mac-monitor: type yes to continue: " answer || answer=""
    case "$answer" in
        yes|YES|Yes) ;;
        *) echo "aborted (nothing was changed)"; exit 0 ;;
    esac
fi

# ---------- pre-flight: nothing is patched unless every node is reachable ----
echo "== pre-flight =="
UNREACHABLE=()
SSH_ERROR_NODES=""
SSH_ERROR_TEXT=""
for node in $NODES; do
    if node_is_local "$node"; then
        printf '%-16s local (%s)\n' "$node" "$(pveversion 2>/dev/null | head -n1)"
        continue
    fi
    ssh_err=""
    if remote_ver="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
                        -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
                        "root@${node}" "pveversion 2>/dev/null | head -n1" 2>&1)" \
       && [[ -n "$remote_ver" ]]; then
        printf '%-16s %s\n' "$node" "$(head -n1 <<<"$remote_ver")"
    else
        # Keep the real reason: "Permission denied (publickey)", "Could not
        # resolve hostname", "Connection refused", "Host key verification
        # failed", a login banner, ...
        ssh_err="$(printf '%s\n' "$remote_ver" \
                    | grep -v '^Warning: Permanently added' \
                    | grep -v '^[[:space:]]*$' \
                    | tail -n1 || true)"
        [[ -z "$ssh_err" ]] && ssh_err="ssh exited non-zero with no output"
        printf '%-16s UNREACHABLE  (%s)\n' "$node" "$ssh_err"
        UNREACHABLE+=("$node")
        ssh_error_set "$node" "$ssh_err"
    fi
done

if ((${#UNREACHABLE[@]})); then
    echo >&2
    if [[ "$PARTIAL" -eq 0 ]]; then
        echo "ABORT: unreachable over ssh: ${UNREACHABLE[*]}" >&2
        echo "       Nothing was changed." >&2
        echo >&2
        echo "Fixes, in order of likelihood:" >&2
        echo "  1. root ssh keys are per cluster: on this node check" >&2
        echo "       ls -l /root/.ssh/authorized_keys   # should link to /etc/pve/priv/authorized_keys" >&2
        echo "       ssh -v root@${UNREACHABLE[0]}      # shows which auth method fails" >&2
        echo "  2. name resolution: the node names must resolve from here (/etc/hosts)" >&2
        echo "       getent hosts ${UNREACHABLE[0]}" >&2
        echo "  3. if the nodes are NOT in one cluster, ssh is not preconfigured:" >&2
        echo "       ssh-copy-id root@${UNREACHABLE[0]}   # from this node" >&2
        echo >&2
        echo "Workarounds:" >&2
        echo "  - patch the reachable nodes only:  ... --partial" >&2
        echo "  - or run the installer on each server's own shell (Node -> Shell):" >&2
        echo "      curl -fsSL https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_REF}/install.sh | bash" >&2
        exit 3
    fi
    echo "WARN: --partial, skipping unreachable nodes: ${UNREACHABLE[*]}" >&2
    REACHABLE=""
    for node in $NODES; do
        if ! ssh_error_has "$node" || node_is_local "$node"; then
            REACHABLE="${REACHABLE} ${node}"
        fi
    done
    NODES="${REACHABLE# }"
    echo "       proceeding with: ${NODES}" >&2
fi

# A degraded cluster is not a reason to refuse, but restarting services on a
# node that has lost quorum should be a conscious decision.
if cluster_present; then
    if pvecm_out status | grep -q 'Quorate:.*Yes'; then
        echo "cluster: quorate"
    else
        echo "WARN: cluster is not quorate; patching one node is still safe (no" >&2
        echo "      cluster config is touched), but check 'pvecm status' first." >&2
    fi
else
    echo "cluster: none detected (standalone node(s), ssh-based rollout)"
fi
echo

NODE_TOTAL=0
for node in $NODES; do NODE_TOTAL=$((NODE_TOTAL + 1)); done
echo "== installing on ${NODE_TOTAL} node(s) =="
echo "   each node downloads the project archive, patches two files, installs"
echo "   the collector and restarts pvedaemon/pveproxy — expect ~30-60s per node"
echo

FAILED=()
NODE_INDEX=0
for node in $NODES; do
    NODE_INDEX=$((NODE_INDEX + 1))
    echo "---- [${NODE_INDEX}/${NODE_TOTAL}] ${node} ----"
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
                 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
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
    if pvecm_out status | grep -q 'Quorate:.*Yes'; then
        echo "quorate: yes"
    else
        echo "WARN: cluster reports no quorum — check 'pvecm status'" >&2
    fi
    if pvecm_out status | grep -q '\b(online)\b'; then
        offline="$(pvecm_out status | awk '/^Nodes:/{f=1;next} f && /^[0-9]/{print}' | grep -v online || true)"
        if [[ -n "$offline" ]]; then
            echo "WARN: nodes not online:" >&2
            echo "$offline" >&2
        fi
    fi
    echo
fi

if ((${#UNREACHABLE[@]})); then
    echo "NOT PATCHED (unreachable): ${UNREACHABLE[*]}" >&2
    for node in "${UNREACHABLE[@]}"; do
        echo "  ${node}: $(ssh_error_get "$node")" >&2
    done
    echo "Run the installer on those nodes directly:" >&2
    echo "  curl -fsSL https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_REF}/install.sh | bash" >&2
    echo
fi

if ((${#FAILED[@]})); then
    echo "FAILED nodes: ${FAILED[*]}" >&2
    echo "Each node is idempotent and rolls back on its own; re-run this script" >&2
    echo "to retry, or restore with: ssh root@<node> pve-mac-monitor-uninstall --from-backup" >&2
    exit 5
fi
if ((${#UNREACHABLE[@]})); then
    attempted=0
    for node in $NODES; do attempted=$((attempted + 1)); done
    echo "patched: ${attempted} node(s), skipped: ${#UNREACHABLE[@]}" >&2
    echo "Re-run this script after fixing ssh to finish the rollout." >&2
    exit 6
fi

echo "all nodes done"
