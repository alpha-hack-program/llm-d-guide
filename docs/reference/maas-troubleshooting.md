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

Without Authorino TLS, `POST /v1/api-keys` returns `500`. The gateway annotation must be
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

All four MaaS-related `OdhDashboardConfig` flags must be `true`:

```bash
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge \
  -p '{"spec":{"dashboardConfig":{"genAiStudio":true,"modelAsService":true,"maasAuthPolicies":true,"vLLMDeploymentOnMaaS":true}}}'
```

The inference chart sets these automatically when `modelsAsService=true` in the RHOAI values. The `observabilityDashboard` flag (for the monitoring drawer) is separate and configured in Phase 4.

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

## MaaSSubscription and MaaSAuthPolicy stuck after creation — stale status race condition

**Affected version:** RHOAI 3.4.2 (maas-controller shipped with this release)

**Symptom:** After creating (or deleting and recreating) MaaS resources, one or both of:

- `MaaSSubscription` shows no `phase` (blank), and API keys created against it fail with
  `"subscription is in unreconciled phase (allowed: Active, Degraded)"`.
- `MaaSAuthPolicy` shows `Phase: Degraded` with message `AuthPolicy waiting for the following
  components to sync: [AuthConfig (...)]`, even though the underlying Kuadrant `AuthPolicy` is
  `Accepted + Enforced` and all `AuthConfig` resources are `Ready: True`.

Both can happen simultaneously. The `MaaSAuthPolicy` issue can also cascade — deleting and
recreating one policy causes previously-Active policies to flip to `Degraded` as the shared
`AuthPolicy` is rebuilt.

**Root cause:** Two distinct races in the maas-controller:

1. **MaaSSubscription:** When multiple subscriptions are created at once, the controller's
   status update for one can fail with `"the object has been modified; please apply your
   changes to the latest version"` due to a stale `resourceVersion`. The controller does not
   retry, so the subscription is left with no `phase` field indefinitely.

2. **MaaSAuthPolicy:** When the controller rebuilds the shared Kuadrant `AuthPolicy` for a
   model, there is a brief window where `AuthConfig` resources are being re-synced by
   Authorino. The controller snapshots the `AuthPolicy` status during this transient window
   and writes `NotEnforced`. Once the `AuthConfig` resources finish syncing and the
   `AuthPolicy` transitions to `Enforced`, the controller does not re-reconcile — the stale
   `Degraded` status persists indefinitely.

**Diagnosis:**

```bash
# Check subscription and auth policy status
oc get maassubscription -n models-as-a-service
oc get maasauthpolicy -n models-as-a-service

# Verify the underlying Kuadrant AuthPolicy is actually enforced
oc get authpolicy maas-auth-<model-name> -n <model-namespace> \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool
# Expected: Accepted: True, Enforced: True

# Verify AuthConfigs are ready
oc get authconfig -n kuadrant-system \
  -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status'
# Expected: all True

# Check maas-controller logs for the race
oc logs deployment/maas-controller -n redhat-ods-applications --tail=50 \
  | grep -i 'failed to update\|the object has been modified'
```

If the Kuadrant resources are healthy but `MaaSSubscription` or `MaaSAuthPolicy` show stale
status, the controller lost the race.

**Fix:** Restart the maas-controller to force a clean reconciliation:

```bash
oc rollout restart deployment/maas-controller -n redhat-ods-applications
oc rollout status deployment/maas-controller -n redhat-ods-applications --timeout=60s
```

All `MaaSAuthPolicy` and `MaaSSubscription` resources should transition to `Active` within
~15 seconds.

If a `MaaSSubscription` remains stuck after the restart (rare), delete and recreate it:

```bash
oc delete maassubscription <name> -n models-as-a-service
# re-apply the original manifest
```

**Impact:** The underlying auth and rate-limit enforcement (Kuadrant `AuthPolicy` and
`TokenRateLimitPolicy`) are unaffected — requests are correctly authenticated and rate-limited.
The exception is `MaaSSubscription` with a missing `phase`: API keys created while the
subscription was in this state return 403 or the `"unreconciled phase"` error. Revoke and
recreate the key after the controller restart fixes the status.

## Gen AI Studio playground 500 — missing TrustyAI / NemoGuardrails CRDs (RHOAI 3.5.1+)

**Affected version:** RHOAI 3.5.1+

**Symptom:** Sending a message in the Gen AI Studio playground returns HTTP 500. The
llama-stack backend shows no incoming request — the error originates in the `gen-ai-ui` pod.
Browser DevTools shows the failing request as `POST /gen-ai/api/v1/lsd/responses`.

**Root cause:** Starting in RHOAI 3.5.1, the `gen-ai-ui` backend attempts to discover
`NemoGuardrails` CRs (API group `trustyai.opendatahub.io/v1alpha1`) on every `/responses`
request. If TrustyAI is `Removed` in the DataScienceCluster, the CRD does not exist and API
discovery fails with:

```
failed to discover NemoGuardrails service: failed to list NemoGuardrails CRs:
unable to retrieve the complete list of server APIs: trustyai.opendatahub.io/v1alpha1:
no matches for trustyai.opendatahub.io/v1alpha1
```

The `gen-ai-ui` treats this as a hard error and returns 500 — it does not gracefully handle a
missing TrustyAI API group.

**Diagnosis:**

```bash
# Check gen-ai-ui logs for the NemoGuardrails discovery failure
oc logs -n redhat-ods-applications -l deployment=gen-ai-ui --tail=50 \
  | grep -i "NemoGuardrails\|trustyai"

# Confirm TrustyAI is not installed
oc get datasciencecluster default-dsc \
  -o jsonpath='{.spec.components.trustyai.managementState}'
# If "Removed" → this is the cause
```

**Fix:** Enable TrustyAI in the DataScienceCluster so the NemoGuardrails CRDs are installed:

```bash
oc patch datasciencecluster default-dsc --type merge \
  -p '{"spec":{"components":{"trustyai":{"managementState":"Managed"}}}}'

# Wait for the operator
oc rollout status deployment/trustyai-service-operator-controller-manager \
  -n redhat-ods-applications --timeout=120s

# Restart gen-ai-ui to pick up the new API
oc delete pod -n redhat-ods-applications -l deployment=gen-ai-ui
```

The NemoGuardrails CRD will exist (with zero instances), the discovery succeeds, and
`/responses` requests work normally.

## MaaSAuthPolicy status loop — harmless

The maas-controller may log `"failed to update MaaSAuthPolicy status"` in a tight loop. This is a
controller/CRD version mismatch (controller writes `accepted`/`enforced`; CRD requires `ready`).
Auth and rate limits work correctly — ignore this log noise.

## Multi-tenant MaaS (Phase 7) — findings confirmed on a live cluster

The following were validated end-to-end while deploying two real tenants (`team-alpha`,
`team-beta`) with models and smoke-testing isolation — see
[Phase 7 — MaaS Multi-Tenant](../phases/07-maas-multi-tenant.md).

### `LLMInferenceService` lands in the wrong namespace (fixed in the chart)

**Symptom (older checkouts only):** After `helm template gitops/instance/llm-d/inference -n
<tenant-ns> ... | oc apply -f -`, the `MaaSModelRef` and `ServiceMonitor`s appear correctly in
`<tenant-ns>`, but `oc get llminferenceservice -n <tenant-ns>` returns nothing. The model and its
connection `Secret` instead appear in your current `oc` context's namespace (often `default`).

**Root cause:** The chart's `LLMInferenceService`/`pd-disaggregation` and connection `Secret`
templates (`templates/intelligent-inference.yaml`, `templates/pd-disaggregation.yaml`,
`templates/connections.yaml`) did not set `metadata.namespace`, unlike
`MaaSModelRef`/`ServiceMonitor`, which explicitly set `namespace: {{ .Release.Namespace }}`.
`helm template -n <ns>` only populates `.Release.Namespace` for templates that reference it — it
has no effect on where `oc apply -f -` sends a resource with no namespace in its manifest. That
falls through to `oc apply`'s ambient current-namespace context.

**Fix (applied):** All three templates now explicitly set `namespace: {{ .Release.Namespace }}`.
`oc apply -n <tenant-ns> -f -` is still good practice, but is no longer required for correct
placement. If you're on an older checkout without this fix: always pass `oc apply -n <tenant-ns>
-f -` explicitly, and if a model already landed in the wrong namespace, run
`oc delete llminferenceservice <name> -n <wrong-ns>` and
`oc delete secret <name>-connection -n <wrong-ns>`, then re-apply with the explicit `-n`.

### `maas-api-<tenant>` Deployments share one pod selector across all tenants

**Symptom:** `oc logs deployment/maas-api-team-alpha -n redhat-ai-gateway-infra` reports "Found
N pods" where N is far more than 1, and may show log lines from other tenants' `maas-api`
instances or `maas-api-key-cleanup` CronJob pods.

**Root cause:** Every per-tenant `maas-api-<tenant>` Deployment (and the original `maas-api`)
uses the identical selector `app.kubernetes.io/name: maas-api`,
`app.kubernetes.io/component: api`, `app.kubernetes.io/part-of: models-as-a-service` — with no
tenant-distinguishing label. `oc get deployment` still correctly reports one owned pod per
Deployment (ReplicaSet ownership is tracked separately), but any command that resolves pods by
label — including `oc logs deployment/...`, which falls back to label selection — can match
pods belonging to a different tenant.

**Fix:** Get the exact pod name first, then target it directly:
```bash
oc get pods -n redhat-ai-gateway-infra | grep <tenant>
oc logs pod/maas-api-<tenant>-<hash> -n redhat-ai-gateway-infra
```

### New group membership doesn't apply to API key minting for several minutes

**Symptom:** Immediately after `oc adm groups new <tenant>` + `oc adm groups add-users <tenant>
<user>`, that user's `POST /v1/api-keys` against the tenant's gateway fails:
```json
{"code":"invalid_subscription","error":"Unable to resolve a subscription for this API key"}
```
even though the `MaaSSubscription`/`MaaSAuthPolicy` for that group are correctly configured and
`Active`.

**Root cause:** `TokenReview`'s reported `user.groups` lags live `Group` object changes by
roughly 2–3 minutes. `maas-api` resolves the subscription from the groups `TokenReview` reports
for the bearer token, not from a live `Group` lookup — so it sees the user as not yet a member.

**Diagnosis:**
```bash
oc create -f - -o json <<EOF | python3 -c "import json,sys; print(json.load(sys.stdin)['status']['user']['groups'])"
apiVersion: authentication.k8s.io/v1
kind: TokenReview
spec:
  token: $(oc whoami -t)
EOF
```
If the tenant's group is missing from the printed list, this is the cause.

**Fix:** Wait 2–3 minutes after the group change and retry. Do not touch the
`MaaSSubscription`/`MaaSAuthPolicy`/RBAC config — they are not the problem.

### `MaaSSubscription` shows `Failed` right after creation — self-heals

**Symptom:** A freshly created `MaaSSubscription` shows `phase: Failed` with
`modelRefStatuses[].reason: NotFound` and message `HTTPRoute not found yet`.

**Root cause:** The `MaaSSubscription` was created before its referenced model's
`LLMInferenceService` reached `Ready` — the model's `HTTPRoute` doesn't exist until then, and
the subscription controller needs it to build the `TokenRateLimitPolicy`.

**Fix:** None needed — this is transient. `maas-controller` reconciles continuously; both
`MaaSSubscription` and `MaaSAuthPolicy` flip to `Active` on their own once the model becomes
`Ready`. Do not delete and recreate them. Verify with
`oc get maassubscription,maasauthpolicy -n <tenant-ns>`.

### Additional tenants never appear in the RHOAI dashboard (Gen AI Studio)

**Symptom:** After completing Phase 7 and confirming a tenant (e.g. `team-alpha`) works via
direct API calls (minting keys, calling models), none of its models, subscriptions, API keys, or
auth policies ever show up in the RHOAI dashboard's Gen AI Studio pages — only the default
tenant's data is visible, no matter how long you wait or refresh.

**Root cause:** Confirmed via `maas-ui` logs (`oc logs -n redhat-ods-applications
deployment/maas-ui`). Gen AI Studio's Model Catalog/Subscriptions/API Keys/Authorization Policies
pages are served by the `maas-ui` Deployment, which is hardcoded to a single Kubernetes Service:
```
msg="Resolved maas-api namespace from DSC release" namespace=redhat-ai-gateway-infra
msg="Discovering MaaS API URL via /v1/tenants" internalURL=https://maas-api.redhat-ai-gateway-infra.svc.cluster.local:8443
msg="Discovered MaaS API URL from /v1/tenants" tenant=models-as-a-service gateway=maas-default-gateway url=https://maas.apps.<cluster>/maas-api
```
At startup, `maas-ui` calls `GET /v1/tenants` on exactly one `maas-api` Service —
`maas-api.redhat-ai-gateway-infra.svc:8443`, the **default tenant's** instance — and permanently
locks onto whatever single tenant/gateway that call reports. It never discovers or contacts
`maas-api-<tenant>` Services created for additional `AITenant`s (Phase 7); there is no
per-tenant selector, tenant-switcher, or multi-backend logic in this component.

**Fix:** None available from this repo — `maas-ui` ships as a RHOAI container image
(`odh-mod-arch-maas-rhel9`), not a chart this guide controls. This is a genuine RHOAI 3.5 product
limitation, not a misconfiguration. Manage additional tenants entirely via API/CLI against their
own gateway hostname (`https://<tenant>.<cluster-domain>/v1/api-keys`, etc.), as in
[Phase 7 Step 6](../phases/07-maas-multi-tenant.md#step-6--smoke-test-tenant-isolation) — do not
expect dashboard visibility for anything beyond the default tenant.
