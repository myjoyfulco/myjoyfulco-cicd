# fewcoco-core Deploy Config

`fewcoco-core` is the v2 REST API for the Etsy listing-drafting tool, running alongside the v1
monolith (`tools-myjoyfulco-com/`, this same repo) on `tools.myjoyfulco.com` for a bounded
coexistence period — see `fewcoco-core`'s own `doc/fewcoco-core.md`. It serves
`/etsy-shop-assistant/api/v2/*`; v1 keeps serving everything else. This folder is modeled
directly on `../tools-myjoyfulco-com/deploy-config/` — read that one too if something here is
unclear, most of the mechanics are identical.

## Files

- **deploy.sh** — the redeploy script. Clones the repo fresh, tags and pushes that as-cloned
  commit as the given `-version` (or checks out an existing tag instead, if `-revert-to` was
  given), restores the static files below into the clone, builds `.env` from the repo's own
  `.env.example` template merged with `deploy.env` then `secret.env`, tears down the running
  stack, brings up the new one, health-checks it, and (on success, only for a `-version` deploy)
  appends an entry to `../release-notes.md`.
- **deploy.env** — non-secret deployment settings sourced by `deploy.sh` and `bootstrap-db.sh`
  (repo URL, branch, DB deployment overrides, v1's db container name, health-check
  host/port/path/timeouts).
- **secret.env** — the app's actual secret/static `.env` values (DB credentials, API keys, JWT
  signing key), chmod 600, gitignored. **Not present in a fresh clone of this repo** — copy
  `secret.env.template` to `secret.env` and fill it in on the server directly; see that file's
  own comments for where each value comes from.
- **Dockerfile** — copied into the fresh clone before each build.
- **docker-compose.yml** — copied into the fresh clone before each build. One service (`api`)
  only — see "Database" below for why there's no `db` service here.
- **bootstrap-db.sh** — one-time database/role setup plus the v1 data copy. Not called by
  `deploy.sh`. See "Database" below.
- **nginx-tools-myjoyfulco.conf** — **reference copy only**, same file
  `../tools-myjoyfulco-com/deploy-config/` also carries a copy of (both v1's `location /` and
  v2's `/etsy-shop-assistant/api/v2/` locations live in the one server block for
  `tools.myjoyfulco.com`, since both services share the same host and port 443/80). `deploy.sh`
  never reads or applies it — it's a version-controlled twin of the live host config at
  `/etc/nginx/sites-available/tools.myjoyfulco.com`. Edit the live file directly, copy the
  change back here by hand (and vice versa), then `nginx -t && systemctl reload nginx`.
- **cloudflare-real-ip.conf**, **nginx-reject-unknown-tls.conf** — reference copies, not specific
  to this app (they live in `/etc/nginx/conf.d/`, included globally). Duplicated here and in
  `myjoyfulco-dot-com/deployment-config/` and `tools-myjoyfulco-com/deploy-config/` on purpose,
  same reasoning as those folders: each app's deploy-config stays self-contained.

## Database

`fewcoco_core_db` is **not** a dedicated Postgres container — it's a second database inside
v1's own Postgres container (`etsy-shop-assistant-db-1`), per the project's Phase 1.6 decision
(one Postgres process to operate). Consequences:

- **No `db` service in `docker-compose.yml`.** The `api` service instead joins v1's compose
  network, `etsy-shop-assistant_default`, declared as `external: true`. That network already
  carries the `db` alias for v1's Postgres container, so `deploy.env`'s `DB_HOST=db` resolves
  correctly from inside the `api` container.
- **v1's stack must be up before this one can start.** If `etsy-shop-assistant_default` doesn't
  exist yet (v1 has never been brought up), `docker compose up` fails clearly on the missing
  network. v1's own `docker compose down` also won't remove that network while this stack is
  attached to it.
- **`bootstrap-db.sh` creates the database and role, and copies v1's data — run this once,
  manually, before the first `deploy.sh` run ever executed against a given Postgres instance**
  (and again any time `fewcoco_core_db` needs rebuilding from scratch — see
  `doc/db-migration-plan.md`'s "part 2", production's copy was dropped there on 2026-09-06):
  ```
  ./bootstrap-db.sh
  ```
  It expects `docker-compose.yml` already staged in `../fewcoco-core/` (i.e. `deploy.sh` run at
  least once already, even if the container then fails its health check because the database
  doesn't exist yet — that ordering is fine, this script brings the stack up itself). Re-run
  with `--data-only` any time later to just refresh the v1 data copy (safe, idempotent,
  read-only against v1) — e.g. one final incremental refresh at v1 decommission, per
  `doc/fewcoco-core.md`'s "Etsy OAuth during coexistence" section.
- **`--wipe-db` is not offered by `deploy.sh`** — there's no volume here for it to remove.
  Dropping/rebuilding `fewcoco_core_db` itself is `bootstrap-db.sh`'s job, run by hand.

## `.env` construction

Unlike v1 (which commits a `.env` template directly), `fewcoco-core` gitignores `.env` and
tracks only `.env.example`. `deploy.sh` copies `.env.example` to `.env` in the fresh clone as
its base, then merges in `deploy.env`, then `secret.env`: for each key in those files, if that
key already exists in `.env` (i.e. it exists in `.env.example`), its value is overwritten; if it
doesn't exist there, it's ignored — neither file can introduce a new key. `V1_DB_PASSWORD` in
`secret.env` is a deliberate exception — it's not an app config key, `bootstrap-db.sh` reads it
directly and `deploy.sh`'s merge simply ignores it since it isn't in `.env.example`.

## Instructions

`-version` is optional. When given, it's used both as the git tag created and pushed on the
as-cloned commit (before any `.env` values are injected) and as the heading in
`../release-notes.md`; the script fails clearly (without touching containers) if that tag
already exists. When omitted, you're asked to confirm (`-version not supplied, deployment will
run a redeploy Y/n` — Enter or `y` proceeds, `n` aborts before anything happens), and the
redeploy runs without creating a tag or recording a release-notes.md entry.

`-revert-to <tagname>` is a rollback/redeploy of an **existing, already-released** version, not
a new release — use it instead of `-version` (never together with it). Everything else —
`.env` construction, stack teardown/rebuild, health check, clone cleanup — behaves identically
to the `-version` flow; skipped: tag creation/push, the `-version`-style confirmation prompt,
and the `release-notes.md` entry.

To manually run a redeploy with a version tag:

```
ssh myjoyfulco
~/deployment/fewcoco-core/deploy-config/deploy.sh -version v0.1.0
```

To manually run a redeploy without a version tag:

```
~/deployment/fewcoco-core/deploy-config/deploy.sh
```

To roll back to an already-released version by redeploying its tag:

```
~/deployment/fewcoco-core/deploy-config/deploy.sh -revert-to v0.1.0
```

To deploy a branch other than the default set in `deploy.env`:

```
DEPLOY_BRANCH=some-branch ~/deployment/fewcoco-core/deploy-config/deploy.sh -version v0.1.0
```

## Coexistence flags

`deploy.env` sets `ETSY_DRY_RUN=false` (v2 answers real Etsy calls on request) but
`ETSY_PUBLISH_SCHEDULER_ENABLED=false` and `ETSY_OAUTH_ENABLED=false` — v1 keeps owning the
publish-scheduler timer and `/oauth/*` for the entire coexistence period (see
`doc/fewcoco-core.md`'s "Etsy OAuth during coexistence"). Flip both to `true`/removed only at
v1 decommission, alongside that document's Phase 3 OAuth cutover.

## Host volume directories

Create these once before the first deploy (owned by the deploy user, matching how
`/app/etsy-shop-assistant/` was set up for v1):

```
sudo mkdir -p /app/fewcoco-core/{logs,staged_uploads,templates/static,templates/prompts/users}
sudo chown -R dad-mojx:dad-mojx /app/fewcoco-core
```
