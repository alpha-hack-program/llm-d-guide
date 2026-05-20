# CLAUDE.md — llm-d-guide project context

## What this repo is

Installation guide and GitOps manifests for **Red Hat OpenShift AI 3.4** (self-managed) with
**llm-d** and **Models-as-a-Service (MaaS)** on OpenShift Container Platform 4.21.
The canonical manual is [`README.md`](README.md); agent runbook is [`AGENTS.md`](AGENTS.md).

Target cluster: `apps.ocp.sandbox202.opentlc.com` (AWS, single AZ, GPU nodes A10G).

---

## Repo layout (key paths)

```
gitops/operators/          — OLM Subscriptions (kustomize or Helm)
gitops/instance/rhoai/     — DSCInitialization + DataScienceCluster + OdhDashboardConfig (Helm)
gitops/instance/llm-d/     — llm-d gateway + LLMInferenceService (Helm)
gitops/instance/maas/
  connectivity-link/       — Kuadrant CR in kuadrant-system (REQUIRED for MaaS)
  gateway/                 — maas-default-gateway in openshift-ingress (Helm)
  rbac/                    — OpenShift Groups for MaaS subscriptions
  database/                — MaaS API backing store
  monitoring/              — Grafana dashboards + Prometheus rules
```

All `gitops/instance/maas/*/run.sh` scripts use `set -x` so the expanded `helm template` command
is printed before the YAML output.

---

## MaaS — key facts and gotchas

### `modelsAsService` must be enabled AFTER the MaaS gateway is ready

`gitops/instance/rhoai/values.yaml` defaults to `modelsAsService: false`. Do NOT enable it during
Phase 3 (RHOAI install). The `maas-api` pod will not start until the `maas-default-gateway` exists
in `openshift-ingress`. Enabling it before the gateway is created leaves the DataScienceCluster
`Not Ready (modelsasservice)` with no maas-api pod.

**Correct order:**
1. Phase 3: apply `gitops/instance/rhoai` with `modelsAsService: false` (the default)
2. Phase 5 Step 1: deploy the MaaS gateway (`gitops/instance/maas/gateway`)
3. Phase 5 Step 2: deploy the MaaS database (`gitops/instance/maas/database`) — creates `maas-db-config` secret
4. Phase 5 Step 4: re-apply with `modelsAsService=true` — maas-api can now start because both gateway and db are ready:
   `helm template rhoai ./gitops/instance/rhoai --set modelsAsService=true | oc apply -f -`

### Kuadrant CR is mandatory

The RHCL operator installs CRDs but does **not** deploy Authorino or Limitador pods until a
`Kuadrant` CR exists in `kuadrant-system`. Without it, `AuthPolicy` and `TokenRateLimitPolicy`
resources are created by `maas-api` but never translated into `AuthConfig` — auth is silently
unenforced.

Apply: `helm template gitops/instance/maas/connectivity-link --name-template maas-connectivity-link | oc apply -f -`

Verify: `oc get kuadrant -n kuadrant-system` must show `Ready: True`.

### Kuadrant `MissingDependency` on OCP 4.19+

The Kuadrant operator may start with `Ready: False` and message:
> `[Gateway API provider (istio / envoy gateway)] is not installed`

On OCP 4.19+, no Service Mesh or Envoy Gateway install is needed — the OCP built-in Gateway API
controller is sufficient. The operator detects it on startup. Fix: delete the operator pod to
force a restart.

```bash
oc delete pod -n openshift-operators -l app.kubernetes.io/name=kuadrant-operator
```

### Gateway `allowedRoutes` — model namespaces

The `maas-default-gateway` listener uses a namespace `Selector`. Every namespace containing
MaaS-published `LLMInferenceService` resources must be explicitly allowed, or HTTPRoutes will be
rejected with `NotAllowedByListeners` and the service stays `Ready: False`.

Add namespaces via `--set "gateway.modelNamespaces={ns1,ns2}"` when re-applying the gateway chart:

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
helm template gitops/instance/maas/gateway --name-template maas-gateway \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --set useOpenShiftRoute=true \
  --set tls.secretName=ingress-certs \
  --set limitador.exhaustiveTelemetry=false \
  --set telemetry.enabled=false \
  --set "gateway.modelNamespaces={llm-d-demo}" | oc apply -f -
```

Currently allowed model namespaces: `llm-d-demo`.

### Only llm-d runtime supports MaaS

`Publish as MaaS endpoint` in Advanced settings is only available when **Distributed inference
with llm-d** is selected as the serving runtime. vLLM standalone and other runtimes do not expose
this option.

### `LLMInferenceService` API version

The inference chart (`gitops/instance/llm-d/inference`) generates `apiVersion: serving.kserve.io/v1alpha2`.
The RHOAI dashboard edit form uses the API version in `last-applied-configuration` to build its
UI; resources applied with `v1alpha1` will not show the MaaS toggle or other advanced fields.

### Re-applying LLMInferenceService drops unlisted env vars

`oc apply` uses strategic merge patch. For `LLMInferenceService`, the `env` list on the main
container is **replaced**, not merged — any env var absent from the rendered YAML is removed from
the live resource. This includes `VLLM_ADDITIONAL_ARGS`.

**Fix:** use a per-model values file (e.g. `qwen3-8b-values.yaml`) that includes `vllmAdditionalArgs`
and always pass it with `-f` on every `helm template … | oc apply`:

```bash
helm template gitops/instance/llm-d/inference --name-template inference \
  -n llm-d-demo \
  -f gitops/instance/llm-d/inference/qwen3-8b-values.yaml \
  | oc apply -n llm-d-demo -f -
```

Per-model values files live alongside `values.yaml` in `gitops/instance/llm-d/inference/`.
Current files: `qwen3-8b-values.yaml`.

### GPU update strategy — not configurable via CRD

The `LLMInferenceService` CRD does not expose an update strategy field. The operator controls the
underlying Deployments: the scheduler Deployment is always `Recreate`; the main workload
Deployment is always `RollingUpdate`. This cannot be changed via the LLMInferenceService spec.
The `updateStrategy` value in the inference chart is wired up but currently no-op (silently
dropped by the API server).

### Authorino TLS is mandatory for the MaaS API key endpoint

Without Authorino TLS, `POST /maas-api/v1/api-keys` returns `500 Internal Server Error`. The
Envoy proxy (via `kuadrant-auth-maas-default-gateway` EnvoyFilter) connects to Authorino's gRPC
port 50051. Once TLS is enabled on Authorino, Envoy must also use TLS — but that TLS cluster
config is only applied when the maas-controller creates the `maas-default-gateway-authn-ssl`
EnvoyFilter in response to the `security.opendatahub.io/authorino-tls-bootstrap: "true"` gateway
annotation.

**Critical ordering:** The gateway annotation must be applied (or removed and re-applied) AFTER
Authorino TLS is configured. The maas-controller creates the TLS EnvoyFilter only in reaction to
an annotation change event. If the annotation was already present before TLS was enabled, the
filter will not exist and all auth calls will fail with 500.

Steps (in order):
1. Annotate `authorino-authorino-authorization` service with `service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert`
2. Patch Authorino CR: `spec.listener.tls.enabled: true` with `certSecretRef.name: authorino-server-cert`
3. Set `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` env vars on the `authorino` deployment
4. Remove then re-add `security.opendatahub.io/authorino-tls-bootstrap="true"` on the gateway

Verify the TLS EnvoyFilter exists: `oc get envoyfilter maas-default-gateway-authn-ssl -n openshift-ingress`

### MaaS subscription stack — `models-as-a-service` namespace required

MaaS uses `Tenant`, `MaaSModelRef`, `MaaSSubscription`, and `MaaSAuthPolicy` CRs. All live in
the `models-as-a-service` namespace. The maas-controller watches this namespace but does nothing
until the namespace and a `Tenant` CR named exactly `default-tenant` exist.

**Database is a hard prerequisite — deploy before enabling `modelsAsService`:** The `maas-api`
pod will not start without a `maas-db-config` Secret in `redhat-ods-applications` containing
`DB_CONNECTION_URL`. On a clean install this secret does **not** exist until the database chart
is applied (`gitops/instance/maas/database`). The maas-controller checks for this secret when
reconciling the `default-tenant` CR and reports `PrerequisitesNotMet` until it exists. Always
deploy the database (Phase 5 Step 2) before enabling `modelsAsService` (Phase 5 Step 4).

**DB injection (EA2 → stable migration only):** After upgrading from `3.4.0-ea.2` to `3.4.0`
stable the `maas-api` Deployment may additionally lack the `DB_CONNECTION_URL` env var reference
(not just the secret) because the stable operator did not re-reconcile the EA2 Deployment. Without
it `/v1/api-keys` returns 404. Patch it in from the `maas-db-config` secret (see `PATCH-MAAS.md §3`).

**MaaSAuthPolicy status bug:** The maas-controller successfully creates Kuadrant `AuthPolicy` and
`TokenRateLimitPolicy` resources, but fails to update the `MaaSAuthPolicy` status subresource
(controller writes `accepted`/`enforced` fields; CRD requires `ready`). This is a controller/CRD
version mismatch — log shows `"failed to update MaaSAuthPolicy status"` in a tight loop but is
functionally harmless. Auth and rate limits work correctly.

**Currently deployed MaaS 3.4 resources:**
- Namespace: `models-as-a-service`
- Tenant: `default-tenant` (90-day key expiration)
- MaaSModelRefs: `qwen3-8b` and `opt-125m` in `llm-d-demo`
- MaaSSubscription: `free-tier-subscription` (groups: `cluster-admins`, `tier-free-users`)
- MaaSAuthPolicy: `free-tier-auth-policy` (same groups and models)

### Token rate limiting

Limits are defined in `MaaSSubscription.spec.modelRefs[].tokenRateLimits` and translated by the
maas-controller into Kuadrant `TokenRateLimitPolicy` resources in the model namespace. Limitador
counts tokens **per user** (`auth.identity.userid`) from each response's usage metadata.

Key rules:
- Window units: `s`, `m`, `h` only — `d` is not supported, use `24h`
- Multiple windows per model are supported (e.g. burst + daily)
- Different limits per group → separate `MaaSSubscription` objects
- A user in multiple subscriptions picks one via `x-maas-subscription` request header
- The maas-controller reconciles `TokenRateLimitPolicy` immediately on `MaaSSubscription` change

Current limits: `qwen3-8b` → 100k tokens/h, `opt-125m` → 200k tokens/h (both: `cluster-admins` + `tier-free-users`).

Check: `oc get tokenratelimitpolicy -n llm-d-demo`

### `maas-ui` sidecar 500 errors — wrong gateway hostname (fresh installs)

The `maas-ui` sidecar in the dashboard returns 500 errors on all API keys / authorization policies
pages. Sidecar logs show: `statusCode=503 endpoint=https://maas.<cluster-domain>/maas-api/... invalid character '<'`.

**Root cause:** The gateway chart had a bug — when `useOpenShiftRoute=true` the listener hostname
and OCP Route host were both set to `maas-default-gateway-openshift-ingress.<cluster-domain>`, but
the `maas-ui` sidecar always calls `maas.<cluster-domain>/maas-api/...` (using `subdomain: "maas"`).
The ingress returned an HTML 503 for the unknown hostname, which the sidecar tried to JSON-parse.

**Fix (applied in chart):** `gateway.yaml` and `route.yaml` now always use `subdomain.<clusterDomain>`
regardless of `useOpenShiftRoute`. Re-apply the gateway chart to update both the Gateway listener
and the OCP Route to `maas.<cluster-domain>`.

On EA2 → stable upgrades: same symptom but additional cause — the EA2 operator exposed maas-api
via an HTTPRoute (not an OCP Route), and the stable operator skipped reconciling those resources
due to their `platform.opendatahub.io/version: 3.4.0-ea.2` annotation. Re-applying the gateway
chart fixes this as well.

**Fix:** Create the missing OCP Route manually and restart the dashboard:

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
cat <<EOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: maas
  namespace: redhat-ods-applications
  labels:
    app.kubernetes.io/part-of: models-as-a-service
    app.opendatahub.io/modelsasservice: "true"
spec:
  host: maas.${CLUSTER_DOMAIN}
  to:
    kind: Service
    name: maas-api
    weight: 100
  port:
    targetPort: https
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
EOF
oc rollout restart deployment/rhods-dashboard -n redhat-ods-applications
```

Verify: `curl -sk https://maas.${CLUSTER_DOMAIN}/health` should return `{"status":"healthy"}`.

### MaaS dashboard flags

Four `OdhDashboardConfig` flags must all be `true` for the full MaaS dashboard experience:

| Flag | Effect |
|---|---|
| `genAiStudio` | Gen AI studio section (not MaaS-exclusive) |
| `modelAsService` | MaaS model serving toggle |
| `maasAuthPolicies` | Settings → Authorization policies tab |
| `vLLMDeploymentOnMaaS` | Gen AI studio → API keys tab |

```bash
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge \
  -p '{"spec":{"dashboardConfig":{"genAiStudio":true,"modelAsService":true,"maasAuthPolicies":true,"vLLMDeploymentOnMaaS":true}}}'
```

The chart (`gitops/instance/rhoai/templates/odh-dashboard-config.yaml`) sets all four
automatically: `genAiStudio` is always `true`; the other three follow the `modelsAsService`
values toggle.

### Kueue is NOT required for MaaS

Kueue is disabled (`kueue: false`) in `gitops/instance/rhoai/values.yaml`. MaaS uses Kuadrant
(Authorino + Limitador) for policy enforcement, not Kueue. Do not enable Kueue unless you
specifically need distributed workload scheduling — it causes namespace label conflicts.

---

## Connectivity Link (RHCL) install location

The RHCL operator subscription is in `openshift-operators` (all-namespaces mode), not in a
dedicated `kuadrant-system` namespace. The `kuadrant-system` namespace is created by the
`Kuadrant` CR in `gitops/instance/maas/connectivity-link`.

---

## Hardware profiles

`gitops/instance/rhoai/values.yaml` defines three hardware profiles:
- `gpu-profile` — generic GPU, `scheduling.type: Node` with only a GPU toleration. No Kueue
  dependency, no product-specific nodeSelector. Safe for any NVIDIA GPU when Kueue is not installed.
- `gpu-kueue-profile` — GPU profile that uses `scheduling.type: Queue` (Kueue LocalQueue). The
  chart template gates this on the global `kueue: true` toggle; when `kueue: false` it silently
  falls back to Node scheduling. Only use this profile when Kueue is installed and a LocalQueue
  named `default` exists in the workload namespace.
- `nvidia-a10g-profile` — `scheduling.type: Node` with `nodeSelector: nvidia.com/gpu.product: NVIDIA-A10G`
  plus a GPU toleration. Use when the cluster has mixed GPU types and you need to pin to A10G nodes.
  This is the profile referenced in `gitops/instance/llm-d/inference/qwen3-8b-values.yaml`.

---

## Quick health checks

```bash
# MaaS core
oc get kuadrant -n kuadrant-system
oc get pods -n kuadrant-system
oc get pods -n redhat-ods-applications -l app.kubernetes.io/name=maas-api
oc get gateway maas-default-gateway -n openshift-ingress
oc get authconfig -A

# MaaS 3.4 subscription stack
oc get tenant,maasmodelref,maassubscription,maasauthpolicy -A
oc get envoyfilter maas-default-gateway-authn-ssl -n openshift-ingress  # TLS filter
oc get authpolicy,tokenratelimitpolicy -n llm-d-demo                    # Kuadrant policies

# Authorino TLS
oc get authorino authorino -n kuadrant-system -o jsonpath='{.spec.listener.tls.enabled}'
oc get secret authorino-server-cert -n kuadrant-system

# All inference services
oc get llminferenceservice -A

# Operator health
oc get csv -A | grep -v Succeeded
```
