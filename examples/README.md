# Examples

Reference push/query shapes for Tempo. Apply them after `tempo_install`
has the StatefulSet running.

| File | Use case | Exercised by smoke? |
|---|---|---|
| [`otlp_curl_push.sh`](otlp_curl_push.sh) | The minimal OTLP/JSON push round-trip — same shape as `tests/smoke_test.sh` but extracted for reading. POSTs a single span and reads it back via `/api/traces/<id>`. | Yes (the rule set's smoke uses this exact pattern) |
| [`otel_collector.yaml`](otel_collector.yaml) | OpenTelemetry Collector pod configured to receive OTLP from app workloads and forward to Tempo. The "real production" ingest shape — apps send to the local collector, collector batches and forwards to Tempo's central endpoint. | No |
| [`query_examples.sh`](query_examples.sh) | One-liners against Tempo's HTTP API: trace-by-id, search-by-tag, list available tags. | No (trace-by-id only is in the smoke) |

## Connecting from your own code

Inside the cluster, point your OpenTelemetry SDK / Collector at:

```
OTLP/gRPC:   tempo.tempo.svc.cluster.local:4317
OTLP/HTTP:   http://tempo.tempo.svc.cluster.local:4318/v1/traces
Query API:   http://tempo.tempo.svc.cluster.local:3200
```

Multitenancy is OFF in the smoke render — requests don't need an
`X-Scope-OrgID` header. If you flip `multitenancyEnabled: true` in
your values override, every push and query must carry the header.

## Things this directory deliberately does NOT show

- **Object-storage backends (S3, GCS, Azure Blob).** Each backend has
  its own auth flow; the smoke fixture uses `storage.trace.backend: local`.
- **Authentication.** Tempo accepts `X-Scope-OrgID` for multitenancy
  but doesn't have a built-in auth layer — production deployments
  put a gateway (nginx, Envoy) in front.
- **Grafana datasource wiring.** That's a Grafana concern, not
  Tempo's. See `rules_grafana` for examples of registering a
  datasource via Grafana's HTTP API.
- **Metrics-generator wiring.** Tempo can derive metrics from spans
  and remote-write them to a Prometheus-compatible target. v0.1
  smoke render has it disabled (`metricsGenerator.enabled: false`).
