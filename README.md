# xnumeter

A zero-dependency macOS system monitor. One Swift binary, no packages, no
script runtime, no Electron — it reads XNU kernel statistics directly and
renders them as a terminal UI, a text snapshot, or NDJSON.

The point of building it on raw kernel calls instead of wrapping `top` or
`vm_stat` is that the numbers come from the same source those tools read, so
they can be checked against them. `scripts/selftest.sh` does exactly that and
fails the build when xnumeter and the OS disagree.

![The menu-bar dashboard: CPU, memory, swap and disk gauges, a rolling network
graph over the busiest interface, and the top interfaces and processes](docs/screenshot.png)

## Requirements

- macOS (Apple Silicon or Intel)
- Xcode or Command Line Tools providing Swift 6 — `swiftc` is the only build step

No `Package.swift`, no dependency resolution, no network access during build.

## Build

```sh
make          # builds ./xnumeter and ./XnumeterApp.app
make test     # builds the CLI, then runs the cross-check suite
```

## Terminal UI

```sh
./xnumeter                  # live TUI, redraws every second
./xnumeter --once           # single text snapshot, pipe-friendly
./xnumeter --json           # NDJSON, one object per interval
./xnumeter -i 250 -n 30 -s mem
```

```
xnumeter  14.local  up 22h59m                                           22:13:19
--------------------------------------------------------------------------------
CPU   48.4% [#######.......]  user 33 sys 15  load 2.35 2.58 2.93  10 cores
MEM   66.8% [#########.....]  10.7G/16.0G  wired 2.0G  comp 4.0G  purge 103.6M
SWAP   0.0% [..............]  0/0
DISK  87.0% [############..]  /  400.7G/460.4G  free 59.7G
NET  en0      rx 11.4K/s   tx 3.8K/s    total rx 741.8M tx 2.2G

   PID NAME                      CPU%     RSS    FOOT
 61798 ReportCrashService        74.1  234.0M    7.0M
   725 Siri AI                   65.5  237.3M  140.3M
```

| Option | Effect |
| --- | --- |
| `-i`, `--interval <ms>` | refresh interval, minimum 100 (default 1000) |
| `-n`, `--top <count>` | process rows to rank (default 15) |
| `-s`, `--sort <key>` | `cpu` or `mem` (default `cpu`) |
| `--once` | one snapshot then exit; switches output to text unless `--json` is given |
| `--json` | NDJSON instead of a rendered view |
| `--no-io` | drop the per-process disk read/write columns |
| `--no-color` | disable ANSI colour (also implied when stdout is not a TTY) |

Keys in the TUI: `q` quit, `s` toggle sort, `↑`/`↓` or `j`/`k` scroll the
process list.

Piping or redirecting stdout falls back to plain text automatically, so
`./xnumeter > snap.txt` never writes escape codes into the file.

## JSON

Each line is one snapshot:

```json
{"cpu":{...},"disks":[...],"hostName":"…","mem":{...},
 "net":[{"name":"en0","rxBytes":…,"rxBytesPerSec":…,"txBytes":…,"txBytesPerSec":…}],
 "processes":[{"pid":…,"name":"…","cpuPercent":…,"rssBytes":…,"footprintBytes":…,
               "diskReadBytesPerSec":…,"diskWriteBytesPerSec":…}],
 "timestampMs":…,"uptimeSeconds":…}
```

Rates are derived from the difference between two reads of a cumulative
counter, so the first sample of any run reports the counters it could only
measure absolutely, not rates.

## Menu-bar app

```sh
make app
open XnumeterApp.app
```

An `NSStatusItem` in the menu bar shows `↓ rx ↑ tx` for the busiest interface;
left-click toggles the dashboard window, right-click opens its menu. The
dashboard draws CPU / memory / swap / disk gauges, a 120-sample rolling network
graph, and the top interfaces and processes, refreshing once per second. It
shares `Sampler.swift` with the CLI rather than reimplementing the sampling.

The dashboard follows the system language and ships English and Simplified
Chinese tables (`Sources/XnumeterApp/*.lproj`). The terminal UI stays ASCII on
purpose: its columns are aligned by character count, and CJK glyphs are
double-width.

To preview another language without changing your system settings:

```sh
defaults write local.xnumeter.app AppleLanguages -array en      # back to English
defaults delete local.xnumeter.app AppleLanguages               # follow the system
```

## What it reads

| Metric | Source |
| --- | --- |
| CPU time, load averages, core count | `host_statistics` `HOST_CPU_LOAD_INFO`, `getloadavg`, `ProcessInfo.activeProcessorCount` |
| Memory, wired, compressed, purgeable, swap | `host_statistics64` `vm_statistics64` + `sysctl vm.swapusage` |
| Filesystems | `getfsstat` |
| Network counters | `sysctl NET_RT_IFLIST2` |
| Processes | `proc_listpids` + `proc_pid_rusage` |

## Known limits

- **Interface receive bytes wrap at 2³².** In the `NET_RT_IFLIST2` record on
  macOS 27, `ifi_ibytes` carries a 32-bit wrapped count while `ifi_obytes` is
  genuinely 64-bit. A decrease is treated as one wrap, but only when both
  readings fit in 32 bits; otherwise the interface is assumed to have been
  recreated and the delta is reported as 0.
- **`netstat` will not match byte-for-byte.** It reads the
  `net.link.generic.ifdata` MIB, which runs a few hundred bytes ahead of
  `NET_RT_IFLIST2` on Wi-Fi. The selftest compares with a tolerance instead of
  demanding equality.
- **Idle interfaces report zero.** An interface that has never carried traffic
  has no rate to show; that is reported as `-`, not as a measurement.
- **Per-process CPU is a rate over the sampling window**, not a lifetime
  average, so a process that finished between two samples can briefly read 0.

## Tests

```sh
./scripts/selftest.sh
```

Cross-checks the running binary against `netstat`, `vm_stat`, `sysctl` and
`top`, calibrates CPU percentage against a single-threaded busy loop (must
land near 100 % of one core), verifies every reported rate against its own byte
deltas, asserts the interface set has no loopback and no duplicates, and checks
that the text snapshot contains each gauge and table header. Ends with
`ALL CHECKS PASSED`.

## License

MIT — see [LICENSE](LICENSE).
