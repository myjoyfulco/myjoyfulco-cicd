#!/usr/bin/env bash
# Deploy fewcoco-web from Git. The reverse proxy is intentionally out of scope.
# Usage: deploy.sh [--force] [--ref <branch-or-sha>] [--no-push]

set -Eeuo pipefail

DEPLOY_ROOT=${DEPLOY_ROOT:-/srv/data/deployments/fewcoco-web}
DEPLOY_DIR=$DEPLOY_ROOT/deployment
PROPERTIES_DIR=$DEPLOY_ROOT/properties
PV_DIR=$DEPLOY_ROOT/pv
APP_DIR=/srv/data/app/fewcoco-web
BUILD_CACHE=$PV_DIR/buildcache
TMP_DIR=$PV_DIR/tmp
REPO=git@github.com-fewcoco-web:myjoyfulco/fewcoco-web.git
IMAGE_NAME=fewcoco-web
CONTAINER_NAME=fewcoco-web
BUILDER_NAME=fewcoco-web-deployer
COMPOSE_FILE=$DEPLOY_DIR/docker-compose.yml
CONFIG_ENV=$PROPERTIES_DIR/config.env
SECRET_ENV=$PROPERTIES_DIR/secret.env
ENV_EXAMPLE=${ENV_EXAMPLE:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env.example"}
SYNC_STATE=$DEPLOY_DIR/.last-synchronized-commit
REF=develop
FORCE=0
PUSH=1
KEEP_IMAGES=5
SRC=
PREVIOUS_IMAGE=
DEPLOY_ATTEMPTED=0
VALIDATE_PROPERTIES=0

SYNC_FILES=(Dockerfile README.md deploy.sh docker-compose.yml config.env.example secret.env.example)

log() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

usage() {
  printf 'Usage: %s [--force] [--ref <branch-or-sha>] [--no-push] [--validate-properties]\n' "${0##*/}"
}

while (($#)); do
  case "$1" in
    --force) FORCE=1; shift ;;
    --no-push) PUSH=0; shift ;;
    --validate-properties) VALIDATE_PROPERTIES=1; shift ;;
    --ref)
      (($# >= 2)) || die '--ref requires a value'
      REF=$2
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ $status -ne 0 ]]; then
    rollback
  fi
  if [[ -n "$SRC" && -d "$SRC" ]]; then
    rm -rf -- "$SRC"
    info "removed temporary checkout $SRC"
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

env_value() {
  local key=$1
  awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$CONFIG_ENV"
}

compose() {
  IMAGE="$1" docker compose --env-file "$CONFIG_ENV" --env-file "$SECRET_ENV" -f "$COMPOSE_FILE" "${@:2}"
}

rollback() {
  [[ $DEPLOY_ATTEMPTED -eq 1 ]] || return 0
  DEPLOY_ATTEMPTED=0
  if [[ -n "$PREVIOUS_IMAGE" ]]; then
    log "Rolling back to $PREVIOUS_IMAGE"
    compose "$PREVIOUS_IMAGE" up -d --remove-orphans || true
  else
    log 'No prior image exists; removing the failed container'
    IMAGE="$IMAGE_REF" docker compose --env-file "$CONFIG_ENV" --env-file "$SECRET_ENV" -f "$COMPOSE_FILE" down || true
  fi
}

on_error() {
  local status=$?
  local line=$1
  trap - ERR
  rollback
  printf '\nFAILED: deployment stopped at line %s (exit %s)\n' "$line" "$status" >&2
  exit "$status"
}
trap 'on_error $LINENO' ERR

validate_config_env() {
  [[ -f "$CONFIG_ENV" ]] || die "$CONFIG_ENV is missing; copy config.env.example"

  local line key value
  declare -A seen=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "$CONFIG_ENV contains an invalid line"
    key=${line%%=*}
    value=${line#*=}
    [[ -z "${seen[$key]:-}" ]] || die "$CONFIG_ENV defines $key more than once"
    seen[$key]=1
    case "$key" in
      BIND_IP|HOST_PORT) ;;
      IMAGE_ALLOWED_HOSTS)
        [[ "$value" =~ ^https?://[^[:space:]/?#]+(:[0-9]+)?([[:space:]]+https?://[^[:space:]/?#]+(:[0-9]+)?)*$ ]] || die 'IMAGE_ALLOWED_HOSTS must be a space-separated list of http or https origins'
        ;;
      VITE_*)
        grep -q "^${key}=" "$ENV_EXAMPLE" || die "$key is not declared in .env.example"
        [[ ! "$key" =~ (SECRET|TOKEN|PASSWORD|PASS|KEY|CREDENTIAL|USERNAME) ]] || die "$key looks credential-bearing and cannot enter a browser bundle"
        [[ "$value" == /* && "$value" != //* && "$value" != *://* ]] || die "$key must be a same-origin absolute path"
        ;;
      *) die "$CONFIG_ENV contains unsupported key: $key" ;;
    esac
  done < "$CONFIG_ENV"

  local bind_ip host_port
  bind_ip=$(env_value BIND_IP) || die 'BIND_IP is required'
  host_port=$(env_value HOST_PORT) || die 'HOST_PORT is required'
  [[ "$bind_ip" == 127.0.0.1 ]] || die 'BIND_IP must be 127.0.0.1'
  [[ "$host_port" =~ ^[0-9]+$ ]] && ((host_port >= 1 && host_port <= 65535)) || die 'HOST_PORT must be an integer from 1 through 65535'
}

validate_secret_env() {
  [[ -f "$SECRET_ENV" ]] || die "$SECRET_ENV is missing; create an empty file and set mode 0600"
  [[ "$(stat -c '%a' "$SECRET_ENV")" == 600 ]] || die "$SECRET_ENV must have mode 0600"

  local line key
  declare -A seen=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "$SECRET_ENV contains an invalid line"
    key=${line%%=*}
    [[ -z "${seen[$key]:-}" ]] || die "$SECRET_ENV defines $key more than once"
    seen[$key]=1
    die "$SECRET_ENV contains unsupported key: $key"
  done < "$SECRET_ENV"
}

validate_properties() {
  [[ -d "$PROPERTIES_DIR" ]] || die "$PROPERTIES_DIR is missing"

  local property_file
  while IFS= read -r property_file; do
    case "$property_file" in
      config.env|secret.env) ;;
      *) die "properties/ accepts only config.env and secret.env as operator input" ;;
    esac
  done < <(find "$PROPERTIES_DIR" -maxdepth 1 -type f -printf '%f\n' | sort)

  validate_config_env
  validate_secret_env
}

render_app_env() {
  local destination=$1 key value temporary
  cp "$SRC/.env.example" "$destination"
  temporary=${destination}.tmp
  while IFS='=' read -r key value; do
    [[ "$key" == VITE_* ]] || continue
    awk -F= -v key="$key" -v value="$value" 'BEGIN { OFS="=" } $1 == key { print key, value; next } { print }' "$destination" > "$temporary"
    mv "$temporary" "$destination"
  done < "$CONFIG_ENV"
  chmod 600 "$destination"
}

sync_deployment_files() {
  local last_sync file server_file repo_file base_file server_changed repo_changed
  last_sync=$(cat "$SYNC_STATE" 2>/dev/null || true)
  if [[ -n "$last_sync" ]] && ! git -C "$SRC" cat-file -e "$last_sync^{commit}" 2>/dev/null; then
    git -C "$SRC" fetch --quiet origin "$last_sync" || die "cannot fetch last synchronized commit $last_sync"
  fi

  for file in "${SYNC_FILES[@]}"; do
    server_file=$DEPLOY_DIR/$file
    repo_file=$SRC/deployment/$file
    [[ -f "$server_file" ]] || die "server-authoritative file is missing: $server_file"

    if [[ -n "$last_sync" ]] && git -C "$SRC" cat-file -e "$last_sync:deployment/$file" 2>/dev/null; then
      base_file=$(mktemp "$TMP_DIR/sync-base.XXXXXXXX")
      git -C "$SRC" show "$last_sync:deployment/$file" > "$base_file"
      server_changed=0
      repo_changed=0
      cmp -s "$server_file" "$base_file" || server_changed=1
      cmp -s "$repo_file" "$base_file" || repo_changed=1
      if [[ $server_changed -eq 1 && $repo_changed -eq 1 ]] && ! cmp -s "$server_file" "$repo_file"; then
        rm -f -- "$base_file"
        die "deployment/$file changed both on the server and in Git since $last_sync"
      fi
      rm -f -- "$base_file"
    elif [[ -n "$last_sync" && $FORCE -eq 0 ]]; then
      die "deployment/$file was absent at last synchronization; use --force after reviewing the server copy"
    fi
    cp "$server_file" "$repo_file"
  done

  git -C "$SRC" add -- "${SYNC_FILES[@]/#/deployment/}"
  local staged
  staged=$(git -C "$SRC" diff --cached --name-only)
  if [[ -n "$staged" ]]; then
    while IFS= read -r file; do
      case " deployment/Dockerfile deployment/README.md deployment/deploy.sh deployment/docker-compose.yml deployment/config.env.example deployment/secret.env.example " in
        *" $file "*) ;;
        *) die "refusing to commit non-allowlisted file: $file" ;;
      esac
    done <<< "$staged"
    git -C "$SRC" -c user.name='fewcoco-web deploy' -c user.email='deploy@fewcoco-web' \
      commit --quiet -m "deployment: synchronize server configuration"
    info 'committed server-authoritative deployment changes'
  fi

  if [[ $PUSH -eq 1 ]]; then
    git check-ref-format --branch "$REF" >/dev/null 2>&1 || die '--ref must name a branch unless --no-push is used'
    local remote_tip clone_base
    clone_base=$(git -C "$SRC" rev-parse "origin/$REF")
    git -C "$SRC" fetch --quiet origin "$REF"
    remote_tip=$(git -C "$SRC" rev-parse "origin/$REF")
    [[ "$remote_tip" == "$clone_base" ]] || die "origin/$REF advanced during deployment; refusing to overwrite it"
    git -C "$SRC" push --quiet origin "HEAD:$REF"
    git -C "$SRC" rev-parse HEAD > "$SYNC_STATE"
  else
    info 'skipping Git push (--no-push)'
  fi
}

smoke_status() {
  local path=$1 expected=$2 actual
  actual=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 5 "http://127.0.0.1:${HOST_PORT}${path}")
  [[ "$actual" == "$expected" ]] || die "$path returned $actual; expected $expected"
  info "$path -> $actual"
}

prune_images() {
  mapfile -t old_images < <(docker image ls "$IMAGE_NAME" --format '{{.Repository}}:{{.Tag}}' | tail -n "+$((KEEP_IMAGES + 1))")
  ((${#old_images[@]} == 0)) || docker image rm "${old_images[@]}" >/dev/null 2>&1 || true
}

if [[ $VALIDATE_PROPERTIES -eq 1 ]]; then
  validate_properties
  info 'properties validation passed'
  exit 0
fi

[[ $EUID -ne 0 ]] || die 'run as the deployment user, not root'
for command in git docker curl awk cmp mktemp stat sha256sum ss; do require_command "$command"; done
docker info >/dev/null 2>&1 || die 'Docker daemon is unavailable to this user'
docker buildx version >/dev/null 2>&1 || die 'Docker buildx is required'
docker compose version >/dev/null 2>&1 || die 'Docker Compose v2 is required'
if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
  docker buildx create --name "$BUILDER_NAME" --driver docker-container >/dev/null
fi
docker buildx inspect --bootstrap "$BUILDER_NAME" >/dev/null

mkdir -p "$BUILD_CACHE" "$TMP_DIR" "$DEPLOY_DIR" "$PROPERTIES_DIR" "$APP_DIR"
[[ -w "$DEPLOY_DIR" && -w "$PV_DIR" ]] || die "$DEPLOY_ROOT must be writable by $(id -un)"

SRC=$(mktemp -d /tmp/fewcoco-web-deploy-XXXXXXXX)
log "Cloning $REF"
git clone --quiet --branch "$REF" "$REPO" "$SRC" || die "unable to clone ref $REF"
ENV_EXAMPLE=$SRC/.env.example
validate_properties

HOST_PORT=$(env_value HOST_PORT)
mapfile -t port_containers < <(docker ps --filter "publish=$HOST_PORT" --format '{{.Names}}')
for name in "${port_containers[@]}"; do
  [[ "$name" == "$CONTAINER_NAME" ]] || die "127.0.0.1:$HOST_PORT is already published by container $name"
done
if ss -H -ltn "sport = :$HOST_PORT" | grep -q . && ((${#port_containers[@]} == 0)); then
  die "port $HOST_PORT is already held by a non-Docker listener"
fi

log 'Synchronizing deployment files'
sync_deployment_files

FULL_SHA=$(git -C "$SRC" rev-parse HEAD)
SHORT_SHA=$(git -C "$SRC" rev-parse --short=12 HEAD)
IMAGE_REF=$IMAGE_NAME:$SHORT_SHA
PREVIOUS_IMAGE=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)
if [[ "$PREVIOUS_IMAGE" == "$IMAGE_REF" && $FORCE -eq 0 ]]; then
  log "$IMAGE_REF is already running; use --force to redeploy"
  exit 0
fi

APP_ENV=$SRC/.env.deploy
render_app_env "$APP_ENV"
# BuildKit secrets are intentionally excluded from cache keys. This file
# contains only validated public browser configuration, so its hash can safely
# invalidate the build layer when a VITE_* override changes.
PUBLIC_CONFIG_HASH=$(sha256sum "$APP_ENV" | awk '{print $1}')
NEXT_CACHE=$PV_DIR/buildcache-next
rm -rf -- "$NEXT_CACHE"

log "Building $IMAGE_REF (lint, typecheck, unit tests, production build)"
docker buildx build --builder "$BUILDER_NAME" --load \
  --file "$SRC/deployment/Dockerfile" \
  --secret "id=app_env,src=$APP_ENV" \
  --build-arg "PUBLIC_CONFIG_HASH=$PUBLIC_CONFIG_HASH" \
  --cache-from "type=local,src=$BUILD_CACHE" \
  --cache-to "type=local,dest=$NEXT_CACHE,mode=max" \
  --label "org.opencontainers.image.revision=$FULL_SHA" \
  --tag "$IMAGE_REF" "$SRC"
rm -rf -- "$BUILD_CACHE"
mv "$NEXT_CACHE" "$BUILD_CACHE"

log "Deploying $IMAGE_REF"
DEPLOY_ATTEMPTED=1
# --force also covers configuration-only deployments. Browser configuration is
# baked into the image, so the rendered public config fingerprints the build
# cache and the unchanged-image container is recreated afterward.
if [[ $FORCE -eq 1 ]]; then
  compose "$IMAGE_REF" up -d --force-recreate --remove-orphans
else
  compose "$IMAGE_REF" up -d --remove-orphans
fi

log 'Waiting for container health'
healthy=0
for _ in $(seq 1 30); do
  [[ "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)" == healthy ]] && healthy=1 && break
  sleep 2
done
[[ $healthy -eq 1 ]] || die 'container did not become healthy'

log 'Running loopback smoke tests'
smoke_status /healthz 200
smoke_status / 200
smoke_status /listing-draft 200
smoke_status /assets/does-not-exist.js 404
smoke_status /etsy-shop-assistant/api/v2/me 404
smoke_status /etsy-shop-assistant/oauth/start 404
smoke_status /outside 200

DEPLOY_ATTEMPTED=0
prune_images

log 'Deployment complete'
info "commit:   $FULL_SHA"
info "image:    $IMAGE_REF"
info "status:   $(docker inspect --format '{{.State.Status}} / {{.State.Health.Status}}' "$CONTAINER_NAME")"
info "loopback: http://127.0.0.1:$HOST_PORT/"
info "logs:     IMAGE=$IMAGE_REF docker compose --env-file $CONFIG_ENV --env-file $SECRET_ENV -f $COMPOSE_FILE logs -f"
