# etsy-shop-assistant Deploy Config

## Files

- **deploy.sh** — the redeploy script. Clones the repo fresh, tags and pushes that as-cloned commit as the given `-version`, restores the static files below into the clone, builds `.env` from the repo's own `.env` template merged with `deploy.env` then `secret.env`, tears down the running stack, brings up the new one, health-checks it, and (on success) appends an entry to `../release-notes.md`.
- **deploy.env** — non-secret deployment settings sourced by `deploy.sh` (repo URL, branch, Flask/DB deployment overrides, health-check host/port/path/timeouts).
- **secret.env** — the app's actual secret/static `.env` values (API keys, DB credentials, prompt paths, etc.), chmod 600.
- **Dockerfile** — copied into the fresh clone before each build.
- **docker-compose.yml** — copied into the fresh clone before each build; its `db` service mounts `init.sql` from this folder directly (persistent path) rather than from the clone.
- **init.sql** — Postgres init script, mounted by `docker-compose.yml`.

## .env construction

The freshly cloned repo's own `.env` (committed template) is the base and the source of truth for which keys exist. `deploy.env` is merged in first, then `secret.env`: for each key in those files, if that key already exists in the repo's `.env`, its value is overwritten; if it doesn't exist there, it's ignored — neither file can introduce a new key. The result is written back into the clone's `.env` in place.

## Instructions

`-version` is optional. When given, it's used both as the git tag created and pushed on the as-cloned commit (before any `.env` values are injected) and as the heading in `../release-notes.md`; the script fails clearly (without touching containers) if that tag already exists. When omitted, you're asked to confirm (`-version not supplied, deployment will run a redeploy Y/n` — Enter or `y` proceeds, `n` aborts before anything happens), and the redeploy runs without creating a tag or recording a release-notes.md entry.

To manually run a redeploy with a version tag:

```
ssh myjoyfulco
~/deployment/deploy-config/deploy.sh -version v1.2.3
```

To manually run a redeploy without a version tag:

```
~/deployment/deploy-config/deploy.sh
```

To also wipe the Postgres data volume during the redeploy:

```
~/deployment/deploy-config/deploy.sh -version v1.2.3 --wipe-db
```

To deploy a branch other than the default set in `deploy.env`:

```
DEPLOY_BRANCH=some-branch ~/deployment/deploy-config/deploy.sh -version v1.2.3
```
