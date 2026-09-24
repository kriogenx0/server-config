#!/bin/bash
# Manual/ops tooling for Docker-backed sites on the shared host: bring up a
# site's container, redeploy, enable/disable/remove its vhost, list, and
# tail logs. Run from your local machine — every subcommand SSHes out to
# the server; nothing here runs on the server itself (contrast
# bootstrap.sh).
#
# Each app owns its own nginx vhost conf and runs certbot itself, in its
# own repo/deploy workflow (see README) — this script never writes nginx
# config or calls certbot. What it does own: the host-level shared bits
# (bootstrap.sh, the nginx/snippets every app's vhost includes) and generic
# per-site container lifecycle you might otherwise reach for manually
# (first bring-up before an app's own CI exists yet, ad-hoc redeploys,
# decommissioning).
#
# Usage:
#   ./site.sh bootstrap
#   ./site.sh new <domain> <compose-file> <service> [env-file]
#   ./site.sh redeploy <domain> [service]
#   ./site.sh enable <domain>
#   ./site.sh disable <domain>
#   ./site.sh remove <domain> [--stop] [--purge]
#   ./site.sh list
#   ./site.sh logs <domain> [docker|nginx-access|nginx-error]
#
# `bootstrap` copies this repo's bootstrap.sh (and nginx/snippets/) to
# admin@ (host-level admin, not deploy — bootstrap.sh needs broad sudo
# deploy doesn't have) and runs it there with a terminal attached, since it
# needs one interactive sudo password prompt (see bootstrap.sh/README).
# Everything else here operates as deploy, per the narrow NOPASSWD grant
# bootstrap.sh installs for it.
#
# `new` brings up only the named service from your compose file — never
# any db service also defined there. Point the app at the managed database
# instead, via the env file. It picks a free host port on first run and
# remembers it (as HOST_PORT in the site's .env) for every later command —
# your compose file's `ports:` should reference it (e.g.
# "127.0.0.1:${HOST_PORT}:3000"), and it's what your app's own nginx vhost
# should proxy_pass to. It does not touch nginx or certbot at all.
#
# `remove` only disables the nginx vhost by default. --stop also runs
# `docker compose down` (containers/network, not volumes). --purge (implies
# --stop) additionally deletes the nginx config and /var/www/<domain>
# entirely, after an interactive y/N confirmation — it's the only
# irreversible thing here.
set -euo pipefail

SSH_TARGET="deploy@104.131.183.186"
ADMIN_TARGET="admin@104.131.183.186" # host-level admin, used only by `bootstrap`

usage() {
  cat >&2 <<'EOF'
Usage:
  ./site.sh bootstrap
  ./site.sh new <domain> <compose-file> <service> [env-file]
  ./site.sh redeploy <domain> [service]
  ./site.sh enable <domain>
  ./site.sh disable <domain>
  ./site.sh remove <domain> [--stop] [--purge]
  ./site.sh list
  ./site.sh logs <domain> [docker|nginx-access|nginx-error]
EOF
  exit 1
}

validate_domain() {
  if [[ ! "$1" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    echo "Not a valid domain: $1" >&2
    exit 1
  fi
}

remote_dir() { echo "/var/www/$1"; }

enable_and_reload() {
  local DOMAIN="$1"
  ssh "$SSH_TARGET" "sudo ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN && sudo nginx -t && sudo systemctl reload nginx"
}

# ---- bootstrap: ship bootstrap.sh (+ shared nginx snippets) to admin@ ----
cmd_bootstrap() {
  local SCRIPT_DIR; SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  local BOOTSTRAP="$SCRIPT_DIR/bootstrap.sh"
  [ -f "$BOOTSTRAP" ] || { echo "No such file: $BOOTSTRAP" >&2; exit 1; }
  echo "==> Copying bootstrap.sh and shared nginx snippets to $ADMIN_TARGET"
  scp "$BOOTSTRAP" "$ADMIN_TARGET:~/bootstrap.sh"
  ssh "$ADMIN_TARGET" "mkdir -p ~/nginx-snippets"
  scp "$SCRIPT_DIR"/nginx/snippets/*.conf "$ADMIN_TARGET:~/nginx-snippets/"
  echo "==> Running it on $ADMIN_TARGET (needs a terminal for sudo's password prompt)"
  ssh -t "$ADMIN_TARGET" "chmod +x ~/bootstrap.sh && ~/bootstrap.sh"
}

# ---- new: bring up a docker-backed site's container + port -------------
cmd_new() {
  if [ "$#" -lt 3 ]; then echo "Usage: $0 new <domain> <compose-file> <service> [env-file]" >&2; exit 1; fi
  local DOMAIN="$1" COMPOSE_FILE="$2" SERVICE="$3" ENV_FILE="${4:-}"
  validate_domain "$DOMAIN"
  [ -f "$COMPOSE_FILE" ] || { echo "No such compose file: $COMPOSE_FILE" >&2; exit 1; }
  [ -z "$ENV_FILE" ] || [ -f "$ENV_FILE" ] || { echo "No such env file: $ENV_FILE" >&2; exit 1; }

  local REMOTE_DIR; REMOTE_DIR=$(remote_dir "$DOMAIN")

  echo "==> Setting up $REMOTE_DIR"
  ssh "$SSH_TARGET" "sudo mkdir -p '$REMOTE_DIR' && sudo chown deploy:deploy '$REMOTE_DIR'"

  echo "==> Copying compose file"
  scp "$COMPOSE_FILE" "$SSH_TARGET:$REMOTE_DIR/docker-compose.yml"
  if [ -n "$ENV_FILE" ]; then
    echo "==> Copying env file"
    scp "$ENV_FILE" "$SSH_TARGET:$REMOTE_DIR/.env"
  fi

  echo "==> Picking (or reusing) a host port, recording the service name"
  local HOST_PORT
  HOST_PORT=$(ssh "$SSH_TARGET" bash -s -- "$REMOTE_DIR" "$SERVICE" <<'REMOTE'
set -e
cd "$1"
touch .env
port=$(grep -m1 '^HOST_PORT=' .env | cut -d= -f2 || true)
if [ -z "$port" ]; then
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  echo "HOST_PORT=$port" >> .env
fi
if grep -q '^SERVICE=' .env; then
  sed -i "s/^SERVICE=.*/SERVICE=$2/" .env
else
  echo "SERVICE=$2" >> .env
fi
echo "$port"
REMOTE
)
  echo "    HOST_PORT=$HOST_PORT (compose ports: should bind \"127.0.0.1:\${HOST_PORT}:<container-port>\")"

  cmd_redeploy "$DOMAIN" "$SERVICE"
  echo "Done. $SERVICE is up at 127.0.0.1:$HOST_PORT."
  echo "Next: in the app's own repo, add its nginx vhost (proxy_pass to"
  echo "that port, include snippets/acme-challenge.conf + ssl-params.conf)"
  echo "and have its deploy workflow copy it in, get a cert, and reload nginx."
}

# ---- redeploy: pull latest image + recreate container --------------------
cmd_redeploy() {
  if [ "$#" -lt 1 ]; then echo "Usage: $0 redeploy <domain> [service]" >&2; exit 1; fi
  local DOMAIN="$1" SERVICE="${2:-}"
  validate_domain "$DOMAIN"
  local REMOTE_DIR; REMOTE_DIR=$(remote_dir "$DOMAIN")
  echo "==> Redeploying $DOMAIN"
  ssh "$SSH_TARGET" bash -s -- "$REMOTE_DIR" "$SERVICE" <<'REMOTE'
set -e
cd "$1"
svc="$2"
[ -n "$svc" ] || svc=$(grep -m1 '^SERVICE=' .env | cut -d= -f2)
if [ -z "$svc" ]; then echo "No service recorded for this site and none given" >&2; exit 1; fi
docker compose pull "$svc" || true
docker compose up -d --no-deps "$svc"
REMOTE
}

# ---- enable / disable: toggle sites-enabled without touching the app -----
cmd_enable() {
  if [ "$#" -lt 1 ]; then echo "Usage: $0 enable <domain>" >&2; exit 1; fi
  validate_domain "$1"
  echo "==> Enabling $1"
  enable_and_reload "$1"
}

cmd_disable() {
  if [ "$#" -lt 1 ]; then echo "Usage: $0 disable <domain>" >&2; exit 1; fi
  validate_domain "$1"
  echo "==> Disabling $1"
  ssh "$SSH_TARGET" "sudo rm -f /etc/nginx/sites-enabled/$1 && sudo nginx -t && sudo systemctl reload nginx"
}

# ---- remove: disable, optionally stop containers, optionally purge -------
cmd_remove() {
  if [ "$#" -lt 1 ]; then echo "Usage: $0 remove <domain> [--stop] [--purge]" >&2; exit 1; fi
  local DOMAIN="$1"; shift
  validate_domain "$DOMAIN"
  local STOP=0 PURGE=0 arg
  for arg in "$@"; do
    case "$arg" in
      --stop) STOP=1 ;;
      --purge) STOP=1; PURGE=1 ;;
      *) echo "Unknown flag: $arg" >&2; exit 1 ;;
    esac
  done
  local REMOTE_DIR; REMOTE_DIR=$(remote_dir "$DOMAIN")

  echo "==> Disabling $DOMAIN"
  ssh "$SSH_TARGET" "sudo rm -f /etc/nginx/sites-enabled/$DOMAIN && sudo nginx -t && sudo systemctl reload nginx"

  if [ "$STOP" = 1 ]; then
    echo "==> Stopping containers (docker compose down, volumes kept)"
    ssh "$SSH_TARGET" bash -s -- "$REMOTE_DIR" <<'REMOTE'
set -e
if [ -f "$1/docker-compose.yml" ]; then
  cd "$1" && docker compose down
fi
REMOTE
  fi

  if [ "$PURGE" = 1 ]; then
    read -r -p "Permanently delete $REMOTE_DIR and its nginx config on the server? [y/N] " reply
    if [[ "$reply" =~ ^[Yy]$ ]]; then
      echo "==> Purging nginx config and $REMOTE_DIR"
      ssh "$SSH_TARGET" "sudo rm -f /etc/nginx/sites-available/$DOMAIN && sudo rm -rf '$REMOTE_DIR'"
    else
      echo "Skipped purge."
    fi
  fi
  echo "Done."
}

# ---- list: enabled sites, their port/service, and cert expiry ------------
cmd_list() {
  echo "==> Sites on $SSH_TARGET"
  ssh "$SSH_TARGET" bash -s <<'REMOTE'
set -e
for f in /etc/nginx/sites-enabled/*; do
  domain=$(basename "$f")
  [ "$domain" = "default" ] && continue
  port="-"; service="-"
  if [ -f "/var/www/$domain/.env" ]; then
    p=$(grep -m1 '^HOST_PORT=' "/var/www/$domain/.env" | cut -d= -f2); [ -n "$p" ] && port="$p"
    s=$(grep -m1 '^SERVICE=' "/var/www/$domain/.env" | cut -d= -f2); [ -n "$s" ] && service="$s"
  fi
  cert="none"
  if sudo test -f "/etc/letsencrypt/live/$domain/cert.pem"; then
    cert=$(sudo openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$domain/cert.pem" | cut -d= -f2)
  fi
  printf '%-30s port=%-6s service=%-15s cert_expires=%s\n' "$domain" "$port" "$service" "$cert"
done
REMOTE
}

# ---- logs: tail docker or nginx logs for one site ------------------------
cmd_logs() {
  if [ "$#" -lt 1 ]; then echo "Usage: $0 logs <domain> [docker|nginx-access|nginx-error]" >&2; exit 1; fi
  local DOMAIN="$1" KIND="${2:-docker}"
  validate_domain "$DOMAIN"
  local REMOTE_DIR; REMOTE_DIR=$(remote_dir "$DOMAIN")
  case "$KIND" in
    docker)
      ssh -t "$SSH_TARGET" bash -s -- "$REMOTE_DIR" <<'REMOTE'
set -e
cd "$1"
svc=$(grep -m1 '^SERVICE=' .env | cut -d= -f2)
docker compose logs -f --tail=100 "$svc"
REMOTE
      ;;
    nginx-access)
      ssh -t "$SSH_TARGET" "sudo tail -f /var/log/nginx/access.log | grep --line-buffered '$DOMAIN'"
      ;;
    nginx-error)
      ssh -t "$SSH_TARGET" "sudo tail -f /var/log/nginx/error.log | grep --line-buffered '$DOMAIN'"
      ;;
    *)
      echo "Unknown log kind: $KIND (expected docker|nginx-access|nginx-error)" >&2
      exit 1
      ;;
  esac
}

cmd="${1:-}"
if [ "$#" -gt 0 ]; then shift; fi
case "$cmd" in
  bootstrap) cmd_bootstrap "$@" ;;
  new) cmd_new "$@" ;;
  redeploy) cmd_redeploy "$@" ;;
  enable) cmd_enable "$@" ;;
  disable) cmd_disable "$@" ;;
  remove) cmd_remove "$@" ;;
  list) cmd_list "$@" ;;
  logs) cmd_logs "$@" ;;
  *) usage ;;
esac
