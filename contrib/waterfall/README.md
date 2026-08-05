# waterfall (side-loaded APK)

AREDN **RF spectrum waterfall** focused on **5 GHz** radios. Primary targets:

- Ubiquiti **Rocket M5** (XM / XW) — ath9k spectral FFT
- **PowerBeam 500** / PowerBeam M5 class — ath9k
- **PowerBeam 500 AC** / MikroTik **hAP ac lite** 5 GHz — ath10k isolated FFT + survey fallback

## What works now (0.2.31)

- **Honest frequency axis**: FFT bins are placed only at MHz the radio actually measured — **no stretch** across a wider plot
- If plot BW &gt; one listen BW: **stitched sections** (retune → dwell → next), drawn side-by-side on X; time is sequential per section
- **ath9k ALL / wide stitch**: classic kn6plv path — `chanscan` + `iw scan freq` (temporary mesh RF interrupt; denser full-band FFT); falls back to section retune if empty
- ath9k current-channel: mesh-safer `background`+`trigger`
- FFT bins use Tim-style absolute dBm → heatmap levels (calibrated across chipsets)
- ath10k: isolated FFT worker + survey fallback (not Tim’s scan-while-spectral primary path)
- Install hooks do not restart `uhttpd`

## Install

1. Build `waterfall-0.2.31-r0.apk`
2. Prefer SSH once when leaving older builds: `apk add --allow-untrusted waterfall-0.2.31-r0.apk`

## Build

```sh
chmod +x build.sh
./build.sh
# → dist/waterfall-0.2.31-r0.apk
```

## CLI

```text
waterfall [-i iface] [-d secs] [-c channel|all] [-b bw|all] [status|capture|session|stop|cache]
waterfall-ath10k-fft -i wlan0 -p phy0 [-t 4]
waterfall-spectral-recover [iface] [phy]
```
