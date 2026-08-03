# waterfall (side-loaded APK)

AREDN **RF spectrum waterfall** focused on **5 GHz** radios. Primary targets:

- Ubiquiti **Rocket M5** (XM / XW) — ath9k spectral FFT
- **PowerBeam 500** / PowerBeam M5 class — ath9k
- **PowerBeam 500 AC** / MikroTik **hAP ac lite** 5 GHz — ath10k isolated FFT + survey fallback

## What works now (0.2.9)

- **Admin-only** Tools → Waterfall + `/a/waterfall`
- **Modal Done** properly closes `#ctrl-modal` (no stuck grey backdrop)
- **ath9k**: spectral FFT via `spectral_scan_ctl`
- **ath10k**: true FFT via isolated worker:
  - single-flight lock (no concurrent spectral ops)
  - hard timeout (default 10s) with on-node watchdog
  - recovery: disable spectral → iface bounce → `/sbin/wifi` reload (not power cycle)
  - exponential cooldown after failures
  - **survey fallback** if FFT empty / cooldown / recovery
- Per-radio RAM cache, radio + duration pickers, CLI

## ath10k design notes

Firmware on hAP ac lite (QCA9887 CT 10.1) advertises spectral WMI. Leaving `background` on and combining with `iw scan` / blocking relay reads has hard-locked IBSS mesh. The worker:

1. Serializes via flock/mkdir lock
2. Prefers short **manual** pulses, then brief **background**, disable ASAP
3. Bounds all relay reads with `timeout`
4. Does **not** enable `--scan` by default (IBSS hang trigger)
5. Arms a local watchdog that recovers Wi-Fi if the pulse exceeds the hard timeout

## Install

1. Build `waterfall-0.2.9-r0.apk`
2. `apk add --allow-untrusted waterfall-0.2.9-r0.apk`

## Build

```sh
chmod +x build.sh
./build.sh
# → dist/waterfall-0.2.9-r0.apk
```

## CLI

```text
waterfall [-i iface] [-d secs] [status|capture|session|stop|cache]
waterfall-ath10k-fft -i wlan0 -p phy0 [-t 10]
waterfall-spectral-recover [iface] [phy]
```
