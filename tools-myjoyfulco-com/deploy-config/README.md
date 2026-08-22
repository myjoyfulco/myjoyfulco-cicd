# etsy-shop-assistant Deploy Config

## Files

- **deploy.sh** — the redeploy script. Clones the repo fresh, tags and pushes that as-cloned commit as the given `-version` (or checks out an existing tag instead, if `-revert-to` was given — see below), restores the static files below into the clone, builds `.env` from the repo's own `.env` template merged with `deploy.env` then `secret.env`, tears down the running stack, brings up the new one, health-checks it, and (on success, and only for a `-version` deploy) appends an entry to `../release-notes.md`.
- **deploy.env** — non-secret deployment settings sourced by `deploy.sh` (repo URL, branch, Flask/DB deployment overrides, health-check host/port/path/timeouts).
- **secret.env** — the app's actual secret/static `.env` values (API keys, DB credentials, prompt paths, etc.), chmod 600.
- **Dockerfile** — copied into the fresh clone before each build.
- **docker-compose.yml** — copied into the fresh clone before each build; its `db` service mounts `init.sql` from this folder directly (persistent path) rather than from the clone.
- **init.sql** — Postgres init script, mounted by `docker-compose.yml`.
- **nginx-tools-myjoyfulco.conf** — **reference copy only.** `deploy.sh` never reads, copies, or applies it — it's a version-controlled twin of the live host config at `/etc/nginx/sites-available/tools.myjoyfulco.com` (proxies `tools.myjoyfulco.com` to `127.0.0.1:5050`). Confirmed identical to the live file as of this writing; nothing keeps them in sync automatically — edit the live file directly, then copy the change back here by hand (and vice versa), then `nginx -t && systemctl reload nginx` on the host. This is outside `deploy.sh`'s scope entirely.
- **cloudflare-real-ip.conf**, **nginx-reject-unknown-tls.conf** — also reference copies only, same caveat as above. **These two are not actually specific to this app** — on the host they live in `/etc/nginx/conf.d/`, included globally from `nginx.conf`'s `http {}` block, so they apply to *every* site nginx serves (`myjoyfulco.com` included), not just `tools.myjoyfulco.com`. Identical copies of these same two files also live in `myjoyfulco-dot-com/deployment-config/` for the same reason — a deliberate duplication (not a mistake) so each app's deploy-config folder is self-contained, at the cost of needing both copies hand-updated if the live global config ever changes.

## .env construction

The freshly cloned repo's own `.env` (committed template) is the base and the source of truth for which keys exist. `deploy.env` is merged in first, then `secret.env`: for each key in those files, if that key already exists in the repo's `.env`, its value is overwritten; if it doesn't exist there, it's ignored — neither file can introduce a new key. The result is written back into the clone's `.env` in place.

## Instructions

`-version` is optional. When given, it's used both as the git tag created and pushed on the as-cloned commit (before any `.env` values are injected) and as the heading in `../release-notes.md`; the script fails clearly (without touching containers) if that tag already exists. When omitted, you're asked to confirm (`-version not supplied, deployment will run a redeploy Y/n` — Enter or `y` proceeds, `n` aborts before anything happens), and the redeploy runs without creating a tag or recording a release-notes.md entry.

`-revert-to <tagname>` is a rollback/redeploy of an **existing, already-released** version, not a new release — use it instead of `-version` (never together with it — the script rejects that combination outright). Instead of cloning the branch's latest HEAD and cutting a new tag from it, the script checks out the given tag as the deploy target and runs everything else exactly the same: `.env` construction, stack teardown/rebuild, health check, and clone cleanup all behave identically to the `-version` flow. What's skipped: no new tag is created or pushed, there's no `-version`-style confirmation prompt, and nothing is appended to `../release-notes.md` — there's nothing new to tag or log when you're just redeploying something that was already released. If the tag doesn't exist in the repo, the script fails clearly before touching any containers rather than surfacing a raw git error.

To manually run a redeploy with a version tag:

```
ssh myjoyfulco
~/deployment/deploy-config/deploy.sh -version v1.2.3
```

To manually run a redeploy without a version tag:

```
~/deployment/deploy-config/deploy.sh
```

To roll back to an already-released version by redeploying its tag:

```
~/deployment/deploy-config/deploy.sh -revert-to v1.2.3
```

To also wipe the Postgres data volume during the redeploy:

```
~/deployment/deploy-config/deploy.sh -version v1.2.3 --wipe-db
```

To deploy a branch other than the default set in `deploy.env`:

```
DEPLOY_BRANCH=some-branch ~/deployment/deploy-config/deploy.sh -version v1.2.3
```
