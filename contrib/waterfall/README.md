# waterfall (side-loaded APK)

AREDN **RF spectrum waterfall** focused on **5 GHz** radios. Primary targets:

- Ubiquiti **Rocket M5** (XM / XW) — ath9k spectral FFT (primary path)
- **PowerBeam 500** / PowerBeam M5 class — ath9k
- **PowerBeam 500 AC** (PBE-5AC-500) — ath10k FFT experimental
- MikroTik **hAP ac lite** (RB952Ui-5ac2nD) — dual radio; auto-selects **5 GHz** (QCA9887 / ath10k, experimental). 2.4 GHz is ath9k on the SoC.

## What works now (0.2.5)

- **Admin-only** Tools → Waterfall heatmap + dedicated page `/a/waterfall`
- **Bounded** spectral session (5s–10m, default 30s; disrupts RF), then **always** restores the radio
- Longer runs **space sweeps** (≤90) so RAM stays bounded
- Parsed FFT TLV sweeps cached **per radio** in RAM (`/tmp/waterfall-cache-<iface>.json`) — switching radios loads that cache
- Canvas waterfall history (frequency × sweep, blue→red intensity)
- **Radio + duration pickers** on Tools + `/a/waterfall`
- **CLI**: `waterfall status|capture|session|stop|cache`
- Capability detection; hardware-not-supported banner when FFT is unavailable

## RF safety

Spectral scan takes the radio out of normal mesh/client use. Sessions are hard-capped at **10 minutes** (selectable durations up to that), spectral mode is forced **disable** afterward (even if the browser disconnects), and results are stored only in `/tmp` (tmpfs). Do not leave an open-ended live scan running over RF.

## GUI

- **Tools → Waterfall** (admin menu) — wide dialog with heatmap
- **Page:** `http://<node>/a/waterfall` (admin login required)
- **API:** `/a/waterfall/e/api?action=start|stop|status|cache` (admin)

## Install

1. Build (or download) `waterfall-0.2.5-r0.apk`
2. On the node: **Status → Packages** → upload / install with allow-untrusted  
   or: `apk add --allow-untrusted waterfall-0.2.5-r0.apk`

## Build

```sh
chmod +x build.sh
./build.sh
# → dist/waterfall-0.2.5-r0.apk
```

Uses a vendored copy of [kn6plv/MakeAPK](https://github.com/kn6plv/MakeAPK) (`tools/mkapk.py`). No OpenWrt buildroot required.

## CLI

```text
waterfall [-i iface] [-d secs] [status|capture|session|stop|cache]
```
