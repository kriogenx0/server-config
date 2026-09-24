#!/bin/bash
# Deploys flyer.ironyoung.com: a PHP app (PHP-FPM), no container. Only the
# vhost and cert are managed here -- the app files (about 190M with images)
# already live in /var/www/flyer.ironyoung.com on the server and aren't kept
# in this repo. Same per-app pattern as the other domains on this host.
#
# One-time setup, before the first run (interactive -- deploy has no sudo
# to install its own sudoers rule, only admin does):
#   scp sudoers.d/flyer-ironyoung-com admin@104.131.183.186:/tmp/
#   ssh -t admin@104.131.183.186 'sudo visudo -c -f /tmp/flyer-ironyoung-com && sudo install -m 0440 -o root -g root /tmp/flyer-ironyoung-com /etc/sudoers.d/flyer-ironyoung-com && rm /tmp/flyer-ironyoung-com'
#
# Safe to re-run; skips certbot once the cert exists.
set -euo pipefail

SSH_TARGET="deploy@104.131.183.186"
DOMAIN="flyer.ironyoung.com"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

echo "==> Installing HTTP-only bootstrap vhost (serves the ACME challenge)"
scp "$SCRIPT_DIR/$DOMAIN.bootstrap.conf" "$SSH_TARGET:/tmp/$DOMAIN.bootstrap.conf"
ssh "$SSH_TARGET" "sudo cp /tmp/$DOMAIN.bootstrap.conf /etc/nginx/sites-available/$DOMAIN && sudo ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN && sudo nginx -t && sudo systemctl reload nginx"

if ssh "$SSH_TARGET" "sudo test -f /etc/letsencrypt/live/$DOMAIN/cert.pem"; then
  echo "==> Certificate already exists, skipping certbot"
else
  echo "==> Requesting certificate"
  ssh "$SSH_TARGET" "sudo certbot certonly --webroot -w /var/www/certbot -d $DOMAIN --non-interactive --agree-tos -m simplex0@gmail.com --deploy-hook 'systemctl reload nginx'"
fi

echo "==> Installing full HTTPS vhost"
scp "$SCRIPT_DIR/$DOMAIN.conf" "$SSH_TARGET:/tmp/$DOMAIN.conf"
ssh "$SSH_TARGET" "sudo cp /tmp/$DOMAIN.conf /etc/nginx/sites-available/$DOMAIN && sudo nginx -t && sudo systemctl reload nginx"

echo "Done: https://$DOMAIN"
