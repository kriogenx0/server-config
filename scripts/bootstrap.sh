#!/bin/bash
# One-time (or repeatable) provisioning shared by every site on this host.
# Run by hand over SSH as admin@104.131.183.186 — see README.
set -e

sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get autoremove -y
sudo apt-get clean

# nginx: reverse-proxies every site on this host to its own app (Docker
# container, Passenger, whatever that app uses).
sudo apt-get install -y nginx

# Passenger: nginx module for the Passenger-deployed sites (ironyoung,
# paulandvaos, lauradantoni). Config lives in
# nginx/conf.d/mod-http-passenger.conf, tracked in this repo.
sudo apt-get install -y nginx-extras passenger

# certbot: HTTPS certs. Each app runs it itself, in its own deploy workflow
# (see README), always in --webroot mode against /var/www/certbot -- never
# the --nginx plugin, so it never edits an app's own vhost config.
sudo apt-get install -y certbot
sudo mkdir -p /var/www/certbot

# Shared nginx snippets (ACME challenge location + TLS params) that every
# vhost -- this repo's or an app's own -- includes rather than certbot
# editing each vhost's config directly. nginx/snippets/ in this repo is the
# source of truth; `site.sh bootstrap` ships it alongside this script.
if [ -d ~/nginx-snippets ]; then
  sudo mkdir -p /etc/nginx/snippets
  sudo cp ~/nginx-snippets/*.conf /etc/nginx/snippets/
  rm -rf ~/nginx-snippets
  sudo nginx -t && sudo systemctl reload nginx
fi

# Docker: apps that run in containers (rather than e.g. Passenger) use this.
# Official apt repo (not the get.docker.com script) so updates flow through
# normal apt upgrades and the install is pinned/auditable.
sudo apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc || true
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# RVM: Ruby version manager shared by the Passenger/Rails sites (ironyoung,
# paulandvaos, lauradantoni). No default ruby installed here — each app
# installs/pins its own version via `rvm install` against its
# .ruby-version, same division of labor as Docker above.
sudo apt-get install -y gnupg2
# Imported for both admin (for any later interactive `rvm get`/`rvm install`
# as admin) and root -- the installer below runs as root (`sudo bash`), and
# checks *root's* keyring for these keys, not admin's.
gpg2 --keyserver keyserver.ubuntu.com --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 7D2BAF1CF37B13E2069D6956105BD0E739499BDB
sudo gpg2 --keyserver keyserver.ubuntu.com --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 7D2BAF1CF37B13E2069D6956105BD0E739499BDB
curl -sSL https://get.rvm.io | sudo bash -s stable
sudo usermod -aG rvm admin

# deploy: the account that owns every Docker-backed site on this host.
# site.sh (both its own `redeploy` and every GitHub-Actions-driven CI
# deploy) SSHes in as deploy to run `docker compose pull`/`up` directly in
# that site's /var/www/<domain>/, which it also owns outright (see
# cmd_new) — no more admin involvement in Docker sites at all. Docker-group
# membership covers the compose commands; the NOPASSWD sudoers rule below
# covers the narrow mkdir/nginx slice site.sh itself needs. Each app's own
# nginx vhost + certbot call is a separate, narrower grant that app adds
# for itself under /etc/sudoers.d/<app-name> (see README) — not here.
#
# admin remains the account for host-level administration (this script,
# ad-hoc server work, apt upgrades) and for the older Passenger/RVM sites
# (ironyoung, paulandvaos, lauradantoni), which are a separate, non-Docker
# deploy path this migration doesn't touch. deploy intentionally has no
# general sudo — only the scoped grant below — so it staying CI-facing
# doesn't expand to host-admin-equivalent access.
if ! id deploy >/dev/null 2>&1; then
  sudo adduser --disabled-password --gecos "" deploy
fi
sudo usermod -aG docker deploy

# site.sh SSHes in as deploy directly from your local machine (not via
# admin), so it needs the same key(s) already authorized for admin --
# --disabled-password means deploy has no password to fall back on, so
# without this, every site.sh command hangs on an unanswerable password
# prompt.
sudo mkdir -p /home/deploy/.ssh
sudo cp /home/admin/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
sudo chown -R deploy:deploy /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh
sudo chmod 600 /home/deploy/.ssh/authorized_keys

# Swap: bundle install / yarn / assets:precompile have OOM'd on this box's
# RAM alone during deploys. 4G swapfile, persisted via fstab so it survives
# a reboot (previously had to be hand-recreated after every one).
if [ ! -f /swapfile ]; then
  sudo fallocate -l 4G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
fi
sudo swapon /swapfile 2>/dev/null || true
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null

# Disk hygiene: the journal had no size cap (grew to 3.6G) and Passenger
# dumps a ~250K passenger-error-*.html into /tmp on every failed app start
# (22k files, 5.4G). Cap the journal, and clear stale error pages daily.
sudo mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=200M\n' | sudo tee /etc/systemd/journald.conf.d/size.conf > /dev/null
sudo systemctl restart systemd-journald
sudo journalctl --vacuum-size=200M
sudo find /tmp -maxdepth 1 -name 'passenger-error-*.html' -delete
printf '#!/bin/sh\nfind /tmp -maxdepth 1 -name "passenger-error-*.html" -mtime +3 -delete\n' | sudo tee /etc/cron.daily/passenger-error-clean > /dev/null
sudo chmod 755 /etc/cron.daily/passenger-error-clean

# Log rotation: logrotate's systemd timer does the daily run (nginx, syslog,
# auth.log, php-fpm already have stock configs). Two gaps on this host:
#  - btmp (failed-login log) only rotated monthly and reached 250M+.
#  - Docker's default json-file driver never rotates container logs.
sudo apt-get install -y logrotate
sudo systemctl enable --now logrotate.timer
printf '/var/log/btmp {\n    missingok\n    weekly\n    maxsize 50M\n    rotate 2\n    compress\n    create 0660 root utmp\n}\n' | sudo tee /etc/logrotate.d/btmp > /dev/null
sudo logrotate --debug /etc/logrotate.conf > /dev/null

# Don't access-log health checks (/up, /health, /healthz, /healthcheck) --
# one global map + conditional on the stock access_log covers every vhost,
# including apps' own. Reverts itself if nginx -t rejects the result.
printf 'map $request_uri $loggable {\n    ~^/(up|health|healthz|healthcheck)(\\?|$) 0;\n    default 1;\n}\n' | sudo tee /etc/nginx/conf.d/skip-health-logs.conf > /dev/null
if grep -qE '^\s*access_log /var/log/nginx/access.log;' /etc/nginx/nginx.conf; then
  sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
  sudo sed -i 's#^\(\s*\)access_log /var/log/nginx/access.log;#\1access_log /var/log/nginx/access.log combined if=$loggable;#' /etc/nginx/nginx.conf
  if sudo nginx -t; then
    sudo rm /etc/nginx/nginx.conf.bak
    sudo systemctl reload nginx
  else
    sudo mv /etc/nginx/nginx.conf.bak /etc/nginx/nginx.conf
    echo "WARNING: health-check log filter rejected by nginx -t; reverted" >&2
  fi
fi

# Docker log cap. Only applies to containers created after the daemon next
# restarts -- not restarted here, since that would bounce every site;
# existing containers keep unlimited logs until recreated.
sudo mkdir -p /etc/docker
printf '{\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "10m", "max-file": "3" }\n}\n' | sudo tee /etc/docker/daemon.json > /dev/null

# Passwordless sudo for site.sh: it makes many short-lived SSH connections
# per command (see site.sh's header), so needing a password each time isn't
# workable. Scoped narrowly to the mkdir/vhost-toggle/reload commands it
# actually runs -- apt-get, docker installs, etc. above still prompt, which
# is fine since this script is run by hand, ideally with `ssh -t` so one
# password covers the whole run (sudo's timestamp cache).
#
# No certbot here: site.sh never calls it (see its header) — each app
# grants that to itself, narrowly, under its own /etc/sudoers.d/<app-name>.
#
# Granted to deploy, not admin — site.sh (and CI) both operate as deploy
# now, see the comment above the deploy account creation.
# Paths below must be each binary's *actual* resolved location (check with
# `which <cmd>` on the box, since sudo matches the literal absolute path,
# not whatever's on PATH at grant-authoring time) -- this box doesn't have
# a full usr-merge, so chown/ln/rm/systemctl live in /bin, not /usr/bin,
# even though mkdir does resolve to /usr/bin (a symlink) and nginx to
# /usr/sbin. Getting one of these wrong doesn't error at install time --
# it just silently falls through to an (unusable, non-interactive) sudo
# password prompt the next time site.sh or an app's deploy.sh runs.
TMP_SUDOERS=$(mktemp)
cat > "$TMP_SUDOERS" <<'EOF'
deploy ALL=(root) NOPASSWD: /usr/bin/mkdir -p /var/www/*, \
  /bin/chown deploy\:deploy /var/www/*, \
  /bin/ln -sf /etc/nginx/sites-available/* /etc/nginx/sites-enabled/*, \
  /bin/rm -f /etc/nginx/sites-enabled/*, \
  /bin/rm -f /etc/nginx/sites-available/*, \
  /bin/rm -rf /var/www/*, \
  /usr/sbin/nginx -t, \
  /bin/systemctl reload nginx, \
  /usr/bin/test -f /etc/letsencrypt/live/*/cert.pem, \
  /usr/bin/openssl x509 -enddate -noout -in /etc/letsencrypt/live/*/cert.pem
EOF
sudo visudo -c -f "$TMP_SUDOERS"
sudo install -m 0440 -o root -g root "$TMP_SUDOERS" /etc/sudoers.d/deploy-site-scripts
rm -f "$TMP_SUDOERS"

# Retire the old admin-owned grant now that site.sh runs as deploy instead —
# idempotent like everything else in this script.
sudo rm -f /etc/sudoers.d/admin-site-scripts

echo "Done. Log out/in (or start a new shell) for the docker/rvm group membership to take effect."
