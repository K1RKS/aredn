# babel-monitor

Side-loaded AREDN APK that keeps Babel / LQM / arednlink metrics in RAM, exposes a
stateless JSON pull API for external historians, a public status page, and a
live-config CLI.

- Package: `babel-monitor-0.1.65-r0.apk`
- Daemon: `babel-monitord`
- CLI: `babel-monitor`
- Status UI: `/babel-monitor/`
- Sync API: `/cgi-bin/babel-monitor?api=…`
- Does **not** touch stock Prometheus (`/cgi-bin/metrics`)

## Build

```sh
cd contrib/babel-monitor
./build.sh
```

APK lands in `dist/babel-monitor-0.1.65-r0.apk`.

## Install on a node

From the work-area root (after configuring `install_package_remotely.conf`):

```sh
./install_package_remotely -apk babel-monitor
```

Or copy the APK and:

```sh
apk add --allow-untrusted /tmp/babel-monitor-0.1.65-r0.apk
```

## On-node storage

- Configurable in-RAM sample ring via UCI `ring_size`: `none` | `5m` | `30m` | `1h` | `4h` | `24h` (slots @ 10s: 0 / 30 / 180 / 360 / 1440 / 8640) + event ring (`512`)
- `.post-install` picks `ring_size` from `MemAvailable`: `<2MB→none`, `≤4MB→5m`, `≤6MB→1h`, `≤30MB→4h`, else `24h` (30m is manual-only)
- Each sample slot is a slice of one **flat int buffer** (schema 9), overwritten in place via a rolling head index; resizing clears history
- `none` keeps live KPIs/neighbors but disables History metric tabs that need the ring (Logs / Top stay available)
- RF/link **names** live in a shared label dictionary (cap 64); the buffer stores indices + values only
- Series expands at most **5 minutes** of samples per API call (UI stitches longer windows; shortcut buttons above retention are disabled; pan uses `end_age`)
- Expanded named objects are built only for the response — never retained on the store
- Daemon runs ucode mark-and-sweep GC periodically and after each sample / API reply (refcount alone leaves temps)
- API socket handlers are deleted on client close (avoids uloop handle leak while the status page polls)
- `mem_total_kb` lives in meta only; flash/UCI holds **config only** — never metrics
- Reboot / daemon restart clears history

## CLI

```sh
babel-monitor                  # show live settings + status
babel-monitor -h
babel-monitor -interval 30 -compress off
babel-monitor -enabled off     # pause sampling; API still serves RAM
babel-monitor -ring-size 1h    # resize sample ring (clears history)
```

| Flag | UCI | Default |
|------|-----|---------|
| `-interval` | `sample_interval` | 10 (5–300) |
| `-compress` | `compress` | on |
| `-enabled` | `enabled` | on |
| `-sync-limit` | `sync_limit` | 500 |
| `-compress-min` | `compress_min_bytes` | 1024 |
| `-ring-size` | `ring_size` | set at install from free RAM (`none`/`5m`/`30m`/`1h`/`4h`/`24h`) |

Changes apply via the control socket and persist to `/etc/config/babel-monitor` without restarting the daemon.

## Sync API (pull-only)

Base: `/cgi-bin/babel-monitor`

| Query | Purpose |
|-------|---------|
| `?api=meta` (alias `hello`) | Identity + versions: `api_version` (wire contract), `schema_version` (sample layout), `package_version`, `node_id`, mac, hostname, boot_id, `ring_size`, retention |
| `?api=ring` | Sample-ring options + estimates; `?api=ring&set=SIZE` requires admin `authV1` cookie |
| `?api=sync&since_seq=N&limit=M` | Samples with `seq > N` for current `boot_id` |
| `?api=events&since_seq=N` | Event ring |
| `?api=live` | Current neighbors + latest sample + optional `wg` tunnel counts |
| `?api=series&seconds=S&end_age=A` | Samples in `[now-A-S, now-A]` (S capped at **300**/5m per request; UI fetches longer windows as slices) |
| `?api=logs&source=S&filters=F&limit=N` | Log panel: `syslog` (filters match OpenWrt service tag `name[pid]:` — e.g. babel-monitord,babeld_wrapper,babel_monitor,uhttpd,netifd,dropbear,procd,update-time,dnsmasq,arednlink), `dumps`, `lqm`, `dmesg` |
| `?api=download&source=S` | Full raw download (no filters/tail): `syslog`, `lqm`, `dmesg`, `dumps` — streamed attachment named `{hostname}-{source}-yyyymmdd.ext` |
| `?api=syslog&limit=N&filters=F` | Alias of logs source=syslog |
| `?api=top` | One-shot `top -bn1` process table (not stored in the ring) |

Optional `compress=1|0|on|off` (default from UCI; gzip level 1 when body ≥ `compress_min_bytes` and client sends `Accept-Encoding: gzip`).

Gap-tolerant: HTTP 200 when the daemon is up; responses include `truncated`, `gap_before`, `next_seq`, `complete`, `boot_id`. No per-poller state on the node.

`api_version` is the stable pull-API contract for central servers (also on `live.meta` / CLI status). Bump it when clients must change how they talk to a node; do not conflate with `schema_version` (in-RAM sample layout) or `package_version` (APK). Current value: **2**.

### Sample host / RF / link fields (schema 9)

Wire samples (sync/series/live) use named fields. Internally the ring is one **flat int buffer** (schema 9; slots overwritten in place). RF/link/cost **labels live once** in a shared dictionary (`LABEL_CAP=64`); each sample stores label indices + values only.

| Field | Meaning |
|-------|---------|
| `uptime_s` | Seconds since boot (`/proc/uptime`) — drops on reboot |
| `reboot_delta` | `1` if uptime decreased since the previous sample |
| `t` | Sample time as wall-clock Unix seconds (`clock()`); hover/history use this |
| `mem_available_kb` / `mem_used_pct` | RAM from `/proc/meminfo` |
| `daemon_rss_kb` | babel-monitord VmRSS (kB) from `/proc/self` at sample time |
| `cpu_pct` | Busy % over the full sample interval (`/proc/stat`) |
| `cpu_peak_pct` | Peak busy % from 1s windows within the interval |
| `mean_snr` | Average SNR across RF LQM trackers (AVG on the RF graph) |
| `rf` | Present only when RF neighbors exist: label → SNR (hostname when known; capped at 12) |
| `tx_packets_delta` / `rx_packets_delta` | Node-wide packet Δ since last sample (unique mesh ifaces via sysfs) |
| `tx_retries_delta` / `tx_fail_delta` | LQM TX retry/fail Δ (mainly RF) |
| `links` | Present when link I/O exists: label → `[tx_delta, rx_delta]` (capped at 12; `br0.N` labeled `XLink(N)`) |
| `stuck_neighbor_count` | Neighbors with cost 65535 and LQ ≥ 50 (firmware hard-reset candidate; observe only) |
| `bad_cost_count` | Neighbors with cost 65535 (any LQ) |
| `costs` | Present when Babel neighbors exist: label → cost (hostname when known; capped at 12) |

`mem_total_kb` is on `?api=meta` / live `meta` only (nearly constant). Live `meta.daemon_rss_kb` is the current reading; per-sample `daemon_rss_kb` is in the ring for history. `meta.label_count` is the shared label dictionary size. `rss_estimate_bytes` estimates the dense ring.

Live neighbors use `type` (DtD, RF, WG-S/WG-C, XLink(N), …) instead of raw iface — not stored in the sample ring. Xlink ifaces `br0.N` display as `XLink(N)`. Live neighbors include `stuck: true` when they match the cost/LQ candidate rule. Events `babel_stuck` / `babel_unstuck` edge-trigger with host/type/ipv6 detail; `babel_hard` includes `prior_stuck=[…]` when known. This package never restarts Babel.

Central pollers should treat a falling `uptime_s` (or `reboot_delta=1` / new `boot_id`) as a reboot gap.

## Example poller

Workstation script (not part of the on-node APK runtime requirement):

```sh
contrib/babel-monitor/tools/babel-monitor-poller hello k1rks-node.local.mesh
contrib/babel-monitor/tools/babel-monitor-poller pull  k1rks-node.local.mesh
contrib/babel-monitor/tools/babel-monitor-poller status k1rks-node.local.mesh
```

State/logs: `~/.babel-monitor/` (override with `BABEL_MONITOR_STATE`).

## Status page

Open `http://<node>/babel-monitor/` — live neighbors, KPIs, routing events, and a history graph with metric tabs (LQ, Cost, Neighbors, Routes, Packets, Link I/O, Hosts, CPU, RAM, Self RSS, RF, Logs, Top). History opens at the full ring window (browser `localStorage` remembers the last Zoom/shortcut span). The chart X axis shows wall-clock time (HH:MM). Shortcut ranges are 5m / 30m / 1h / 4h / 24h (disabled when longer than `ring_size`); each shortcut snaps to the live edge. Zoom−/Zoom+/Oldest/Live sit on the same toolbar row (right-justified). Side scroll and an overview bar (click to center, drag to pan) pan within the ring. Header **Setup** opens the ring-size picker (prompts for admin password if needed; estimates + 50% free-RAM guard). Longer chart windows are fetched as 5m API slices. Optional **WG Server Tunnels** / **WG Server Clients** KPIs show `live/active/total` when the tunnel config has entries. Viewing the UI does not write flash. An **Activity monitor** icon appears in the left admin bar (above Tools) via the app launcher and opens this page.

## Layout

```
contrib/babel-monitor/
  build.sh / tools/mkapk.py / README.md
  tools/babel-monitor-poller
  src/
    etc/init.d/babel-monitor
    etc/config/babel-monitor
    usr/sbin/babel-monitord
    usr/bin/babel-monitor
    usr/share/ucode/babel_monitor/
    www/babel-monitor/index.html
    www/cgi-bin/babel-monitor
    www/cgi-bin/apps/babel-monitor/{user,admin}   # admin-bar launcher
    www/apps/babel-monitor/icon.svg
    .post-install / .post-upgrade / .pre-deinstall
```