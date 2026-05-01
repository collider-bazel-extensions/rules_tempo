#!/usr/bin/env bash
# One-liners against Tempo's HTTP API. Useful for inspecting a running
# Tempo install during composition development.
#
# Run after `tempo_install` is healthy. Inside the cluster, point at
# `tempo.tempo.svc.cluster.local:3200`. From outside, port-forward
# the service first:
#   kubectl -n tempo port-forward svc/tempo 3200:3200
set -euo pipefail

TEMPO_BASE="${TEMPO_BASE:-http://tempo.tempo.svc.cluster.local:3200}"

# Trace by ID — direct lookup. Fastest path; hits the ingester for
# recent traces, the storage backend for older ones.
trace_by_id() {
  local id="$1"
  curl -s "${TEMPO_BASE}/api/traces/${id}"
}

# Search by tag — TraceQL `{ resource.service.name = "..." }`. Returns
# matching traces (limited; use `?limit=N`).
search_by_service() {
  local svc="$1"
  curl -s --get "${TEMPO_BASE}/api/search" \
    --data-urlencode "q={ resource.service.name = \"${svc}\" }"
}

# List the available tags Tempo has indexed. Useful for discovering
# what's queryable.
list_tags() {
  curl -s "${TEMPO_BASE}/api/search/tags"
}

# Echo Tempo's own self-reported `/status/version` — sanity check the
# API is reachable.
status() {
  curl -s "${TEMPO_BASE}/status/version"
}

case "${1:-status}" in
  status)             status ;;
  trace)              trace_by_id "${2:?usage: $0 trace <traceID>}" ;;
  search-by-service)  search_by_service "${2:?usage: $0 search-by-service <name>}" ;;
  tags)               list_tags ;;
  *)                  echo "usage: $0 {status|trace <id>|search-by-service <name>|tags}"; exit 1 ;;
esac
