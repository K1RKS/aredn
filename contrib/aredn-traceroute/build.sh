#!/bin/sh
# Build aredn-traceroute noarch APK using vendored MakeAPK (kn6plv/MakeAPK).
set -e
cd "$(dirname "$0")"
mkdir -p dist
chmod +x \
  src/usr/bin/aredn-traceroute \
  src/usr/share/aredn-traceroute/cgi-bin-traceroute \
  src/usr/share/aredn-traceroute/cgi-swap.sh \
  src/usr/share/aredn-traceroute/traceroute.firmware.default \
  src/.post-install \
  src/.post-upgrade \
  src/.pre-deinstall \
  tools/mkapk.py
python3 tools/mkapk.py \
  -n aredn-traceroute \
  -v 0.1.18 \
  -r r0 \
  -a noarch \
  -d src \
  -o dist \
  -D "AREDN traceroute with per-hop GPS, link type, tx/rx cost, and Babel metric" \
  -u "https://github.com/K1RKS/aredn" \
  -l GPL-3.0-only \
  -m "K1RKS <noreply@localhost>"
ls -la dist/
