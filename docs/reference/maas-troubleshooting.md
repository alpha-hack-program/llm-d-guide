# MaaS — Key Facts and Gotchas

> Part of the [llm-d-guide Co-pilot Runbook]](../../AGENTS.md). Reference material for
> [Phase 6 — MaaS](../phases/06-maas.md).

## `modelsAsService` ordering

`gitops/instance/rhoai/values.yaml` defaults to `modelsAsService: false`. Do NOT enable it during
Phase 3. The `maas-api` pod requires both the MaaS gateway AND the `maas-db-config` Secret before
it can start. Correct order: gateway (Phase 6 Step 1) → database (Phase 6 Step 2) → enable
`modelsAsService=true` (Phase 6 Step 3).

## Kuadrant CR is mandatory

The RHCL operator installs CRDs but does **not** deploy Authorino or Limitador until a `Kuadrant`
CR exists in `kuadrant-system`. Without it, `AuthPolicy` and `TokenRateLimitPolicy` resources are
created but never translated into `AuthConfig` — auth is silently unenforced.

Apply: `helm template gitops/instance/maas/connectivity-link --name-template maas-connectivity-link | oc apply -f -`

Verify: `oc get kuadrant -n kuadrant-system` must show `Ready: True`.

## Kuadrant `MissingDependency` on OCP 4.19+

If the Kuadrant CR stays `Ready: False` with `[Gateway API provider (istio / envoy gateway)] is not installed`:
on OCP 4.19+ the OCP built-in Gateway API controller is sufficient — no Service Mesh needed. Delete
the operator pod to force a restart and let it detect the built-in controller:

```bash
oc delete pod -n openshift-operators -l app.kubernetes.io/name=kuadrant-operator
```

## Gateway `allowedRoutes` — model namespaces

Every namespace containing MaaS-published models must be in the gateway's `allowedRoutes` selector,
or HTTPRoutes are rejected with `NotAllowedByListeners`. Add namespaces via:

```bash
helm template gitops/instance/maas/gateway --name-template maas-gateway \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --set useOpenShiftRoute=true \
  --set tls.secretName=ingress-certs \
  --set "gateway.modelNamespaces={llm-d-demo,other-ns}" | oc apply -f -
```

## MaaSModelRef must exist before subscriptions

The `MaaSSubscription` controller resolves model references at creation time. If the `MaaSModelRef`
is missing, subscriptions enter `Failed` phase immediately. The inference chart
(`gitops/instance/llm-d/inference`) creates the `MaaSModelRef` automatically when `maas.enabled=true`.
For a clean-slate reset, re-apply with `--set maas.enabled=true` before creating subscriptions.

## Subscription management UI only shows published models

The RHOAI dashboard "Add models" dialog in subscription management queries existing `MaaSModelRef`
objects — not raw `LLMInferenceService` resources. A model must be published (MaaSModelRef created)
before it appears in the subscription picker. There is no way to create a MaaSModelRef from the
subscription page itself; use the model deployment page's **Publish as MaaS endpoint** toggle, or
set `maas.enabled=true` in the inference chart.

## Authorino TLS is mandatory for the API key endpoint

Without Authorino TLS, `POST /maas-api/v1/api-keys` returns `500`. The gateway annotation must be
applied (or removed and re-applied) **after** Authorino TLS is configured — the maas-controller
creates the `maas-default-gateway-authn-ssl` EnvoyFilter only in reaction to an annotation change.

Steps in order:
1. Annotate the Authorino service with `service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert`
2. Patch Authorino CR: `spec.listener.tls.enabled: true` with `certSecretRef.name: authorino-server-cert`
3. Set `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` env vars on the `authorino` deployment
4. Remove then re-add the gateway annotation: `security.opendatahub.io/authorino-tls-bootstrap="true"`

Verify: `oc get envoyfilter maas-default-gateway-authn-ssl -n openshift-ingress`

## Token rate limiting — rules and schema

**Rules:**
- Window units: `s`, `m`, `h` only — `d` is not supported, use `24h`
- Multiple windows per model are supported (e.g. burst + daily)
- Different limits per group → separate `MaaSSubscription` objects
- A user in multiple subscriptions selects one via the `x-maas-subscription` request header
- The maas-controller reconciles `TokenRateLimitPolicy` immediately on `MaaSSubscription` change

**Correct schema:**
```yaml
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: example-subscription
  namespace: models-as-a-service
spec:
  owner:
    groups:
    - name: my-group          # Object with 'name' field, NOT bare string
  modelRefs:
  - name: model-name
    namespace: model-namespace
    tokenRateLimits:          # REQUIRED field (list of window/limit pairs)
    - window: 1h              # Burst limit
      limit: 100
    - window: 24h             # Daily limit
      limit: 1000
```

**Common errors:**
- `groups: ["my-group"]` → `groups: [{name: "my-group"}]`
- `tokenRateLimitPolicy.daily: 1000` → `tokenRateLimits: [{window: "24h", limit: 1000}]`
- `window: 1d` → `window: 24h` (days not supported)
- Missing `tokenRateLimits` → API rejects with "Required value"

## Token rate limiting does not support streaming requests

`TokenRateLimitPolicy` only counts tokens from non-streaming responses (`stream: false` or
omitted). It cannot inspect an SSE response body, so streaming requests bypass token counting
entirely — the quota is not decremented and limits are not enforced per-token for `stream: true`.

**Symptom:** A user whose token quota is exhausted sends a streaming request (`stream: true`).
The gateway returns HTTP 200 with `content-type: text/event-stream` but then hangs — no SSE
chunks are ever sent and the connection must be closed by the client. The same request with
`stream: false` correctly returns HTTP 429 `Too Many Requests`.

**Root cause:** This is a documented Kuadrant limitation. The `TokenRateLimitPolicy` enforcer
reads `usage.total_tokens` from the response body after the call completes. For streaming
responses the body arrives in chunks and the final usage field is not available upfront, so
token counting is skipped. Once the quota is already exceeded from prior non-streaming calls,
the gateway has no mechanism to surface a 429 inside an already-opened SSE stream.

**Workaround:** Enforce rate limits using the standard request-count `RateLimitPolicy` (not
`TokenRateLimitPolicy`) for users who primarily use streaming. Token-based limits only apply
reliably to `stream: false` calls.

**Reference:** [Kuadrant TokenRateLimitPolicy docs](https://docs.kuadrant.io/1.3.x/kuadrant-operator/doc/overviews/token-rate-limiting/) — streaming support is planned for a future release.

## `maas-ui` sidecar 500 errors — wrong gateway hostname

Symptom: API keys / authorization policies pages fail; sidecar logs show
`statusCode=503 ... invalid character '<'`. The OCP Route host must be exactly `maas.<cluster-domain>`.
Fix: re-apply the gateway chart (hostname is now always set to `subdomain.<clusterDomain>`).

Check: `oc get route -n openshift-ingress -l app.opendatahub.io/modelsasservice=true -o jsonpath='{.items[0].spec.host}'`

## MaaS dashboard flags

All four `OdhDashboardConfig` flags must be `true`:

```bash
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge \
  -p '{"spec":{"dashboardConfig":{"genAiStudio":true,"modelAsService":true,"maasAuthPolicies":true,"vLLMDeploymentOnMaaS":true}}}'
```

The inference chart sets these automatically when `modelsAsService=true` in the RHOAI values.

## MaaSAuthPolicy subjects must match MaaSSubscription owner groups

`MaaSSubscription` controls which groups are **entitled** to a model (rate limits, billing tier).
`MaaSAuthPolicy` controls which groups are **permitted** at the gateway (Authorino enforcement).
Both must cover the same groups for a model — a mismatch causes the model to be silently omitted
from `/maas/models` responses for the affected groups, even though their subscription shows as Active.

**Symptom:** A user's `/gen-ai/api/v1/maas/models` response is missing a model that their
subscription should grant access to.

**Root cause pattern:**

| Resource | Model X |
|---|---|
| `MaaSSubscription` owner | `group-a` + `group-b` |
| `MaaSAuthPolicy` subjects | `group-b` only |

Users in `group-a` have a valid subscription but no auth policy → model is invisible to them.

**Diagnosis:**

```bash
# Compare subscription owner groups vs auth policy subjects for the missing model
oc get maassubscription -n models-as-a-service -o json | \
  jq '.items[] | {name: .metadata.name, groups: .spec.owner.groups, models: [.spec.modelRefs[].name]}'

oc get maasauthpolicy -n models-as-a-service -o json | \
  jq '.items[] | {name: .metadata.name, groups: .spec.subjects.groups, models: [.spec.modelRefs[].name]}'
```

**Fix:** Add the missing group to the `MaaSAuthPolicy` subjects so it matches the subscription.

## Model missing from AI assets view — no `MaaSModelRef`

**Symptom:** A model is deployed and `Ready` but never appears in the Gen AI Studio AI assets
view or the subscription management "Add models" picker.

**Root cause:** The `MaaSModelRef` for the model was never created. The AI assets view and
subscription picker query `MaaSModelRef` objects — not `LLMInferenceService` resources directly.
A model with no `MaaSModelRef` is invisible to both.

**Diagnosis:**

```bash
# Check whether a MaaSModelRef exists for the model
oc get maasmodelref -n <model-namespace>

# If missing, check whether maas.enabled is set on the LLMInferenceService
oc get llminferenceservice <name> -n <model-namespace> \
  -o jsonpath='{.metadata.annotations.security\.opendatahub\.io/enable-auth}'
```

**Fix:** Re-apply the inference chart with `maas.enabled=true`, or use the RHOAI dashboard
model deployment page's **Publish as MaaS endpoint** toggle. Do not do this before the MaaS
gateway and Kuadrant policies are in place (Phase 6) — enabling it too early causes
maas-controller reconcile errors.

## Models missing from AI assets view — `gen-ai-ui` crash loop

**Symptom:** The Gen AI Studio / AI Assets page shows:
```
Some models may be unavailable
Locally deployed models could not be loaded. Only models from available sources are shown.
{"statusCode": 500, "code": "UND_ERR_SOCKET", ...}
```
No models appear at all, even ones that were previously visible.

**Root cause:** An `LLMInferenceService` in the namespace has a missing `spec.model.name` field.
The `gen-ai-ui` sidecar dereferences this field without a nil guard, panics, and enters
CrashLoopBackOff. Every restart window causes the BFF to return `ECONNREFUSED`/500 for all
Gen AI Studio requests.

This happens when a model is deployed via the **RHOAI dashboard UI** — that path does not write
`spec.model.name`. Only the Helm chart (`gitops/instance/llm-d/inference`) populates it.

**Diagnosis:**

```bash
# Look for the panic in gen-ai-ui logs
oc logs -n redhat-ods-applications deploy/rhods-dashboard -c gen-ai-ui --tail=50 \
  | grep -E "panic|nil pointer|SIGSEGV"

# Find any LLMInferenceService missing spec.model.name
oc get llminferenceservice -n <namespace> -o json \
  | jq '.items[] | select(.spec.model.name == null or .spec.model.name == "") \
    | .metadata.name'
```

**Fix:** Patch the offending resource to add the missing field:

```bash
oc patch llminferenceservice <name> -n <namespace> \
  --type=merge -p '{"spec":{"model":{"name":"<hf-org/model-name>"}}}'
```

The gen-ai-ui crash loop stops immediately after the patch. Upstream fix needed in
`gen-ai-ui` at `token_k8s_client.go` to nil-guard `spec.model.name`.

## MaaSAuthPolicy status loop — harmless

The maas-controller may log `"failed to update MaaSAuthPolicy status"` in a tight loop. This is a
controller/CRD version mismatch (controller writes `accepted`/`enforced`; CRD requires `ready`).
Auth and rate limits work correctly — ignore this log noise.
