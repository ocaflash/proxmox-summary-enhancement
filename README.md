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

### Several nodes (two servers, cluster or not)

Both setups need the same thing on **each** node: the collector, its cron
entry, and both patches. Nothing is shared between nodes, the count is per
server (Hetzner limits MACs per server), and every node serves the GUI, so a
node without the patch shows no MAC rows when you open its Summary.

**Clustered** — the script finds the nodes itself:

```bash
curl -fsSL .../install-cluster.sh | bash -s -- --check-only
curl -fsSL .../install-cluster.sh | bash -s -- --retention 168 -y
```

**Two standalone servers (not a cluster)** — list them explicitly; root ssh
from the node where you run it to the other one is required:

```bash
curl -fsSL .../install-cluster.sh | bash -s -- --nodes "pve66 pve77" -y
```

or simply run the installer on each server:

```bash
for h in pve66 pve77; do
  ssh root@$h 'curl -fsSL https://raw.githubusercontent.com/ocaflash/proxmox-summary-enhancement/main/install.sh | bash'
done
```

If some nodes cannot be reached over ssh, the script names the ssh error for
each one and stops **before** changing anything:

```
== pre-flight ==
pve107           UNREACHABLE  (root@pve107: Permission denied (publickey,password).)
pve17            UNREACHABLE  (ssh: Could not resolve hostname pve17: Name or service not known)
pve66            pve-manager/9.2.20/... (running kernel: 6.14.8-2-pve)
pve88            local (pve-manager/9.2.10/...)
```

Root ssh in a cluster comes from `/etc/pve/priv/authorized_keys`; on each node
`/root/.ssh/authorized_keys` should be a symlink to it. If it is not, the node
cannot be reached from other members (repair with `pvecm updatecerts`, or
`ssh-copy-id root@<node>` for standalone servers). For a quick partial rollout
add `--partial`: reachable nodes are patched and the rest are listed at the end
with exit code 6.

`install-cluster.sh` asks for confirmation before patching. With a normal
terminal the prompt appears on `/dev/tty`; when there is no terminal (cron, CI,
`curl | bash` with stdin closed) it refuses unless `--yes` (`-y`) is given.

After the rollout the script prints one line per node:

```
== verification ==
NODE             MAC        API      HISTORY
pve66            17/32      ok       61 points (last hour)
pve77            4/32       ok       61 points (last hour)
```

`API` empty means the node status response has no `mac` field (patch not
applied); `0 points` means the history endpoint answered but the window is
empty (collector was writing zeros or just started). Without a cluster each
server has its own web UI — open each one and hard-refresh. In a cluster a
single UI shows every node, and each node's Summary shows that node's own
count.

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

## Safety model

What the installer does and does not do, and what protects the cluster.

**Never touched** (this is why a node keeps working even if the patch is wrong):

- `/etc/pve/**` — `corosync.conf`, `nodes.conf`, VM/CT configs, replication,
  HA rules. The cluster stack (`corosync`, `pmxcfs`, `pve-cluster`) is never
  restarted or reconfigured.
- RRD data and the `pve2-node` schema, `/etc/network/interfaces`, bridges,
  firewall, storage, `pvestatd`.
- Only two files are modified, both from `pve-manager`:
  `API2/Nodes.pm` and `js/pvemanagerlib.js`, and only inside
  `# >>> pve-mac-monitor` markers.

**Guards before a change is made**

- version guard on `pve-manager` (8.x/9.x) — aborts on an unknown version
  unless `--force`;
- `--check-only` prints anchor state and changes nothing;
- timestamped backup of both files in
  `/var/backups/pve-mac-monitor-<ts>/` with `SHA256SUMS`, never reused.

**Guards after a change**

- `perl -c Nodes.pm` → rollback on error;
- `node --check pvemanagerlib.js` (when `node` is present) → rollback on error;
- `systemctl restart` failure or an inactive unit → rollback + services
  restarted from the backup;
- API smoke test: `pvesh get /nodes/<node>/status` must expose `macstats`,
  otherwise rollback (exit 10).

**Cluster-level (`install-cluster.sh`)**

- pre-flight: every node must answer over ssh (`pveversion`) before anything is
  patched; unreachable node aborts the whole run with nothing changed;
- nodes are patched sequentially, never in parallel, so quorum and the GUI stay
  available during the rollout;
- warns if the cluster is not quorate, and re-checks quorum and node online
  state afterwards;
- a failing node is reported and the script exits non-zero; each node is
  idempotent, so re-running repairs a partially applied state.

**Residual risks (honest list)**

- `node --check` validates syntax only. A JS runtime error in a patched row
  would break the node Summary for that node (the API, VM management, cluster
  and storage stay unaffected). Mitigation: roll back with
  `pve-mac-monitor-uninstall`, or restore the backup.
- A `pve-manager` upgrade overwrites both patched files. The GUI rows and the
  `mac` field disappear until `install.sh` is re-run; nothing breaks.
- The collector runs as root every minute. It only reads `qm list`, `pct list`,
  `bridge fdb show` and writes under `/var/lib/pve-mac-monitor`; `flock`
  prevents overlap.
- `uninstall.sh --from-backup` restores the files as they were at install time.
  Do not use it after a `pve-manager` upgrade, it would downgrade the package
  files; plain `uninstall.sh` is safe at any time.

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

## Why `current` can be 0

The counting logic is the one from `pve-mac-monitor-orig.sh`, unchanged:
running guests -> `vmbr*` bridges that have an `en*/eth*/bond*` port -> guest
ports `tap*/veth*/fwpr*` -> `bridge fdb show`, filtered to dynamic unicast
entries of those ports. If the result is 0, one of those four steps found
nothing. `state.json` records which:

```json
"diag": {"bridges":"1","external":"1","uplinks":"vmbr0:eno1","running":"3",
         "guest_ports":"4","all_guest_ports":"4","fdb_lines":"37",
         "bridge_cmd":"1"}
```

Read it left to right:

| diag field | 0 means |
|---|---|
| `bridges` | no `vmbr*` interface at all (`ip -br link | grep vmbr`) |
| `external` | no bridge has a physical uplink port (`ip link show master vmbr0`) |
| `uplinks` | which bridge:port pairs were detected (informational) |
| `running` | `qm list` / `pct list` report no running guests |
| `all_guest_ports` | no `tap*/veth*/fwpr*` on any bridge |
| `guest_ports` | ports exist but their VMIDs are not in the running list: check that `qm list` column 3 is `running`. `all_guest_ports` counts every port, `guest_ports` only matching ones |
| `fdb_lines` | `bridge fdb show br <bridge>` returned nothing (empty FDB) |
| `bridge_cmd` | the `bridge` binary is not in `PATH` |

Then run it by hand for the full picture:

```bash
MAC_VERBOSE=1 MAC_DEBUG=1 /usr/local/bin/pve-mac-monitor
```

This prints the same counters, every counted MAC, the raw FDB dump and a
per-guest-port entry count, e.g. `tap100i0: 1`. A port with 0 entries tells you
the bridge never learned that guest's MAC (no traffic yet, VLAN mismatch, or the
guest is attached to a different bridge).

Note that the FDB only holds **dynamic** entries: MACs appear after guest
traffic and age out. `permanent`, multicast and bridge-local addresses are
excluded by design — the same filter as in the original script.

## Chart is empty (axis shows 1970)

An empty chart with a 1970 axis means the store loaded **no rows**, not a
rendering problem. Check the endpoint with exactly the parameters the stock
selector sends (`cf` is upper case):

```bash
pvesh get /nodes/$(hostname)/mac-history --timeframe hour --cf AVERAGE --output-format json | head -c 300
```

- **points returned** — the API is fine; check the browser console and make
  sure you hard-refreshed (Ctrl+Shift+R) so the new `pvemanagerlib.js` is
  loaded.
- **`Parameter verification failed - invalid value for option cf`** — the
  backend patch is older than v2.3.1; re-run `install.sh`.
- **`[]`** — the endpoint works but nothing is in the window: the collector may
  have been writing zeros, or `history.json` is older than the selected
  timeframe. Compare with `cat /var/lib/pve-mac-monitor/history.json`.

`install.sh` now tests this endpoint right after restarting the services and
rolls back if it does not answer.

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
