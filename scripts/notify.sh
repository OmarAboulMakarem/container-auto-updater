#!/usr/bin/env bash
set -euo pipefail

# send_email <subject> <body>
# Routes to SendGrid or SMTP depending on NOTIFY_PROVIDER (default: sendgrid).
send_email() {
  local subject="$1"
  local body="$2"

  case "${NOTIFY_PROVIDER:-sendgrid}" in
    sendgrid) _send_sendgrid "$subject" "$body" ;;
    smtp)     _send_smtp     "$subject" "$body" ;;
    *)
      echo "[notify] WARNING: unknown NOTIFY_PROVIDER '${NOTIFY_PROVIDER}', defaulting to sendgrid" >&2
      _send_sendgrid "$subject" "$body"
      ;;
  esac
}

_send_sendgrid() {
  local subject="$1"
  local body="$2"

  local to_array
  to_array="$(
    echo "$EMAIL_TO" | tr ',' '\n' | while read -r addr; do
      addr="$(echo "$addr" | xargs)"
      [ -z "$addr" ] && continue
      printf '{"email":"%s"}' "$addr"
    done | paste -sd ','
  )"

  local payload
  payload="$(jq -nc \
    --arg from "$EMAIL_FROM" \
    --arg subject "$subject" \
    --arg body "$body" \
    --argjson to "[$to_array]" \
    '{
      personalizations: [{ to: $to }],
      from: { email: $from },
      subject: $subject,
      content: [{ type: "text/plain", value: $body }]
    }')"

  local http_code
  http_code="$(curl -s -o /dev/null -w "%{http_code}" \
    --request POST \
    --url https://api.sendgrid.com/v3/mail/send \
    --header "Authorization: Bearer ${SENDGRID_API_KEY}" \
    --header "Content-Type: application/json" \
    --data "$payload")"

  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    echo "[notify] Email sent via SendGrid: $subject (HTTP $http_code)"
  else
    echo "[notify] WARNING: SendGrid returned HTTP $http_code for: $subject" >&2
  fi
}

_send_smtp() {
  local subject="$1"
  local body="$2"

  local smtp_host="${SMTP_HOST}"
  local smtp_port="${SMTP_PORT:-587}"
  local smtp_user="${SMTP_USERNAME:-}"
  local smtp_pass="${SMTP_PASSWORD:-}"
  local tls_flag=""

  # Use smtps:// (implicit TLS) for port 465, starttls flag for 587/25
  if [ "$smtp_port" = "465" ]; then
    tls_flag="--ssl-reqd"
    local protocol="smtps"
  else
    tls_flag="--starttls smtp"
    local protocol="smtp"
  fi

  # Build RFC 2822 message, one recipient per To: line
  local to_header
  to_header="$(echo "$EMAIL_TO" | tr ',' '\n' | while read -r addr; do
    addr="$(echo "$addr" | xargs)"
    [ -z "$addr" ] && continue
    printf 'To: %s\n' "$addr"
  done)"

  local message
  message="$(printf 'From: %s\n%sSubject: %s\nDate: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s' \
    "$EMAIL_FROM" \
    "$to_header" \
    "$subject" \
    "$(date -u +"%a, %d %b %Y %H:%M:%S +0000")" \
    "$body")"

  # Build --rcpt-file equivalent: pass each recipient as a separate --mail-rcpt flag
  local rcpt_flags=()
  while IFS= read -r addr; do
    addr="$(echo "$addr" | xargs)"
    [ -z "$addr" ] && continue
    rcpt_flags+=(--mail-rcpt "$addr")
  done <<< "$(echo "$EMAIL_TO" | tr ',' '\n')"

  local curl_auth=()
  if [ -n "$smtp_user" ]; then
    curl_auth=(--user "${smtp_user}:${smtp_pass}")
  fi

  if echo "$message" | curl -s --fail \
    --url "${protocol}://${smtp_host}:${smtp_port}" \
    $tls_flag \
    "${curl_auth[@]+"${curl_auth[@]}"}" \
    --mail-from "$EMAIL_FROM" \
    "${rcpt_flags[@]}" \
    --upload-file - >/dev/null 2>&1; then
    echo "[notify] Email sent via SMTP (${smtp_host}:${smtp_port}): $subject"
  else
    echo "[notify] WARNING: SMTP delivery failed for: $subject" >&2
  fi
}
