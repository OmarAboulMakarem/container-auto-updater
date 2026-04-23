#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/registry_auth.sh"
source "${SCRIPT_DIR}/digest_check.sh"
source "${SCRIPT_DIR}/redeploy.sh"
source "${SCRIPT_DIR}/notify.sh"

# ── Env validation ────────────────────────────────────────────────────────────
missing=""
for var in WATCH_IMAGES COMPOSE_FILE SENDGRID_API_KEY EMAIL_FROM EMAIL_TO; do
  [ -z "${!var:-}" ] && missing="$missing $var"
done
if [ -n "$missing" ]; then
  echo "[entrypoint] FATAL: missing required env vars:$missing" >&2
  exit 1
fi

INTERVAL_SECONDS=$(( ${CHECK_INTERVAL_MINUTES:-5} * 60 ))
# Allow explicit project name override; fall back to parent dir of compose file
COMPOSE_PROJECT="${CA_UPDATER_PROJECT_NAME:-$(basename "$(dirname "$COMPOSE_FILE")")}"
SKIP_FIRST_RUN="${SKIP_FIRST_RUN:-false}"

log() {
  local level="$1" msg="$2"
  shift 2
  # Extra key=value pairs passed as additional args
  local extras=""
  while [ $# -gt 0 ]; do
    extras="$extras, \"$1\": \"$2\""
    shift 2
  done
  printf '{"level":"%s","time":"%s","msg":"%s"%s}\n' \
    "$level" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$msg" "$extras"
}

log info "Starting auto-pull watcher" \
  images "$WATCH_IMAGES" \
  compose "$COMPOSE_FILE" \
  project "$COMPOSE_PROJECT" \
  interval "${CHECK_INTERVAL_MINUTES:-5}m" \
  skip_first_run "$SKIP_FIRST_RUN"

first_run=true

# ── Main loop ─────────────────────────────────────────────────────────────────
while true; do
  IFS=',' read -ra IMAGES <<< "$WATCH_IMAGES"

  for image_ref in "${IMAGES[@]}"; do
    image_ref="$(echo "$image_ref" | xargs)"
    [ -z "$image_ref" ] && continue

    log info "Checking image" image "$image_ref"

    if ! login_for_image "$image_ref" >/dev/null 2>&1; then
      log warn "Auth failed, skipping" image "$image_ref"
      continue
    fi

    remote=""
    if ! remote="$(remote_digest "$image_ref")"; then
      log warn "Could not fetch remote digest after 3 attempts, skipping" image "$image_ref"
      continue
    fi
    [ -z "$remote" ] && { log warn "Empty remote digest, skipping" image "$image_ref"; continue; }

    local_d="$(local_digest "$image_ref")"

    # On first run, skip redeploy if SKIP_FIRST_RUN=true (avoids restart-triggered deploys)
    if $first_run && [ "$SKIP_FIRST_RUN" = "true" ]; then
      log info "First run — skipping redeploy (SKIP_FIRST_RUN=true)" image "$image_ref" digest "${remote:0:19}"
      continue
    fi

    if [ "$remote" = "$local_d" ]; then
      log info "Up to date" image "$image_ref" digest "${remote:0:19}..."
      continue
    fi

    old_short="${local_d:0:19}..."
    new_short="${remote:0:19}..."
    log info "Update detected" image "$image_ref" old "$old_short" new "$new_short"

    # ── Initial redeploy ──────────────────────────────────────────────────────
    redeploy_output=""
    redeploy_ok=true
    if ! redeploy_output="$(do_redeploy "$COMPOSE_FILE" 2>&1)"; then
      redeploy_ok=false
      log error "Redeploy output" image "$image_ref" output "$redeploy_output"
    fi

    if $redeploy_ok; then
      log info "Redeploy succeeded" image "$image_ref"
      subject="[ca-updater] $COMPOSE_PROJECT — redeployed successfully"
      body="$(printf \
'Project : %s
Time    : %s
Image   : %s
Old     : %s
New     : %s

All containers are running:

%s' \
        "$COMPOSE_PROJECT" "$(date -u +"%a, %d %b %Y %H:%M:%S UTC")" \
        "$image_ref" "$old_short" "$new_short" \
        "$(compose_status "$COMPOSE_FILE")")"
      send_email "$subject" "$body" || true
      break
    fi

    # ── Redeploy failed — send initial failure email then attempt recovery ─────
    log warn "Initial redeploy failed, sending failure email and starting recovery" image "$image_ref"

    subject="[ca-updater] $COMPOSE_PROJECT — REDEPLOY FAILED"
    body="$(printf \
'Project : %s
Time    : %s
Image   : %s
Old     : %s
New     : %s

Container status:

%s

Redeploy output:

%s

Logs from failing services:

%s

Recovery in progress: will recheck in 2 min, then force-recreate if still unhealthy.' \
      "$COMPOSE_PROJECT" "$(date -u +"%a, %d %b %Y %H:%M:%S UTC")" \
      "$image_ref" "$old_short" "$new_short" \
      "$(compose_status "$COMPOSE_FILE")" \
      "$redeploy_output" \
      "$(failing_service_logs "$COMPOSE_FILE" 20)")"
    send_email "$subject" "$body" || true

    # ── Recovery attempt ──────────────────────────────────────────────────────
    retry_output=""
    retry_ok=true
    if ! retry_output="$(retry_redeploy "$COMPOSE_FILE" 2>&1)"; then
      retry_ok=false
    fi

    retry_outcome="$(echo "$retry_output" | grep '^RETRY_OUTCOME=' | cut -d= -f2 || echo "unknown")"
    force_output="$(echo "$retry_output" | grep '^FORCE_OUTPUT=' | cut -d= -f2- || echo "")"

    if $retry_ok; then
      case "$retry_outcome" in
        recovered_on_own)
          log info "Services recovered on their own during retry wait" image "$image_ref"
          subject="[ca-updater] $COMPOSE_PROJECT — recovered automatically"
          body="$(printf \
'Project : %s
Time    : %s
Image   : %s

Good news: services recovered on their own during the 2-minute retry window.
No force-recreate was needed.

Current container status:

%s' \
            "$COMPOSE_PROJECT" "$(date -u +"%a, %d %b %Y %H:%M:%S UTC")" "$image_ref" \
            "$(compose_status "$COMPOSE_FILE")")"
          ;;
        force_recreate_succeeded)
          log info "Force-recreate succeeded" image "$image_ref"
          subject="[ca-updater] $COMPOSE_PROJECT — recovered via force-recreate"
          body="$(printf \
'Project : %s
Time    : %s
Image   : %s

Services were still unhealthy after 2 minutes.
Force-recreate (docker compose up -d --force-recreate) was run and succeeded.

Force-recreate output:

%s

Current container status:

%s' \
            "$COMPOSE_PROJECT" "$(date -u +"%a, %d %b %Y %H:%M:%S UTC")" "$image_ref" \
            "$force_output" \
            "$(compose_status "$COMPOSE_FILE")")"
          ;;
        *)
          log warn "Retry succeeded but outcome unclear" image "$image_ref" outcome "$retry_outcome"
          subject="[ca-updater] $COMPOSE_PROJECT — recovered (outcome: $retry_outcome)"
          body="$(compose_status "$COMPOSE_FILE")"
          ;;
      esac
    else
      log error "Recovery failed — services still unhealthy after force-recreate" image "$image_ref"
      subject="[ca-updater] $COMPOSE_PROJECT — STILL FAILING after force-recreate"
      body="$(printf \
'Project : %s
Time    : %s
Image   : %s

Services were still unhealthy after:
  1. Initial redeploy (docker compose up -d)
  2. 2-minute wait + re-check
  3. Force-recreate (docker compose up -d --force-recreate)
  4. 1-minute wait + re-check

Manual intervention required.

Force-recreate output:

%s

Current container status:

%s

Logs from failing services:

%s' \
        "$COMPOSE_PROJECT" "$(date -u +"%a, %d %b %Y %H:%M:%S UTC")" "$image_ref" \
        "$force_output" \
        "$(compose_status "$COMPOSE_FILE")" \
        "$(failing_service_logs "$COMPOSE_FILE" 20)")"
    fi

    send_email "$subject" "$body" || true
    break
  done

  first_run=false
  log info "Sleeping" seconds "$INTERVAL_SECONDS"
  sleep "$INTERVAL_SECONDS"
done
