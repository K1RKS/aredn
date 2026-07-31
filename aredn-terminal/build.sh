#!/bin/sh
# Build aredn-terminal noarch APK using vendored MakeAPK (kn6plv/MakeAPK).
# Bump -v (patch: 0.1.x) on every package change before rebuild/commit.
set -e
cd "$(dirname "$0")"
mkdir -p dist
chmod +x \
  src/www/cgi-bin/terminal \
  src/www/cgi-bin/terminal-api \
  src/www/cgi-bin/apps/terminal/admin \
  src/usr/libexec/aredn-terminal-session \
  tools/mkapk.py
python3 tools/mkapk.py \
  -n aredn-terminal \
  -v 0.1.10 \
  -r r0 \
  -a noarch \
  -d src \
  -o dist \
  -p socat \
  -D "AREDN authenticated interactive terminal (xterm.js + ucode CGI)" \
  -u "https://github.com/K1RKS/aredn" \
  -l GPL-3.0-only \
  -m "K1RKS <noreply@localhost>"
ls -la dist/
