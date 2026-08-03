# waterfall (side-loaded APK)

AREDN **RF spectrum waterfall** focused on **5 GHz** radios. Primary targets:

- Ubiquiti **Rocket M5** (XM / XW)
- **PowerBeam 500**
- **PowerBeam 500 AC** (PBE-5AC-500 class)

This package is a **scaffold / stub**: Tools menu entry and CGI exist, but spectrum
capture (FFT / debugfs) and the live waterfall display are not implemented yet.

Stock firmware already has **Tools → WiFi Scan** for nearby SSIDs. Release notes
note missing wifi scan / waterfall info on some Ubiquiti 802.11ac devices; this
work area is where waterfall support for the focus radios will grow.

## GUI

Installs **Tools → Waterfall**. Install/upgrade restarts uhttpd so the Tools menu
picks up the new entry. CGI endpoint: `/cgi-bin/waterfall`.

## Install

1. Build (or download) `waterfall-0.1.1-r0.apk`
2. On the node: **Status → Packages** → upload / install with allow-untrusted  
   or: `apk add --allow-untrusted waterfall-0.1.1-r0.apk`

## Build

```sh
chmod +x build.sh
./build.sh
# → dist/waterfall-0.1.1-r0.apk
```

Uses a vendored copy of [kn6plv/MakeAPK](https://github.com/kn6plv/MakeAPK) (`tools/mkapk.py`). No OpenWrt buildroot required.
