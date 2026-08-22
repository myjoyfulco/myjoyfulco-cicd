# myjoyfulco-dot-com Deploy Config

`deploy.sh` deploys the production MyJoyfulArt website (`myjoyfulco.com`) — a Next.js `site` service plus a companion `editor-api` service, both built from the same image and backed by an external PostgreSQL instance. It is considerably stricter and more defensive than a typical redeploy script: single-instance locking, commit-SHA-pinned images, an automatic rollback if the new deployment fails health checks, and heavy input/environment validation throughout. Read the whole file before changing it — very little here is accidental.

## Files

- **deploy.sh** — the deploy script itself. See "How a deploy runs" below for the full lifecycle.
- **deploy.env** — non-secret deployment settings, merged into the cloned repo's `.env` template (repo URL, branch, service hosts/ports, health-check target/timeouts).
- **secret.env** — the actual secret `.env` values (`SECRET_KEY`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` — exactly these four keys, no more, no fewer). Must be `chmod 600` or the script refuses to run.
- **Dockerfile** — copied into the fresh clone before each build. Multi-stage: installs deps, then in a `validation-build` stage asserts no stray `.env` was committed, runs lint/build/test, then copies the validated `/app` into a clean runtime stage.
- **docker-compose.yml** — copied into the fresh clone before each build. Both services run with `network_mode: host`, are built from the same `myjoyfulco-dot-com:${IMAGE_TAG}` image (tagged by commit SHA, not `latest`), and run as `${RUNTIME_UID}:${RUNTIME_GID}` — the deploying host user's own UID/GID, not root and not a fixed container user.
- **.dockerignore** — copied into the fresh clone before each build; keeps `.env`, `.git`, `node_modules`, and stray planning docs out of the build context.
- **nginx-myjoyfulco.conf**, **nginx-reject-unknown-tls.conf**, **cloudflare-real-ip.conf** — **reference copies only.** `deploy.sh` never reads, copies, or applies these — they exist here purely so the host's actual nginx config (`/etc/nginx/sites-available/myjoyfulco.com`, included from nginx's `http` context together with `cloudflare-real-ip.conf`) has a version-controlled twin to diff against. Confirmed identical to the live host file as of this writing, but nothing keeps them in sync automatically — if you edit the live nginx config, copy the change back here by hand (and vice versa), then `nginx -t && systemctl reload nginx` on the host as usual; that's entirely outside this script.

## How a deploy runs

`main()`: `parse_args` → `confirm_unversioned` → `acquire_lock` → `begin_log` → `preflight` → `deploy_lifecycle`.

1. **Argument parsing** (`parse_args`) — see Instructions below for the two mutually-exclusive modes (`-version` / `-revert-to`), both optional.
2. **Confirmation** (`confirm_unversioned`) — if neither `-version` nor `-revert-to` was given, prompts `-version not supplied, deployment will run a redeploy Y/n` before doing anything else. Enter or `y` proceeds; `n`/anything else aborts.
3. **Locking** (`acquire_lock`) — takes a non-blocking `flock` on `../.deploy.lock` (i.e. `~/deployment/myjoyfulco-dot-com/.deploy.lock`). A second concurrent invocation fails immediately with "another deployment is already running" rather than racing the first. Released automatically on exit (success, failure, or signal) via the `EXIT`/`INT`/`TERM`/`HUP` traps installed by `install_traps`.
4. **Logging** (`begin_log`) — truncates and redirects all of this run's stdout/stderr to `/app/myjoyfulco-dot-com/logs/deploy.log` (via `tee`, so it's still visible live in the terminal too). **This happens on every invocation, including one that fails a moment later in preflight** — the log only ever holds the most recent run, so if you need the output of a specific past deploy, copy it out before running again.
5. **Preflight** (`preflight`) — validates, in order: required files present; `deploy.sh` itself not group/world-writable; required commands (`git`, `docker`, `curl`, `awk`, `flock`, `mktemp`, `date`, `grep`, `sed`, plus `readlink`/`realpath`) available; Docker Compose and the Docker daemon reachable; `secret.env` well-formed (exactly the 4 required keys, correct file mode); `deploy.env` well-formed and complete; this script is actually running from a directory named `deployment-config` (a sanity check against being copied/run from the wrong place); the target branch exists on the remote; **for `-version`, that the tag does *not* already exist remotely; for `-revert-to`, that the tag *does* exist remotely** (both checked via `git ls-remote`, before anything is cloned); the configured Postgres host/port is reachable; and that ports 3000/3030 aren't occupied by some other, non-compose-managed process. Any failure here means nothing has been cloned and no container has been touched yet.
6. **Lifecycle** (`deploy_lifecycle`):
   - `clone_repository` — removes any leftover clone at `../myjoyfulco-dot-com`, clones `$BRANCH` fresh, fetches all tags. For a `-revert-to` deploy, checks out that tag instead of trusting the branch's HEAD, and skips the "checked-out commit matches remote branch HEAD" assertion (which only makes sense for the default flow). The deploy's `IMAGE_TAG` is always the resulting commit SHA. Copies in `Dockerfile`/`.dockerignore`/`docker-compose.yml` from this folder.
   - `merge_environment` — builds `.env` from the repo's own committed `.env` template: every key declared there gets its value from `secret.env` first, then `deploy.env`, falling back to the template's own value if neither overrides it. Written via a `mktemp` + `chmod 600` + atomic `mv`, never in place, so a partially-written `.env` is never observable. Dies if `SECRET_KEY`/`DB_NAME`/`DB_USER`/`DB_PASSWORD` aren't all present and non-empty in the final result.
   - `runtime_compose_vars` — exports `IMAGE_TAG`, `RUNTIME_UID`/`RUNTIME_GID` (the deploying user's own `id -u`/`id -g`), and `COMPOSE_PROJECT_NAME` for `docker compose` to pick up.
   - `compose_validate` — `docker compose config --quiet`, i.e. the compose file must actually parse with these vars before anything is built.
   - `detect_prior_image` — if a `site` container is currently running, records its image ID as `PRIOR_IMAGE_ID` and tags it `myjoyfulco-dot-com:rollback-<epoch>-<pid>` (`ROLLBACK_TAG`) so it can be restored later without depending on the (about-to-be-overwritten) image build succeeding again. A brand-new environment with nothing running yet just skips this — there's nothing to roll back to.
   - `build_image` — `docker compose build --no-cache site` (the `editor-api` service reuses the same image).
   - `initialize_database` — `docker compose run --rm --no-deps editor-api npm run db:init:postgres`.
   - `cutover` — `docker compose stop site editor-api` then `docker compose up -d --no-build site editor-api` on the new image.
   - `poll_local_health` / `public_health` — see Health checks below. **If either fails, `rollback` runs automatically** (see Rollback below) and the deploy is marked failed — the clone is deliberately *not* cleaned up in this case, for diagnostics.
   - `tag_release` — **only when `-version` was given** (a no-op, returning immediately, for both a plain redeploy and a `-revert-to` rollback): tags the deployed commit, pushes that tag, and appends a `../release-notes.md` entry (heading = the version, commit subjects since the previous tag reachable from `HEAD`, in Brisbane local time). If this step itself fails, the already-healthy deployment is *not* rolled back — only the tag/release-notes bookkeeping is left for manual recovery, and the clone + the tagged prior image are retained.
   - On full success: `COMPLETE=1` is set, which is what tells the `EXIT` trap to actually remove the clone (`../myjoyfulco-dot-com`) and delete the tagged rollback image — **this cleanup never runs on any failure path**, so a failed deploy always leaves the clone (and, if it got far enough, the rollback-tagged image) in place for you to inspect.

## Locking, logging, and cleanup — what's preserved on failure vs. success

| Outcome | `../myjoyfulco-dot-com` clone | `myjoyfulco-dot-com:rollback-*` image | `.deploy.lock` | `deploy.log` |
|---|---|---|---|---|
| Success | removed | removed | released | this run's full output |
| Any failure (preflight, build, health, tag/release-notes) | **kept** for debugging | **kept** if it got that far | released | this run's full output |

Because the lock is only ever held for the duration of one `deploy.sh` process (released by the `EXIT` trap no matter how it exits), a failed run never blocks the next attempt — but it does mean a stale clone from a previous failure is silently deleted and replaced (`clone_repository` removes anything already at that path) rather than reused, so don't rely on it surviving between runs for anything other than manual inspection.

## Health checks

Two independent checks, both must pass or `rollback` (below) runs automatically:

- **`poll_local_health`** — polls (every `HEALTH_POLL_INTERVAL` seconds, up to `HEALTH_TIMEOUT_SECONDS`) until: both `site` and `editor-api` compose services report `running`; `http://127.0.0.1:3000/` returns `200` and contains `MyJoyfulArt`; `http://127.0.0.1:3030/api/health` and `/api/ready` both return `200`; and `http://127.0.0.1:3030/api/content` returns `200` with a body whose `"source"` field is `"database"` (i.e. actually reading from Postgres, not falling back to some cached/static content path).
- **`public_health`** — hits the real public site through Cloudflare/nginx, independent of the local checks above: `https://myjoyfulco.com/` must return `200` and contain `MyJoyfulArt`; `https://www.myjoyfulco.com/health-check?preserved=1` must redirect (`301`/`308`) without actually following the redirect; `https://myjoyfulco.com/api/health`'s response headers must include `Cache-Control: ... no-store`; and every same-origin `.js` asset referenced from the homepage is fetched and checked to make sure none of them still points at `http://localhost:3030` (a leftover-dev-config canary).

## Rollback — two different mechanisms, don't confuse them

- **Automatic, deploy-time (`rollback()`)** — fires only when the *deployment that's currently running* fails `poll_local_health`/`public_health` after cutover. Captures diagnostics (compose `ps` + last 80 lines of both services' logs, secrets redacted) to the log, tears the stack down, brings it back up on the previously-tagged `ROLLBACK_TAG` image, re-checks local health, and confirms the running `site` image ID matches what was there before. This is a safety net for *this run only* — it has nothing to do with, and is not triggered by, the `-revert-to` flag described next.
- **Manual, operator-initiated (`-revert-to <tag>`)** — see Instructions below. You choosing to redeploy a specific already-released tag on purpose (e.g. the current `develop` HEAD is broken and you want back on the last known-good release while a fix goes in). This *is* a full deploy in its own right — it goes through preflight, build, DB init, cutover, and both health checks exactly like any other deploy, and if *that* fails health checks, the automatic mechanism above still applies on top of it.

## Instructions

`-version <tag>` and `-revert-to <tag>` are both optional and **mutually exclusive** — passing both fails immediately in argument parsing, before the lock is even acquired.

- **`-version <tag>`** — the normal release flow. Clones the configured branch's latest HEAD, deploys it, and only on a fully successful deploy: tags that commit `<tag>`, pushes the tag, and appends an entry to `../release-notes.md`. Fails clearly (nothing cloned yet) if `<tag>` already exists on the remote.
- **`-revert-to <tag>`** — rollback/redeploy of an **existing, already-released** tag, not a new release. Checks out `<tag>` as the deploy target instead of the branch's latest HEAD. Runs through the exact same build/DB-init/cutover/health-check pipeline as any other deploy. Skips: creating or pushing a new tag, the `-version`-style confirmation prompt, and the `release-notes.md` entry — there's nothing new to tag or log when you're redeploying something that was already released. Fails clearly, before cloning, if `<tag>` doesn't exist on the remote.
- **Neither flag** — an unversioned redeploy of the branch's latest HEAD. You'll be prompted to confirm; no tag is created and nothing is appended to `release-notes.md`.

To manually run a versioned release:

```
ssh myjoyfulco
~/deployment/myjoyfulco-dot-com/deployment-config/deploy.sh -version v1.2.3
```

To manually run an unversioned redeploy of the branch's latest HEAD:

```
~/deployment/myjoyfulco-dot-com/deployment-config/deploy.sh
```

To roll back to an already-released version by redeploying its tag:

```
~/deployment/myjoyfulco-dot-com/deployment-config/deploy.sh -revert-to v1.0.0
```

To deploy a branch other than the default set in `deploy.env`:

```
DEPLOY_BRANCH=some-branch ~/deployment/myjoyfulco-dot-com/deployment-config/deploy.sh -version v1.2.3
```

If a deploy fails, check `/app/myjoyfulco-dot-com/logs/deploy.log` (that run's full output) — the retained clone at `~/deployment/myjoyfulco-dot-com/myjoyfulco-dot-com` and, if the build got that far, the `myjoyfulco-dot-com:rollback-*` image are both left in place for you to inspect before retrying.

## Security/validation notes worth knowing before editing this script

- **`secret.env` is validated strictly**: file mode must match `[0-6]00` (owner-only), and it must contain *exactly* `SECRET_KEY`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` — no more, no fewer. Adding a new secret key means updating `validate_secret_file`'s expected-key list, not just the file.
- **Every secret value is redacted from captured diagnostics** (`redact_line`/`redact_stream`, used by `capture_diagnostics`) — a literal substring match/replace against every value in `secret.env`, run over `compose ps`/`compose logs` output before it's logged. It is not a general-purpose secret scanner — it only redacts the exact values loaded from `secret.env`, not anything else that happens to look sensitive.
- **`.env` is generated by template, never invented**: `merge_environment` only ever fills in values for keys the repo's *own* `.env` template already declares — `deploy.env`/`secret.env` can override, never introduce, a key. Written atomically (`mktemp` in the same directory + `chmod 600` + `mv`), so a reader never sees a partially-written file.
- **`safe_clone_path`/`remove_clone`**: before any `rm -rf` of the clone directory, the script re-derives and re-checks the resolved path — it must resolve to exactly `<base>/myjoyfulco-dot-com`, `<base>` must not be `/` or `$HOME` itself. This exists specifically so a misconfigured `CONFIG_DIR`/`BASE_DIR` (e.g. this script accidentally run from the wrong location) can't turn into a `rm -rf` of something unintended.
- **Containers run as the deploying user, not root**: `RUNTIME_UID`/`RUNTIME_GID` in `docker-compose.yml` are `id -u`/`id -g` of whoever runs `deploy.sh`, not a fixed value — keep that in mind if this is ever run under a different system account, since file ownership inside the bind-mounted `/app/myjoyfulco-dot-com/tmp` (mounted into `editor-api` at `/app/tmp`) will follow whichever account last deployed.
- **`deploy.sh` itself must not be group/world-writable** (`preflight_files` checks its own mode) — if you `chmod` it loosely while editing, the very next run will refuse to start until it's fixed back (e.g. `chmod 750`).
