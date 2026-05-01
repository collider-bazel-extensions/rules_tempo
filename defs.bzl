"""Public API for rules_tempo."""

load("@rules_kubectl//:defs.bzl", "kubectl_apply", "kubectl_apply_health_check")

# The single-binary `tempo` chart renders one StatefulSet — the release
# name (pinned to `tempo` at maintainer-render time). Pod runs all
# components (distributor + ingester + querier + query-frontend +
# compactor) in one process. No CRDs.
_TEMPO_DEPLOYS = []
_TEMPO_ROLLOUTS = [
    "sts/tempo",
]
_TEMPO_CRD = ""

def tempo_install(
        name,
        namespace = "tempo",
        wait_timeout = "300s",
        **kwargs):
    """Apply the pinned Tempo manifest into `namespace` and block until
    the single-binary StatefulSet's pod is Ready before idling.

    Drops into `itest_service.exe`. Wait timeout 300s — the
    `grafana/tempo` image is ~150MB and the pod boots quickly once
    pulled.
    """
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    kubectl_apply(
        name = name,
        manifests = ["@rules_tempo//private/manifests:tempo.yaml"],
        namespace = namespace,
        create_namespace = True,
        server_side = True,
        wait_for_deployments = list(_TEMPO_DEPLOYS) + list(extra_deploys),
        wait_for_rollouts = list(_TEMPO_ROLLOUTS) + list(extra_rollouts),
        wait_timeout = wait_timeout,
        **kwargs
    )

def tempo_health_check(
        name,
        namespace = "tempo",
        **kwargs):
    """Readiness probe paired with `tempo_install`."""
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    kubectl_apply_health_check(
        name = name,
        namespace = namespace,
        wait_for_deployments = list(_TEMPO_DEPLOYS) + list(extra_deploys),
        wait_for_rollouts = list(_TEMPO_ROLLOUTS) + list(extra_rollouts),
        **kwargs
    )
