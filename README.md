# server-config

One-time provisioning for the shared Ubuntu host at `104.131.183.186`,
which hosts multiple independent sites/apps side by side (e.g.
`ironyoung.com`, `pocketproducer.net`). This repo holds only what's common
across all of them — installing Docker, nginx (+ the Passenger module and
RVM for the Passenger/Rails sites), certbot, the nginx snippets every
vhost includes, a swapfile, and shared conventions. Each app's own
deploy-specific setup (its database, its git checkout, its **own** nginx
site conf and certbot call, its sudoers rule, its own pinned Ruby version
via `rvm install`) lives in that app's own repo, typically under `deploy/`.

Two accounts: `admin` for host-level administration (this script, ad-hoc
server work, apt upgrades) and the older Passenger/RVM sites; `deploy` for
every Docker-backed site — it owns `/var/www/<domain>/` outright and is
what `site.sh` and every GitHub-Actions CI deploy SSH in as. `deploy`
intentionally has no general sudo, only the narrow grant `site.sh` needs
(see bootstrap.sh) — it's a CI-facing account, not an admin-equivalent one.

## Usage

Run once on a fresh box, or after adding a new tool everything should share:

```
scp bootstrap.sh admin@104.131.183.186:~
ssh -t admin@104.131.183.186 ./bootstrap.sh
```

or equivalently, `./site.sh bootstrap` from this repo does the same two
steps (plus it also ships `nginx/snippets/` — see below). Safe to re-run —
every step is idempotent. Both use `-t`/a terminal so the one password
prompt for `sudo` covers the whole run (sudo caches it for a few minutes);
without a terminal, `sudo` has nowhere to prompt and just fails.

`site.sh` is manual/ops tooling for Docker-backed sites — bringing up a
site's container, redeploying, toggling or removing its vhost, listing,
tailing logs. It never writes nginx config or calls certbot; that's each
app's own job, in its own repo (see Conventions below). Run it from your
local machine; it SSHes out to the server rather than running on it:

```
./site.sh bootstrap                                          # ship + run bootstrap.sh as admin
./site.sh pull-nginx                                          # mirror the server's /etc/nginx into nginx/ here
./site.sh new <domain> <compose-file> <service> [env-file]   # bring up the container + a stable port
./site.sh redeploy <domain> [service]                         # pull + recreate container
./site.sh enable <domain>                                     # symlink into sites-enabled + reload
./site.sh disable <domain>                                    # unlink from sites-enabled + reload
./site.sh remove <domain> [--stop] [--purge]                  # disable, optionally stop/delete
./site.sh list                                                # enabled sites, ports, cert expiry
./site.sh logs <domain> [docker|nginx-access|nginx-error]     # tail logs
```

`new` brings up only the named service from your compose file — never any
db service also defined there; point the app at the managed database
instead, via the env file. It picks a free host port on first run and
remembers it (as `HOST_PORT` in the site's `.env` on the server) for every
later command — your compose file's `ports:` should reference it (e.g.
`"127.0.0.1:${HOST_PORT}:3000"`), and it's what the app's own nginx vhost
should `proxy_pass` to. It does not touch nginx or certbot at all; that
happens in the app's own repo (see Conventions).

`remove` only disables the vhost by default; `--stop` also runs `docker
compose down` (keeps volumes); `--purge` (implies `--stop`) additionally
deletes the nginx config and `/var/www/<domain>` entirely, after an
interactive y/N confirmation — the only irreversible thing here.

Every subcommand is safe to re-run.

`site.sh` depends on the `NOPASSWD` sudoers rule bootstrap.sh installs at
`/etc/sudoers.d/deploy-site-scripts` — it makes several short-lived SSH
connections per command, so an interactive password prompt isn't workable.
The rule is scoped to only the mkdir/vhost-toggle/reload commands site.sh
itself runs (no certbot — see Conventions); it doesn't grant blanket sudo.
Run bootstrap.sh (or re-run it) before using site.sh on a box that doesn't
have it yet.

## Shared nginx snippets

`nginx/snippets/acme-challenge.conf` and `nginx/snippets/ssl-params.conf`
are the source of truth for the bits every vhost needs, so certbot never
has to edit a vhost's own config (the way `certbot --nginx` does) — that's
what used to cause drift between a tracked config and the live one. Every
vhost — this repo's or an app's own — should `include` them:

```
server {
    listen 80;
    server_name example.com www.example.com;
    include snippets/acme-challenge.conf;   # serves the ACME http-01 challenge
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl;
    server_name example.com www.example.com;
    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
    include snippets/ssl-params.conf;
    # ... proxy_pass / passenger / fastcgi_pass ...
}
```

Cert paths stay per-vhost since they're domain-specific — those two lines
are the only TLS-related thing each vhost still writes itself.

`site.sh bootstrap` deploys these two files to `/etc/nginx/snippets/` on
the server. `site.sh pull-nginx` mirrors the server's live `/etc/nginx`
back into this repo's `nginx/` (via `rsync --delete`) so you can `git diff`
and catch drift regardless of what caused it.

## Conventions for per-app deploy scripts

- Site files live at `/var/www/<domain>/`, owned by `deploy`.
- nginx site configs live in each app's own repo (e.g.
  `deploy/server/sites-available/<domain>.conf`), including the two shared
  snippets above, and get copied into `/etc/nginx/sites-available/` by that
  app's own deploy workflow — not managed here.
- Each app also runs certbot itself, in that same deploy workflow, always
  in `--webroot` mode so it never touches its own vhost config:
  `certbot certonly --webroot -w /var/www/certbot -d <domain> -d
  www.<domain> --non-interactive --agree-tos -m <email> --deploy-hook
  "systemctl reload nginx"`. The `--deploy-hook` matters — without it,
  automatic renewals rotate the cert file on disk but nginx keeps serving
  the old one until something reloads it.
- Each app adds its own narrow sudoers rule under `/etc/sudoers.d/<app-name>`,
  scoped to only the exact commands its deploy needs — typically `cp`/`ln -sf`
  for its own nginx site conf, `nginx -t` and `systemctl reload nginx`, and
  the one `certbot certonly --webroot ...` invocation above, scoped to its
  own domain — never anything broader, and never touching another site's
  files.

## Migrating a site to Docker

1. In the app's own repo: containerize it (Dockerfile/compose), point its
   config at the managed database instead of a local db container, and add
   an nginx vhost conf per the pattern above.
2. Here: `./site.sh new <domain> <compose-file> <service> [env-file]` to
   bring up the container and get a stable `HOST_PORT` for the app's vhost
   to `proxy_pass` to.
3. In the app's repo: wire up its deploy workflow (e.g. GitHub Actions) to
   copy its vhost conf in, run the certbot command above, and reload nginx,
   using its own narrow sudoers rule.
4. Once it's confirmed working end to end, retire the old vhost — e.g.
   `./site.sh disable <domain>` (or remove it by hand for a Passenger
   site's `/etc/nginx/sites-enabled` entry, which site.sh doesn't manage).
