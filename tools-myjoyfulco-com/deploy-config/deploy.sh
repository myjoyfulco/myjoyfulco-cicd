#!/usr/bin/env bash
#
# Redeploys etsy-shop-assistant from scratch: fresh clone, tagged and pushed
# at the as-cloned commit (if -version is given), static config restored
# from deploy-config/, .env rebuilt from the repo's own .env template merged
# with deploy-config's deploy.env/secret.env overrides, old stack torn down,
# new stack built and health-checked, and (on success, if -version was
# given) a release-notes.md entry appended. Lives in deploy-config/ so it
# survives repeated clone/delete cycles of the app repo itself.
#
# -revert-to <tagname> is a rollback/redeploy of an already-released version
# instead: it checks out that existing tag as the deploy target instead of
# the default branch's latest HEAD, and skips creating a tag, the -version
# requirement, and the release-notes.md entry entirely (there's nothing new
# to tag or log — see the README for the full writeup).
#
# Usage: ./deploy.sh [-version <vX.Y.Z>] [-revert-to <tagname>] [--wipe-db]
#   -version    Tag to create/push for this deploy (e.g. v1.2.3) and the
#               heading used in release-notes.md. Optional — if omitted,
#               you'll be asked to confirm, and the redeploy runs without
#               creating a tag or recording a release-notes.md entry.
#   -revert-to  Roll back to an existing tag instead of deploying the
#               branch's latest HEAD. Mutually exclusive with -version.
#               Fails clearly if the tag doesn't exist in the repo.
#   --wipe-db   ALSO remove the Postgres data volume during undeploy.
#               Never happens unless this flag is passed explicitly.

set -euo pipefail

# ---- paths (derived from this script's own location, not hardcoded) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR"
BASE_DIR="$(cd "$CONFIG_DIR/.." && pwd)"
APP_DIR="$BASE_DIR/etsy-shop-assistant"
RELEASE_NOTES="$BASE_DIR/release-notes.md"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  log "FAILURE: $*"
  log "Leaving $APP_DIR intact for debugging."
  echo
  echo "===================================="
  echo " FAILURE: redeploy did not complete"
  echo "===================================="
  exit 1
}

require_file() {
  if [[ ! -f "$1" ]]; then
    fail "Required file missing: $1"
  fi
}

# Merges KEY=VALUE overrides from $1 into $2 in place: for every key in $1,
# if that key already exists in $2, its value is replaced; keys in $1 with
# no match in $2 are ignored (never adds new keys). Comments/blank lines in
# $2 are left untouched. Uses awk (not sed) so values containing /, &, etc.
# (secrets, URLs) can't corrupt the substitution.
apply_env_overrides() {
  local overrides_file="$1"
  local target_file="$2"
  local tmp_file
  tmp_file="$(mktemp)"
  awk '
    NR==FNR {
      if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) { next }
      idx = index($0, "=")
      if (idx == 0) { next }
      key = substr($0, 1, idx-1)
      val = substr($0, idx+1)
      map[key] = val
      next
    }
    {
      if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) { print; next }
      idx = index($0, "=")
      if (idx == 0) { print; next }
      key = substr($0, 1, idx-1)
      if (key in map) {
        print key "=" map[key]
      } else {
        print
      }
    }
  ' "$overrides_file" "$target_file" > "$tmp_file"
  mv "$tmp_file" "$target_file"
}

# ---- deployment settings (non-secret, edit deploy.env to change these) ----
require_file "$CONFIG_DIR/deploy.env"
set -a
# shellcheck disable=SC1090
source "$CONFIG_DIR/deploy.env"
set +a

# Allow a one-off branch override without editing the file.
BRANCH="${DEPLOY_BRANCH:-$BRANCH}"

HEALTH_URL="http://${HEALTH_HOST}:${HEALTH_PORT}${HEALTH_PATH}"

# ---- argument parsing ----
usage() {
  echo "Usage: $0 [-version <vX.Y.Z>] [-revert-to <tagname>] [--wipe-db]" >&2
}

WIPE_DB=0
VERSION=""
REVERT_TO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wipe-db)
      WIPE_DB=1
      shift
      ;;
    -version)
      if [[ $# -lt 2 ]]; then
        usage
        echo "-version requires a value" >&2
        exit 1
      fi
      VERSION="$2"
      shift 2
      ;;
    -revert-to)
      if [[ $# -lt 2 ]]; then
        usage
        echo "-revert-to requires a value" >&2
        exit 1
      fi
      REVERT_TO="$2"
      shift 2
      ;;
    *)
      usage
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -n "$VERSION" && -n "$REVERT_TO" ]]; then
  usage
  echo "-version and -revert-to are mutually exclusive — -version cuts a new release, -revert-to rolls back to an existing one. Pass only one." >&2
  exit 1
fi

if [[ -z "$VERSION" && -z "$REVERT_TO" ]]; then
  read -r -p "-version not supplied, deployment will run a redeploy Y/n " CONFIRM
  case "$CONFIRM" in
    [Nn]*)
      echo "Aborted." >&2
      exit 1
      ;;
  esac
fi

log "Starting redeploy (branch=$BRANCH, version=${VERSION:-none}, revert-to=${REVERT_TO:-none}, wipe-db=$WIPE_DB)"

require_file "$CONFIG_DIR/Dockerfile"
require_file "$CONFIG_DIR/docker-compose.yml"
require_file "$CONFIG_DIR/init.sql"
require_file "$CONFIG_DIR/secret.env"

# ---- 1. Pull the repo fresh ----
log "Step 1/7: preparing clean clone at $APP_DIR"
if [[ -d "$APP_DIR" ]]; then
  log "Removing leftover folder from a previous run"
  rm -rf "$APP_DIR"
fi

log "Cloning $REPO_URL (branch $BRANCH)"
git clone --branch "$BRANCH" --single-branch "$REPO_URL" "$APP_DIR"

# --single-branch skips tags outside that branch's history by default;
# fetch every tag explicitly so the checks below see the repo's full state.
# This also pulls in the commit objects for a -revert-to rollback target
# that isn't reachable from $BRANCH at all.
log "Fetching all tags from origin"
git -C "$APP_DIR" fetch --tags origin

# ---- 2. Tag+push a new release, or check out an existing tag to roll back to ----
if [[ -n "$VERSION" ]]; then
  log "Step 2/7: tagging and pushing $VERSION"

  if git -C "$APP_DIR" rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
    fail "Tag $VERSION already exists on origin — refusing to overwrite. Choose a different -version."
  fi

  LAST_TAG="$(git -C "$APP_DIR" for-each-ref --sort=-creatordate --format='%(refname:short)' refs/tags | head -n1)"
  if [[ -n "$LAST_TAG" ]]; then
    log "Last created tag: $LAST_TAG"
    COMMIT_LIST="$(git -C "$APP_DIR" log "${LAST_TAG}..HEAD" --pretty=format:'%s')"
  else
    log "No prior tag found — release notes will include the full commit history"
    COMMIT_LIST="$(git -C "$APP_DIR" log --pretty=format:'%s')"
  fi

  git -C "$APP_DIR" tag "$VERSION"
  if ! git -C "$APP_DIR" push origin "refs/tags/$VERSION"; then
    fail "Failed to push tag $VERSION to origin (local tag was created but not pushed — investigate, then push or delete it manually before retrying)"
  fi
  log "Tag $VERSION created and pushed"
elif [[ -n "$REVERT_TO" ]]; then
  log "Step 2/7: rolling back to existing tag $REVERT_TO"

  if ! git -C "$APP_DIR" rev-parse -q --verify "refs/tags/$REVERT_TO" >/dev/null; then
    fail "Tag $REVERT_TO does not exist in this repo — refusing to deploy. Check the tag name (git tag -l on the repo) and try again."
  fi

  git -C "$APP_DIR" checkout --quiet "refs/tags/$REVERT_TO"
  log "Checked out tag $REVERT_TO ($(git -C "$APP_DIR" rev-parse --short HEAD))"
else
  log "Step 2/7: skipped (-version not supplied) — no tag will be created or pushed"
fi

# ---- 3. Copy in the static files ----
log "Step 3/7: copying Dockerfile, docker-compose.yml, init.sql from deploy-config"
cp "$CONFIG_DIR/Dockerfile" "$APP_DIR/Dockerfile"
cp "$CONFIG_DIR/docker-compose.yml" "$APP_DIR/docker-compose.yml"
cp "$CONFIG_DIR/init.sql" "$APP_DIR/init.sql"

# ---- 4. Build the .env for this deployment ----
log "Step 4/7: building .env (repo .env as base; secret values never printed)"
ENV_OUT="$APP_DIR/.env"
require_file "$ENV_OUT"

# The repo's own .env (committed template) is the source of truth for which
# keys exist. deploy.env and secret.env only ever overwrite values for keys
# already present there — neither can introduce a new key.
apply_env_overrides "$CONFIG_DIR/deploy.env" "$ENV_OUT"
apply_env_overrides "$CONFIG_DIR/secret.env" "$ENV_OUT"

chmod 600 "$ENV_OUT"
log ".env written ($(wc -l < "$ENV_OUT") lines, not shown)"

# ---- 5. Undeploy the current running stack ----
log "Step 5/7: bringing down the currently running stack (if any)"
pushd "$APP_DIR" >/dev/null
if [[ "$WIPE_DB" -eq 1 ]]; then
  log "WARNING: --wipe-db passed, removing DB volume as well"
  docker compose down -v
else
  docker compose down
fi
popd >/dev/null

# ---- 6. Deploy ----
log "Step 6/7: building and starting the new stack"
pushd "$APP_DIR" >/dev/null
docker compose up -d --build
popd >/dev/null

# ---- 7. Test the connection ----
log "Step 7/7: waiting for the stack to come up and verifying health"
sleep 5

pushd "$APP_DIR" >/dev/null
COMPOSE_PS_OUTPUT="$(docker compose ps)"
popd >/dev/null
echo "$COMPOSE_PS_OUTPUT"

APP_UP=false
DB_UP=false
if echo "$COMPOSE_PS_OUTPUT" | grep -qE '^etsy-shop-assistant-app-1.*Up'; then
  APP_UP=true
fi
if echo "$COMPOSE_PS_OUTPUT" | grep -qE '^etsy-shop-assistant-db-1.*Up'; then
  DB_UP=true
fi

if [[ "$APP_UP" != true || "$DB_UP" != true ]]; then
  fail "One or both containers are not Up (app=$APP_UP, db=$DB_UP)"
fi
log "Both containers are Up"

log "Polling $HEALTH_URL (up to ${HEALTH_TIMEOUT_SECONDS}s)"
elapsed=0
HEALTH_OK=false
while [[ "$elapsed" -lt "$HEALTH_TIMEOUT_SECONDS" ]]; do
  if curl -sf -o /dev/null "$HEALTH_URL"; then
    HEALTH_OK=true
    break
  fi
  sleep "$HEALTH_POLL_INTERVAL"
  elapsed=$((elapsed + HEALTH_POLL_INTERVAL))
done

if [[ "$HEALTH_OK" != true ]]; then
  fail "Health check against $HEALTH_URL did not succeed within ${HEALTH_TIMEOUT_SECONDS}s"
fi
log "Health check passed ($HEALTH_URL)"

# ---- Release notes, only on confirmed success and only when -version was given ----
if [[ -n "$VERSION" ]]; then
  log "Recording release notes entry for $VERSION"
  {
    echo "# $VERSION"
    echo
    echo "## $(date '+%d %b %Y')"
    echo
    echo "### What's Included"
    if [[ -n "$COMMIT_LIST" ]]; then
      while IFS= read -r subject; do
        echo "- $subject"
      done <<< "$COMMIT_LIST"
    else
      echo "- (no new commits since $LAST_TAG)"
    fi
    echo
  } >> "$RELEASE_NOTES"
elif [[ -n "$REVERT_TO" ]]; then
  log "Skipping release notes entry (rollback via -revert-to $REVERT_TO — nothing new to log)"
else
  log "Skipping release notes entry (-version not supplied)"
fi

# ---- Cleanup of the cloned folder on success ----
log "Step 8/8: cleaning up cloned folder"
rm -rf "$APP_DIR"

echo
echo "===================================="
if [[ -n "$VERSION" ]]; then
  echo " SUCCESS: redeploy completed ($VERSION)"
elif [[ -n "$REVERT_TO" ]]; then
  echo " SUCCESS: redeploy completed (rollback to tag $REVERT_TO)"
else
  echo " SUCCESS: redeploy completed (no version tag)"
fi
echo "===================================="
