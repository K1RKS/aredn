# waterfall (side-loaded APK)

AREDN **RF spectrum waterfall** focused on **5 GHz** radios. Primary targets:

- Ubiquiti **Rocket M5** (XM / XW) — ath9k spectral FFT
- **PowerBeam 500** / PowerBeam M5 class — ath9k
- **PowerBeam 500 AC** / MikroTik **hAP ac lite** 5 GHz — **survey by default** (QCA9887); FFT opt-in only

## What works now (0.2.41)

- **QCA988x / hAP ac lite 5 GHz safe default**: survey heatmap (no `spectral_scan_ctl`). FFT is an explicit UI/CLI opt-in, capped to **5s**, with **disable-only** recover (no `wifi reload` / iface bounce).
- **4-slot cache history per radio** in `/tmp` (RAM; cleared on reboot): Current / Previous / −2 / −3; Start rotates history and shows “New scan in process”
- Browser keeps slot images in memory after first fetch so tab switches are instant; node cache still serves new sessions
- **Amplify survey** (default on): boosts noise/busy contrast so tiny channel activity shows over time; toggle in UI or `--no-amplify`
- **Clear cache**: removes all per-radio `/tmp` caches (all slots); hover shows space freed
- Title shows **Experimental FFT** only when that capture mode was used
- **Honest frequency axis**: FFT bins placed only at measured MHz
- ath9k ALL/wide: classic kn6plv `chanscan` + `iw scan freq` (temporary mesh RF interrupt)
- Persist scan notes under `/etc/waterfall/session.log`; hold file `/tmp/waterfall-scan.active`
- Install hooks do not restart `uhttpd`

## Install

1. Build `waterfall-0.2.41-r0.apk`
2. Prefer SSH once when leaving older builds: `apk add --allow-untrusted waterfall-0.2.41-r0.apk`

## Build

```sh
chmod +x build.sh
./build.sh
# → dist/waterfall-0.2.41-r0.apk
```

## CLI

```text
waterfall [-i iface] [-d secs] [-c channel|all] [-b bw|all] [--fft] [--no-amplify] [status|capture|session|stop|cache]
# On QCA988x, omit --fft for survey (safe). Use --fft only for short experimental pulses.
waterfall-ath10k-fft -i wlan0 -p phy0 [-t 4] [--safe-recover]
waterfall-spectral-recover [iface] [phy]   # disable-only by default; --escalate for bounce/reload
```
