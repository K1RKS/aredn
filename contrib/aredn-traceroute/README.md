# AREDN metadata traceroute (side-loaded APK)

Standalone package that replaces `/www/cgi-bin/traceroute` and adds `/usr/bin/aredn-traceroute`.

Each hop line is enriched with:

- **GPS** of that hop node (`lat,lon`)
- **Link type** used on the incoming edge: `DtD`, `RF`, `WG`, or `Xlink`
- **Babel link cost** for that edge (local Babel `cost`, or remote LQM `rxcost`)

Example:

```text
 1  nodeB.local.mesh (10.1.2.3)  23.034 ms  45.1234,-122.1234  DtD  352
 2  nodeC.local.mesh (10.1.2.4)  123.03 ms  44.2412,-12.1234  RF  3593
 3  nodeD.local.mesh (175.0.1.3)  19 ms  14.2412,-132.1234  WG  133
```

## Install

1. Build (or download) `aredn-traceroute-0.1.1-r0.apk`
2. On the node: **Status → Packages** → upload / install with allow-untrusted  
   or: `apk add --allow-untrusted aredn-traceroute-0.1.1-r0.apk`
3. Tools → Traceroute uses the drop-in CGI automatically when this package is installed on the **source** node.
4. CLI: `aredn-traceroute <destination>`

Removing the package restores the firmware traceroute CGI (overlayfs).

## Build

```sh
cd contrib/aredn-traceroute
chmod +x build.sh
./build.sh
# → dist/aredn-traceroute-0.1.1-r0.apk
```

Uses a vendored copy of [kn6plv/MakeAPK](https://github.com/kn6plv/MakeAPK) (`tools/mkapk.py`). No OpenWrt buildroot required.

## How enrichment works

1. Run stock `/bin/traceroute -q 1 -w 1`.
2. Seed local LQM (`/tmp/lqm.info`) + Babel neighbors for first-hop type/cost.
3. For each new hop node, fetch **once**: `http://{node}/a/sysinfo?lqm=1` (GPS + neighbor trackers). Cache by mesh IP/hostname for the rest of the run; failed fetches are cached so timeouts are not repeated.
4. GPS comes from the hop’s cached sysinfo; type/cost come from the **previous** hop’s cached LQM neighbor entry for this hop (route-specific).

Missing values print as `-`. Unreachable hops (`* * *`) are not enriched.

## Compatibility

- CGI keeps the same HTML SUCCESS/ERROR envelope and streaming behavior as firmware traceroute so the existing Tools UI keeps working; extra fields are appended on hop lines.
- Mid-path nodes must answer `/a/sysinfo?lqm=1` (normal AREDN nodes). Non-AREDN hops show RTT only.
- Tunnel/xlink ICMP source-address quirks are out of scope for this package.
