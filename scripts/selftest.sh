#!/bin/bash
# Evidence check for xnumeter: does it agree with the OS's own tools?
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=./xnumeter
# Without this, a missing binary returns 127, which satisfies every "must exit non-zero"
# assertion below and prints three green lines for a program that was never built.
[ -x "$BIN" ] || { echo "FAIL: $BIN not built (run 'make')"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 not on PATH"; exit 1; }

fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

# Fixed, guessable /tmp names would let another local user pre-create a symlink, and a
# stale file from an earlier run would be parsed as if it had just been produced.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/xnumeter-selftest.XXXXXX") || exit 1
LOADED_PIDS=""
cleanup() {
    [ -n "$LOADED_PIDS" ] && kill $LOADED_PIDS 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export BIN
export PROBE="$WORK/probe.json"
export CAL="$WORK/cal.json"

echo "1) CLI contract"
$BIN --help >/dev/null && ok "--help exits 0" || bad "--help failed"
# stdout goes to a file on purpose: with a tty the tool would enter raw mode and, if an
# argument guard ever regressed, poll forever instead of reporting FAIL.
$BIN --interval 5 >/dev/null 2>&1 </dev/null; [ $? -ne 0 ] && ok "rejects interval < 100" || bad "accepted interval < 100"
$BIN --sort bogus >/dev/null 2>&1 </dev/null; [ $? -ne 0 ] && ok "rejects bad sort" || bad "accepted bad sort"
$BIN --nope >/dev/null 2>&1 </dev/null; [ $? -ne 0 ] && ok "rejects unknown arg" || bad "accepted unknown arg"

echo "2) --json --once values cross-checked against sysctl/df/netstat"
$BIN --json --once > "$PROBE" || bad "json mode exited non-zero"
python3 - <<'PY'
import json, os, subprocess, sys
def out(cmd): return subprocess.check_output(cmd).decode().strip()
try:
    d = json.load(open(os.environ["PROBE"]))
except Exception as e:
    print("  FAIL json unparseable: %s" % e); sys.exit(1)
bad = 0
need = ["timestampMs", "hostName", "uptimeSeconds", "cpu", "mem", "disks", "net", "processes"]
missing = [k for k in need if k not in d]
print("  ok   all top-level keys present" if not missing else "  FAIL missing %s" % missing); bad |= bool(missing)

def eq(label, got, want, tol):
    global bad
    good = abs(got - want) <= tol
    print("  %s %s (got %s, want %s +/- %s)" % ("ok  " if good else "FAIL", label, got, want, tol))
    bad |= (not good)

eq("coreCount == hw.activecpu", d["cpu"]["coreCount"], int(out(["sysctl", "-n", "hw.activecpu"])), 0)
eq("mem.totalBytes == hw.memsize", d["mem"]["totalBytes"], int(out(["sysctl", "-n", "hw.memsize"])), 0)
df_free_kb = int(out(["df", "-k", "/"]).split("\n")[1].split()[3])
eq("/ freeBytes within 1% of df -k /", d["disks"][0]["freeBytes"] // 1024, df_free_kb, max(20480, df_free_kb // 100))
procs = d["processes"]
print("  %s process list non-empty (%d rows)" % ("ok  " if procs else "FAIL", len(procs))); bad |= not procs
ok_cpu = all(p["cpuPercent"] >= 0 for p in procs)
print("  %s cpu percentages non-negative" % ("ok  " if ok_cpu else "FAIL")); bad |= not ok_cpu
mem = d["mem"]["totalBytes"]
ok_rss = all(p["rssBytes"] < mem for p in procs)
print("  %s no process rss exceeds physical memory" % ("ok  " if ok_rss else "FAIL")); bad |= not ok_rss
used_pct = 100.0 * d["mem"]["usedBytes"] / mem
ok_used = 0 < d["mem"]["usedBytes"] < mem
print("  %s used memory in range (%.1f%%)" % ("ok  " if ok_used else "FAIL", used_pct)); bad |= not ok_used

def netstat_link(name):
    """Cumulative RX/TX for one interface, read from the OS's own counter viewer."""
    lines = out(["netstat", "-ibn"]).split("\n")
    header = lines[0].split()
    if "Ibytes" not in header or "Obytes" not in header:
        return None
    # Count back from the end: the Address cell is empty on some rows, so leading column
    # indices shift, but the trailing Coll/Obytes/.../Ibytes block is fixed. Deriving the
    # distance from the header keeps this correct if netstat ever gains a trailing column.
    rx_off, tx_off = len(header) - header.index("Ibytes"), len(header) - header.index("Obytes")
    for line in lines[1:]:
        f = line.split()
        if len(f) >= max(rx_off, tx_off) and f[0].rstrip("*") == name and f[2].startswith("<Link#"):
            # xnumeter reads NET_RT_IFLIST2, whose ifi_ibytes wraps at 2**32 on this OS
            # (verified: it equals netstat's value modulo 2**32, and the true 64-bit count
            # appears nowhere in the kernel record). Bring netstat into the same domain
            # rather than pretending xnumeter can see the unwrapped total.
            return int(f[-rx_off]) % (1 << 32), int(f[-tx_off]) % (1 << 32)
    return None

net = d.get("net")
ok_net = isinstance(net, list)
print("  %s net is a list" % ("ok  " if ok_net else "FAIL")); bad |= not ok_net
if ok_net and net:
    busy = max(net, key=lambda n: n["rxBytes"] + n["txBytes"])
    before = netstat_link(busy["name"])
    fresh = json.loads(out([os.environ["BIN"], "--json", "--once"]))
    after = netstat_link(busy["name"])
    now = next((n for n in fresh["net"] if n["name"] == busy["name"]), None)
    if not (before and after and now):
        print("  FAIL %s vanished between netstat reads" % busy["name"]); bad = 1
    elif after[0] < before[0] or after[1] < before[1]:
        print("  ok   %s counters wrapped or reset mid-check; bracket skipped" % busy["name"])
    else:
        # netstat reads the net.link.generic.ifdata MIB, xnumeter reads NET_RT_IFLIST2;
        # the two kernel paths disagree by about a kilobyte on Wi-Fi. The bracket itself
        # covers live traffic, so the slack only has to cover that disagreement.
        for label, i in (("rx", 0), ("tx", 1)):
            got = now[label + "Bytes"]
            slack = max(65536, after[i] // 100_000)
            good = before[i] - slack <= got <= after[i] + slack
            print("  %s %s %s cumulative %s near netstat [%d..%d] +/- %d"
                  % ("ok  " if good else "FAIL", busy["name"], label, got, before[i], after[i], slack))
            bad |= not good
        negative = [n for n in net if n["rxBytesPerSec"] < 0 or n["txBytesPerSec"] < 0]
        print("  %s all net rates non-negative" % ("ok  " if not negative else "FAIL %s" % negative))
        bad |= bool(negative)
        names = [n["name"] for n in net]
        clean = "lo0" not in names and len(names) == len(set(names))
        print("  %s no loopback, no duplicate interfaces (%s)" % ("ok  " if clean else "FAIL", ", ".join(names)))
        bad |= not clean
elif ok_net:
    print("  ok   no interface has carried traffic; net list correctly empty")
sys.exit(bad)
PY
[ $? -eq 0 ] || fail=1

echo "3) rate calibration: a single-threaded busy loop must read ~100% of one core"
/usr/bin/yes >/dev/null &
yes_pid=$!
# Registered so an abnormal exit in the next seconds cannot leave a core pegged, which
# would also silently skew every later CPU assertion.
LOADED_PIDS="$yes_pid"
sleep 1
# No subshell: `( cmd ) &` is not guaranteed to exec, so $! could be the subshell and
# killing it would leave xnumeter sampling every process for its full run.
$BIN --json -i 1200 -n 500 > "$CAL" 2>/dev/null &
reader=$!
sleep 4
kill $reader 2>/dev/null
kill $yes_pid 2>/dev/null
LOADED_PIDS=""
wait 2>/dev/null
python3 - <<'PY'
import json, os, sys
snaps = []
for line in open(os.environ["CAL"]):
    line = line.strip()
    if line.endswith("}"):
        try:
            snaps.append(json.loads(line))
        except json.JSONDecodeError:
            pass
if not snaps:
    print("  FAIL reader produced no complete snapshot"); sys.exit(1)
seen = [p["cpuPercent"] for s in snaps for p in s["processes"] if p["name"] == "yes"]
if not seen:
    print("  FAIL busy 'yes' process never appeared in top ranks"); sys.exit(1)
peak = max(seen)
good = 60 <= peak <= 140
print("  %s busy 'yes' peaked at %.1f%% of one core across %d samples (expect ~100)" % ("ok  " if good else "FAIL", peak, len(seen)))

machine = [s["cpu"]["totalPercent"] for s in snaps]
in_range = all(0 <= v <= 100 for v in machine)
print("  %s machine cpu%% bounded 0..100 with a loaded core (%.1f..%.1f)"
      % ("ok  " if in_range else "FAIL", min(machine), max(machine)))

# Rates must be byte deltas divided by the real elapsed span, so re-deriving them from
# consecutive snapshots catches a wrong divisor or a stale baseline.
checked = drifted = 0
for a, b in zip(snaps, snaps[1:]):
    span = (b["timestampMs"] - a["timestampMs"]) / 1000.0
    if span <= 0:
        continue
    prev = {n["name"]: n for n in a["net"]}
    for n in b["net"]:
        old = prev.get(n["name"])
        if not old:
            continue
        for direction in ("rx", "tx"):
            if n[direction + "Bytes"] < old[direction + "Bytes"]:
                continue  # interface recreated between frames; nothing to compare against
            want = (n[direction + "Bytes"] - old[direction + "Bytes"]) / span
            got = n[direction + "BytesPerSec"]
            if want <= 0 and got <= 0:
                continue
            checked += 1
            if abs(got - want) > 0.25 * max(want, got) + 64:
                drifted += 1
                print("  FAIL %s %s rate %.1f B/s, byte delta implies %.1f B/s" % (n["name"], direction, got, want))
if checked:
    print("  %s %d net rates agree with their byte deltas over the sampled span" % ("ok  " if not drifted else "FAIL", checked))
elif any(n["rxBytesPerSec"] or n["txBytesPerSec"] for s in snaps for n in s["net"]):
    print("  FAIL interfaces are moving but no rate could be re-derived")
    checked = -1
else:
    print("  ok   no interface carried traffic during calibration; rate re-derivation skipped")
sys.exit(0 if (good and in_range and not drifted and checked >= 0) else 1)
PY
[ $? -eq 0 ] || fail=1

echo "4) text mode"
OUT=$($BIN --once --no-color) || bad "text mode exited non-zero"
# Anchored: an unanchored CPU also matches the CPU% column header and DISK matches
# DISK-R/DISK-W, so the gauge rows could vanish and these checks would still pass.
for row in '^CPU ' '^MEM ' '^SWAP ' '^DISK '; do
  printf '%s' "$OUT" | grep -q "$row" && ok "text snapshot contains gauge $row" || bad "text snapshot missing gauge $row"
done
for col in PID NAME CPU% RSS FOOT; do
  printf '%s' "$OUT" | grep -q "$col" && ok "process table contains $col" || bad "process table missing $col"
done
# Three distinct outcomes: interfaces exist (assert the rows), no interface ever carried
# traffic (correctly absent), or the probe is unreadable (must not pass silently).
python3 -c '
import json, os, sys
try:
    d = json.load(open(os.environ["PROBE"]))
except Exception:
    sys.exit(2)
sys.exit(0 if d.get("net") else 1)
' 2>/dev/null
case $? in
  0) printf '%s' "$OUT" | grep -q "^NET " && ok "text snapshot contains NET rows" || bad "text snapshot missing NET rows" ;;
  1) ok "no interface has carried traffic; NET rows correctly absent" ;;
  *) bad "could not read the probe json to decide whether NET rows are expected" ;;
esac

echo
[ $fail -eq 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $fail
