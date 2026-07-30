#!/bin/sh
# Build aredn-traceroute noarch APK using vendored MakeAPK (kn6plv/MakeAPK).
set -e
cd "$(dirname "$0")"
mkdir -p dist
chmod +x src/usr/bin/aredn-traceroute src/www/cgi-bin/traceroute tools/mkapk.py
python3 tools/mkapk.py \
  -n aredn-traceroute \
  -v 0.1.9 \
  -r r0 \
  -a noarch \
  -d src \
  -o dist \
  -D "AREDN traceroute with per-hop GPS, link type, and Babel cost" \
  -u "https://github.com/K1RKS/aredn" \
  -l GPL-3.0-only \
  -m "K1RKS <noreply@localhost>"
ls -la dist/
