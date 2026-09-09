#!/usr/bin/env bash
#
# One-time, idempotent database bootstrap for fewcoco-core. Run manually,
# once, BEFORE the first deploy.sh run against a given database — and again
# any time fewcoco_core_db needs to be rebuilt from scratch (e.g. it was
# dropped, as production's was on 2026-09-06 — see
# doc/db-migration-plan.md).
#
# deploy.sh does NOT call this. create_app() runs run_migrations() at
# container startup, but yoyo cannot create the database or role itself —
# skip this step and the container crash-loops on first boot.
#
# What this does, against v1's existing Postgres container
# ($V1_DB_CONTAINER, e.g. etsy-shop-assistant-db-1):
#   1. CREATE DATABASE fewcoco_core_db, if it doesn't already exist.
#   2. CREATE ROLE fewcoco_app (or ALTER ROLE if it already exists, e.g.
#      left over from a prior bootstrap) with the password from secret.env,
#      and grant it ownership of the database plus its public schema (the
#      schema grant matters on Postgres 15+, which postgres:16-alpine is).
#   3. Bring the stack up so run_migrations() builds the schema (0001
#      through the latest — 0007_published_drafts.sql is absent from
#      migrations/ by design, Phase 1.5's archive retirement, nothing to
#      skip here).
#   4. Run scripts/copy_v1_data.py inside the api container (which already
#      bundles psycopg2 and the script itself) to copy users, invite_codes,
#      and etsy_oauth_tokens from v1's user_account database. Read-only
#      against v1; safe to re-run at any time to pick up new v1 rows (e.g.
#      a final refresh at decommission).
#
# Usage: ./bootstrap-db.sh [--data-only]
#   --data-only   Skip steps 1-3 (database/role/stack), just (re-)run the
#                 v1 data copy against an already-running stack.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR"
BASE_DIR="$(cd "$CONFIG_DIR/.." && pwd)"
APP_DIR="$BASE_DIR/fewcoco-core"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  log "FAILURE: $*"
  exit 1
}

require_file() {
  if [[ ! -f "$1" ]]; then
    fail "Required file missing: $1"
  fi
}

DATA_ONLY=0
if [[ "${1:-}" == "--data-only" ]]; then
  DATA_ONLY=1
fi

require_file "$CONFIG_DIR/deploy.env"
require_file "$CONFIG_DIR/secret.env"
set -a
# shellcheck disable=SC1090
source "$CONFIG_DIR/deploy.env"
# shellcheck disable=SC1090
source "$CONFIG_DIR/secret.env"
set +a

: "${DB_SUPERUSER:?deploy.env must set DB_SUPERUSER}"
: "${V1_DB_NAME:?deploy.env must set V1_DB_NAME}"
: "${V1_DB_CONTAINER:?deploy.env must set V1_DB_CONTAINER}"
: "${DB_NAME:?secret.env must set DB_NAME}"
: "${DB_USER:?secret.env must set DB_USER}"
: "${DB_PASSWORD:?secret.env must set DB_PASSWORD}"

if [[ "$DATA_ONLY" -eq 0 ]]; then
  # psql defaults to a database named after the connecting user when none is
  # given with -d — dbadmin has no such database of its own, so every
  # maintenance-level call below (CREATE DATABASE, CREATE ROLE, and the
  # pg_database/pg_roles lookups, none of which are scoped to one database
  # anyway) explicitly targets -d "$V1_DB_NAME" (user_account, which does
  # exist) purely as a connection target.
  log "Step 1/4: ensuring database $DB_NAME exists on $V1_DB_CONTAINER"
  DB_EXISTS="$(docker exec "$V1_DB_CONTAINER" psql -U "$DB_SUPERUSER" -d "$V1_DB_NAME" -tAc \
    "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")"
  if [[ "$DB_EXISTS" == "1" ]]; then
    log "Database $DB_NAME already exists — leaving it as-is"
  else
    docker exec "$V1_DB_CONTAINER" psql -U "$DB_SUPERUSER" -d "$V1_DB_NAME" -c "CREATE DATABASE $DB_NAME;"
    log "Created database $DB_NAME"
  fi

  log "Step 2/4: ensuring role $DB_USER exists with the configured password"
  ROLE_EXISTS="$(docker exec "$V1_DB_CONTAINER" psql -U "$DB_SUPERUSER" -d "$V1_DB_NAME" -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'")"
  if [[ "$ROLE_EXISTS" == "1" ]]; then
    log "Role $DB_USER already exists — resetting its password to match secret.env"
    docker exec "$V1_DB_CONTAINER" psql -U "$DB_SUPERUSER" -d "$V1_DB_NAME" -c \
      "ALTER ROLE $DB_USER WITH LOGIN PASSWORD '$DB_PASSWORD';"
  else
    docker exec "$V1_DB_CONTAINER" psql -U "$DB_SUPERUSER" -d "$V1_DB_NAME" -c \
      "CREATE ROLE $DB_USER WITH LOGIN PASSWORD '$DB_PASSWORD';"
    log "Created role $DB_USER"
  fi

  docker exec "$V1_DB_CONTAINER" psql -U "$DB_SUPERUSER" -d "$V1_DB_NAME" -c \
    "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;"
  docker exec "$V1_DB_CONTAINER" psql -U "$DB_SUPERUSER" -d "$DB_NAME" -c \
    "GRANT ALL ON SCHEMA public TO $DB_USER;"
  log "Granted $DB_USER full privileges on $DB_NAME (database + public schema)"

  log "Step 3/4: bringing up the stack so run_migrations() builds the schema"
  log "(this expects deploy.sh to have already been run at least once to build the .env/image — if it hasn't, run deploy.sh first, then re-run this script with --data-only)"
  if [[ ! -f "$APP_DIR/docker-compose.yml" ]]; then
    fail "$APP_DIR/docker-compose.yml not found — run deploy.sh first to create the initial deployment, then re-run this script with --data-only for the data copy."
  fi
  pushd "$APP_DIR" >/dev/null
  docker compose up -d
  popd >/dev/null

  log "Waiting for migrations to apply"
  sleep 8
  docker logs fewcoco-core-api-1 --tail 50
else
  log "Steps 1-3 skipped (--data-only)"
fi

: "${V1_DB_PASSWORD:?secret.env must set V1_DB_PASSWORD, the v1 DB_PASSWORD value for the DB_SUPERUSER account that owns user_account}"

log "Step 4/4: copying users/invite_codes/etsy_oauth_tokens from v1's $V1_DB_NAME"
docker exec fewcoco-core-api-1 python scripts/copy_v1_data.py \
  "postgresql://$DB_SUPERUSER:$V1_DB_PASSWORD@db:5432/$V1_DB_NAME?sslmode=disable" \
  "postgresql://$DB_USER:$DB_PASSWORD@db:5432/$DB_NAME?sslmode=disable"

log "Bootstrap complete."
echo
echo "Verify with, e.g.:"
echo "  docker exec $V1_DB_CONTAINER psql -U $DB_SUPERUSER -d $DB_NAME -c '\\dt'"
echo "  docker exec $V1_DB_CONTAINER psql -U $DB_SUPERUSER -d $DB_NAME -c 'SELECT count(*) FROM users;'"
