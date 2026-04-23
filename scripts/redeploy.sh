#!/usr/bin/env bash
set -euo pipefail

# Prints a human-readable table of all services: NAME  STATE  HEALTH  PORTS
_compose() {
  local compose_file="$1"
  shift
  if [ -n "${COMPOSE_ENV_FILE:-}" ]; then
    docker compose -f "$compose_file" --env-file "$COMPOSE_ENV_FILE" "$@"
  else
    docker compose -f "$compose_file" "$@"
  fi
}

compose_status() {
  local compose_file="$1"
  _compose "$compose_file" ps --format json 2>/dev/null \
    | jq -r 'if type == "array" then .[] else . end
             | [.Name, .State, (if .Health == "" then "-" else .Health end), (if .Publishers then (.Publishers | map(.PublishedPort | tostring) | join(",")) else "-" end)]
             | @tsv' \
    | awk 'BEGIN{printf "%-40s %-10s %-12s %s\n","SERVICE","STATE","HEALTH","PORTS"
                 printf "%-40s %-10s %-12s %s\n","-------","-----","------","-----"}
           {printf "%-40s %-10s %-12s %s\n",$1,$2,$3,$4}' || echo "(could not retrieve service status)"
}

# Prints last N lines of logs for each unhealthy/stopped service.
failing_service_logs() {
  local compose_file="$1"
  local lines="${2:-20}"
  local services
  services="$(_compose "$compose_file" ps --format json 2>/dev/null \
    | jq -r 'if type == "array" then .[] else . end
             | select((.State != "running") or (.Health == "unhealthy"))
             | .Service' \
    | sort -u | grep -v '^$' || true)"

  if [ -z "$services" ]; then
    _compose "$compose_file" logs --tail="$lines" 2>&1
    return
  fi

  while IFS= read -r svc; do
    printf '\n--- logs: %s (last %s lines) ---\n' "$svc" "$lines"
    _compose "$compose_file" logs --tail="$lines" "$svc" 2>&1
  done <<< "$services"
}

verify_health() {
  local compose_file="$1"
  local unhealthy
  unhealthy="$(_compose "$compose_file" ps --format json 2>/dev/null \
    | jq -r 'if type == "array" then .[] else . end
             | select((.State != "running") or (.Health == "unhealthy"))
             | .Name' \
    | grep -v '^$' || true)"

  if [ -z "$unhealthy" ]; then
    return 0
  else
    echo "$unhealthy"
    return 1
  fi
}

do_redeploy() {
  local compose_file="$1"
  local pull_output up_output

  echo "[redeploy] Pulling images..."
  if ! pull_output="$(_compose "$compose_file" pull 2>&1)"; then
    echo "[redeploy] ERROR: compose pull failed"
    echo "$pull_output"
    return 1
  fi

  echo "[redeploy] Running docker compose up -d..."
  if ! up_output="$(_compose "$compose_file" up -d 2>&1)"; then
    echo "[redeploy] ERROR: compose up failed"
    echo "$up_output"
    return 1
  fi

  echo "[redeploy] Waiting 60s for services to stabilise..."
  sleep 60

  local unhealthy_services
  if ! unhealthy_services="$(verify_health "$compose_file")"; then
    echo "[redeploy] ERROR: unhealthy services after redeploy:"
    echo "$unhealthy_services"
    echo "--- compose ps ---"
    _compose "$compose_file" ps
    echo "--- logs (last 50 lines) ---"
    _compose "$compose_file" logs --tail=50
    return 1
  fi

  echo "[redeploy] All services healthy."
  return 0
}

# Called after do_redeploy fails. Waits 2 min, re-checks health.
# If still unhealthy, tries force-recreate, waits 1 min, re-checks again.
# Outputs a summary block describing the outcome of each attempt.
# Returns 0 if recovery succeeded, 1 if both attempts failed.
retry_redeploy() {
  local compose_file="$1"

  echo "[redeploy] Waiting 2 min before retry health check..."
  sleep 120

  echo "[redeploy] Retry check #1 — re-checking health..."
  if verify_health "$compose_file" >/dev/null 2>&1; then
    echo "[redeploy] Retry check #1 — services recovered on their own."
    printf 'RETRY_OUTCOME=recovered_on_own\n'
    return 0
  fi

  echo "[redeploy] Retry check #1 — still unhealthy. Attempting force-recreate..."
  local force_output
  if ! force_output="$(_compose "$compose_file" up -d --force-recreate 2>&1)"; then
    echo "[redeploy] ERROR: force-recreate failed"
    echo "$force_output"
    printf 'RETRY_OUTCOME=force_recreate_failed\nFORCE_OUTPUT=%s\n' "$force_output"
    return 1
  fi

  echo "[redeploy] Waiting 60s after force-recreate..."
  sleep 60

  echo "[redeploy] Retry check #2 — checking health after force-recreate..."
  if verify_health "$compose_file" >/dev/null 2>&1; then
    echo "[redeploy] Retry check #2 — services healthy after force-recreate."
    printf 'RETRY_OUTCOME=force_recreate_succeeded\nFORCE_OUTPUT=%s\n' "$force_output"
    return 0
  fi

  echo "[redeploy] Retry check #2 — still unhealthy after force-recreate."
  printf 'RETRY_OUTCOME=force_recreate_failed\nFORCE_OUTPUT=%s\n' "$force_output"
  return 1
}
