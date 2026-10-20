#!/usr/bin/env python3
"""patch-mac-frontend.py — idempotent pvemanagerlib.js patch for pve-mac-monitor.

In PVE.node.StatusView:
  - raises the status box height to 400 only when it is smaller
  - inserts two rows after the Manager Version row:
      macstats        bar + "used / limit (pct)" from the `mac` {used,total} field
      macstats_peaks  15m / 1h / 24h peaks from the `macstats` object

In PVE.node.Summary:
  - adds the pve-rrd-mac model, a macStore (UpdateStore -> /mac-history) that
    follows the stock RRD timeframe selector, and a proxmoxRRDChart appended
    to the Summary charts (same pattern as Server Load / Memory usage)
  - starts/stops the store with the panel like rrdstore

Marker-guarded and re-runnable; safe after pve-manager updates.
Usage: patch-mac-frontend.py [--check-only|--apply|--remove]
Env:   PVE_MGR_JS (override target path, for tests)
"""
import os
import pathlib
import re
import sys

TARGET = pathlib.Path(os.environ.get("PVE_MGR_JS", "/usr/share/pve-manager/js/pvemanagerlib.js"))

# The two added rows (bar + peaks, each with a spacer cell) need ~50px more
# than the stock 350px box at the default PVE row height.
TARGET_HEIGHT = 400

BEGIN = "// >>> pve-mac-monitor BEGIN"
END = "// <<< pve-mac-monitor END"
MODEL_BEGIN = "// >>> pve-mac-monitor model BEGIN"
MODEL_END = "// <<< pve-mac-monitor model END"
STORE_BEGIN = "// >>> pve-mac-monitor store BEGIN"
STORE_END = "// <<< pve-mac-monitor store END"
CHART_BEGIN = "// >>> pve-mac-monitor chart BEGIN"
CHART_END = "// <<< pve-mac-monitor chart END"
HOOK_MARK = "// pve-mac-monitor hook"

ROWS = """{
    iconCls: 'fa fa-fw fa-sitemap',
    itemId: 'macstats',
    title: gettext('Hetzner MAC Limit'),
    valueField: 'mac_current',
    maxField: 'mac_limit',
    printBar: true,
    // Proxmox.widget.Info compares strictly (usage > threshold), so each
    // threshold sits one MAC below the level that must trigger it:
    // 0.84375 = 27/32 -> amber from 28/32
    // 0.9375  = 30/32 -> red from 31/32
    warningThreshold: 0.84375,
    criticalThreshold: 0.9375,
    renderer: function(value, max) {
        if (!Ext.isNumeric(value)) {
            return '-';
        }
        var total = Ext.isNumeric(max) && max > 0 ? max : 32;
        return value + ' / ' + total + ' (' + Math.round((value / total) * 100) + '%)';
    },
},
{
    xtype: 'box',
    html: '&nbsp;',
    padding: '0 10 5 10',
},
{
    iconCls: 'fa fa-fw fa-history',
    itemId: 'macstats_peaks',
    printBar: false,
    title: gettext('MAC peaks'),
    textField: 'macstats',
    renderer: function(value) {
        if (!value || typeof value !== 'object') {
            return '-';
        }
        return '15m: ' + (value.max_15min || 0) +
               ' / 1h: ' + (value.max_1h || 0) +
               ' / 24h: ' + (value.max_24h || 0);
    },
},
{
    xtype: 'box',
    html: '&nbsp;',
    padding: '0 10 5 10',
},"""

MODEL_BLOCK = """// >>> pve-mac-monitor model BEGIN
Ext.define('pve-rrd-mac', {
    extend: 'Ext.data.Model',
    fields: ['mac', { type: 'date', dateFormat: 'timestamp', name: 'time' }],
});
// <<< pve-mac-monitor model END"""

STORE_BLOCK = """// >>> pve-mac-monitor store BEGIN
var macTimeframe = 'hour';
var macCf = 'average';
try {
    var macStateProvider = Ext.state.Manager.getProvider();
    var macRrdState = macStateProvider && macStateProvider.get('proxmoxRRDTypeSelection');
    if (macRrdState && macRrdState.timeframe) {
        macTimeframe = macRrdState.timeframe;
    }
    if (macRrdState && macRrdState.cf) {
        macCf = macRrdState.cf;
    }
} catch (e) {}
var macStore = Ext.create('Proxmox.data.UpdateStore', {
    interval: 60000,
    autoStart: true,
    model: 'pve-rrd-mac',
    storeid: 'pve-mac-history',
    proxy: {
        type: 'proxmox',
        url: '/api2/json/nodes/' + nodename + '/mac-history?timeframe=' + macTimeframe + '&cf=' + macCf,
    },
});
me.mon(Ext.state.Manager.getProvider(), 'statechange', function (provider, skey, svalue) {
    if (skey === 'proxmoxRRDTypeSelection' && svalue && svalue.timeframe) {
        macCf = svalue.cf || 'average';
        macStore.proxy.url = '/api2/json/nodes/' + nodename + '/mac-history?timeframe=' + svalue.timeframe + '&cf=' + macCf;
        macStore.reload();
    }
});
// <<< pve-mac-monitor store END"""

CHART_BLOCK = """// >>> pve-mac-monitor chart BEGIN
{
    title: gettext('MAC addresses (used)'),
    xtype: 'proxmoxRRDChart',
    fields: ['mac'],
    fieldTitles: [gettext('MACs')],
    store: macStore,
},
// <<< pve-mac-monitor chart END"""


def indent_block(block, indent):
    return "\n".join(
        (indent + line) if line.strip() else line
        for line in block.splitlines()
    )


def find_matching(text, open_idx):
    """Index of the bracket closing text[open_idx], JS strings/comments aware."""
    pairs = {"[": "]", "{": "}", "(": ")"}
    open_ch = text[open_idx]
    close_ch = pairs[open_ch]
    depth = 0
    i = open_idx
    while i < len(text):
        ch = text[i]
        if ch in "'\"`":
            quote = ch
            i += 1
            while i < len(text):
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    break
                i += 1
            i += 1
            continue
        if ch == "/" and i + 1 < len(text) and text[i + 1] == "/":
            newline = text.find("\n", i)
            i = len(text) if newline == -1 else newline + 1
            continue
        if ch == "/" and i + 1 < len(text) and text[i + 1] == "*":
            close = text.find("*/", i + 2)
            i = len(text) if close == -1 else close + 2
            continue
        if ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def status_view_bounds(text):
    start = re.search(r"Ext\.define\(\s*'PVE\.node\.StatusView'", text)
    if not start:
        return None
    nxt = re.search(r"Ext\.define\(", text[start.end():])
    end = start.end() + nxt.start() if nxt else len(text)
    return start.start(), end


def summary_bounds(text):
    start = re.search(r"Ext\.define\(\s*'PVE\.node\.Summary'", text)
    if not start:
        return None
    nxt = re.search(r"Ext\.define\(", text[start.end():])
    end = start.end() + nxt.start() if nxt else len(text)
    return start.start(), end


def remove_region(text, begin, end, blank_after=True):
    start = text.find(begin)
    if start == -1:
        return text, False
    finish = text.find(end, start)
    if finish == -1:
        return text, False
    finish += len(end)
    newline = text.find("\n", finish)
    if newline != -1:
        finish = newline + 1
    line_start = text.rfind("\n", 0, start) + 1
    joined = text[:line_start] + text[finish:]
    # Blocks that were inserted with a trailing blank line get it back on
    # removal, so a patch/unpatch round-trip leaves the file byte-identical.
    if blank_after and joined[line_start:line_start + 1] == "\n":
        joined = joined[:line_start] + joined[line_start + 1:]
    return joined, True


def has_region(text, begin, end):
    start = text.find(begin)
    return start != -1 and text.find(end, start) != -1


def remove_hooks(text):
    lines = text.splitlines(keepends=True)
    return "".join(line for line in lines if HOOK_MARK not in line)


def current_height(text):
    bounds = status_view_bounds(text)
    if bounds is None:
        return None
    match = re.search(r"(height:\s*)(\d+)(\s*,)", text[bounds[0]:bounds[1]])
    if not match:
        return None
    return int(match.group(2)), bounds[0] + match.start(2), bounds[0] + match.end(2)


def bump_height(text):
    info = current_height(text)
    if info is None:
        return text, None
    height, start, end = info
    if height >= TARGET_HEIGHT:
        return text, "kept height {}".format(height)
    return text[:start] + str(TARGET_HEIGHT) + text[end:], "height {}->{}".format(height, TARGET_HEIGHT)


def find_row_anchor(text):
    """Return (insert_at, row_indent) after the Manager Version row."""
    anchor = re.search(r"^([ \t]*)textField:\s*'pveversion',[ \t]*$", text, re.M)
    if not anchor:
        return None, "Manager Version anchor (textField: 'pveversion') not found"

    close = re.search(r"^[ \t]*\},[ \t]*\r?\n", text[anchor.end():], re.M)
    if not close:
        return None, "closing brace of Manager Version row not found"
    insert_at = anchor.end() + close.end()

    brace = text.rfind("{", 0, anchor.start())
    line_start = text.rfind("\n", 0, brace) + 1
    row_indent = re.match(r"[ \t]*", text[line_start:]).group(0)
    return (insert_at, row_indent), None


def build_rows(indent):
    return indent + BEGIN + "\n" + indent_block(ROWS, indent) + "\n" + indent + END + "\n\n"


def insert_rows(text):
    anchor, error = find_row_anchor(text)
    if error:
        return None, error
    insert_at, row_indent = anchor
    return text[:insert_at] + build_rows(row_indent) + text[insert_at:], None


def line_indent(text, pos):
    line_start = text.rfind("\n", 0, pos) + 1
    return re.match(r"[ \t]*", text[line_start:]).group(0)


def insert_model(text):
    bounds = summary_bounds(text)
    if bounds is None:
        return None, "PVE.node.Summary not found"
    line_start = text.rfind("\n", 0, bounds[0]) + 1
    return text[:line_start] + MODEL_BLOCK + "\n\n" + text[line_start:], None


def find_chart_items_array(text, bounds):
    """Innermost `items: [...]` array that holds the stock proxmoxRRDChart list.

    On PVE 9 the Summary wraps its charts in a column container, so the first
    `items: [` in the define is the outer container list. Anchor on the last
    proxmoxRRDChart and pick the smallest enclosing array.
    """
    charts = [m for m in re.finditer(r"xtype\s*:\s*'proxmoxRRDChart'", text[bounds[0]:bounds[1]])]
    if not charts:
        return None, "no proxmoxRRDChart found in PVE.node.Summary"
    chart_pos = bounds[0] + charts[-1].start()

    candidates = []
    for match in re.finditer(r"\bitems\s*:\s*\[", text[bounds[0]:bounds[1]]):
        open_idx = bounds[0] + match.end() - 1
        close_idx = find_matching(text, open_idx)
        if close_idx == -1 or close_idx < chart_pos:
            continue
        candidates.append((open_idx, close_idx))

    if not candidates:
        return None, "items array containing proxmoxRRDChart not found"
    return max(candidates, key=lambda pair: pair[0]), None


def insert_chart(text):
    bounds = summary_bounds(text)
    if bounds is None:
        return None, "PVE.node.Summary not found"
    arrays, error = find_chart_items_array(text, bounds)
    if error:
        return None, error
    open_idx, close = arrays

    head = text[:close].rstrip()
    if head.endswith("}"):
        head += ","
    tail = text[close:]

    element_indent = None
    for line in reversed(head.splitlines()):
        if line.strip().startswith("{"):
            element_indent = re.match(r"[ \t]*", line).group(0)
            break
    if element_indent is None:
        element_indent = line_indent(text, open_idx) + "    "

    block = "\n" + indent_block(CHART_BLOCK, element_indent) + "\n" + line_indent(text, open_idx)
    return head + block + tail, None


def insert_store(text):
    bounds = summary_bounds(text)
    if bounds is None:
        return None, "PVE.node.Summary not found"
    match = re.search(r"^([ \t]*)var\s+rrdstore\s*=\s*Ext\.create\('Proxmox\.data\.RRDStore'", text[bounds[0]:bounds[1]], re.M)
    if not match:
        return None, "rrdstore definition anchor not found in PVE.node.Summary"
    pos = bounds[0] + match.start()
    indent = match.group(1)
    return text[:pos] + indent_block(STORE_BLOCK, indent) + "\n\n" + text[pos:], None


def insert_hooks(text):
    bounds = summary_bounds(text)
    if bounds is None:
        return text, "PVE.node.Summary not found"
    start, end = bounds

    for call, note in (("startUpdate", "start"), ("stopUpdate", "stop")):
        match = re.search(r"^([ \t]*)rrdstore\." + call + r"\(\);", text[start:end], re.M)
        if not match:
            continue
        pos = start + match.end()
        newline = text.find("\n", pos)
        if newline == -1:
            newline = len(text)
        indent = match.group(1)
        hook = "\n" + indent + "if (typeof macStore !== 'undefined') { macStore." + call + "(); } " + HOOK_MARK
        text = text[:newline] + hook + text[newline:]
        start, end = summary_bounds(text)
    return text, None


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check-only"
    if mode not in ("--check-only", "--apply", "--remove"):
        print("usage: patch-mac-frontend.py [--check-only|--apply|--remove]", file=sys.stderr)
        return 2
    if not TARGET.is_file():
        print("missing target: {}".format(TARGET), file=sys.stderr)
        return 4

    text = TARGET.read_text()
    regions = {
        "status rows": has_region(text, BEGIN, END),
        "model": has_region(text, MODEL_BEGIN, MODEL_END),
        "store": has_region(text, STORE_BEGIN, STORE_END),
        "chart": has_region(text, CHART_BEGIN, CHART_END),
    }
    hooks_present = HOOK_MARK in text

    if mode == "--check-only":
        height = current_height(text)
        print("target: {}".format(TARGET))
        for label, present in regions.items():
            print("{} present: {}".format(label, present))
        print("store hooks present: {}".format(hooks_present))
        print("StatusView found: {}".format(status_view_bounds(text) is not None))
        print("Summary found: {}".format(summary_bounds(text) is not None))
        print("Manager Version anchor found: {}".format(
            re.search(r"^([ \t]*)textField:\s*'pveversion',[ \t]*$", text, re.M) is not None))
        print("status box height: {}".format(height[0] if height else "unknown"))
        return 0 if all(regions.values()) else 1

    if mode == "--remove":
        if not any(regions.values()) and not hooks_present:
            print("frontend: no pve-mac-monitor blocks found")
            return 0
        for begin, end in ((BEGIN, END), (MODEL_BEGIN, MODEL_END),
                           (STORE_BEGIN, STORE_END), (CHART_BEGIN, CHART_END)):
            text, _ = remove_region(text, begin, end)
        text = remove_hooks(text)
        tmp = str(TARGET) + ".tmp"
        pathlib.Path(tmp).write_text(text)
        os.replace(tmp, TARGET)
        print("frontend patch removed (status box height left unchanged)")
        return 0

    # Rebuild from a clean state so upgrades and re-runs are deterministic.
    upgraded = any(regions.values()) or hooks_present
    for begin, end in ((BEGIN, END), (MODEL_BEGIN, MODEL_END),
                       (STORE_BEGIN, STORE_END), (CHART_BEGIN, CHART_END)):
        text, _ = remove_region(text, begin, end)
    text = remove_hooks(text)

    text, error = insert_rows(text)
    if error:
        print(error + ", abort", file=sys.stderr)
        return 3

    text, error = insert_model(text)
    if error:
        print(error + ", abort", file=sys.stderr)
        return 3

    text, error = insert_store(text)
    if error:
        print(error + ", abort", file=sys.stderr)
        return 3

    text, error = insert_chart(text)
    if error:
        print(error + ", abort", file=sys.stderr)
        return 3

    text, error = insert_hooks(text)
    if error:
        print(error + ", abort", file=sys.stderr)
        return 3

    text, height_note = bump_height(text)
    if height_note:
        print("status box {}".format(height_note))
    print("frontend patch {}".format("upgraded" if upgraded else "applied"))

    expected = [
        (BEGIN, END, "status"),
        (MODEL_BEGIN, MODEL_END, "model"),
        (STORE_BEGIN, STORE_END, "store"),
        (CHART_BEGIN, CHART_END, "chart"),
    ]
    for begin, end, label in expected:
        if text.count(begin) != 1 or text.count(end) != 1:
            print("{} marker validation failed (BEGIN={}, END={}), abort".format(
                label, text.count(begin), text.count(end)), file=sys.stderr)
            return 3
    if text.count("itemId: 'macstats'") != 1:
        print("macstats row count={}, abort".format(
            text.count("itemId: 'macstats'")), file=sys.stderr)
        return 3
    if text.count("Ext.define('pve-rrd-mac'") != 1 or text.count("macStore") < 3:
        print("chart wiring validation failed, abort", file=sys.stderr)
        return 3

    tmp = str(TARGET) + ".tmp"
    pathlib.Path(tmp).write_text(text)
    os.replace(tmp, TARGET)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
