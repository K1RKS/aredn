# waterfall (side-loaded APK)

AREDN **RF spectrum waterfall** focused on **5 GHz** radios. Primary targets:

- Ubiquiti **Rocket M5** (XM / XW) — ath9k spectral FFT
- **PowerBeam 500** / PowerBeam M5 class — ath9k
- **PowerBeam 500 AC** / MikroTik **hAP ac lite** 5 GHz — ath10k isolated FFT + survey fallback

## What works now (0.2.17)

- Dense **time-axis** waterfall: many short ath10k FFT pulses; Y = wall-clock 0→duration. Strict TLV resync (no false HT20 from garbage). Works without `timeout`/`usleep`.
- **ath10k** isolated FFT worker (lock + timeout + local Wi-Fi recovery) + survey fallback
- Modal Done closes cleanly (no grey backdrop)

## Install

1. Build `waterfall-0.2.17-r0.apk`
2. `apk add --allow-untrusted waterfall-0.2.17-r0.apk`

## Build

```sh
chmod +x build.sh
./build.sh
# → dist/waterfall-0.2.17-r0.apk
```

## CLI

```text
waterfall [-i iface] [-d secs] [status|capture|session|stop|cache]
waterfall-ath10k-fft -i wlan0 -p phy0 [-t 4]
waterfall-spectral-recover [iface] [phy]
```
