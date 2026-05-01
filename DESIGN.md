# rules_tempo — design decisions

Hermetic [Grafana Tempo](https://grafana.com/oss/tempo/) install for
Bazel test compositions. Same shape as `rules_loki` / `rules_grafana` /
`rules_harbor` / `rules_external_secrets` / `rules_kafka` — pure glue
over `rules_kubectl` + `rules_helm`.

## Decided

| # | Decision | Choice | Source |
|---|---|---|---|
| 1 | Bzlmod / WORKSPACE | **Bzlmod-only at v0.1.** | Sibling-family |
| 2 | Module / repo name | `rules_tempo`. | Convention |
| 3 | Architecture | **Layered.** Two macros wrapping `kubectl_apply` / `kubectl_apply_health_check`. | rules_loki / rules_grafana / rules_harbor / rules_external_secrets / rules_kafka |
| 4 | Manifest provisioning | Grafana's `tempo` (single-binary) helm chart **pre-rendered** into `private/manifests/tempo.yaml` via `rules_helm`. Committed. | rules_loki pattern |
| 5 | Single-binary vs. distributed | **Single-binary** (`tempo` chart) at v0.1. The `tempo-distributed` chart matches Mimir's shape (~5 Deployments + 3 StatefulSets, internal-replication knobs to tune); the single-binary chart is one StatefulSet running all components in one process — strictly simpler for a smoke fixture. See "Single-binary vs. distributed" below. | Smaller smoke surface |
| 6 | Single-version | One pinned chart (`1.24.4`, Tempo app `2.9.0`). Multi-version is the rules_cloudnativepg pattern; add it if a real consumer wants two versions side-by-side. | Pragmatic |
| 7 | Render mode | **Smoke fixture.** `replicas: 1`, `local` filesystem trace storage, multitenancy off, anonymous-usage reporting off, persistence off (emptyDir), serviceMonitor off, OTLP receiver only (jaeger/opencensus rendered as defaults but unused — Helm's deep-merge keeps them around). README warns the values are not a production starting point. | Smoke pragmatic |
| 8 | Public surface | `tempo_install`, `tempo_health_check`. **No `tempo_tenant` rule** — tenants are HTTP headers (`X-Scope-OrgID`), not k8s objects; consumers control them at request time. | Smaller surface |
| 9 | Namespace | `tempo` (default, idempotent create). | Convention |
| 10 | Wait shape | One StatefulSet (`tempo`) — single-binary mode. No CRDs (Tempo doesn't ship any). | Tempo single-binary specific |
| 11 | Smoke client | **`kubectl run` a curl pod.** OTLP/HTTP accepts JSON bodies, so a hand-crafted JSON trace + curl POST is the lightest-weight client. No OpenTelemetry SDK pod, no collector — keeps the wire format visible in the smoke. | Pragmatic |
| 12 | Smoke assertion | Generate a random 16-byte trace ID + 8-byte span ID. POST an OTLP/JSON trace at `tempo:4318/v1/traces` (one resource, one scope, one span with a unique marker attribute). Poll `tempo:3200/api/traces/<traceId>` until 200 OK. Assert the response body contains both the trace ID and the marker attribute we sent. Proves OTLP receiver + distributor + ingester (write path) + queryFrontend + querier (read path) — **not** "Tempo pod is up." | Per the family's "exercise the functionality" rule |
| 13 | Cross-rule deps | `rules_kubectl` public dep. `rules_helm` + `rules_kind` + `rules_itest` + `rules_shell` dev-only. | rules_loki precedent |
| 14 | Naming | snake_case rules/macros, `MixedCaseInfo` providers (none in v0.1), `UPPER_SNAKE` constants. | All siblings |
| 15 | Update workflow | `bash tools/render_tempo.sh <chart-version>` → thin shim. | rules_loki precedent |

## Single-binary vs. distributed

Two paths to install Tempo. They both work, they match different family shapes:

- **`tempo` (single-binary)** — one container running all Tempo
  components (distributor + ingester + querier + query-frontend +
  compactor) in one process. One StatefulSet, one Service, one
  ConfigMap. Designed for "ops-light" deployments and as the test
  fixture for downstream consumers.
- **`tempo-distributed`** — full microservice topology with separate
  Deployments per component, plus optional memcached/Redis caches.
  Production scale, but matches Mimir's shape (and brings Mimir's
  set of single-replica gotchas: internal topic replication factors,
  query-scheduler dependencies, etc.).

v0.1 picks **single-binary** because:

1. It's structurally simpler — one wait target, no internal config
   knobs around replication, no scheduler vs. direct-querier
   topology choice.
2. The chart's defaults map cleanly to "smoke fixture" with a few
   overrides (single replica, local filesystem, telemetry off).
3. The smoke's value-add (OTLP push round-trip) is identical between
   the two shapes — distributed adds no additional protocol or API
   surface to test.

> **Caveat:** Grafana marks the `tempo` chart deprecated upstream
> (latest version 1.24.4 carries `deprecated: true` in the Helm
> index). Functionally fine — it still pulls Tempo 2.9.0 and works
> as advertised. But future Tempo releases may not get a
> single-binary chart, and users should expect a migration to
> `tempo-distributed` at some point. v0.1's pin will keep working;
> a future v0.2 may pivot.

## Why OTLP/JSON, not Jaeger / Zipkin / OTLP-gRPC

OTLP is Tempo's #1 ingestion path — it's the OpenTelemetry standard
and what almost all modern instrumentation emits. The HTTP variant
accepts JSON bodies, which means we can hand-craft the wire payload
in a shell heredoc instead of needing a tracing SDK / collector pod.
That's the lightest possible smoke client.

The Tempo wire-format JSON for traces is OTLP's `ExportTraceServiceRequest`:
```json
{
  "resourceSpans": [{
    "resource": {"attributes": [...]},
    "scopeSpans": [{
      "scope": {"name": "..."},
      "spans": [{
        "traceId": "<32 hex chars>",
        "spanId": "<16 hex chars>",
        "name": "...",
        "kind": <int>,
        "startTimeUnixNano": "...",
        "endTimeUnixNano": "..."
      }]
    }]
  }]
}
```

Trace IDs are 16 random bytes (32 hex chars); span IDs are 8 bytes
(16 hex chars). The smoke generates them from `/dev/urandom`.
Tempo accepts hex or base64 — JSON-over-HTTP convention is hex.

Alternatives considered:
- **Jaeger thrift HTTP (port 14268).** Would need a Jaeger client to
  produce thrift; not shell-friendly.
- **Zipkin HTTP (port 9411).** JSON-friendly but Zipkin's wire format
  is a separate spec from what Tempo's other receivers use; less
  representative of "real Tempo deployments."
- **OTLP/gRPC.** Same payload shape but binary protobuf; needs a
  client to serialize. JSON over HTTP is strictly more shell-portable.

## Receivers — what's enabled and what's disabled

The chart's default `tempo.receivers` block enables jaeger (4 protocol
variants), opencensus, and otlp (gRPC + HTTP) — every receiver Tempo
supports. The smoke only uses OTLP.

The values file overrides `tempo.receivers` to an OTLP-only block,
**but Helm's deep-merge against the chart's defaults keeps the jaeger
and opencensus fields around** (`opencensus: null`, jaeger fully
populated). Tempo binds those ports too; resource cost is negligible
on a single-replica smoke fixture, so the rendered manifest leaves
them alone. To produce a strict OTLP-only render, override each
receiver to `null` explicitly:
```yaml
tempo:
  receivers:
    jaeger: null
    opencensus: null
    otlp:
      protocols: { grpc: ..., http: ... }
```
Not done in v0.1 — adds noise without changing what's tested.

## v0.1.0 status

| Area | State |
|---|---|
| MODULE.bazel (Bzlmod-only) | done |
| `tempo_install` + `tempo_health_check` macros | done |
| Pinned `tempo` chart 1.24.4 (rendered + committed) | done |
| `config/tempo-values.yaml` (exported) | done |
| Maintainer render flow (`bash tools/render_tempo.sh <ver>`) | done |
| Analysis test | done |
| Smoke (kind + Tempo + OTLP/JSON push + trace-by-id round-trip) | done |
| `examples/` (OTLP curl, OpenTelemetry Collector, query API) | done |

## Deferred (not v0.1.0)

- **Pivot to `tempo-distributed`** — chart is non-deprecated; matches
  the Mimir shape. Adds wait matrix + replication-factor overrides.
  Either v0.2 of this rule set or a separate `rules_tempo_distributed`.
- **Object-storage backend smoke** (S3 / GCS / Azure) — switch
  `storage.trace.backend` away from `local`, compose a `minio` (or
  `rules_minio`) fixture. v0.2 candidate.
- **Multi-tenant smoke** — flip `multitenancyEnabled: true`; push +
  query under two tenants; assert isolation.
- **TraceQL search smoke** (`/api/search`) — v0.1 only exercises
  trace-by-id lookup. TraceQL adds a query language; smoke could
  search by attribute.
- **Jaeger / Zipkin receiver smoke** — chart already exposes the
  ports. Smoke would need to pivot the wire protocol; chart values
  don't change.
- **Compose with `rules_grafana`** — Grafana queries Tempo as a
  datasource. Cross-rule composition smoke (modeled on rules_mimir
  + rules_kafka).
- **Multi-version chart support** — single pin in v0.1.
- **Metrics-generator smoke** — Tempo can derive metrics from spans
  (service graphs, span metrics). Smoke would need a Mimir/Prometheus
  remote-write target + a real workload generating spans. v0.2
  candidate, possibly composed with rules_mimir.
