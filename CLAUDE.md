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

**DB injection required:** The `maas-api` deployment does NOT have `DB_CONNECTION_URL` in its
env vars by default. Without it, `/v1/api-keys` returns 404. Patch it in from the
`maas-db-config` secret in `redhat-ods-applications`.

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

### EA2 → stable 3.4 upgrade leaves missing `maas` OCP Route

After upgrading from `3.4.0-ea.2` to `3.4.0` stable, the `maas-ui` sidecar in the dashboard
fails to discover the MaaS API and Gen AI studio / API keys / Authorization policies tabs do not
appear, even with `genAiStudio`, `modelAsService`, and `maasAuthPolicies` set to `true`.

**Root cause:** The `maas-ui` sidecar auto-discovers `https://maas.<cluster-domain>/maas-api` by
convention. The EA2 operator exposed the maas-api via an HTTPRoute through the MaaS gateway
(not via a plain OCP Route), so `maas.<cluster-domain>` never existed. The stable 3.4 operator
did not replace the EA2 resources because it saw their `platform.opendatahub.io/version: 3.4.0-ea.2` annotation.

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

### `maasAuthPolicies` dashboard flag

`oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge -p '{"spec":{"dashboardConfig":{"maasAuthPolicies":true}}}'`

Required in addition to `genAiStudio: true` and `modelAsService: true` to fully enable the MaaS
dashboard experience in RHOAI 3.4.

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

`gitops/instance/rhoai/values.yaml` defines two hardware profiles:
- `gpu-profile` — uses `scheduling.kueue` (references a LocalQueue named `default`). Currently
  inconsistent because `kueue: false` in the same file. Harmless for MaaS but will break
  workbench scheduling on that profile if Kueue is not installed.
- `nvidiaa10g-profile` — uses `scheduling.node` with `nvidia.com/gpu.product: NVIDIA-A10G`
  nodeSelector. Safe to use.

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
