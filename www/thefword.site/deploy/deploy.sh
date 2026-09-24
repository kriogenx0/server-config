#!/bin/bash
# Deploys thefword.site: a plain static file, no container. Same
# ownership pattern as every other app on this host (own vhost conf, own
# certbot call, own narrow sudoers rule) minus the Docker step -- see
# server-config's README, "Conventions for per-app deploy scripts".
#
# One-time setup, before the first run (interactive -- deploy has no sudo
# to install its own sudoers rule, only admin does):
#   scp sudoers.d/thefword-site admin@104.131.183.186:/tmp/
#   ssh -t admin@104.131.183.186 'sudo visudo -c -f /tmp/thefword-site && sudo install -m 0440 -o root -g root /tmp/thefword-site /etc/sudoers.d/thefword-site && rm /tmp/thefword-site'
#
# DNS (thefword.site + www A records -> the host's IP) must resolve before
# certbot's http-01 challenge can succeed -- this script doesn't check
# that for you.
#
# Safe to re-run any time index.html changes; skips the vhost/certbot
# steps once they're already done.
set -euo pipefail

SSH_TARGET="deploy@104.131.183.186"
DOMAIN="thefword.site"
REMOTE_DIR="/var/www/$DOMAIN"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

echo "==> Ensuring $REMOTE_DIR exists"
ssh "$SSH_TARGET" "sudo mkdir -p '$REMOTE_DIR' && sudo chown deploy:deploy '$REMOTE_DIR'"

echo "==> Syncing site files"
rsync -az "$SCRIPT_DIR/../index.html" "$SSH_TARGET:$REMOTE_DIR/index.html"

echo "==> Installing HTTP-only bootstrap vhost (serves the ACME challenge)"
scp "$SCRIPT_DIR/$DOMAIN.bootstrap.conf" "$SSH_TARGET:/tmp/$DOMAIN.bootstrap.conf"
ssh "$SSH_TARGET" "sudo cp /tmp/$DOMAIN.bootstrap.conf /etc/nginx/sites-available/$DOMAIN && sudo ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN && sudo nginx -t && sudo systemctl reload nginx"

if ssh "$SSH_TARGET" "sudo test -f /etc/letsencrypt/live/$DOMAIN/cert.pem"; then
  echo "==> Certificate already exists, skipping certbot"
else
  echo "==> Requesting certificate"
  ssh "$SSH_TARGET" "sudo certbot certonly --webroot -w /var/www/certbot -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos -m simplex0@gmail.com --deploy-hook 'systemctl reload nginx'"
fi

echo "==> Installing full HTTPS vhost"
scp "$SCRIPT_DIR/$DOMAIN.conf" "$SSH_TARGET:/tmp/$DOMAIN.conf"
ssh "$SSH_TARGET" "sudo cp /tmp/$DOMAIN.conf /etc/nginx/sites-available/$DOMAIN && sudo nginx -t && sudo systemctl reload nginx"

echo "Done: https://$DOMAIN"
