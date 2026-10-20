#!/usr/bin/env python3
"""patch-mac-backend.py — idempotent Nodes.pm patch for pve-mac-monitor.

Adds two independent, marker-guarded pieces:

1. Status fields from /var/lib/pve-mac-monitor/state.json:
     mac        -> { used, total }  (stock bar/renderer shape)
     macstats   -> full state hash  (current, limit, peaks, timestamp)
     mac_current/mac_limit -> scalars kept for backward compatibility

2. GET /nodes/{node}/mac-history?timeframe=<hour|day|week|month|year>
   serving the collector ring windowed + downsampled like rrddata
   (numerics only, <=800 points, uncapped read: the stock helper caps at 1MB).

Re-runnable; never resets the file from a stale .bak.
Usage: patch-mac-backend.py [--check-only|--apply|--remove]
Env:   PVE_NODES_PM (override target path, for tests)
"""
import os
import pathlib
import re
import sys

TARGET = pathlib.Path(os.environ.get("PVE_NODES_PM", "/usr/share/perl5/PVE/API2/Nodes.pm"))

BEGIN = "# >>> pve-mac-monitor BEGIN"
END = "# <<< pve-mac-monitor END"
HIST_BEGIN = "# >>> pve-mac-monitor history BEGIN"
HIST_END = "# <<< pve-mac-monitor history END"

BLOCK = """# >>> pve-mac-monitor BEGIN (v2.5.0, idempotent)
# Publish Hetzner MAC-limit state to the Node Summary StatusView.
# eval-guarded: a missing or corrupt state file never breaks the API.
eval {
    my $mac_state_file = '/var/lib/pve-mac-monitor/state.json';
    if (-f $mac_state_file && -r _) {
        require JSON;
        my $mac_raw = PVE::Tools::file_get_contents($mac_state_file);
        my $mac_data = JSON::decode_json($mac_raw);
        if (ref($mac_data) eq 'HASH') {
            $res->{macstats} = $mac_data;
            $res->{mac} = {
                used  => ($mac_data->{current} // 0) + 0,
                total => ($mac_data->{limit}   // 32) + 0,
            };
            $res->{mac_current} = ($mac_data->{current} // 0) + 0;
            $res->{mac_limit}   = ($mac_data->{limit}   // 32) + 0;
        }
    }
};
# <<< pve-mac-monitor END"""

HISTORY_BLOCK = """# >>> pve-mac-monitor history BEGIN (v2.5.0, idempotent)
__PACKAGE__->register_method({
    name => 'mac_history',
    path => 'mac-history',
    method => 'GET',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
    description => "MAC address usage history (windowed + downsampled like rrddata)",
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            timeframe => {
                description => "Window like rrddata (hour/day/week/month/year)",
                type => 'string',
                enum => ['hour', 'day', 'week', 'month', 'year'],
                optional => 1,
            },
            cf => {
                description => "The RRD consolidation function",
                type => 'string',
                enum => ['AVERAGE', 'MAX', 'average', 'max'],
                optional => 1,
            },
        },
    },
    returns => { type => "array" },
    code => sub {
        my ($param) = @_;
        # MAC-HIST-TIMEFRAME
        my %win = (hour => 3700, day => 90000, week => 700000, month => 3100000, year => 32000000);
        my $tf = $param->{timeframe} // 'hour';
        # cf mirrors rrddata: the stock Average/Maximum toggle picks which
        # value the (single) series carries. At full resolution both are equal.
        my $cf = ($param->{cf} // 'AVERAGE') =~ /^max$/i ? 'max' : 'average';
        my $cut = time() - ($win{$tf} // $win{hour});
        my $f = '/var/lib/pve-mac-monitor/history.json';
        return [] unless -f $f;
        # MAC-HIST-UNCAPPED-READ: PVE::Tools::file_get_contents caps at 1MB and
        # would silently empty long-retention rings. Slurp directly instead.
        my $c = eval { open my $fh, '<', $f or die $!; local $/; my $d = <$fh>; close $fh; $d } // '[]';
        require JSON;
        my $a = eval { JSON::decode_json($c) } // [];
        $a = [] unless ref($a) eq 'ARRAY';
        my @pts;
        for my $p (@$a) {
            next unless ref($p) eq 'HASH';
            next unless defined($p->{t}) && "$p->{t}" =~ /^\\d+$/ && $p->{t} >= $cut;
            next unless defined($p->{v}) && "$p->{v}" =~ /^\\d+$/;
            push @pts, { time => int($p->{t}), mac => int($p->{v}) };
        }
        if (@pts > 800) {
            my $per = int(@pts / 800) + 1;
            my @avg;
            for (my $i = 0; $i < @pts; $i += $per) {
                my $e = $i + $per - 1;
                $e = $#pts if $e > $#pts;
                my ($n, $tsum, $vsum, $vmax) = (0, 0, 0, 0);
                for my $q (@pts[$i .. $e]) {
                    $n++;
                    $tsum += $q->{time};
                    $vsum += $q->{mac};
                    $vmax = $q->{mac} if $q->{mac} > $vmax;
                }
                my $val = $cf eq 'max' ? $vmax : int($vsum / $n + 0.5);
                push @avg, { time => int($tsum / $n), mac => $val };
            }
            @pts = @avg;
        }
        return \\@pts;
    }});
# <<< pve-mac-monitor history END"""


def indent_block(block, indent):
    return "\n".join(
        (indent + line) if line.strip() else line
        for line in block.splitlines()
    )


def find_status_return(text):
    """Return (line_start, return_pos) of `return $res;` in the status method."""
    status = re.search(r"name\s*=>\s*['\"]status['\"]", text)
    starts = [status.start()] if status else []
    starts.append(0)

    for start in starts:
        rootfs = text.find("$res->{rootfs}", start)
        if rootfs == -1:
            continue
        ret = text.find("return $res;", rootfs)
        if ret == -1:
            continue
        line_start = text.rfind("\n", 0, ret) + 1
        return line_start, ret
    return None


def find_method_anchor(text):
    """Return (insert_at, indent) for the mac-history method registration."""
    anchor = re.search(r"__PACKAGE__->register_method\(\{\s*\n[ \t]*name\s*=>\s*'netstat',", text)
    if anchor:
        line_start = text.rfind("\n", 0, anchor.start()) + 1
        return line_start, ""
    tail = re.search(r"\n1;[ \t]*\n?\s*$", text)
    if tail:
        return tail.start() + 1, ""
    return None, None


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


def write_target(text):
    tmp = str(TARGET) + ".tmp"
    pathlib.Path(tmp).write_text(text)
    os.replace(tmp, TARGET)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check-only"
    if mode not in ("--check-only", "--apply", "--remove"):
        print("usage: patch-mac-backend.py [--check-only|--apply|--remove]", file=sys.stderr)
        return 2
    if not TARGET.is_file():
        print("missing target: {}".format(TARGET), file=sys.stderr)
        return 4

    text = TARGET.read_text()
    status_present = has_region(text, BEGIN, END)
    history_present = has_region(text, HIST_BEGIN, HIST_END)

    if mode == "--check-only":
        print("target: {}".format(TARGET))
        print("status patch present: {}".format(status_present))
        print("history method present: {}".format(history_present))
        print("status anchor found: {}".format(find_status_return(text) is not None))
        anchor, _ = find_method_anchor(text)
        print("method anchor found: {}".format(anchor is not None))
        return 0 if (status_present and history_present) else 1

    if mode == "--remove":
        if not status_present and not history_present:
            print("backend: no pve-mac-monitor blocks found")
            return 0
        text, _ = remove_region(text, BEGIN, END)
        text, _ = remove_region(text, HIST_BEGIN, HIST_END)
        write_target(text)
        print("backend patch removed")
        return 0

    anchor = find_status_return(text)
    if anchor is None:
        print("status anchor ($res->{rootfs} ... return $res;) not found, abort", file=sys.stderr)
        return 3

    # --- status fields ---
    if status_present:
        line_start = text.rfind("\n", 0, text.find(BEGIN)) + 1
        indent = re.match(r"[ \t]*", text[line_start:]).group(0)
        text, _ = remove_region(text, BEGIN, END)
        anchor = find_status_return(text)
        if anchor is None:
            print("status anchor lost during upgrade, abort", file=sys.stderr)
            return 3
        line_start, _ = anchor
        text = text[:line_start] + indent_block(BLOCK, indent) + "\n\n" + text[line_start:]
        print("status patch upgraded")
    else:
        line_start, _ = anchor
        indent = re.match(r"[ \t]*", text[line_start:]).group(0)
        text = text[:line_start] + indent_block(BLOCK, indent) + "\n\n" + text[line_start:]
        print("status patch applied")

    # --- history method ---
    if history_present:
        text, _ = remove_region(text, HIST_BEGIN, HIST_END)
        anchor, _ = find_method_anchor(text)
        if anchor is None:
            print("method anchor lost during upgrade, abort", file=sys.stderr)
            return 3
        text = text[:anchor] + HISTORY_BLOCK + "\n\n" + text[anchor:]
        print("history method upgraded")
    else:
        anchor, _ = find_method_anchor(text)
        if anchor is None:
            print("method anchor (netstat / end of file) not found, abort", file=sys.stderr)
            return 3
        text = text[:anchor] + HISTORY_BLOCK + "\n\n" + text[anchor:]
        print("history method applied")

    for begin, end, label in (
        (BEGIN, END, "status"),
        (HIST_BEGIN, HIST_END, "history"),
    ):
        if text.count(begin) != 1 or text.count(end) != 1:
            print("{} marker validation failed (BEGIN={}, END={}), abort".format(
                label, text.count(begin), text.count(end)), file=sys.stderr)
            return 3
    if text.count("name => 'mac_history'") != 1:
        print("mac-history method count={}, abort".format(
            text.count("name => 'mac_history'")), file=sys.stderr)
        return 3

    write_target(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
