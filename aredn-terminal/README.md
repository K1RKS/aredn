# AREDN Terminal

Side-loaded **noarch** APK that adds an authenticated interactive terminal to an AREDN node.

- **UI:** `/cgi-bin/terminal` (xterm.js in the browser)
- **API:** `/cgi-bin/terminal-api` (ucode CGI session I/O)
- **Apps bar:** Admin launcher under `apps/terminal` with a live **BUSY** badge while a session is open

## Install

1. Build (or download) `aredn-terminal-0.1.2-r0.apk`
2. On the node: **Status → Packages**, or:

```sh
apk add --allow-untrusted /tmp/aredn-terminal-0.1.2-r0.apk
```

3. Open `http://<node>/cgi-bin/terminal`, or use the apps-bar **terminal** icon (admin).

Uses the node root password and the same `authV1` cookie as the stock `/a` UI. If you are already logged into the admin UI, the terminal page skips the password form. Every API call also requires a valid cookie.

## Build

```sh
cd aredn-terminal
chmod +x build.sh
./build.sh
```

Output: `dist/aredn-terminal-0.1.2-r0.apk`

Uses vendored [kn6plv/MakeAPK](https://github.com/kn6plv/MakeAPK) — no OpenWrt buildroot required.

## Behavior notes

- Spawns `/bin/ash -l` with FIFO stdin and file-captured stdout (no PTY daemon).
- Full-screen TTY programs (e.g. `vim`) may not behave correctly; basic interactive shell use is the target.
- Only **one** concurrent session is allowed. Abandoned sessions clear after ~60s without heartbeat; the apps badge then drops.
- Badge: `/tmp/apps/terminal/badge` = `BUSY` (red) while a session is alive; removed when idle.

## Layout

```
aredn-terminal/
├── build.sh
├── tools/mkapk.py
└── src/
    ├── usr/libexec/aredn-terminal-session
    ├── usr/share/ucode/aredn_terminal.uc
    ├── www/cgi-bin/terminal
    ├── www/cgi-bin/terminal-api
    ├── www/cgi-bin/apps/terminal/admin
    ├── www/apps/terminal/icon.svg
    └── www/aredn-terminal/          # vendored xterm.js + page assets
```
