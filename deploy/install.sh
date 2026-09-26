#!/bin/sh
# Installs (or upgrades) bent for the current user: builds, copies the
# release to ~/bent, keeps data in ~/bent-data, (re)starts the user units.
# One-time root steps are in deploy/README.md.
set -eu
cd "$(dirname "$0")/.."
HOST="${BENT_HOST:-slopstack.tomasbjartur.com}"
# Test deployment without a mail sender: sign-up goes straight to the
# passkey (no email verification, no recovery). Set to 0 once mail works.
DIRECT="${BLOG_SIGNUP_DIRECT:-1}"
./build.sh
mkdir -p "$HOME/bent" "$HOME/bent-data" "$HOME/.config/systemd/user"
chmod 700 "$HOME/bent-data"
# Back up the database before the new server migrates it (the backup API
# gives a consistent copy of a live WAL database; cp does not).
if [ -f "$HOME/bent-data/blog.db" ]; then
  mkdir -p "$HOME/bent-data/backups"
  python3 -c 'import sqlite3, sys; s = sqlite3.connect(sys.argv[1]); d = sqlite3.connect(sys.argv[2]); s.backup(d); d.close()' \
    "$HOME/bent-data/blog.db" "$HOME/bent-data/backups/blog-$(date -u +%Y%m%dT%H%M%SZ).db"
  ls -1t "$HOME/bent-data/backups"/blog-*.db | tail -n +11 | xargs -r rm --
fi
install -m 755 build/server "$HOME/bent/server.new" && mv "$HOME/bent/server.new" "$HOME/bent/server"
install -m 644 deploy/Caddyfile "$HOME/bent/Caddyfile"
cat > "$HOME/bent/env" <<ENV
PORT=8080
BLOG_DB=$HOME/bent-data/blog.db
BLOG_ORIGIN=https://$HOST
BLOG_RP_ID=$HOST
BENT_HOST=$HOST
BLOG_SIGNUP_DIRECT=$DIRECT
BEND_NO_TELEMETRY=1
ENV
install -m 644 deploy/bent.service deploy/caddy.service "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable bent caddy >/dev/null
systemctl --user restart bent caddy
sleep 2
systemctl --user --no-pager status bent caddy | grep -E "Active|Main PID"
