#!/bin/sh
# Installs Chrome for Testing's headless shell and the system libraries it
# needs into ~/opt, without root (for tests/browser_test.py).
set -eu
mkdir -p "$HOME/opt" && cd "$HOME/opt"
if [ ! -x chrome-headless-shell-linux64/chrome-headless-shell ]; then
  url=$(curl -fsSL https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json |
    python3 -c "import json,sys; d=json.load(sys.stdin); print([x['url'] for x in d['channels']['Stable']['downloads']['chrome-headless-shell'] if x['platform']=='linux64'][0])")
  curl -fsSL -o chs.zip "$url"
  python3 -c "import zipfile; zipfile.ZipFile('chs.zip').extractall('.')"
  rm chs.zip
  chmod +x chrome-headless-shell-linux64/chrome-headless-shell
fi
tmp=$(mktemp -d)
(cd "$tmp" && apt-get download libasound2t64 libatk1.0-0t64 libatk-bridge2.0-0t64 libatspi2.0-0t64 libgbm1 \
  libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libwayland-server0 libdrm2 libxi6 libxtst6 libxrender1 >/dev/null)
for f in "$tmp"/*.deb; do dpkg-deb -x "$f" "$HOME/opt/chromelibs"; done
rm -rf "$tmp"
LD_LIBRARY_PATH="$HOME/opt/chromelibs/usr/lib/x86_64-linux-gnu" chrome-headless-shell-linux64/chrome-headless-shell --version
