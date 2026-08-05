#!/bin/sh
# Build babel-monitor noarch APK using vendored MakeAPK (kn6plv/MakeAPK).
set -e
cd "$(dirname "$0")"
mkdir -p dist
chmod +x \
  src/usr/sbin/babel-monitord \
  src/usr/bin/babel-monitor \
  src/www/cgi-bin/babel-monitor \
  src/etc/init.d/babel-monitor \
  src/.post-install \
  src/.post-upgrade \
  src/.pre-deinstall \
  tools/mkapk.py \
  tools/babel-monitor-poller
python3 tools/mkapk.py \
  -n babel-monitor \
  -v 0.1.43 \
  -r r0 \
  -a noarch \
  -d src \
  -o dist \
  -D "AREDN Babel metrics: in-RAM rings, pull sync API, public status page, live-config CLI" \
  -u "https://github.com/K1RKS/aredn" \
  -l GPL-3.0-only \
  -m "K1RKS <noreply@localhost>"
ls -la dist/
