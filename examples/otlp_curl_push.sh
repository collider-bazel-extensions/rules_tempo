#!/usr/bin/env bash
# Minimal OTLP/JSON push + trace-by-id round-trip via curl. Same shape
# the rule set's `tests/smoke_test.sh` uses — extracted for reference.
# Run after `tempo_install` is healthy.
#
# Assumes:
#   - kubectl on PATH, KUBECONFIG pointing at the cluster.
#   - Tempo installed in namespace `tempo`, release name `tempo`,
#     OTLP/HTTP receiver on 4318, query API on 3200.
set -euo pipefail

NS="${NS:-default}"
TEMPO_HOST="${TEMPO_HOST:-tempo.tempo.svc.cluster.local}"
TRACE_ID=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
SPAN_ID=$(head -c 8  /dev/urandom | od -An -tx1 | tr -d ' \n')
NOW_NS=$(( $(date +%s) * 1000000000 ))
END_NS=$(( NOW_NS + 1000000 ))

echo "[otlp_push] launching curl pod"
kubectl -n "$NS" run otlp-push --restart=Never --image=curlimages/curl:8.10.1 \
    --command -- sleep 300
trap 'kubectl -n "$NS" delete pod otlp-push --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
kubectl -n "$NS" wait pod/otlp-push --for=condition=Ready --timeout=60s

echo "[otlp_push] POSTing trace_id=$TRACE_ID"
PAYLOAD=$(cat <<EOF
{
  "resourceSpans": [{
    "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "demo"}}]},
    "scopeSpans": [{
      "scope": {"name": "demo-tracer"},
      "spans": [{
        "traceId": "${TRACE_ID}",
        "spanId": "${SPAN_ID}",
        "name": "demo-span",
        "kind": 1,
        "startTimeUnixNano": "${NOW_NS}",
        "endTimeUnixNano": "${END_NS}"
      }]
    }]
  }]
}
EOF
)

kubectl -n "$NS" exec otlp-push -- \
    curl -s -X POST -H 'Content-Type: application/json' \
    --data-binary "$PAYLOAD" \
    "http://${TEMPO_HOST}:4318/v1/traces"

echo "[otlp_push] GET /api/traces/${TRACE_ID}"
sleep 2
kubectl -n "$NS" exec otlp-push -- \
    curl -s "http://${TEMPO_HOST}:3200/api/traces/${TRACE_ID}" | head -c 500
echo
