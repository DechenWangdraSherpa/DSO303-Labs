#!/usr/bin/env bash
# Diagnose "my data disappeared" / "new Docker volumes keep appearing".
# Read-only. Destroys nothing. Paste its output into your lab report.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

ok()   { printf '\033[1;32m  [ok]\033[0m   %s\n' "$*"; }
bad()  { printf '\033[1;31m  [FAIL]\033[0m %s\n' "$*"; }
note() { printf '         %s\n' "$*"; }
hdr()  { printf '\n\033[1;34m=== %s\033[0m\n' "$*"; }

envof() {
  docker container inspect "$FLOCI_CONTAINER_NAME" \
    --format '{{ range .Config.Env }}{{ println . }}{{ end }}' | sed -n "s/^$1=//p"
}

hdr "1. Container, and who created it"
if ! docker container inspect "$FLOCI_CONTAINER_NAME" >/dev/null 2>&1; then
  bad "No container named '$FLOCI_CONTAINER_NAME'. Run ./scripts/setup/floci-up.sh"
  exit 1
fi
note "status: $(docker container inspect "$FLOCI_CONTAINER_NAME" --format '{{.State.Status}}')"
proj="$(docker container inspect "$FLOCI_CONTAINER_NAME" \
        --format '{{ index .Config.Labels "com.docker.compose.project" }}')"
if [ "$proj" = "$FLOCI_COMPOSE_PROJECT" ]; then
  ok "Created by Compose project '$FLOCI_COMPOSE_PROJECT'."
else
  bad "NOT created by Compose (project label = '$proj')."
  note "This is a 'floci start' container. Fix: floci stop --remove && ./scripts/setup/floci-up.sh"
fi

hdr "2. Storage mode — the usual culprit"
mode="$(envof FLOCI_STORAGE_MODE)"; mode="${mode:-<unset>}"
if [ "$mode" = "memory" ] || [ "$mode" = "<unset>" ]; then
  bad "FLOCI_STORAGE_MODE=$mode"
  note "Floci defaults to 'memory'. Nothing survives a restart, and Floci deletes"
  note "its own volumes on teardown — hence 'a new volume every time'."
  note "Fix: FLOCI_STORAGE_MODE=hybrid in configs/course.env, then floci-up.sh"
else
  ok "FLOCI_STORAGE_MODE=$mode (durable)"
fi

hdr "3. Is /app/data a real host directory?"
m="$(docker container inspect "$FLOCI_CONTAINER_NAME" \
     --format '{{ range .Mounts }}{{ if eq .Destination "/app/data" }}{{ .Type }} {{ .Source }}{{ end }}{{ end }}')"
if [ -z "$m" ]; then
  bad "/app/data is not mounted — state dies with the container."
else
  set -- $m
  if [ "$1" = "bind" ]; then
    ok "bind mount -> $2"
    [ "$2" = "$FLOCI_HOST_DATA_DIR" ] || bad "...but that is NOT $FLOCI_HOST_DATA_DIR"
  else
    bad "/app/data is a Docker '$1', not your host directory."
    note "A literal '~' in the path is the usual cause; nothing expands it."
  fi
fi

hdr "4. Sidecar storage (RDS / OpenSearch / MSK / ECR)"
hp="$(envof FLOCI_STORAGE_HOST_PERSISTENT_PATH)"
if [ -z "$hp" ]; then
  bad "FLOCI_STORAGE_HOST_PERSISTENT_PATH is unset — sidecars use anonymous volumes."
elif [ "${hp#/}" = "$hp" ]; then
  bad "FLOCI_STORAGE_HOST_PERSISTENT_PATH='$hp' is not absolute. Floci rejects it."
else
  ok "FLOCI_STORAGE_HOST_PERSISTENT_PATH=$hp"
fi

hdr "5. Floci-managed volumes on this machine"
vols="$(docker volume ls -q --filter label=floci=true || true)"
if [ -z "$vols" ]; then
  note "(none — expected while everything is bind-mounted)"
else
  printf '%s\n' "$vols" | sed 's/^/         /'
  note "Count: $(printf '%s\n' "$vols" | wc -l | tr -d ' ')"
  note "Growing on every restart? Storage mode is still wrong."
fi

hdr "6. Host state directory"
if [ -d "$FLOCI_HOST_DATA_DIR" ]; then
  ok "$FLOCI_HOST_DATA_DIR exists (size: $(du -sh "$FLOCI_HOST_DATA_DIR" 2>/dev/null | cut -f1))"
  ls -1 "$FLOCI_HOST_DATA_DIR" 2>/dev/null | head -20 | sed 's/^/           /'
  [ -n "$(ls -A "$FLOCI_HOST_DATA_DIR" 2>/dev/null)" ] || bad "Directory is EMPTY — see checks 2 and 3."
else
  bad "$FLOCI_HOST_DATA_DIR does not exist."
fi
printf '\n'
