# waterfall (side-loaded APK)

AREDN **RF spectrum waterfall** focused on **5 GHz** radios. Primary targets:

- Ubiquiti **Rocket M5** (XM / XW) — ath9k spectral FFT (primary path)
- **PowerBeam 500** / PowerBeam M5 class — ath9k
- **PowerBeam 500 AC** (PBE-5AC-500) — ath10k FFT experimental
- MikroTik **hAP ac lite** (RB952Ui-5ac2nD) — dual radio; auto-selects **5 GHz** (QCA9887 / ath10k, experimental). 2.4 GHz is ath9k on the SoC.

## What works now (0.1.4)

- **Tools → Waterfall**: Status probe + Capture button
- Clear **Hardware not supported** banner (and no Capture) when spectral FFT is unavailable
- **CLI**: `waterfall status` / `waterfall capture` (`-i wlan1` to force an iface)
- Auto-select prefers a **5 GHz** mesh radio when dual-band (hAP ac lite)
- Capability detection (board, phy, chipset, spectral debugfs)
- NL80211 survey noise/busy summary
- ath9k / experimental ath10k current-channel spectral dump → `/tmp/waterfall-fft.bin`

Not yet: FFT TLV parse / live waterfall heatmap UI.

## GUI

Installs **Tools → Waterfall**. CGI: `/cgi-bin/waterfall?action=status|capture[&iface=wlan1]`.
Install/upgrade restarts uhttpd so the Tools menu picks up the entry.

## Install

1. Build (or download) `waterfall-0.1.4-r0.apk`
2. On the node: **Status → Packages** → upload / install with allow-untrusted  
   or: `apk add --allow-untrusted waterfall-0.1.4-r0.apk`

## Build

```sh
chmod +x build.sh
./build.sh
# → dist/waterfall-0.1.4-r0.apk
```

Uses a vendored copy of [kn6plv/MakeAPK](https://github.com/kn6plv/MakeAPK) (`tools/mkapk.py`). No OpenWrt buildroot required.

## CLI

```text
waterfall [-i iface] [status|capture]
```
