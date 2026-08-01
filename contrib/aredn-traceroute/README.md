# AREDN metadata traceroute (side-loaded APK)

Standalone package that replaces `/www/cgi-bin/traceroute` and adds `/usr/bin/aredn-traceroute`.

Each hop line is enriched with:

- **Link type** used on the incoming edge: `DtD`, `RF`, `WG`, or `Xlink`
- **txcost/rxcost**, **(tx%/rx%)**, **neighbor errors%** from previous-hop LQM when `-tx_rx_info` is on (**default on**; disable with `-no_tx_rx_info`)
- **Babel path metric** from this node to the hop (`babel.getHostRoutes()` / installed host route metric; falls back to the hop’s mesh IP when the traceroute address is a tunnel IP)
- **AREDN firmware version** at the end of the hop when `--node_version` is passed (off by default; from sysinfo `node_details.firmware_version`)
- **GPS** (`lat,lon`) only when `-gps` is passed (off by default)

Example (default: tx/rx info on, no GPS, no node version):

```text
traceroute to nodeD.local.mesh (10.1.2.5), 30 hops max, 46 byte packets
Aredn-Traceroute(0.1.24-r0): Babel Metric 4078
 1 nodeB (10.1.2.3) 23 ms DtD 96/96 (100%/100%) 352 0%
 2 nodeC (10.1.2.4) 123 ms RF 3593/3520 (98%/99%) 3945 1%
 3 nodeD (175.0.1.3) 19 ms WG 133/133 (100%/100%) 4078 0%
```

The banner (package version + Babel path metric) is printed right after the stock `traceroute to …` line so Tools → Traceroute still shows it (the UI skips CGI lines until that stock banner). Hop hostnames omit `.local.mesh`; RTT is rounded to whole milliseconds; fields are single-spaced.

With `-no_tx_rx_info`:

```text
 1 nodeB (10.1.2.3) 23 ms DtD 352
```

With `--node_version`:

```text
 1 nodeB (10.1.2.3) 23 ms DtD 96/96 (100%/100%) 352 0% 4.26.7.0
```

With `-gps`:

```text
 1 nodeB (10.1.2.3) 23 ms 45.1234,-122.1234 DtD 96/96 (100%/100%) 352 0%
```

## Install

1. Build (or download) `aredn-traceroute-0.1.24-r0.apk`
2. On the node: **Status → Packages** → upload / install with allow-untrusted  
   or: `apk add --allow-untrusted aredn-traceroute-0.1.24-r0.apk`
3. Tools → Traceroute uses the drop-in CGI automatically when this package is installed on the **source** node (GPS off unless `gps=1` is in the query string; `node_version=1` / `tx_rx_info=0` supported).
4. CLI: `aredn-traceroute <destination>`  
   GPS: `aredn-traceroute -gps <destination>`  
   No tx/rx columns: `aredn-traceroute -no_tx_rx_info <destination>`  
   Firmware versions: `aredn-traceroute --node_version <destination>`  
   Verbose: `aredn-traceroute -verbose <destination>`

When traceroute only returns an IP for a hop, the display name is filled from that hop’s `/a/sysinfo` `node` field, or from the previous hop’s LQM neighbor hostname. The `(IP)` still shows the hop address. If the previous hop’s traceroute IP failed sysinfo but its name was learned from the hop before that, later lookups re-fetch that previous hop via its mesh hostname (and mesh IP) so LQM/type/cost/metric/name can still be resolved.

On install, the package backs up the firmware `/www/cgi-bin/traceroute` (when present) and installs a drop-in. On remove, a `.pre-deinstall` script restores that backup (or a packaged firmware copy if the backup was never taken — e.g. older APKs that overwrote the CGI in place on a writable rootfs).

## Build

```sh
chmod +x build.sh
./build.sh
# → dist/aredn-traceroute-0.1.24-r0.apk
```

Uses a vendored copy of [kn6plv/MakeAPK](https://github.com/kn6plv/MakeAPK) (`tools/mkapk.py`). No OpenWrt buildroot required.

## How enrichment works

1. Run stock `/bin/traceroute -q 1 -w 1`.
2. Seed local Babel host-route metrics and local LQM (`/tmp/lqm.info`) for first-hop type/cost/success/errors.
3. For each new hop node, fetch **once**: `http://{node}/a/sysinfo?lqm=1` (neighbor trackers; lat/lon used only with `-gps`). Cache by mesh IP/hostname for the rest of the run; failed fetches are cached so timeouts are not repeated.
4. Type, **txcost/rxcost**, **(tx%/rx% success)**, and **neighbor errors%** come from the **previous** hop’s cached LQM neighbor entry for this hop. Path **metric** comes from this node’s Babel host route to the hop IP (or that hop’s mesh IP from sysinfo). GPS (optional) comes from the hop’s cached sysinfo.

Missing values print as `-`. Unreachable hops (`* * *`) are not enriched.

## Compatibility / caveats

- Enriched Tools UI output only when the **source** node has the APK installed (UI hits `http://{source}/cgi-bin/traceroute`).
- Mid-path nodes must answer `/a/sysinfo?lqm=1` (normal AREDN nodes do). Non-AREDN hops get RTT only.
- First-hop type/cost use local Babel/LQM; later hops’ type/cost depend on previous hop’s cached LQM. Path metric always uses this node’s Babel host routes.
- Tunnel/xlink ICMP quirks remain a separate concern (historical FixTraceroute / link-local SNAT); this APK does not replace that.
