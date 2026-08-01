# stableroute (side-loaded APK)

Standalone CLI package that runs stock `/bin/traceroute` **N** times (default 10),
groups identical ordered hop paths, and prints a stability report.

Path identity is the full hop sequence (hostname/IP/`*`). RTT does **not** affect
equality — `nodea→nodeb→nodec` and `noded→nodee→nodec` are different paths.

## Install

1. Build (or download) `stableroute-0.1.0-r0.apk`
2. On the node: **Status → Packages** → upload / install with allow-untrusted  
   or: `apk add --allow-untrusted stableroute-0.1.0-r0.apk`
3. CLI: `stableroute <destination>`  
   Custom run count: `stableroute -n 20 <destination>`

## Build

```sh
chmod +x build.sh
./build.sh
# → dist/stableroute-0.1.0-r0.apk
```

Uses a vendored copy of [kn6plv/MakeAPK](https://github.com/kn6plv/MakeAPK) (`tools/mkapk.py`). No OpenWrt buildroot required.

## Usage

```text
Usage: stableroute [-n N] <destination>
  Run traceroute N times (default 10), group identical hop paths, report stability.
```

Bare node names (no dots) get `.local.mesh` appended for the probe.

## How it works

1. Run `/bin/traceroute -q 1 -w 1` N times (quiet during runs).
2. Parse hop lines (same busybox shapes as aredn-traceroute).
3. Key each run by ordered hop identities (short hostname preferred, else IP, else `*`).
4. Aggregate counts and per-hop RTTs across matching paths.
5. Print summary, then each unique path with occurrence count and `avg Xms +- Yms`
   (Y = max absolute deviation from the mean for that hop on that path).

### Summary fields

- **unique paths** — distinct hop sequences observed
- **shortest route** / **longest route** — min/max hop counts among all runs
- **Unreachable** — runs that never landed on the destination
- **most common** — highest-frequency path count and percentage

Unreachable / partial paths are still listed as unique paths (marked `[unreachable]`).

## Example

```text
stableroute(0.1.0-r0): destination nodec  runs 10
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

- CLI only in v1 (no Tools UI / CGI swap).
- Uses stock BusyBox traceroute; does not depend on the `aredn-traceroute` APK.
- Concepts (parse/dest normalize/MakeAPK layout) follow the aredn-traceroute package.
