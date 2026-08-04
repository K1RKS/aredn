#!/bin/sh
# Build waterfall noarch APK using vendored MakeAPK (kn6plv/MakeAPK).
set -e
cd "$(dirname "$0")"
mkdir -p dist
chmod +x \
  src/usr/bin/waterfall \
  src/usr/bin/waterfall-session \
  src/usr/bin/waterfall-ath10k-fft \
  src/usr/bin/waterfall-spectral-recover \
  src/www/cgi-bin/waterfall \
  src/usr/share/waterfall/tools-menu.sh \
  src/.post-install \
  src/.post-upgrade \
  src/.pre-deinstall \
  tools/mkapk.py
python3 tools/mkapk.py \
  -n waterfall \
  -v 0.2.20 \
  -r r0 \
  -a noarch \
  -d src \
  -o dist \
  -D "AREDN RF waterfall for 5 GHz radios (Rocket M5, PowerBeam 500/500 AC, hAP ac lite)" \
  -u "https://github.com/K1RKS/aredn" \
  -l GPL-3.0-only \
  -m "K1RKS <noreply@localhost>"
ls -la dist/
