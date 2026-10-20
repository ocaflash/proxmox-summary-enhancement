# pve-mac-monitor

Hetzner MAC-limit monitor for Proxmox VE. Counts the unicast MAC addresses of
running VMs/CTs on bridges with a physical uplink (bridge FDB), keeps a history
ring and shows the usage in the node **Summary**:

- `Hetzner MAC Limit` — progress bar `used / limit (pct)`, amber from 28/32,
  red from 31/32 (Hetzner's hard limit is 32 MACs per server)
- `MAC peaks` — 15m / 1h / 24h maximum
- `MAC addresses (used)` — history chart under the stock node charts, follows
  the built-in Hour / Day / Week / Month / Year selector and the
  Average / Max consolidation switch

Tested anchors: PVE 8.x / 9.x (`pve-manager`, `proxmox-widget-toolkit`). Any
`pve-manager` upgrade overwrites the patched files — just re-run the installer.

## Install

One command, no clone needed. `install.sh` downloads the rest of the project
itself (single repository archive, SHA256SUMS verified):

```bash
# as root on the PVE host
curl -fsSL https://raw.githubusercontent.com/ocaflash/proxmox-summary-enhancement/main/install.sh | bash

# with options (e.g. 7 days of history)
curl -fsSL https://raw.githubusercontent.com/ocaflash/proxmox-summary-enhancement/main/install.sh \
  | bash -s -- --retention 168
```

Dry run first (read-only, works as a normal user):

```bash
curl -fsSL https://raw.githubusercontent.com/ocaflash/proxmox-summary-enhancement/main/install.sh \
  | bash -s -- --check-only
```

### Several nodes (cluster)

The monitor is per-node: the MAC count comes from the local bridge FDB, every
Hetzner server has its own 32-MAC limit, and the node status API is served by
the node that owns it. The GUI JavaScript is served by the node you connect
to, so **every node needs both the patch and the collector**. Use the driver:

```bash
# from a checkout on any cluster node (root ssh between nodes is already set up)
./install-cluster.sh --check-only                 # dry run on all nodes
./install-cluster.sh --retention 168              # install on all nodes
./install-cluster.sh --nodes "pve1 pve2 pve3" -y  # explicit list
```

It detects nodes from `/etc/pve/nodes`, streams `install.sh` to each node over
ssh and verifies the `mac` field with `pvesh` afterwards. Uninstall on every
node:

```bash
for n in $(ls /etc/pve/nodes); do ssh root@$n pve-mac-monitor-uninstall; done
```

From a checkout:

```bash
git clone https://github.com/ocaflash/proxmox-summary-enhancement.git
cd proxmox-summary-enhancement
./install.sh --check-only
./install.sh
./install.sh --retention 168        # 7 days of history
```

Options: `--check-only`, `--force` (skip the version guard), `--retention HOURS`
(1..8760, default 24), `--ref REF` (branch/tag/commit to download).

`install.sh` works in two modes:

- **standalone** (`curl ... | bash`, or the file copied alone to a host): the
  missing companion files are downloaded from `codeload.github.com` as one
  archive, so all files come from the same commit; `SHA256SUMS` is verified
  and a mismatch aborts the install.
- **checkout** (`./install.sh` next to `src/` and `pve-mac-monitor.sh`): uses
  the local files, no network access needed.

`MAC_REPO=<owner>/<repo>` points the download at a fork; `MAC_REF=<ref>` does
the same as `--ref`.

## Requirements

- Proxmox VE 8.x / 9.x, root
- `python3` (stdlib only), `perl` (syntax check), `cron`, `flock`
- optional: `node` for the JS syntax check, `curl` or `wget` for the
  single-file install

## What gets changed

| Path | Change |
|---|---|
| `/usr/share/perl5/PVE/API2/Nodes.pm` | `mac` / `macstats` fields in `status`, new `GET /nodes/{node}/mac-history` |
| `/usr/share/pve-manager/js/pvemanagerlib.js` | Summary rows, chart, model/store, status box height 350→420 |
| `/usr/local/bin/pve-mac-monitor` | collector |
| `/usr/local/lib/pve-mac-monitor/` | patchers + `VERSION` (used by the uninstaller) |
| `/usr/local/sbin/pve-mac-monitor-uninstall` | uninstaller |
| `/etc/cron.d/pve-mac-monitor` | every-minute schedule (only the marked block) |
| `/var/lib/pve-mac-monitor/` | `state.json`, `history.json` |
| `/var/backups/pve-mac-monitor-<timestamp>/` | originals + `SHA256SUMS` |

Nothing else is touched: no RRD schema changes, no `/etc/pve` edits, no
`proxmoxlib.js` patch, `pvestatd` is not restarted.

## History and retention

`/var/lib/pve-mac-monitor/history.json` is a JSON array of
`{"t": <epoch>, "v": <count>}` points, one per minute, written atomically.
Points newer than 24h keep full resolution; older ones are compacted into
5-minute buckets, so long retention stays small (a year is ~12k points).
Retention is set by `--retention` and stored in the cron line
(`MAC_RETENTION_HOURS`), so re-running the installer with a new value is enough.

## Verify

```bash
cat /var/lib/pve-mac-monitor/state.json
pvesh get /nodes/$(hostname)/status --output-format json | grep -o '"mac"[^}]*}'
pvesh get /nodes/$(hostname)/mac-history --timeframe day | head -c 200
journalctl -t pve-mac-monitor --no-pager | tail
```

Then hard-refresh the browser (Ctrl+Shift+R) on Node → Summary.

## Uninstall

```bash
pve-mac-monitor-uninstall                # remove only the marked blocks
pve-mac-monitor-uninstall --from-backup  # restore the newest backup instead
```

`--from-backup` is only safe when `pve-manager` has not been upgraded since the
install, otherwise it would downgrade the package files. History in
`/var/lib/pve-mac-monitor` is kept on purpose.

## Layout

```
install.sh                        # self-contained installer (downloads the rest)
install-cluster.sh                # runs install.sh on every cluster node
uninstall.sh                      # removes patches, collector, cron entry
pve-mac-monitor.sh                # collector (cron, every minute)
VERSION
src/patch-mac-backend.py          # idempotent Nodes.pm patch
src/patch-mac-frontend.py         # idempotent pvemanagerlib.js patch
patches/REFERENCE-*.patch         # anchor documentation for hand-porting
SHA256SUMS                        # verified by the single-file installer
```

## License

MIT for these scripts. Proxmox files remain under their own licenses
(AGPL-3.0); only patches are distributed here.
