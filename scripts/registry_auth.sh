#!/usr/bin/env bash
# Routes docker login to ECR, OCIR, or Docker Hub based on image hostname.
set -euo pipefail

login_for_image() {
  local image_ref="$1"
  local host
  host="$(echo "$image_ref" | cut -d'/' -f1)"

  if echo "$host" | grep -qE '\.ecr\.[a-z0-9-]+\.amazonaws\.com'; then
    if [ -z "${AWS_REGION:-}" ] || [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
      echo "[registry_auth] ERROR: AWS_REGION/AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY not set for ECR" >&2
      return 1
    fi
    aws ecr get-login-password --region "${AWS_REGION}" \
      | docker login --username AWS --password-stdin "$host"

  elif echo "$host" | grep -qE '\.ocir\.io$'; then
    if [ -z "${OCIR_AUTH_TOKEN:-}" ] || [ -z "${OCIR_USERNAME:-}" ]; then
      echo "[registry_auth] ERROR: OCIR_AUTH_TOKEN/OCIR_USERNAME not set for OCIR" >&2
      return 1
    fi
    echo "${OCIR_AUTH_TOKEN}" \
      | docker login --username "${OCIR_USERNAME}" --password-stdin "$host"

  elif [ "$host" = "docker.io" ] || echo "$image_ref" | grep -qvE '^[^/]+\.[^/]+/'; then
    if [ -z "${DOCKERHUB_TOKEN:-}" ] || [ -z "${DOCKERHUB_USERNAME:-}" ]; then
      echo "[registry_auth] ERROR: DOCKERHUB_TOKEN/DOCKERHUB_USERNAME not set for Docker Hub" >&2
      return 1
    fi
    echo "${DOCKERHUB_TOKEN}" \
      | docker login --username "${DOCKERHUB_USERNAME}" --password-stdin

  else
    echo "[registry_auth] WARNING: unknown registry host '$host', skipping login" >&2
  fi
}
