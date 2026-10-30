# rules_tempo

Hermetic [Grafana Tempo](https://grafana.com/oss/tempo/) install for Bazel
test compositions. Pure glue layer over
[`rules_kubectl`](https://github.com/collider-bazel-extensions/rules_kubectl) —
`tempo_install` is a macro emitting a `kubectl_apply` target pre-configured
with Tempo's pinned manifest and the right wait shape.

```python
load("@rules_tempo//:defs.bzl", "tempo_install", "tempo_health_check")

tempo_install(name = "tempo_install_bin")          # default ns: tempo
tempo_health_check(name = "tempo_health_bin")
```

That's the whole API. Tempo is a distributed tracing backend — ingest
via OTLP / Jaeger / Zipkin, query via Tempo's HTTP API. This rule set
installs Tempo in single-binary mode (one StatefulSet, all components
in one process) ready for trace push/query traffic.

**Pinned versions:** Grafana `tempo` helm chart `1.24.4` (Tempo app
`2.9.0`). Smoke-fixture render — single replica, `local` filesystem
trace storage, multitenancy off, anonymous-usage reporting off, OTLP
receiver enabled (gRPC `:4317` and HTTP `:4318`). The values file is
exported as `@rules_tempo//config:tempo-values.yaml` for inspection /
extension. Production deployments override storage / replica /
receiver fields.

> **Chart deprecation note.** The single-binary `tempo` chart is marked
> deprecated upstream — Grafana's recommended path for new deployments
> is the `tempo-distributed` chart. The single-binary chart still works
> (and is the right shape for a smoke fixture), but a future
> `rules_tempo` v0.2 may switch to `tempo-distributed`. See DESIGN.md.

**Supported platforms (v0.1):** any platform where rules_kubectl runs.
Validated on Linux x86\_64 in CI.

---

## Contents

- [Installation](#installation) (Bzlmod-only)
- [Quickstart](#quickstart)
- [Pushing + querying traces](#pushing--querying-traces)
- [Macros](#macros)
- [Hermeticity exceptions](#hermeticity-exceptions)
- [Contributing](#contributing)

---

## Installation

```python
bazel_dep(name = "rules_tempo", version = "0.1.0")
```

Bzlmod-only. Transitively pulls in
[`rules_kubectl`](https://github.com/collider-bazel-extensions/rules_kubectl).

---

## Quickstart

```python
load("@rules_itest//:itest.bzl", "itest_service", "service_test")
load("@rules_kind//:defs.bzl", "kind_cluster", "kind_health_check")
load("@rules_tempo//:defs.bzl", "tempo_install", "tempo_health_check")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

# 1. Cluster.
kind_cluster(name = "cluster", k8s_version = "1.35")
kind_health_check(name = "cluster_health", cluster = ":cluster")
itest_service(name = "kind_svc", exe = ":cluster", health_check = ":cluster_health")

# 2. Tempo.
tempo_install(name = "tempo_install_bin")
tempo_health_check(name = "tempo_health_bin")
sh_binary(name = "tempo_install_wrapper", srcs = ["install_wrapper.sh"], data = [":tempo_install_bin"])
sh_binary(name = "tempo_health_wrapper",  srcs = ["health_wrapper.sh"],  data = [":tempo_health_bin"])

itest_service(
    name = "tempo_svc",
    exe = ":tempo_install_wrapper",
    deps = [":kind_svc"],
    health_check = ":tempo_health_wrapper",
)

# 3. Your push/query workload — see `examples/` for shapes.
```

`install_wrapper.sh` / `health_wrapper.sh` are ~20-line shims — see
`tests/install_wrapper.sh` for the canonical shape (sources kind's env
file under `set -a`, exec's the rule binary).

---

## Pushing + querying traces

Once Tempo is up, the in-cluster Service `tempo.<namespace>.svc.cluster.local`
exposes both the OTLP receiver (port `4318` for HTTP, `4317` for gRPC)
and Tempo's query API (port `3200`).

The simplest pattern (which `tests/smoke_test.sh` uses): hand-craft an
OTLP/JSON trace and POST it from a curl pod, then GET it back via the
trace-by-id API:

```bash
# Push a trace (OTLP/HTTP, JSON body).
curl -X POST -H 'Content-Type: application/json' \
    --data-binary @trace.json \
    http://tempo.tempo.svc.cluster.local:4318/v1/traces

# Fetch it back.
curl http://tempo.tempo.svc.cluster.local:3200/api/traces/<traceId>
```

For real workloads, point your OpenTelemetry SDK / Collector at
`tempo.tempo.svc.cluster.local:4317` (gRPC) or `:4318` (HTTP). See
[`examples/`](examples/) for an OpenTelemetry Collector config.

---

## Macros

### `tempo_install`

```python
tempo_install(
    name = "tempo_install_bin",
    namespace = "tempo",        # default
    wait_timeout = "300s",      # default
)
```

Expands to a `kubectl_apply(...)` target that:

- Applies `@rules_tempo//private/manifests:tempo.yaml`.
- `create_namespace = True` (default `tempo`).
- `server_side = True`.
- `wait_for_rollouts = ["sts/tempo"]` — the single-binary StatefulSet.
- `wait_timeout = "300s"` — the `grafana/tempo` image is ~150MB.

Drops into `itest_service.exe`.

### `tempo_health_check`

```python
tempo_health_check(name = "tempo_health_bin", namespace = "tempo")
```

Drops into `itest_service.health_check`. Same wait shape with
`--timeout=0s`.

---

## Hermeticity exceptions

| Component | Status | Notes |
|---|---|---|
| Tempo manifest | Fully hermetic. URL + sha256 pinned in `tools/versions.bzl`; pre-rendered + committed. | Re-render via `bash tools/render_tempo.sh <ver>`. |
| `kubectl` | Inherited from `rules_kubectl`. | |
| Target cluster | Out of scope. | |
| Tempo container image | Pulled at runtime by the cluster's nodes. `docker.io/grafana/tempo:2.9.0`. | Future: pre-load via `kind_cluster.images`. |

---

## Contributing

PRs welcome. Conventions match the sibling rule sets:

- New rules need an analysis test in `tests/analysis_tests.bzl`.
- Bumping the pinned chart version: edit `tools/versions.bzl`, add a
  `helm_template + sh_binary` block in `tools/BUILD.bazel`, run
  `bash tools/render_tempo.sh <new-version>`, commit.
- `MODULE.bazel.lock` is intentionally not committed.

### Help wanted

- macOS validation
- Pivot to `tempo-distributed` (the non-deprecated chart) — different
  shape (multiple Deployments + StatefulSets), needs a new wait
  matrix; v0.2 candidate
- Compose with [`rules_grafana`](https://github.com/collider-bazel-extensions/rules_grafana) to register Tempo as a datasource and query via Grafana's API
- Object-storage backend smoke (S3/GCS/Azure via a `minio` or
  `rules_minio` fixture)
- Multi-tenant smoke (turn `multitenancyEnabled: true`; verify per-tenant isolation)
- Jaeger / Zipkin receiver smoke (chart already exposes the ports;
  smoke just needs to pivot the protocol)
- TraceQL search smoke (`/api/search`) — currently the smoke only
  exercises trace-by-id lookup
