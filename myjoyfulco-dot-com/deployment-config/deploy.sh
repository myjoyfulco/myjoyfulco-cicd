#!/usr/bin/env bash
set -euo pipefail

# This file is staged locally only so it can be transferred to the server's
# deployment configuration. All paths used at runtime derive from this script.
#
# -revert-to <tag> redeploys an existing, already-released tag instead of the
# branch's latest HEAD (a rollback), skipping tag creation/push and the
# release-notes.md entry. Mutually exclusive with -version. See parse_args,
# preflight, and clone_repository for where it changes behavior.

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
resolve_path() {
    if command -v realpath >/dev/null 2>&1; then realpath -m -- "$1"; else readlink -f -- "$1"; fi
}
CONFIG_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd -P)"
BASE_DIR="$(cd -- "$CONFIG_DIR/.." && pwd -P)"
APP_DIR="$BASE_DIR/myjoyfulco-dot-com"
DEPLOY_ENV="$CONFIG_DIR/deploy.env"
SECRET_ENV="$CONFIG_DIR/secret.env"
DOCKERFILE_SOURCE="$CONFIG_DIR/Dockerfile"
DOCKERIGNORE_SOURCE="$CONFIG_DIR/.dockerignore"
COMPOSE_SOURCE="$CONFIG_DIR/docker-compose.yml"
RELEASE_NOTES="$BASE_DIR/release-notes.md"
DEPLOY_LOG="/app/myjoyfulco-dot-com/logs/deploy.log"
CACHE_HOST_DIR="/app/myjoyfulco-dot-com/tmp"
PROJECT="myjoyfulco-dot-com"

declare -A DEPLOY_VALUES=()
declare -A SECRET_VALUES=()
declare -a REDACT_VALUES=()
declare -a TEMP_FILES=()
VERSION=""
REVERT_TO=""
BRANCH=""
COMMIT_SHA=""
IMAGE_TAG=""
IMAGE_REPOSITORY="myjoyfulco-dot-com"
NEW_IMAGE_REF=""
ROLLBACK_TAG=""
PRIOR_IMAGE_ID=""
NEW_IMAGE_ID=""
GEN_ENV=""
LOCK_FD=""
LOCKED=0
COMPLETE=0
HEALTH_FAILURE=""

timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { printf '%s %s\n' "$(timestamp)" "$*"; }
die() { printf 'deploy: %s\n' "$*" >&2; return 1; }
usage() { printf 'usage: %s [-version <tag>] [-revert-to <tag>]\n' "${0##*/}" >&2; }

is_key() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }
strict_env_file() {
    local file="$1" map_name="$2" line key value count=0
    unset "$map_name" 2>/dev/null || true
    declare -gA "$map_name"
    declare -n target="$map_name"
    target=()
    [[ -f "$file" ]] || { die "missing configuration file: $file"; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *=* ]] || { die "malformed environment record in ${file##*/}"; return 1; }
        key="${line%%=*}"; value="${line#*=}"
        is_key "$key" || { die "malformed environment key in ${file##*/}"; return 1; }
        [[ -z "${target[$key]+x}" ]] || { die "duplicate environment key in ${file##*/}: $key"; return 1; }
        target["$key"]="$value"; ((count+=1))
    done < "$file"
    (( count > 0 )) || { die "no environment records in ${file##*/}"; return 1; }
}

require_value() { [[ -n "${DEPLOY_VALUES[$1]-}" ]] || die "missing required deploy.env setting: $1"; }
validate_secret_file() {
    local mode key
    [[ -f "$SECRET_ENV" ]] || die "missing configuration file: $SECRET_ENV"
    mode="$(stat -c '%a' -- "$SECRET_ENV")"
    [[ "$mode" =~ ^[0-6]00$ ]] || die "secret.env must not be group- or world-readable"
    strict_env_file "$SECRET_ENV" SECRET_VALUES
    for key in SECRET_KEY DB_NAME DB_USER DB_PASSWORD; do
        [[ -n "${SECRET_VALUES[$key]+x}" && -n "${SECRET_VALUES[$key]}" ]] || die "missing or empty secret.env key: $key"
    done
    (( ${#SECRET_VALUES[@]} == 4 )) || die "secret.env contains unexpected keys"
    REDACT_VALUES=("${SECRET_VALUES[SECRET_KEY]}" "${SECRET_VALUES[DB_NAME]}" "${SECRET_VALUES[DB_USER]}" "${SECRET_VALUES[DB_PASSWORD]}")
}
load_deploy_config() {
    local key
    strict_env_file "$DEPLOY_ENV" DEPLOY_VALUES
    for key in REPO_URL BRANCH NODE_ENV SITE_HOST SITE_PORT PORT EDITOR_API_HOST EDITOR_API_PORT LOCAL_SITE_ORIGIN NEXT_PUBLIC_EDITOR_API_ORIGIN DB_HOST DB_PORT DB_SSLMODE WERKZEUG_PBKDF2_ITERATIONS CONTENT_CACHE_PATH HEALTH_HOST HEALTH_PORT HEALTH_PATH HEALTH_TIMEOUT_SECONDS HEALTH_POLL_INTERVAL; do require_value "$key"; done
    BRANCH="${DEPLOY_BRANCH:-${DEPLOY_VALUES[BRANCH]}}"
    valid_branch "$BRANCH" || die "invalid deployment branch"
}
valid_branch() { [[ -n "$1" ]] && git check-ref-format --branch "$1" >/dev/null 2>&1; }
valid_tag() { [[ -n "$1" ]] && git check-ref-format --allow-onelevel "refs/tags/$1" >/dev/null 2>&1; }

parse_args() {
    local seen_version=0 seen_revert=0
    while (( $# )); do
        case "$1" in
            -version)
                (( seen_version == 0 )) || die "-version may be supplied once"
                (( $# >= 2 )) || die "-version requires a tag"
                VERSION="$2"; seen_version=1; shift 2 ;;
            -revert-to)
                (( seen_revert == 0 )) || die "-revert-to may be supplied once"
                (( $# >= 2 )) || die "-revert-to requires a tag"
                REVERT_TO="$2"; seen_revert=1; shift 2 ;;
            *) usage; die "unknown argument: $1" ;;
        esac
    done
    if [[ -n "$VERSION" && -n "$REVERT_TO" ]]; then die "-version and -revert-to are mutually exclusive"; fi
    if [[ -n "$VERSION" ]]; then valid_tag "$VERSION" || die "invalid Git tag"; fi
    if [[ -n "$REVERT_TO" ]]; then valid_tag "$REVERT_TO" || die "invalid Git tag"; fi
}

confirm_unversioned() {
    local answer
    [[ -n "$VERSION" || -n "$REVERT_TO" ]] && return 0
    printf '%s' '-version not supplied, deployment will run a redeploy Y/n'
    if ! IFS= read -r answer; then die "redeploy cancelled: no interactive response"; return 1; fi
    case "$answer" in ''|Y|y) return 0 ;; N|n) die "redeploy cancelled" ;; *) die "redeploy cancelled: unrecognized response" ;; esac
}

acquire_lock() {
    local lock_file="$BASE_DIR/.deploy.lock"
    [[ -d "$BASE_DIR" ]] || die "deployment root is missing"
    exec {LOCK_FD}>"$lock_file"
    flock -n "$LOCK_FD" || die "another deployment is already running"
    LOCKED=1
}
begin_log() {
    : > "$DEPLOY_LOG" || die "deployment log is not writable"
    exec > >(tee -a "$DEPLOY_LOG") 2>&1
}

safe_clone_path() {
    local candidate="$1" base resolved
    [[ -n "$candidate" ]] || return 1
    base="$(resolve_path "$BASE_DIR")" || return 1
    [[ "$base" != / && "$base" != "$(resolve_path "$HOME")" ]] || return 1
    [[ "$(basename -- "$candidate")" == myjoyfulco-dot-com ]] || return 1
    [[ "$(dirname -- "$candidate")" == "$base" ]] || return 1
    resolved="$(resolve_path "$candidate")" || return 1
    [[ "$resolved" == "$base/myjoyfulco-dot-com" && "$resolved" == "$base"/* ]] || return 1
}
remove_clone() {
    safe_clone_path "$APP_DIR" || die "refusing unsafe clone deletion"
    [[ -e "$APP_DIR" || -L "$APP_DIR" ]] && rm -rf -- "$APP_DIR"
}

cleanup_secrets() {
    local f
    [[ -n "$GEN_ENV" && -e "$GEN_ENV" ]] && rm -f -- "$GEN_ENV" || true
    for f in "${TEMP_FILES[@]:-}"; do [[ -n "$f" && -e "$f" ]] && rm -f -- "$f" || true; done
}
on_exit() {
    local status=$?
    cleanup_secrets
    if (( COMPLETE )); then
        if [[ -n "$ROLLBACK_TAG" ]]; then docker image rm "$ROLLBACK_TAG" >/dev/null 2>&1 || true; fi
        remove_clone || { log 'successful cleanup could not remove clone'; status=1; }
    fi
    exit "$status"
}
on_signal() { log 'deployment interrupted'; exit 128; }
install_traps() { trap on_exit EXIT; trap on_signal INT TERM HUP; }

need_command() { command -v "$1" >/dev/null 2>&1 || die "required command unavailable: $1"; }
compose() { docker compose -p "$PROJECT" -f "$APP_DIR/docker-compose.yml" "$@"; }
preflight_files() {
    local f mode
    for f in "$DEPLOY_ENV" "$SECRET_ENV" "$DOCKERFILE_SOURCE" "$DOCKERIGNORE_SOURCE" "$COMPOSE_SOURCE" "$RELEASE_NOTES"; do [[ -f "$f" ]] || die "missing required file: $f"; done
    mode="$(stat -c '%a' -- "$CONFIG_DIR/deploy.sh")"; [[ "$mode" =~ ^[0-7][0-5][0-5]$ ]] || die 'deploy.sh must not be group/world writable'
    [[ -w "$BASE_DIR" && -w "$(dirname -- "$DEPLOY_LOG")" && -w "$CACHE_HOST_DIR" && -w "$RELEASE_NOTES" ]] || die 'deployment paths are not writable'
    safe_clone_path "$APP_DIR" || die 'invalid clone target path'
}
port_ok() {
    local port="$1" service="$2" ids
    if ! command -v ss >/dev/null 2>&1 || ! ss -ltn "sport = :$port" | awk 'NR>1 {found=1} END {exit !found}'; then return 0; fi
    ids="$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$service")"
    [[ -n "$ids" ]] || return 1
    docker inspect -f '{{.HostConfig.NetworkMode}}' $ids | grep -qx host
}
preflight() {
    local cmd remote_sha
    preflight_files
    for cmd in git docker curl awk flock mktemp date grep sed; do need_command "$cmd"; done
    command -v readlink >/dev/null 2>&1 || command -v realpath >/dev/null 2>&1 || die 'readlink or realpath is required'
    docker compose version >/dev/null || die 'Docker Compose is unavailable'
    docker info >/dev/null || die 'Docker daemon is not accessible without sudo'
    validate_secret_file; load_deploy_config
    [[ "$(basename -- "$CONFIG_DIR")" == deployment-config ]] || die 'unexpected configuration directory'
    remote_sha="$(git ls-remote --heads "${DEPLOY_VALUES[REPO_URL]}" "refs/heads/$BRANCH" | awk -v ref="refs/heads/$BRANCH" '$2==ref {print $1; exit}')"
    [[ -n "$remote_sha" ]] || die 'selected branch is not available remotely'
    if [[ -n "$VERSION" ]] && git ls-remote --tags "${DEPLOY_VALUES[REPO_URL]}" "refs/tags/$VERSION" "refs/tags/$VERSION^{}" | awk -v ref="refs/tags/$VERSION" '$2==ref || $2==ref"^{}" {found=1} END {exit !found}'; then
        log "warning: requested tag already exists: $VERSION"; return 1
    fi
    if [[ -n "$REVERT_TO" ]] && ! git ls-remote --tags "${DEPLOY_VALUES[REPO_URL]}" "refs/tags/$REVERT_TO" "refs/tags/$REVERT_TO^{}" | awk -v ref="refs/tags/$REVERT_TO" '$2==ref || $2==ref"^{}" {found=1} END {exit !found}'; then
        die "requested tag does not exist: $REVERT_TO"
    fi
    timeout 3 bash -c '>/dev/tcp/$1/$2' bash "${DEPLOY_VALUES[DB_HOST]}" "${DEPLOY_VALUES[DB_PORT]}" || die 'PostgreSQL listener is unreachable; deployment stopped'
    port_ok 3000 site || die 'port 3000 is occupied by an unverified listener'
    port_ok 3030 editor-api || die 'port 3030 is occupied by an unverified listener'
}

clone_repository() {
    local remote_head
    [[ ! -e "$APP_DIR" && ! -L "$APP_DIR" ]] || remove_clone
    ( cd -- "$BASE_DIR" && git clone --branch "$BRANCH" --single-branch "${DEPLOY_VALUES[REPO_URL]}" )
    # --single-branch skips tags outside that branch's history by default;
    # fetch every tag explicitly so a -revert-to target unreachable from
    # $BRANCH still resolves, and so the preflight tag-exists check above
    # is corroborated against what actually landed in the clone.
    git -C "$APP_DIR" fetch --tags --force
    if [[ -n "$REVERT_TO" ]]; then
        git -C "$APP_DIR" rev-parse -q --verify "refs/tags/$REVERT_TO" >/dev/null || die "tag not present after clone: $REVERT_TO"
        git -C "$APP_DIR" checkout --quiet "refs/tags/$REVERT_TO"
        COMMIT_SHA="$(git -C "$APP_DIR" rev-parse HEAD)"
    else
        COMMIT_SHA="$(git -C "$APP_DIR" rev-parse HEAD)"
        remote_head="$(git -C "$APP_DIR" rev-parse "origin/$BRANCH")"
        [[ "$COMMIT_SHA" == "$remote_head" ]] || die 'checked-out commit does not match selected remote branch'
    fi
    IMAGE_TAG="$COMMIT_SHA"
    NEW_IMAGE_REF="${IMAGE_REPOSITORY}:${IMAGE_TAG}"
    cp -- "$DOCKERFILE_SOURCE" "$APP_DIR/Dockerfile"
    cp -- "$DOCKERIGNORE_SOURCE" "$APP_DIR/.dockerignore"
    cp -- "$COMPOSE_SOURCE" "$APP_DIR/docker-compose.yml"
}
merge_environment() {
    local template="$1" destination="$2" line key value tmp replacements=0 declared=0
    declare -A template_keys=()
    [[ -f "$template" ]] || die 'repository .env template is missing'
    strict_env_file "$DEPLOY_ENV" DEPLOY_VALUES; strict_env_file "$SECRET_ENV" SECRET_VALUES
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *=* ]] || die 'malformed repository .env record'
        key="${line%%=*}"; is_key "$key" || die 'malformed repository .env key'
        [[ -z "${template_keys[$key]+x}" ]] || die "duplicate repository .env key: $key"
        template_keys["$key"]=1; ((declared+=1))
    done < "$template"
    umask 077; tmp="$(mktemp "$(dirname -- "$destination")/.env.tmp.XXXXXX")"; TEMP_FILES+=("$tmp")
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]]; then printf '%s\n' "$line" >> "$tmp"; continue; fi
        key="${line%%=*}"
        if [[ -n "${SECRET_VALUES[$key]+x}" ]]; then value="${SECRET_VALUES[$key]}"; ((replacements+=1))
        elif [[ -n "${DEPLOY_VALUES[$key]+x}" ]]; then value="${DEPLOY_VALUES[$key]}"; ((replacements+=1))
        else value="${line#*=}"; fi
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    done < "$template"
    chmod 600 "$tmp"; mv -f -- "$tmp" "$destination"; GEN_ENV="$destination"; TEMP_FILES=("${TEMP_FILES[@]/$tmp}")
    for key in SECRET_KEY DB_NAME DB_USER DB_PASSWORD; do [[ -n "${template_keys[$key]+x}" && -n "${SECRET_VALUES[$key]}" ]] || die "required production field missing from .env template: $key"; done
    log "generated runtime environment with $declared declared keys and $replacements replacements"
}
runtime_compose_vars() {
    [[ -n "$IMAGE_TAG" && -n "$NEW_IMAGE_REF" ]] || die 'canonical image reference was not initialized'
    export IMAGE_TAG RUNTIME_UID="$(id -u)" RUNTIME_GID="$(id -g)" COMPOSE_PROJECT_NAME="$PROJECT"
}
compose_validate() { compose config --quiet; }
detect_prior_image() {
    local id
    id="$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter 'label=com.docker.compose.service=site')"
    [[ -n "$id" ]] || return 0
    PRIOR_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$id")"
    [[ -n "$PRIOR_IMAGE_ID" ]] || die 'could not identify prior site image'
    ROLLBACK_TAG="$PROJECT:rollback-$(date +%s)-$$"
    docker image inspect "$ROLLBACK_TAG" >/dev/null 2>&1 && die 'rollback tag collision'
    docker tag "$PRIOR_IMAGE_ID" "$ROLLBACK_TAG"
}
build_image() { compose build --no-cache site; NEW_IMAGE_ID="$(docker image inspect --format '{{.Id}}' "$NEW_IMAGE_REF")"; [[ -n "$NEW_IMAGE_ID" ]]; }
initialize_database() { compose run --rm --no-deps editor-api npm run db:init:postgres; }
cutover() { compose stop site editor-api; compose up -d --no-build site editor-api; }

redact_line() {
    local text="$1" secret out i j n found
    for secret in "${REDACT_VALUES[@]:-}"; do
        [[ -n "$secret" ]] || continue; out=''; i=0; n=${#text}
        while (( i < n )); do
            found=0
            if [[ "${text:i:${#secret}}" == "$secret" ]]; then out+='[REDACTED]'; ((i+=${#secret})); found=1; fi
            (( found )) || { out+="${text:i:1}"; ((i+=1)); }
        done
        text="$out"
    done
    printf '%s\n' "$text"
}
redact_stream() { local line; while IFS= read -r line || [[ -n "$line" ]]; do redact_line "$line"; done; }
capture_diagnostics() {
    log "diagnostics: failed endpoint ${HEALTH_FAILURE:-unknown}"
    compose ps 2>&1 | redact_stream || true
    compose logs --tail 80 site 2>&1 | redact_stream || true
    compose logs --tail 80 editor-api 2>&1 | redact_stream || true
}
http_status() { curl --silent --show-error --output "$2" --write-out '%{http_code}' --max-time 10 "$1"; }
local_health() {
    local body status
    compose ps --status running --services | grep -qx site && compose ps --status running --services | grep -qx editor-api || { HEALTH_FAILURE='services'; return 1; }
    body="$(mktemp)"; TEMP_FILES+=("$body"); status="$(http_status 'http://127.0.0.1:3000/' "$body")"; [[ "$status" == 200 ]] && grep -q 'MyJoyfulArt' "$body" || { HEALTH_FAILURE='site'; return 1; }
    status="$(http_status 'http://127.0.0.1:3030/api/health' "$body")"; [[ "$status" == 200 ]] || { HEALTH_FAILURE='api-health'; return 1; }
    status="$(http_status 'http://127.0.0.1:3030/api/ready' "$body")"; [[ "$status" == 200 ]] || { HEALTH_FAILURE='api-ready'; return 1; }
    status="$(http_status 'http://127.0.0.1:3030/api/content' "$body")"; [[ "$status" == 200 ]] && grep -Eq '"source"[[:space:]]*:[[:space:]]*"database"' "$body" || { HEALTH_FAILURE='api-content'; return 1; }
}
poll_local_health() {
    local deadline=$(( $(date +%s) + ${DEPLOY_VALUES[HEALTH_TIMEOUT_SECONDS]} ))
    while (( $(date +%s) < deadline )); do local_health && return 0; sleep "${DEPLOY_VALUES[HEALTH_POLL_INTERVAL]}"; done
    return 1
}
public_health() {
    local body headers status asset
    body="$(mktemp)"; headers="$(mktemp)"; TEMP_FILES+=("$body" "$headers")
    status="$(http_status 'https://myjoyfulco.com/' "$body")"; [[ "$status" == 200 ]] && grep -q 'MyJoyfulArt' "$body" || { HEALTH_FAILURE='public-site'; return 1; }
    status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 10 --location --max-redirs 0 'https://www.myjoyfulco.com/health-check?preserved=1' || true)"; [[ "$status" =~ ^30[18]$ ]] || { HEALTH_FAILURE='public-www-redirect'; return 1; }
    curl --silent --show-error --max-time 10 -D "$headers" -o "$body" 'https://myjoyfulco.com/api/health' >/dev/null
    grep -qi '^Cache-Control:.*no-store' "$headers" || { HEALTH_FAILURE='public-api-cache'; return 1; }
    while IFS= read -r asset; do [[ -z "$asset" ]] && continue; curl --silent --show-error --max-time 10 "$asset" | grep -q 'http://localhost:3030' && { HEALTH_FAILURE='public-client-asset'; return 1; } || true; done < <(grep -Eo 'https://myjoyfulco\.com/[^" ]+\.js' "$body" | sort -u)
}
rollback() {
    capture_diagnostics
    compose down || true
    if [[ -z "$ROLLBACK_TAG" || -z "$PRIOR_IMAGE_ID" ]]; then log 'rollback unavailable: no prior image'; return 1; fi
    export IMAGE_TAG="$ROLLBACK_TAG"
    compose up -d --no-build site editor-api || return 1
    local_health || return 1
    local id; id="$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter 'label=com.docker.compose.service=site')"
    [[ "$(docker inspect -f '{{.Image}}' "$id")" == "$PRIOR_IMAGE_ID" ]] || return 1
    log 'rollback succeeded'; return 0
}
prior_tag_subjects() {
    local prior
    prior="$(git -C "$APP_DIR" tag --merged HEAD --sort=-creatordate | head -n 1 || true)"
    if [[ -n "$prior" ]]; then git -C "$APP_DIR" log --format='%s' "$prior..HEAD"; else git -C "$APP_DIR" log --format='%s' HEAD; fi
}
append_release_notes() {
    local tmp subject count=0
    tmp="$(mktemp "$BASE_DIR/.release-notes.XXXXXX")"; TEMP_FILES+=("$tmp")
    cp --preserve=mode "$RELEASE_NOTES" "$tmp"
    printf '\n# %s\n\n## %s\n\n### What'"'"'s Included\n' "$VERSION" "$(TZ=Australia/Brisbane date '+%-d %b %Y')" >> "$tmp"
    while IFS= read -r subject || [[ -n "$subject" ]]; do subject="$(printf '%s' "$subject" | sed 's/^[[:space:]]*[-*][[:space:]]*//; s/\r//g')"; [[ -n "$subject" ]] || continue; printf '%s\n' "- $subject" >> "$tmp"; ((count+=1)); done < <(prior_tag_subjects)
    (( count > 0 )) || printf '%s\n' '- No commit subjects were available after the prior reachable tag.' >> "$tmp"
    mv -f -- "$tmp" "$RELEASE_NOTES"; TEMP_FILES=("${TEMP_FILES[@]/$tmp}")
}
tag_release() {
    # Also the no-op path for a -revert-to rollback (VERSION is unset there) —
    # nothing new to tag, push, or log to release-notes.md in that case.
    [[ -n "$VERSION" ]] || return 0
    git -C "$APP_DIR" tag "$VERSION" "$COMMIT_SHA"
    git -C "$APP_DIR" push origin "refs/tags/$VERSION:refs/tags/$VERSION"
    append_release_notes
}
deploy_lifecycle() {
    clone_repository; merge_environment "$APP_DIR/.env" "$APP_DIR/.env"; runtime_compose_vars; compose_validate
    detect_prior_image; build_image; initialize_database; cutover
    if ! poll_local_health || ! public_health; then rollback || true; die 'new deployment failed health verification; clone retained for diagnostics'; return 1; fi
    if ! tag_release; then log 'healthy deployment is retained; tag/release bookkeeping failed; clone and rollback tag retained for manual recovery'; return 1; fi
    COMPLETE=1
    local version_label
    if [[ -n "$VERSION" ]]; then version_label="$VERSION"
    elif [[ -n "$REVERT_TO" ]]; then version_label="revert-to-$REVERT_TO"
    else version_label="unversioned-redeploy"; fi
    log "deployment succeeded: branch=$BRANCH commit=$COMMIT_SHA version=$version_label local=passed public=passed"
}
main() {
    install_traps
    parse_args "$@"; confirm_unversioned
    acquire_lock; begin_log; log "deployment accepted (version=${VERSION:-none} revert-to=${REVERT_TO:-none})"
    preflight; deploy_lifecycle
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
