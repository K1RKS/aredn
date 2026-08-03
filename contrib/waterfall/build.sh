#!/bin/sh
# Build waterfall noarch APK using vendored MakeAPK (kn6plv/MakeAPK).
set -e
cd "$(dirname "$0")"
mkdir -p dist
chmod +x \
  src/www/cgi-bin/waterfall \
  src/usr/share/waterfall/tools-menu.sh \
  src/.post-install \
  src/.post-upgrade \
  src/.pre-deinstall \
  tools/mkapk.py
python3 tools/mkapk.py \
  -n waterfall \
  -v 0.1.1 \
  -r r0 \
  -a noarch \
  -d src \
  -o dist \
  -D "AREDN RF waterfall for 5 GHz radios (Rocket M5, PowerBeam 500 / 500 AC)" \
  -u "https://github.com/K1RKS/aredn" \
  -l GPL-3.0-only \
  -m "K1RKS <noreply@localhost>"
ls -la dist/
