#!/usr/bin/env bash
# install.sh — PVE Hetzner MAC-limit monitor installer/patcher.
#
# Self-contained: if the companion files are not next to this script, they are
# downloaded from the project repository, so a single file is enough:
#
#   curl -fsSL https://raw.githubusercontent.com/ocaflash/proxmox-summary-enhancement/main/install.sh | bash
#   # or: wget -qO- .../install.sh | bash
#
# The download source is configurable (see MAC_PROVIDER / MAC_REPO / MAC_HOST
# below), so the same script works when the project is hosted on GitLab.
#
# Version-guarded, backup-first, idempotent. Re-run it after any pve-manager
# update (package upgrades overwrite the patched files).
#
# Usage: install.sh [--check-only] [--force] [--retention HOURS] [--ref REF]
set -euo pipefail

# ---- repository source -------------------------------------------------
# Switch hosting with MAC_PROVIDER (github|gitlab) and MAC_REPO=<owner>/<repo>.
# For self-managed GitLab also set MAC_HOST (e.g. gitlab.example.com).
#
# Private projects: MAC_TOKEN=<read-only token> is sent as a header (GitLab:
# PRIVATE-TOKEN, GitHub: Authorization: Bearer). The token never appears in a
# URL, so it does not leak into logs or shell history of the download step.
REPO_PROVIDER="${MAC_PROVIDER:-github}"
REPO_SLUG="${MAC_REPO:-ocaflash/proxmox-summary-enhancement}"
REPO_REF="${MAC_REF:-main}"
REPO_TOKEN="${MAC_TOKEN:-}"
if [[ -n "$REPO_TOKEN" ]] && [[ ! "$REPO_TOKEN" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    echo "MAC_TOKEN contains unexpected characters (letters, digits, . _ : - only)" >&2
    exit 2
fi
case "$REPO_PROVIDER" in
    github) REPO_HOST="${MAC_HOST:-github.com}" ;;
    gitlab) REPO_HOST="${MAC_HOST:-gitlab.com}" ;;
    *)
        echo "unsupported MAC_PROVIDER='${REPO_PROVIDER}' (use github or gitlab)" >&2
        exit 2
        ;;
esac

# File URL for a path inside the repo. With a token, GitLab is addressed
# through the API (the web /-/raw/ endpoint only takes ?private_token=).
repo_raw_url() {
    case "$REPO_PROVIDER" in
        github)
            if [[ -n "$REPO_TOKEN" ]]; then
                printf 'https://api.github.com/repos/%s/contents/%s?ref=%s' \
                    "$REPO_SLUG" "$1" "$REPO_REF"
            else
                printf 'https://raw.githubusercontent.com/%s/%s/%s' \
                    "$REPO_SLUG" "$REPO_REF" "$1"
            fi
            ;;
        gitlab)
            if [[ -n "$REPO_TOKEN" ]]; then
                printf 'https://%s/api/v4/projects/%s/repository/files/%s/raw?ref=%s' \
                    "$REPO_HOST" "${REPO_SLUG//\//%2F}" "${1//\//%2F}" "$REPO_REF"
            else
                printf 'https://%s/%s/-/raw/%s/%s' \
                    "$REPO_HOST" "$REPO_SLUG" "$REPO_REF" "$1"
            fi
            ;;
    esac
}

# Whole-repository archive URL (one artifact, consistent commit).
repo_archive_url() {
    case "$REPO_PROVIDER" in
        github)
            if [[ -n "$REPO_TOKEN" ]]; then
                printf 'https://api.github.com/repos/%s/tarball/%s' \
                    "$REPO_SLUG" "$REPO_REF"
            else
                printf 'https://codeload.github.com/%s/tar.gz/%s' \
                    "$REPO_SLUG" "$REPO_REF"
            fi
            ;;
        gitlab) printf 'https://%s/api/v4/projects/%s/repository/archive.tar.gz?sha=%s' \
                        "$REPO_HOST" "${REPO_SLUG//\//%2F}" "$REPO_REF" ;;
    esac
}

# Human-readable project URL (messages only).
repo_web_url() {
    printf 'https://%s/%s' "$REPO_HOST" "$REPO_SLUG"
}

BACKUP_ROOT="/var/backups/pve-mac-monitor"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}-${STAMP}"

# Paths are overridable for dry-run testing against copies of the PVE files.
NODES_PM="${PVE_NODES_PM:-/usr/share/perl5/PVE/API2/Nodes.pm}"
PVE_JS="${PVE_MGR_JS:-/usr/share/pve-manager/js/pvemanagerlib.js}"
CRON_FILE="/etc/cron.d/pve-mac-monitor"
CRON_BEGIN="# >>> pve-mac-monitor BEGIN"
CRON_END="# <<< pve-mac-monitor END"
LEGACY_UNIT_DIR="/etc/systemd/system"
COLLECTOR_DST="/usr/local/bin/pve-mac-monitor"
LIB_DIR="/usr/local/lib/pve-mac-monitor"
UNINSTALL_DST="/usr/local/sbin/pve-mac-monitor-uninstall"
STATE_DIR="/var/lib/pve-mac-monitor"

# Files this installer needs. Relative to the repo root (and to this script).
PROJECT_FILES=(
    "pve-mac-monitor.sh"
    "uninstall.sh"
    "src/patch-mac-backend.py"
    "src/patch-mac-frontend.py"
    "VERSION"
)

WORK_DIR=""
CRON_BLOCK_FILE=""

cleanup() {
    if [[ -n "$CRON_BLOCK_FILE" ]]; then rm -f "$CRON_BLOCK_FILE"; fi
    if [[ -n "$WORK_DIR" ]]; then rm -rf "$WORK_DIR"; fi
    true  # never let the EXIT trap override the script exit status
}
trap cleanup EXIT INT TERM

CHECK_ONLY=0
FORCE=0
RETENTION_HOURS="${MAC_RETENTION_HOURS:-24}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-only) CHECK_ONLY=1 ;;
        --force) FORCE=1 ;;
        --retention)
            if [[ $# -lt 2 ]]; then
                echo "--retention requires a value in hours (1..8760)" >&2
                exit 2
            fi
            RETENTION_HOURS="$2"
            shift
            ;;
        --retention=*) RETENTION_HOURS="${1#*=}" ;;
        --ref)
            if [[ $# -lt 2 ]]; then
                echo "--ref requires a branch, tag or commit" >&2
                exit 2
            fi
            REPO_REF="$2"
            shift
            ;;
        --ref=*) REPO_REF="${1#*=}" ;;
        -h|--help)
            cat <<'EOF'
Usage: install.sh [--check-only] [--force] [--retention HOURS] [--ref REF]

Installs the PVE Hetzner MAC-limit monitor:
  - patches Nodes.pm + pvemanagerlib.js (marker-guarded, idempotent)
  - installs /usr/local/bin/pve-mac-monitor
  - schedules it via cron (/etc/cron.d/pve-mac-monitor, every minute)
  - adds a "MAC addresses (used)" history chart to the node Summary
  - restarts pvedaemon and pveproxy

Run it from the repo (./install.sh) or straight from the network:

  curl -fsSL https://raw.githubusercontent.com/ocaflash/proxmox-summary-enhancement/main/install.sh | bash
  curl -fsSL .../install.sh | bash -s -- --check-only

When the companion files are not next to this script they are downloaded from
the project repository into a temporary directory. Source selection:

  MAC_PROVIDER=github|gitlab   hosting (default github)
  MAC_REPO=<owner>/<repo>      repository (default
                               ocaflash/proxmox-summary-enhancement)
  MAC_HOST=<host>              self-managed GitLab host, e.g. gitlab.local
  MAC_REF=<ref>                branch/tag/commit (same as --ref)

GitLab example (variables go to bash, not to curl):

  curl -fsSL https://gitlab.com/infra/pve-mac-monitor/-/raw/main/install.sh \
    | MAC_PROVIDER=gitlab MAC_REPO=infra/pve-mac-monitor bash

or set the defaults once in the script (see the repository source block at the
top of this file), then the URL above is all a user needs.

  --check-only       print patch state and planned actions, change nothing
  --force            bypass the pve-manager version guard
  --retention HOURS  history retention, 1..8760 (default 24, or env
                     MAC_RETENTION_HOURS)
  --ref REF          git branch/tag/commit to download (default main, or env
                     MAC_REF)

History is stored in /var/lib/pve-mac-monitor/history.json. One point per
minute; points older than 24h are compacted to 5-minute averages. The Summary
chart follows the stock Hour/Day/Week/Month/Year selector, limited by this
retention.

Uninstall: pve-mac-monitor-uninstall [--from-backup]
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

case "$RETENTION_HOURS" in
    ''|*[!0-9]*)
        echo "invalid retention '$RETENTION_HOURS': expected hours 1..8760" >&2
        exit 2
        ;;
esac
if ((RETENTION_HOURS < 1 || RETENTION_HOURS > 8760)); then
    echo "invalid retention ${RETENTION_HOURS}: expected hours 1..8760" >&2
    exit 2
fi

need_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "run as root" >&2
        exit 1
    fi
}
have() { command -v "$1" >/dev/null 2>&1; }

# ---------- bootstrap: fetch companion files when missing ----------
# Header line for the configured token, or nothing when anonymous access is used.
token_header() {
    case "$REPO_PROVIDER" in
        github) printf 'Authorization: Bearer %s' "$REPO_TOKEN" ;;
        gitlab) printf 'PRIVATE-TOKEN: %s' "$REPO_TOKEN" ;;
    esac
}

download() {
    local url="$1" dst="$2" max_time="${3:-120}"
    local cfg="" rc=0
    mkdir -p "$(dirname "$dst")"

    if [[ -n "$REPO_TOKEN" ]]; then
        # -K keeps the credential out of the process list (ps) and logs.
        cfg="$(mktemp "${TMPDIR:-/var/tmp}/pve-mac-curl.XXXXXX")" || return 1
        chmod 600 "$cfg"
        {
            printf 'header = "%s"\n' "$(token_header)"
            [[ "$REPO_PROVIDER" == github ]] && \
                printf 'header = "Accept: application/vnd.github.raw"\n'
        } > "$cfg"
    fi

    if have curl; then
        curl -fsSL --retry 2 --connect-timeout 10 --max-time "$max_time" \
             ${cfg:+-K "$cfg"} "$url" -o "$dst" || rc=1
    elif have wget; then
        if [[ -n "$REPO_TOKEN" ]]; then
            wget -q --timeout="$max_time" --header="$(token_header)" -O "$dst" "$url" || rc=1
        else
            wget -q --timeout="$max_time" -O "$dst" "$url" || rc=1
        fi
    else
        echo "need curl or wget to download ${url}" >&2
        rc=1
    fi

    [[ -n "$cfg" ]] && rm -f "$cfg"
    ((rc == 0)) || return 1
    [[ -s "$dst" ]]
}

verify_checksums() {
    local dir="$1"
    if [[ ! -s "${dir}/SHA256SUMS" ]] || ! have sha256sum; then
        echo "WARN: SHA256SUMS not verified (missing file or sha256sum)" >&2
        return 0
    fi
    if (cd "$dir" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1); then
        echo "checksums OK"
        return 0
    fi
    return 1
}

validate_project() {
    local dir="$1"
    if ! bash -n "${dir}/pve-mac-monitor.sh"; then
        echo "ABORT: collector has a syntax error" >&2
        return 1
    fi
    if have python3; then
        if ! python3 -m py_compile "${dir}/src/patch-mac-backend.py" \
                                     "${dir}/src/patch-mac-frontend.py" >/dev/null 2>&1; then
            echo "ABORT: patchers have a syntax error" >&2
            return 1
        fi
        rm -rf "${dir}/src/__pycache__"
    fi
    return 0
}

# Preferred: one tarball for the whole ref. Single artifact means every file
# comes from the same commit, so a stale CDN copy can never mix versions.
fetch_tarball() {
    local dir="$1" tgz="${1}.tar.gz"
    local url
    url="$(repo_archive_url)"
    download "$url" "$tgz" 180 || return 1
    if ! tar -xzf "$tgz" -C "$dir" --strip-components=1 2>/dev/null; then
        return 1
    fi
    rm -f "$tgz"
    [[ -f "${dir}/pve-mac-monitor.sh" && -f "${dir}/src/patch-mac-backend.py" ]]
}

# Fallback: per-file download from raw.githubusercontent.
fetch_files() {
    local dir="$1" rel
    for rel in "${PROJECT_FILES[@]}"; do
        download "$(repo_raw_url "$rel")" "${dir}/${rel}" 120 || {
            echo "download failed: ${rel}" >&2
            return 1
        }
        echo "ok ${rel}"
    done
    # SHA256SUMS is optional: an older tag may not ship it.
    download "$(repo_raw_url SHA256SUMS)" "${dir}/SHA256SUMS" 60 \
        || rm -f "${dir}/SHA256SUMS"
    if [[ -s "${dir}/SHA256SUMS" ]] && ! grep -qE '^[0-9a-f]{64} ' "${dir}/SHA256SUMS"; then
        rm -f "${dir}/SHA256SUMS"
    fi
    return 0
}

bootstrap_project() {
    WORK_DIR="$(mktemp -d "${TMPDIR:-/var/tmp}/pve-mac-monitor.XXXXXX")"
    echo "-- downloading project files from ${REPO_SLUG}@${REPO_REF} --"

    if fetch_tarball "$WORK_DIR"; then
        echo "downloaded repository archive"
    else
        echo "archive download failed, falling back to individual files" >&2
        if ! fetch_files "$WORK_DIR"; then
            echo "ABORT: cannot download project files." >&2
            echo "       Private project? Pass a read-only token: MAC_TOKEN=<token>" >&2
            echo "       Clone $(repo_web_url) and run ./install.sh there." >&2
            exit 4
        fi
    fi

    if ! verify_checksums "$WORK_DIR"; then
        # A just-published ref can be served stale by the CDN for a few
        # seconds; retry once from scratch before giving up.
        echo "checksum mismatch, retrying download once" >&2
        rm -rf "${WORK_DIR:?}/"* 
        if fetch_tarball "$WORK_DIR" || fetch_files "$WORK_DIR"; then
            verify_checksums "$WORK_DIR" || {
                echo "ABORT: downloaded files do not match SHA256SUMS" >&2
                exit 4
            }
        else
            echo "ABORT: retry failed" >&2
            exit 4
        fi
    fi

    validate_project "$WORK_DIR" || exit 4
    REPO_DIR="$WORK_DIR"
}

# Resolve this script's directory. Empty when piped through bash (curl | bash).
SCRIPT_SRC="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_SRC" && -f "$SCRIPT_SRC" ]]; then
    REPO_DIR="$(cd "$(dirname "$SCRIPT_SRC")" && pwd)"
else
    REPO_DIR=""
fi

if [[ -z "$REPO_DIR" || ! -f "${REPO_DIR}/pve-mac-monitor.sh" \
      || ! -f "${REPO_DIR}/src/patch-mac-backend.py" \
      || ! -f "${REPO_DIR}/src/patch-mac-frontend.py" ]]; then
    bootstrap_project
fi

COLLECTOR_SRC="${REPO_DIR}/pve-mac-monitor.sh"
BACKEND_PATCHER="${REPO_DIR}/src/patch-mac-backend.py"
FRONTEND_PATCHER="${REPO_DIR}/src/patch-mac-frontend.py"
UNINSTALL_SRC="${REPO_DIR}/uninstall.sh"

restore_backup() {
    echo "rolling back from ${BACKUP_DIR}" >&2
    cp -a "${BACKUP_DIR}${NODES_PM}" "$NODES_PM" 2>/dev/null || true
    cp -a "${BACKUP_DIR}${PVE_JS}" "$PVE_JS" 2>/dev/null || true
    systemctl restart pvedaemon.service 2>/dev/null || true
    systemctl restart pveproxy.service 2>/dev/null || true
}

echo "== pve-mac-monitor install (${STAMP}) =="
# --check-only is read-only, so it may run unprivileged (handy for dry-runs
# against copies of the PVE files); every other mode needs root.
if [[ "$CHECK_ONLY" -eq 0 ]]; then
    need_root
fi

# ---------- 1. Version guard ----------
echo "-- version guard --"
PVE_VER="$(pveversion 2>/dev/null | head -n1 || true)"
PVEMGR_VER="$(dpkg-query -W -f='${Version}' pve-manager 2>/dev/null || echo unknown)"
PWT_VER="$(dpkg-query -W -f='${Version}' proxmox-widget-toolkit 2>/dev/null || echo unknown)"
echo "pveversion: ${PVE_VER:-unknown}"
echo "pve-manager: ${PVEMGR_VER}"
echo "proxmox-widget-toolkit: ${PWT_VER}"

if [[ "$FORCE" -eq 0 ]]; then
    case "$PVEMGR_VER" in
        8.*|9.*) ;;
        *)
            echo "ABORT: pve-manager ${PVEMGR_VER} is outside the tested 8.x/9.x range." >&2
            echo "       Inspect anchors with --check-only, or re-run with --force." >&2
            exit 3
            ;;
    esac
else
    echo "WARN: --force, skipping version abort"
fi

# ---------- 2. Targets and prerequisites ----------
for f in "$NODES_PM" "$PVE_JS" "$COLLECTOR_SRC" "$BACKEND_PATCHER" "$FRONTEND_PATCHER"; do
    if [[ ! -f "$f" ]]; then
        echo "missing required file: $f" >&2
        exit 4
    fi
done
if ! have python3; then
    echo "python3 is required" >&2
    exit 5
fi

echo "-- prereqs --"
for c in qm pct bridge; do
    if have "$c"; then echo "ok $c"; else echo "WARN: $c not found (collector will count 0)"; fi
done
if have flock; then echo "ok flock"; else echo "WARN: flock not found (overlap protection disabled)"; fi
if have crontab; then echo "ok cron"; else echo "WARN: cron not found (install cron, or run the collector manually)"; fi
if have perl; then echo "ok perl"; else echo "WARN: perl not found (cannot syntax-check Nodes.pm)"; fi
if have node; then echo "ok node (JS syntax check)"; else echo "info: node not found, JS syntax check skipped"; fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    echo "-- check-only: no changes will be made --"
    echo "[backend]"
    PVE_NODES_PM="$NODES_PM" python3 "$BACKEND_PATCHER" --check-only || true
    echo "[frontend]"
    PVE_MGR_JS="$PVE_JS" python3 "$FRONTEND_PATCHER" --check-only || true
    echo "would back up to: ${BACKUP_DIR}"
    echo "would install: ${COLLECTOR_DST}, ${LIB_DIR}, ${UNINSTALL_DST}, ${CRON_FILE}"
    echo "history retention: ${RETENTION_HOURS}h (${STATE_DIR}/history.json)"
    echo "would restart: pvedaemon, pveproxy"
    exit 0
fi

# ---------- 3. Backup (timestamped, never reused) ----------
echo "-- backup to ${BACKUP_DIR} --"
mkdir -p "$BACKUP_DIR"
for f in "$NODES_PM" "$PVE_JS"; do
    mkdir -p "${BACKUP_DIR}$(dirname "$f")"
    cp -a "$f" "${BACKUP_DIR}${f}"
done
sha256sum "$NODES_PM" "$PVE_JS" | tee "${BACKUP_DIR}/SHA256SUMS"
if [[ -f "${REPO_DIR}/VERSION" ]]; then
    cp -a "${REPO_DIR}/VERSION" "${BACKUP_DIR}/"
fi
echo "backup done"

# ---------- 4. Backend patch ----------
echo "-- patch backend (Nodes.pm) --"
PVE_NODES_PM="$NODES_PM" python3 "$BACKEND_PATCHER" --apply

if have perl && ! perl -c "$NODES_PM" >/dev/null 2>&1; then
    echo "ERROR: perl -c failed after backend patch" >&2
    perl -c "$NODES_PM" >&2 || true
    restore_backup
    exit 6
fi
echo "perl syntax OK"

# ---------- 5. Frontend patch ----------
echo "-- patch frontend (pvemanagerlib.js) --"
PVE_MGR_JS="$PVE_JS" python3 "$FRONTEND_PATCHER" --apply

if have node; then
    if ! node --check "$PVE_JS" >/dev/null 2>&1; then
        echo "ERROR: node --check failed after frontend patch" >&2
        node --check "$PVE_JS" >&2 || true
        restore_backup
        exit 7
    fi
    echo "JS syntax OK"
else
    echo "WARN: node not found, skipping JS syntax check"
fi

# ---------- 6. Collector, uninstaller + cron schedule ----------
echo "-- install collector + uninstaller + cron job --"
install -d -m 0755 "$STATE_DIR" "$LIB_DIR"
install -m 0755 "$COLLECTOR_SRC" "$COLLECTOR_DST"
install -m 0755 "$BACKEND_PATCHER" "${LIB_DIR}/patch-mac-backend.py"
install -m 0755 "$FRONTEND_PATCHER" "${LIB_DIR}/patch-mac-frontend.py"
if [[ -f "${REPO_DIR}/VERSION" ]]; then
    install -m 0644 "${REPO_DIR}/VERSION" "${LIB_DIR}/VERSION"
fi
# Keep an uninstaller on the host so the repo is not needed later.
install -m 0755 "$UNINSTALL_SRC" "$UNINSTALL_DST"

# Retire units from older versions of this installer.
for unit in pve-mac-monitor.timer pve-mac-monitor.service; do
    if [[ -f "${LEGACY_UNIT_DIR}/${unit}" ]]; then
        systemctl disable --now "$unit" 2>/dev/null || true
        rm -f "${LEGACY_UNIT_DIR}/${unit}"
        echo "removed legacy ${unit}"
    fi
done
systemctl daemon-reload 2>/dev/null || true

# /etc/cron.d is the root-owned equivalent of `crontab -e` for root.
# Only the marked block belongs to this installer: any other schedule in the
# same file survives install, re-install and uninstall.
CRON_BLOCK_FILE="$(mktemp "${TMPDIR:-/var/tmp}/pve-mac-cron.XXXXXX")"

# Keep the block self-contained: only our job line, with env inline, so other
# schedules in the same file never inherit our variables or shell settings.
cat > "$CRON_BLOCK_FILE" <<EOF
* * * * * root MAC_SAMPLE_INTERVAL=60 MAC_RETENTION_HOURS=${RETENTION_HOURS} ${COLLECTOR_DST} >/dev/null 2>&1
EOF

CRON_BEGIN="$CRON_BEGIN" CRON_END="$CRON_END" python3 - "$CRON_FILE" "${CRON_FILE}.tmp" "$CRON_BLOCK_FILE" <<'PY'
import os
import sys

target, tmp, block_file = sys.argv[1], sys.argv[2], sys.argv[3]
begin, end = os.environ["CRON_BEGIN"], os.environ["CRON_END"]
block = open(block_file).read().strip("\n")

# Exact lines emitted by older versions (before marker blocks existed).
LEGACY_HEADER = "# Managed by patch_pve_summary.sh (pve-mac-monitor). Do not edit by hand."
LEGACY_LINES = {
    LEGACY_HEADER,
    "SHELL=/bin/sh",
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    'MAILTO=""',
    "MAC_SAMPLE_INTERVAL=60",
}
LEGACY_CRON_PREFIX = "* * * * * root MAC_SAMPLE_INTERVAL=60"
LEGACY_CRON_PREFIX_OLD = "* * * * * root /usr/local/bin/pve-mac-monitor"

raw = open(target).read().splitlines() if os.path.exists(target) else []
legacy_owned = LEGACY_HEADER in [line.strip() for line in raw]

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
    if legacy_owned and (stripped in LEGACY_LINES or stripped.startswith(LEGACY_CRON_PREFIX)
                         or stripped.startswith(LEGACY_CRON_PREFIX_OLD)):
        continue
    out.append(line)

while out and not out[-1].strip():
    out.pop()
if not out:
    out = ["# Managed by pve-mac-monitor install.sh. Entries outside the markers are preserved."]

out += [begin] + block.splitlines() + [end]
open(tmp, "w").write("\n".join(out) + "\n")
PY

chmod 0644 "${CRON_FILE}.tmp"
chown root:root "${CRON_FILE}.tmp" 2>/dev/null || true
mv -f "${CRON_FILE}.tmp" "$CRON_FILE"
echo "installed ${CRON_FILE} (block: ${CRON_BEGIN} ... ${CRON_END})"

if have systemctl && systemctl list-unit-files --type=service 2>/dev/null | grep -q '^cron\.service'; then
    systemctl enable --now cron.service 2>/dev/null || true
    systemctl is-active --quiet cron.service \
        && echo "cron: active" \
        || echo "WARN: cron.service is not active, schedule will not fire" >&2
elif ! have cron; then
    echo "WARN: cron not found, install it (apt install cron) and re-run" >&2
fi

MAC_RETENTION_HOURS="$RETENTION_HOURS" "$COLLECTOR_DST" || true

# ---------- 7. Restart services (both: Perl API + JS) ----------
# restart_service must not abort on a non-zero systemctl call: with `set -e`
# that would skip the rollback and leave the node patched but unverified.
restart_service() {
    local unit="$1" code="$2"
    if ! systemctl restart "$unit"; then
        echo "ERROR: systemctl restart ${unit} failed" >&2
        systemctl status "$unit" --no-pager --lines=20 >&2 || true
        restore_backup
        exit "$code"
    fi
    sleep 2
    if ! systemctl is-active --quiet "$unit"; then
        echo "ERROR: ${unit} is not active after restart" >&2
        systemctl status "$unit" --no-pager --lines=20 >&2 || true
        restore_backup
        exit "$code"
    fi
    echo "${unit%.service}: active"
}

echo "-- restart pvedaemon + pveproxy --"
restart_service pvedaemon.service 8
restart_service pveproxy.service 9

# ---------- 7b. Post-install smoke test ----------
# If the patched API answers but does not expose the new fields, the patch did
# not take effect on this node: roll back instead of leaving a half-working UI.
if have pvesh; then
    # PVE node name may differ from the OS hostname; pvecm knows the real one.
    smoke_node="$(pvecm nodename 2>/dev/null || hostname -s)"
    if smoke_json="$(pvesh get "/nodes/${smoke_node}/status" --output-format json 2>/dev/null)"; then
        if grep -q '"macstats"' <<<"$smoke_json"; then
            echo "API smoke test: mac fields present"
        else
            echo "ERROR: node status API answers but has no mac fields" >&2
            echo "       (state file missing or backend patch inactive) — rolling back" >&2
            restore_backup
            exit 10
        fi
    else
        echo "WARN: could not run 'pvesh get /nodes/${smoke_node}/status'; check manually:" >&2
        echo "      pvesh get /nodes/${smoke_node}/status --output-format json | grep -o '\"mac\"[^}]*}'" >&2
    fi

    # The chart needs the history endpoint to answer for the exact parameters
    # the stock timeframe selector sends (cf is AVERAGE/MAX, upper case).
    # A parameter error here leaves the chart empty with a 1970 axis, so treat
    # a failed call as a broken install.
    if hist_json="$(pvesh get "/nodes/${smoke_node}/mac-history" \
                        --timeframe hour --cf AVERAGE --output-format json 2>&1)"; then
        points="$(grep -o '"time"' <<<"$hist_json" | wc -l | tr -d ' ')"
        echo "API smoke test: mac-history answers (${points} points in the last hour)"
    else
        echo "ERROR: 'pvesh get /nodes/${smoke_node}/mac-history --timeframe hour --cf AVERAGE' failed:" >&2
        echo "$hist_json" >&2
        restore_backup
        exit 11
    fi
else
    echo "info: pvesh not available, skipping API smoke test"
fi

# ---------- 8. Summary ----------
cat <<EOF

===============================================
  pve-mac-monitor installed successfully
===============================================
Version:   $(cat "${LIB_DIR}/VERSION" 2>/dev/null || echo unknown)
Source:    ${REPO_SLUG}@${REPO_REF}
State:     ${STATE_DIR}/state.json
History:   ${STATE_DIR}/history.json (${RETENTION_HOURS}h retention)
Cron:      ${CRON_FILE} (every minute, MAC_RETENTION_HOURS=${RETENTION_HOURS})
Chart:     Node -> Summary -> "MAC addresses (used)", follows Hour/Day/Week/Month/Year
Verify:    cat ${STATE_DIR}/state.json
           journalctl -t pve-mac-monitor --no-pager | tail
           grep pve-mac-monitor /var/log/syslog | tail
           pvesh get /nodes/\$(hostname)/status --output-format json | grep -o '"mac"[^}]*}'
           pvesh get /nodes/\$(hostname)/mac-history --timeframe day | head -c 200
Browser:   hard-refresh the node Summary (Ctrl+Shift+R)
Backup:    ${BACKUP_DIR}
Uninstall: ${UNINSTALL_DST}
EOF
