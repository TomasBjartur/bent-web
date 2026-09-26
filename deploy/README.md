# Deploying bent

Target: this server (Ubuntu 24.04), user `claude`, no root needed after
three one-time steps.

## One-time, as root

```sh
# Let Caddy (and only Caddy) bind ports 80 and 443.
sudo setcap 'cap_net_bind_service=+ep' /home/claude/opt/caddy/caddy
# Keep claude's services running when nobody is logged in, and at boot.
sudo loginctl enable-linger claude
# If a firewall is active: allow HTTP (certificate challenges, redirects) and HTTPS.
sudo ufw allow 80/tcp && sudo ufw allow 443/tcp
```

## Install / upgrade

```sh
deploy/install.sh            # builds, installs to ~/bent, restarts
```

The site is `https://slopstack.tomasbjartur.com` (DNS: A record
`slopstack` -> 172.236.228.71). Passkeys are bound to this domain.

**Test mode:** `BLOG_SIGNUP_DIRECT=1` (the default in install.sh) skips the
email step: sign-up goes straight to creating a passkey. Emails are not
verified and there is no account recovery. Set it to 0 once a mail sender
exists.

## Operations

- Logs: `journalctl --user -u bent -u caddy -f`
- Data: `~/bent-data/blog.db` (WAL). Backup: `sqlite3 ~/bent-data/blog.db ".backup backup.db"`.
- Email: nothing sends mail yet. Sign-up and recovery links are in the
  `outbox` table: `tools/outbox.py` prints the pending ones.
