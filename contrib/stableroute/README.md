# stableroute (side-loaded APK)

Standalone CLI package that runs traceroute **N** times (default 10), groups identical
ordered hop paths, and prints a stability report.

Path identity is the full hop sequence (hostname/IP/`*`). RTT does **not** affect
equality — `nodea→nodeb→nodec` and `noded→nodee→nodec` are different paths.

By default, uses **aredn-traceroute** when that binary is already installed on the
node (`/usr/bin/aredn-traceroute`). Otherwise uses stock `/bin/traceroute`.
Pass `-legacy` to force stock traceroute. This package does **not** install
aredn-traceroute.

## GUI

Installs **Tools → StableRoute** (same style as Traceroute): target/source, run
count, legacy/debug checkboxes, and a scrollable console for long reports. Menu uses a
custom offset-deck plane icon shipped by the package. The source node must have
this package installed. CGI endpoint: `/cgi-bin/stableroute`.
Install/upgrade restarts uhttpd so the Tools menu picks up the new entry
(the admin UI preloads tools.ut at process start).

## Install

1. Build (or download) `stableroute-0.1.18-r0.apk`
2. On the node: **Status → Packages** → upload / install with allow-untrusted  
   or: `apk add --allow-untrusted stableroute-0.1.18-r0.apk`
3. CLI: `stableroute <destination>`  
   Custom run count: `stableroute -n 20 <destination>`  
   Debug (raw vs parse): `stableroute -debug -n 3 <destination>`  
   Force stock traceroute: `stableroute -legacy <destination>`

## Build

```sh
chmod +x build.sh
./build.sh
# → dist/stableroute-0.1.18-r0.apk
```

Uses a vendored copy of [kn6plv/MakeAPK](https://github.com/kn6plv/MakeAPK) (`tools/mkapk.py`). No OpenWrt buildroot required.

## Usage

```text
Usage: stableroute [-n N] [-debug] [-legacy] [-progress] <destination>
  Run traceroute N times (default 10), group identical hop paths, report stability.
```

Bare node names (no dots) get `.local.mesh` appended for the probe.

The report header includes `using aredn-traceroute` or `using traceroute`.

## How it works

1. Select probe: `aredn-traceroute` if present and not `-legacy`, else `/bin/traceroute -q 1 -w 1`.
2. Run the probe N times (quiet during runs unless `-debug`).
3. Parse hop lines (BusyBox and aredn-traceroute enriched shapes).
4. Key each run by ordered hop identities (short hostname preferred, else IP, else `*`).
5. Aggregate counts and per-hop RTTs across matching paths.
6. Print summary, then each unique path with occurrence count and `avg Xms +- Yms`
   (Y = max absolute deviation from the mean for that hop on that path).

### Summary fields

- **unique paths** — distinct hop sequences observed
- **shortest route** / **longest route** — min/max hop counts among all runs
- **Unreachable** — runs that never landed on the destination
- **most common** — highest-frequency path count and percentage

Unreachable / partial paths are still listed as unique paths (marked `[unreachable]`).

## Example

```text
stableroute(0.1.18-r0): destination nodec  runs 10
using aredn-traceroute
Summary:
  unique paths: 2
  shortest route: 3 hops
  longest route: 3 hops
  Unreachable: 0
  most common: 7/10 (70%)

Path 1: 7/10 (70%)
  1 nodea (10.1.2.3)  avg 12ms +- 3ms
  2 nodeb (10.1.2.4)  avg 45ms +- 8ms
  3 nodec (10.1.2.5)  avg 50ms +- 5ms

Path 2: 3/10 (30%)
  1 noded (10.2.0.1)  avg 20ms +- 1ms
  2 nodee (10.2.0.2)  avg 33ms +- 4ms
  3 nodec (10.1.2.5)  avg 55ms +- 6ms
```

## Compatibility

- Tools → StableRoute GUI plus CLI.
- Optional use of `aredn-traceroute` when already installed; no hard package dependency.
- Stock BusyBox traceroute remains available via `-legacy` or when aredn-traceroute is absent.
- On remove, the Tools menu entry is cleaned up; other Tools items are left intact.
