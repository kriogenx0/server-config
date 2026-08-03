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
gpg2 --keyserver keyserver.ubuntu.com --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 7D2BAF1CF37B13E2069D6956105BD0E739499BDB
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
TMP_SUDOERS=$(mktemp)
cat > "$TMP_SUDOERS" <<'EOF'
deploy ALL=(root) NOPASSWD: /usr/bin/mkdir -p /var/www/*, \
  /usr/bin/chown deploy\:deploy /var/www/*, \
  /usr/bin/ln -sf /etc/nginx/sites-available/* /etc/nginx/sites-enabled/*, \
  /usr/bin/rm -f /etc/nginx/sites-enabled/*, \
  /usr/bin/rm -f /etc/nginx/sites-available/*, \
  /usr/bin/rm -rf /var/www/*, \
  /usr/sbin/nginx -t, \
  /usr/bin/systemctl reload nginx, \
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
