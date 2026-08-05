# waterfall (side-loaded APK)

AREDN **RF spectrum waterfall** focused on **5 GHz** radios. Primary targets:

- Ubiquiti **Rocket M5** (XM / XW) — ath9k spectral FFT
- **PowerBeam 500** / PowerBeam M5 class — ath9k
- **PowerBeam 500 AC** / MikroTik **hAP ac lite** 5 GHz — ath10k isolated FFT + survey fallback

## What works now (0.2.22)

- Dense **time-axis** waterfall; Y axis uses the **requested duration** (e.g. 0→60s)
- Cached plot title shows **start timestamp** plus selected **channel / BW / freq** range
- Channel + BW selectors (defaults = current radio; sessionStorage for this browser tab). Leaving **ALL** restores last channel / radio BW; live radio channel marked in the list
- Top axis shows **channel numbers** with verticals at centers; bottom keeps Start/Stop MHz
- **ALL** = full-band **hybrid** (survey busy-time deltas + live FFT on the current channel; no IBSS hop). Single other channel = temporary UCI retune + restore
- Invalid survey `noise: 0` entries are ignored (they used to fake a strong peak near ch 36)
- Start disabled while a session is already running (iface + est. time left) + wall-clock progress bar
- **ath10k** isolated FFT worker + survey fallback; modal Done closes cleanly

## Install

1. Build `waterfall-0.2.22-r0.apk`
2. `apk add --allow-untrusted waterfall-0.2.22-r0.apk`

## Build

```sh
chmod +x build.sh
./build.sh
# → dist/waterfall-0.2.22-r0.apk
```

## CLI

```text
waterfall [-i iface] [-d secs] [-c channel|all] [-b bw|all] [status|capture|session|stop|cache]
waterfall-ath10k-fft -i wlan0 -p phy0 [-t 4]
waterfall-spectral-recover [iface] [phy]
```
