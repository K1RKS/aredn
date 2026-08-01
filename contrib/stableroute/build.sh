#!/bin/sh
# Build stableroute noarch APK using vendored MakeAPK (kn6plv/MakeAPK).
set -e
cd "$(dirname "$0")"
mkdir -p dist
chmod +x \
  src/usr/bin/stableroute \
  tools/mkapk.py
python3 tools/mkapk.py \
  -n stableroute \
  -v 0.1.4 \
  -r r0 \
  -a noarch \
  -d src \
  -o dist \
  -D "AREDN path-stability traceroute: N runs, unique hop paths, RTT avg +- max deviation" \
  -u "https://github.com/K1RKS/aredn" \
  -l GPL-3.0-only \
  -m "K1RKS <noreply@localhost>"
ls -la dist/
