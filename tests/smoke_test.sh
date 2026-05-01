#!/usr/bin/env bash
# Round-trip a trace through Tempo to prove the OTLP-ingest +
# storage + query path all work. Strategy:
#
#   1. Generate a unique 16-byte trace ID and 8-byte span ID from
#      /dev/urandom (OTLP wire requires hex-encoded fixed-width IDs).
#   2. `kubectl run` a curl pod inside the cluster.
#   3. POST an OTLP/JSON trace at
#      `http://tempo.tempo.svc.cluster.local:4318/v1/traces`. The
#      payload has one resource (`service.name=smoke`), one scope, one
#      span with the unique IDs and a marker attribute we'll grep for.
#   4. Poll Tempo's query API at
#      `http://tempo.tempo.svc.cluster.local:3200/api/traces/<traceID>`
#      until the trace materializes. Tempo's ingester keeps recent
#      traces in memory; queries hit the in-memory ingester directly
#      (no WAL flush wait needed for fresh samples).
#   5. Assert the response includes the trace ID + the marker
#      attribute we sent — confirming the trace round-tripped.
#
# Proves: OTLP receiver (port 4318) + distributor + ingester (write
# path) + queryFrontend + querier (read path) all working end-to-end.
# Multitenancy is OFF in the smoke render so requests don't need an
# `X-Scope-OrgID` header.
set -euo pipefail

CLUSTER_NAME="cluster"
env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")

NS="smoke"
TEMPO_HOST="tempo.tempo.svc.cluster.local"
TRACE_ID=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
SPAN_ID=$(head -c 8  /dev/urandom | od -An -tx1 | tr -d ' \n')
MARKER="rules-tempo-smoke-$RANDOM-$(date +%s)"
NOW_NS=$(( $(date +%s) * 1000000000 ))
END_NS=$(( NOW_NS + 1000000 ))

echo "smoke_test: trace_id=$TRACE_ID span_id=$SPAN_ID marker=$MARKER"

echo "smoke_test: launching curl pod"
"${KCTL[@]}" create namespace "$NS" --dry-run=client -o yaml | "${KCTL[@]}" apply -f - >/dev/null
"${KCTL[@]}" -n "$NS" run tempo-curl --restart=Never --image=curlimages/curl:8.10.1 \
    --command -- sleep 600
trap '"${KCTL[@]}" -n "$NS" delete pod tempo-curl --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
"${KCTL[@]}" -n "$NS" wait pod/tempo-curl --for=condition=Ready --timeout=60s

# Build the OTLP/JSON payload. Tempo accepts traceId/spanId as either
# hex-encoded strings or base64 — JSON-over-HTTP convention is hex
# strings (lower case). The OTLP spec allows the field to be missing
# `kind` (defaults to UNSPECIFIED); we set kind=1 (INTERNAL) so the
# span is recognizably populated.
PAYLOAD=$(cat <<EOF
{
  "resourceSpans": [{
    "resource": {
      "attributes": [
        {"key": "service.name", "value": {"stringValue": "smoke"}}
      ]
    },
    "scopeSpans": [{
      "scope": {"name": "rules-tempo-smoke"},
      "spans": [{
        "traceId": "${TRACE_ID}",
        "spanId": "${SPAN_ID}",
        "name": "smoke-span",
        "kind": 1,
        "startTimeUnixNano": "${NOW_NS}",
        "endTimeUnixNano": "${END_NS}",
        "attributes": [
          {"key": "smoke.marker", "value": {"stringValue": "${MARKER}"}}
        ]
      }]
    }]
  }]
}
EOF
)

echo "smoke_test: POSTing OTLP/JSON trace to ${TEMPO_HOST}:4318/v1/traces"
post_status=$("${KCTL[@]}" -n "$NS" exec tempo-curl -- \
    curl -s -o /dev/null -w "%{http_code}" \
    -X POST -H "Content-Type: application/json" \
    --data-binary "$PAYLOAD" \
    "http://${TEMPO_HOST}:4318/v1/traces")
if [[ "$post_status" != "200" ]]; then
  echo "smoke_test: FAIL — OTLP push returned HTTP $post_status (expected 200)" >&2
  exit 1
fi
echo "smoke_test: OTLP push -> 200"

# Tempo's query API at port 3200 returns 404 until the trace is
# searchable. The ingester typically makes traces queryable within
# a few seconds. Allow up to 90s.
echo "smoke_test: polling Tempo /api/traces/${TRACE_ID}"
deadline=$(( $(date +%s) + 90 ))
got=""
while (( $(date +%s) < deadline )); do
  resp=$("${KCTL[@]}" -n "$NS" exec tempo-curl -- \
      curl -s -w "\nHTTP %{http_code}\n" \
      "http://${TEMPO_HOST}:3200/api/traces/${TRACE_ID}" 2>/dev/null || true)
  if grep -q "^HTTP 200\$" <<<"$resp"; then
    got="$resp"
    break
  fi
  sleep 3
done

if [[ -z "$got" ]]; then
  echo "smoke_test: FAIL — Tempo never returned 200 for trace ${TRACE_ID}" >&2
  echo "---- last response ----" >&2
  echo "$resp" >&2
  echo "---- tempo logs (tail) ----" >&2
  "${KCTL[@]}" -n tempo logs sts/tempo --tail=80 >&2 || true
  exit 1
fi

# Round-trip check: the unique marker attribute we attached to the
# span must come back. Tempo's `GET /api/traces/<hex_id>` returning
# 200 already proves it matched our trace ID — there's no point
# re-grepping for the trace ID in the body, especially because Tempo
# emits `traceId` as base64 in the JSON response (OTLP/JSON spec
# allows either; Tempo's HTTP API picks base64) while we generated +
# queried by hex. So the marker grep is the canonical assertion.
if ! grep -q "$MARKER" <<<"$got"; then
  echo "smoke_test: FAIL — response missing marker '$MARKER'" >&2
  echo "---- response (truncated) ----" >&2
  head -c 4000 <<<"$got" >&2
  exit 1
fi

echo "smoke_test: OK — trace ${TRACE_ID} round-tripped through Tempo (OTLP push -> ingester -> query)"
