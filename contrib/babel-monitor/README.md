# babel-monitor

Side-loaded AREDN APK that keeps Babel / LQM / arednlink metrics in RAM, exposes a
stateless JSON pull API for external historians, a public status page, and a
live-config CLI.

- Package: `babel-monitor-0.1.41-r0.apk`
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

APK lands in `dist/babel-monitor-0.1.41-r0.apk`.

## Install on a node

From the work-area root (after configuring `install_package_remotely.conf`):

```sh
./install_package_remotely -apk babel-monitor
```

Or copy the APK and:

```sh
apk add --allow-untrusted /tmp/babel-monitor-0.1.41-r0.apk
```

## On-node storage

- Fixed in-RAM sample ring (`1440` slots ≈ **4h @ 10s**) + event ring (`512`)
- Each sample slot is a slice of one **statically allocated flat int buffer** (schema 7), overwritten in place via a rolling head index (not allocate/drop)
- RF/link **names** live in a shared label dictionary (cap 64); the buffer stores indices + values only
- Series expands at most **5 minutes** of samples per API call (UI stitches longer windows)
- Expanded named objects are built only for the response — never retained on the store
- Daemon runs ucode mark-and-sweep GC periodically and after each sample / API reply (refcount alone leaves temps)
- `mem_total_kb` lives in meta only; flash/UCI holds **config only** — never metrics
- Reboot / daemon restart clears history

## CLI

```sh
babel-monitor                  # show live settings + status
babel-monitor -h
babel-monitor -interval 30 -compress off
babel-monitor -enabled off     # pause sampling; API still serves RAM
```

| Flag | UCI | Default |
|------|-----|---------|
| `-interval` | `sample_interval` | 10 (5–300) |
| `-compress` | `compress` | on |
| `-enabled` | `enabled` | on |
| `-sync-limit` | `sync_limit` | 500 |
| `-compress-min` | `compress_min_bytes` | 1024 |

Changes apply via the control socket and persist to `/etc/config/babel-monitor` without restarting the daemon.

## Sync API (pull-only)

Base: `/cgi-bin/babel-monitor`

| Query | Purpose |
|-------|---------|
| `?api=meta` (alias `hello`) | Identity + versions: `api_version` (wire contract), `schema_version` (sample layout), `package_version`, `node_id`, mac, hostname, boot_id, retention |
| `?api=sync&since_seq=N&limit=M` | Samples with `seq > N` for current `boot_id` |
| `?api=events&since_seq=N` | Event ring |
| `?api=live` | Current neighbors + latest sample + optional `wg` tunnel counts |
| `?api=series&seconds=S&end_age=A` | Samples in `[now-A-S, now-A]` (S capped at **300**/5m per request; UI fetches longer windows as slices) |
| `?api=logs&source=S&filters=F&limit=N` | Log panel: `syslog` (optional filters: babel,lqm,arednlink,dnsmasq,netifd,auth), `dumps`, `lqm`, `dmesg` |
| `?api=download&source=S` | Full raw download (no filters/tail): `syslog`, `lqm`, `dmesg`, `dumps` — streamed attachment named `{hostname}-{source}-yyyymmdd.ext` |
| `?api=syslog&limit=N&filters=F` | Alias of logs source=syslog |
| `?api=top` | One-shot `top -bn1` process table (not stored in the ring) |

Optional `compress=1|0|on|off` (default from UCI; gzip level 1 when body ≥ `compress_min_bytes` and client sends `Accept-Encoding: gzip`).

Gap-tolerant: HTTP 200 when the daemon is up; responses include `truncated`, `gap_before`, `next_seq`, `complete`, `boot_id`. No per-poller state on the node.

`api_version` is the stable pull-API contract for central servers (also on `live.meta` / CLI status). Bump it when clients must change how they talk to a node; do not conflate with `schema_version` (in-RAM sample layout) or `package_version` (APK). Current value: **1**.

### Sample host / RF / link fields (schema 7)

Wire samples (sync/series/live) use named fields. Internally the ring is one **flat int buffer** (schema 7; slots overwritten in place). RF/link **labels live once** in a shared dictionary (`LABEL_CAP=64`); each sample stores label indices + values only.

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

`mem_total_kb` is on `?api=meta` / live `meta` only (nearly constant). Live `meta.daemon_rss_kb` is the current reading; per-sample `daemon_rss_kb` is in the ring for history. `meta.label_count` is the shared label dictionary size. `rss_estimate_bytes` estimates the dense ring.

Live neighbors use `type` (DtD, RF, WG-S/WG-C, XLink(N), …) instead of raw iface — not stored in the sample ring. Xlink ifaces `br0.N` display as `XLink(N)`.

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

Open `http://<node>/babel-monitor/` — live neighbors, KPIs, and a history graph with metric tabs (LQ, Cost, Neighbors, Routes, Packets, Link I/O, Hosts, CPU, RAM, Self RSS, RF, Syslog, Top) and 5m / 30m / 1h / 4h ranges from RAM (ring retains ~4h @ 10s). Longer chart windows are fetched as 5m API slices. The X axis is fixed to the selected window. Hover for a crosshair and values. Optional **WG Server Tunnels** / **WG Server Clients** KPIs show `live/active/total` when the tunnel config has entries (live = handshake ≤300s, active = enabled, total = config list). Viewing the UI does not write flash. No Tools menu entry.

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
    .post-install / .post-upgrade / .pre-deinstall
```
