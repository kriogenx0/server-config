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
scp scripts/bootstrap.sh admin@104.131.183.186:~
ssh -t admin@104.131.183.186 ./bootstrap.sh
```

or equivalently, `./scripts/site.sh bootstrap` from this repo does the same two
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
./scripts/site.sh bootstrap                                          # ship + run bootstrap.sh as admin
./scripts/site.sh new <domain> <compose-file> <service> [env-file]   # bring up the container + a stable port
./scripts/site.sh redeploy <domain> [service]                         # pull + recreate container
./scripts/site.sh enable <domain>                                     # symlink into sites-enabled + reload
./scripts/site.sh disable <domain>                                    # unlink from sites-enabled + reload
./scripts/site.sh remove <domain> [--stop] [--purge]                  # disable, optionally stop/delete
./scripts/site.sh list                                                # enabled sites, ports, cert expiry
./scripts/site.sh logs <domain> [docker|nginx-access|nginx-error]     # tail logs
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
the server. This repo tracks nothing else from `/etc/nginx` — no stock
nginx files, no per-site configs (those live in each app's own repo, or for
simple sites under `www/<domain>/deploy/`).

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

### Troubleshooting: sudoers path mismatches

`sudo` matches a NOPASSWD rule against the *literal absolute path* it
resolves the command to via `secure_path` — not whatever `command` happens
to resolve to on your interactive shell's `$PATH`, and not whatever path
looked right when the rule was written. Get the path wrong and there's no
error at install time: the command just silently falls through to a
password prompt, which breaks non-interactively the next time `site.sh` or
an app's own `deploy.sh` runs it (e.g. from CI).

This box doesn't have a full usr-merge — `mkdir` and `nginx` resolve under
`/usr/bin`/`/usr/sbin` as expected, but `chown`, `ln`, `rm`, and
`systemctl` actually live in `/bin`. This bit `deploy-site-scripts`
(bootstrap.sh's shared grant) once already; see its comment for the fixed
paths.

Before writing or debugging any sudoers rule:
- Confirm the real path: `ssh deploy@<host> which <cmd>` (or `admin@` for
  an admin-owned grant).
- After installing/changing a grant, verify what's actually live —
  `sudo -l` reads the current file on disk, so this catches both wrong
  paths and a bootstrap run that silently didn't get as far as the
  sudoers block (e.g. an earlier `set -e` failure, like an expired apt
  signing key mid-script):
  `ssh deploy@<host> 'sudo -n -l'` to see every rule, or
  `ssh deploy@<host> "sudo -n <exact command>"` to test one invocation.

## Bringing up a brand-new site with its own CI-driven deploy

This is the pattern `pocketproducer-web` and `magicbox-web` both use: the
app's own `deploy/deploy.sh`, run by its own GitHub Actions workflow, owns
its entire deploy (compose file, container lifecycle, vhost, certbot) —
distinct from "Migrating a site to Docker" below, which assumes an
existing site and uses `site.sh new` interactively from your machine.
Since CI doesn't have this repo checked out, a from-scratch `deploy.sh`
re-implements the small bit of `site.sh new` it needs (picking/persisting
`HOST_PORT`) inline instead of shelling out to it.

1. DNS: point the domain's A record(s) at this host's IP. Nothing else
   here depends on this, but certbot's http-01 challenge will fail without
   it.
2. If `bootstrap.sh` changed since this host was last bootstrapped, apply
   it: `./scripts/site.sh bootstrap` (one interactive `sudo` password prompt).
3. In the app's own repo: `docker-compose.prod.yml`, `deploy/deploy.sh`,
   optionally `deploy/server_setup.sh` (for any server-side secret file
   the app needs that can't be generated automatically, e.g. an app config
   holding a password hash), the nginx vhost + bootstrap-vhost confs, and
   `deploy/server/sudoers.d/<app-name>` — see any of the above repos for
   the concrete pattern, or `pocketproducer-web`'s README for the fuller
   walkthrough.
4. Run the app's own `server_setup.sh` if it has one (creates its
   `/var/www/<domain>` directory via the shared NOPASSWD grant above, no
   sudo password needed — that's the point of the shared grant).
5. Install the app's own sudoers file (interactive, one-time, as `admin`
   — deploy has no sudo to install its own rules):
   ```
   scp deploy/server/sudoers.d/<app-name> admin@<host>:/tmp/
   ssh -t admin@<host> 'sudo visudo -c -f /tmp/<app-name> && sudo install -m 0440 -o root -g root /tmp/<app-name> /etc/sudoers.d/<app-name> && rm /tmp/<app-name>'
   ```
6. Generate a **dedicated** keypair for this app's CI — never reuse your
   own personal key here (grep an existing site's `deploy` account
   `~/.ssh/authorized_keys` and you'll see exactly this: one entry per app,
   named `github-actions-deploy@<app>`, plus one personal key for by-hand
   access):
   ```
   ssh-keygen -t ed25519 -N "" -C "github-actions-deploy@<app-name>" -f /tmp/<app>_deploy_key
   ssh deploy@<host> "echo '$(cat /tmp/<app>_deploy_key.pub)' >> ~/.ssh/authorized_keys"
   gh secret set DEPLOY_SSH_KEY --repo <org>/<repo> < /tmp/<app>_deploy_key
   rm /tmp/<app>_deploy_key /tmp/<app>_deploy_key.pub
   ```
   (`deploy` owns its own home directory, so appending to its own
   `authorized_keys` never needs sudo.)
7. Push to `main` (or run the workflow manually) once, just to get an
   image built and pushed — `deploy.sh` will likely fail at this point if
   step 4's config file still needs secrets filled in by hand (expected).
   Then make the GHCR package public (GitHub package settings, one-time)
   so the server can pull it without extra credentials.
8. Fill in any secrets the seeded server-side config needs (step 4), by
   hand, over SSH.
9. Push again (or re-run the workflow) — this run's `deploy.sh` brings up
   the container, installs the HTTP-only bootstrap vhost, requests the
   cert, and swaps in the full HTTPS vhost.

## Migrating a site to Docker

1. In the app's own repo: containerize it (Dockerfile/compose), point its
   config at the managed database instead of a local db container, and add
   an nginx vhost conf per the pattern above.
2. Here: `./scripts/site.sh new <domain> <compose-file> <service> [env-file]` to
   bring up the container and get a stable `HOST_PORT` for the app's vhost
   to `proxy_pass` to.
3. In the app's repo: wire up its deploy workflow (e.g. GitHub Actions) to
   copy its vhost conf in, run the certbot command above, and reload nginx,
   using its own narrow sudoers rule.
4. Once it's confirmed working end to end, retire the old vhost — e.g.
   `./scripts/site.sh disable <domain>` (or remove it by hand for a Passenger
   site's `/etc/nginx/sites-enabled` entry, which site.sh doesn't manage).

## Layout

```
scripts/bootstrap.sh   host provisioning, run on the server as admin
scripts/site.sh        local ops CLI that SSHes to the server
nginx/snippets/        shared ACME/TLS snippets shipped by bootstrap
www/<domain>/          simple static sites without their own repo
                       (index.html + deploy/ with vhosts, sudoers, deploy.sh)
docs/AGENTS.md         purpose and conventions for this repo
```
