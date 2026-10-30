# Phase 7 — MaaS Multi-Tenant

> Part of the [llm-d-guide Co-pilot Runbook](../../AGENTS.md). See the
> [Phase Map](../../AGENTS.md#phase-map) for the full sequence.
> Requires [Phase 6 — MaaS](06-maas.md) to be complete (default tenant `Ready`, `maas-api` running).

**Goal:** Add one or more additional, fully isolated MaaS tenants (e.g. `team-alpha`, `team-beta`)
on top of the default tenant created in Phase 6. Each tenant gets its own dedicated `Gateway`,
tenant namespace, `maas-api` instance, and RBAC — independent subscriptions, auth policies, and
rate limits, with no shared blast radius between tenants.

**Architecture (confirmed on a live RHOAI 3.5 cluster, not just from docs):** MaaS's tenant model
is `Config` (cluster singleton) → `AITenant` → `MaasTenantConfig`. Creating an `AITenant` auto-
provisions everything beneath it — there is no manual namespace creation or CR scaffolding, unlike
the (deprecated, no-op) `Tenant` CR flow in Phase 6 Step 5. The one hard constraint: **each
`AITenant` requires its own dedicated `Gateway`** — a cluster admission webhook (`vaitenant.kb.io`)
rejects any `AITenant` whose `spec.gateway.name` is already claimed by another `AITenant`.
`maas-default-gateway` is permanently owned by the Phase 6 default tenant.

> **Scope limitation, confirmed via live logs — additional tenants are API/CLI-only, not visible
> in the RHOAI dashboard.** Gen AI Studio's Model Catalog/Subscriptions/API Keys/Authorization
> Policies pages are served by the `maas-ui` Deployment (`redhat-ods-applications`), which is
> hardcoded to the single Kubernetes Service `maas-api.redhat-ai-gateway-infra.svc:8443` — the
> **default tenant's** `maas-api` instance. At startup it calls that instance's `GET /v1/tenants`
> once and locks onto whatever single tenant/gateway it reports
> (`tenant=models-as-a-service gateway=maas-default-gateway`), using that gateway's public URL for
> every subsequent dashboard call. It never contacts `maas-api-<tenant>` Services created by this
> phase. Tenants created here are fully functional — reachable at their own gateway hostname via
> `curl`/API exactly as in Step 6 — but will **never appear in the RHOAI dashboard** in RHOAI 3.5.
> This is a product limitation in the shipped `maas-ui` image, not something fixable from this
> repo's charts.

**Pre-flight checks the assistant must run before starting:**
```bash
# Default tenant from Phase 6 must be healthy
oc get aitenant models-as-a-service -n ai-tenants
oc get maastenantconfig default-tenant -n models-as-a-service
oc get deployment maas-api -n redhat-ai-gateway-infra
```

> **Chart fix required:** confirm `gitops/instance/maas/gateway/templates/telemetrypolicy.yaml`
> names the `TelemetryPolicy` `{{ .Values.gateway.name }}-telemetry` (not a hardcoded
> `maas-gateway-telemetry`). Without this, deploying a second gateway with `telemetry.enabled=true`
> in the same namespace (`openshift-ingress`) silently overwrites the first gateway's
> `TelemetryPolicy.spec.targetRef`.

**Ask the user:** how many tenants, and what should each be named (e.g. `team-alpha`,
`team-beta`)? Which OCP Group should be each tenant's admin group? Which model(s) should each
tenant host — publish an existing Phase 5/6 model, or deploy a new one per tenant?

Repeat Steps 1–6 below for **each** tenant. `TENANT` is the tenant name (e.g. `team-alpha`).

---

### Step 1 — Deploy a dedicated Gateway for the tenant

Reuse the Phase 6 gateway chart with a distinct name and subdomain. The tenant's model
namespace (`ai-tenant-${TENANT}` — see Step 2) must be in `allowedRoutes`:
```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
TENANT=team-alpha

helm template gitops/instance/maas/gateway --name-template "${TENANT}-gateway" \
  --set gateway.name="${TENANT}-gateway" \
  --set subdomain="${TENANT}" \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --set useOpenShiftRoute=true \
  --set tls.secretName=ingress-certs \
  --set "gateway.modelNamespaces={ai-tenant-${TENANT}}" | oc apply -f -

oc get gateway "${TENANT}-gateway" -n openshift-ingress
```

> **Fixed, was a real isolation gap:** the chart used to hardcode `models-as-a-service` and
> `redhat-ods-applications` into `allowedRoutes` on **every** gateway it creates, including new
> tenant gateways — meaning an `HTTPRoute` from the default tenant's own namespace could attach
> to `team-alpha-gateway`. Confirmed live and fixed: the chart now only hardcodes this gateway's
> own namespace plus the shared `redhat-ai-gateway-infra` (needed by every tenant's own
> `maas-api-route`). **Only pass this tenant's own namespace** (`ai-tenant-${TENANT}`) in
> `modelNamespaces` — never `models-as-a-service`/`redhat-ods-applications`, which belong to the
> default tenant only (see [Phase 6 Step 1](06-maas.md#step-1--maas-gateway)).

> **TLS secret — human gate:** as in Phase 6 Step 1, confirm `ingress-certs` is the correct
> wildcard secret for this cluster before applying (non-cloud/bare-metal installs may need
> `router-certs-default` or a custom cert — stop and ask the user if unsure).

### Step 2 — Create the tenant's `AITenant`

```bash
cat <<EOF | oc apply -f -
apiVersion: maas.opendatahub.io/v1alpha1
kind: AITenant
metadata:
  name: ${TENANT}
  namespace: ai-tenants
spec:
  gateway:
    name: ${TENANT}-gateway
EOF

oc wait aitenant "${TENANT}" -n ai-tenants --for=condition=Ready --timeout=120s
oc get aitenant "${TENANT}" -n ai-tenants
```

> **Gotcha:** if `spec.gateway.name` references a `Gateway` already claimed by another
> `AITenant`, the `vaitenant.kb.io` admission webhook rejects the request immediately:
> `gateway <ns>/<name> is already in use by AITenant <ns>/<name>; each AITenant requires a
> dedicated Gateway for isolation`. Each tenant must reference a freshly deployed Gateway from
> Step 1, never one already bound to another tenant.

Verify the full chain auto-provisioned (no manual steps needed for any of this):
```bash
TENANT_NS="ai-tenant-${TENANT}"

oc get namespace "${TENANT_NS}"
oc get maastenantconfig default-tenant -n "${TENANT_NS}"
oc get deployment "maas-api-${TENANT}" -n redhat-ai-gateway-infra
oc get role "aitenant-${TENANT}-tenant-admin" -n "${TENANT_NS}"
```

> **Naming note:** `ai-tenant-${TENANT}` is the namespace pattern for any tenant created this
> way — confirmed empirically on a live cluster. The Phase 6 *default* tenant is a special case
> (its tenant namespace is `models-as-a-service`, not `ai-tenant-models-as-a-service`) because it
> was auto-migrated from the legacy single-tenant flow — do not generalize from it.

### Step 3 — Grant tenant-admin RBAC

`spec.rbac.admins` on `AITenant` is deprecated and **ignored by the controller** — it only
creates the `Role`, not any `RoleBinding`. Bind the tenant's admin group yourself:
```bash
cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${TENANT}-tenant-admin-binding
  namespace: ${TENANT_NS}
subjects:
- kind: Group
  name: <TENANT_ADMIN_GROUP>
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: aitenant-${TENANT}-tenant-admin
  apiGroup: rbac.authorization.k8s.io
EOF
```

> **Official docs confirm a second Role also exists:** `aitenant-${TENANT}-object-admin` in the
> `ai-tenants` namespace (confirmed live), granting read-only access to the `AITenant` object
> itself so a tenant admin or dashboard can view bootstrap status without broader `ai-tenants`
> access. Optional — bind it only if the tenant's admins need to check their own `AITenant`
> status via `oc`:
> ```bash
> oc create rolebinding "${TENANT}-aitenant-reader" \
>   --role="aitenant-${TENANT}-object-admin" \
>   --group=<TENANT_ADMIN_GROUP> \
>   -n ai-tenants
> ```

> **Confirmed live:** if the tenant admin group is newly created or a user was just added to it
> (`oc adm groups new` / `oc adm groups add-users`), allow **2–3 minutes** before that user can
> mint an API key for this tenant. `TokenReview`'s group list lags live `Group` object changes by
> that long — minting immediately after adding the user fails with
> `{"code":"invalid_subscription","error":"Unable to resolve a subscription for this API key"}`
> even though the `MaaSSubscription`/`MaaSAuthPolicy` are correctly configured. Verify with:
> ```bash
> oc create -f - -o json <<EOF | python3 -c "import json,sys; print(json.load(sys.stdin)['status']['user']['groups'])"
> apiVersion: authentication.k8s.io/v1
> kind: TokenReview
> spec:
>   token: $(oc whoami -t)
> EOF
> ```
> Retry the API key mint once the tenant group appears in that list.

### Step 4 — Deploy or publish a model into the tenant's namespace

Reuse the inference chart from Phase 5/6, deployed **into the tenant's own namespace**, with
`maas.gateway.name` pointed at the tenant's dedicated gateway (this is what drives the generated
`HTTPRoute`'s `parentRefs` — see [Phase 6](06-maas.md) and `RATIONALE.md` for how this wiring
works):
```bash
helm template "${TENANT}-model" gitops/instance/llm-d/inference \
  -n "${TENANT_NS}" \
  -f gitops/instance/llm-d/inference/values.yaml \
  -f <per-model-values-file>.yaml \
  --set maas.enabled=true \
  --set maas.gateway.name="${TENANT}-gateway" \
  --set maas.gateway.namespace=openshift-ingress \
  --include-crds | oc apply -n "${TENANT_NS}" -f -

oc get llminferenceservice -n "${TENANT_NS}"
oc get maasmodelref -n "${TENANT_NS}"
```

> **Fixed, was a live chart bug:** the `LLMInferenceService` and connection `Secret` templates
> used to omit `metadata.namespace` (unlike `MaaSModelRef`/`ServiceMonitor`, which always set it),
> so `helm template -n <ns>` alone did nothing for those two resources — they fell through to
> `oc apply`'s ambient current-namespace context (e.g. `default`) while everything else correctly
> landed in the tenant namespace. Both templates now set `namespace: {{ .Release.Namespace }}`
> explicitly. The `oc apply -n "${TENANT_NS}"` above is still good practice (belt-and-suspenders),
> but is no longer required to get the correct namespace.

### Step 5 — Create the tenant's subscription and auth policy

Unlike Phase 6 (where these live in `models-as-a-service`), a tenant's `MaaSSubscription` and
`MaaSAuthPolicy` live in **its own tenant namespace**, matching the scope of its tenant-admin RBAC:
```bash
cat <<EOF | oc apply -f -
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: ${TENANT}-subscription
  namespace: ${TENANT_NS}
spec:
  owner:
    groups:
    - name: <TENANT_ADMIN_GROUP>
  modelRefs:
  - name: <MODEL_MAAS_NAME>
    namespace: ${TENANT_NS}
    tokenRateLimits:
    - window: 24h
      limit: 1000
EOF

cat <<EOF | oc apply -f -
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: ${TENANT}-auth-policy
  namespace: ${TENANT_NS}
spec:
  subjects:
    groups:
    - name: <TENANT_ADMIN_GROUP>
  modelRefs:
  - name: <MODEL_MAAS_NAME>
    namespace: ${TENANT_NS}
EOF
```

> Same schema rules as Phase 6 apply: `owner.groups`/`subjects.groups` are lists of `{name: ...}`
> objects, `tokenRateLimits` is required per modelRef, and window units are `s`/`m`/`h` only.

> **Confirmed live:** `MaaSSubscription` reliably shows `Failed` (`modelRefStatuses` reason
> `NotFound`, message `HTTPRoute not found yet`) for the first minute or two after creation, if
> created before the model's `LLMInferenceService` has reached `Ready` (its `HTTPRoute` doesn't
> exist until then). This is transient, not an error — the `maas-controller` reconciles
> continuously and both `MaaSSubscription` and `MaaSAuthPolicy` flip to `Active` on their own once
> the model becomes `Ready`. Do not delete and recreate them; just wait and re-check:
> `oc get maassubscription,maasauthpolicy -n ${TENANT_NS}`.

### Step 6 — Smoke test tenant isolation

Each tenant has its own gateway hostname. Confirm inference works through the tenant's own
gateway, and confirm an API key minted for one tenant does **not** work against another tenant's
gateway:
```bash
TOKEN=$(oc whoami -t)
TENANT_GW="${TENANT}.${CLUSTER_DOMAIN}"

# 1. Mint an API key through this tenant's gateway (expected: HTTP 201)
curl -sk -X POST "https://${TENANT_GW}/v1/api-keys" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"test-key","expiresInDays":1}'

API_KEY="<paste sk-oai-... key here>"

# 2. Call the model through this tenant's own gateway (expected: HTTP 200)
curl -sk "https://${TENANT_GW}/${TENANT_NS}/<model>/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"<model>","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'

# 3. Cross-tenant isolation check: the same key against a DIFFERENT tenant's gateway
#    (expected: 403/404 — the model/route does not exist on that gateway)
OTHER_TENANT_GW="team-beta.${CLUSTER_DOMAIN}"
curl -sk "https://${OTHER_TENANT_GW}/${TENANT_NS}/<model>/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"<model>","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'
```

**Human gate:** API key creation returns HTTP 201. The inference call through the tenant's own
gateway returns HTTP 200. The cross-tenant call in step 3 fails (403/404) — proving isolation.

Repeat Steps 1–6 for every additional tenant.

---

### Step 7 — Delete a tenant (optional)

Per the official RHOAI 3.5 documentation, deleting an `AITenant` triggers an ordered
finalizer-driven cleanup — some resources are removed automatically, others are deliberately
preserved to protect user data:

| Resource | Cleanup behavior |
|---|---|
| `AITenant` CR, `MaasTenantConfig`, controller-created Roles, per-tenant `maas-api` Deployment, Gateway `AuthPolicy`, internal `HTTPRoute` | Deleted automatically |
| User-created `RoleBinding`s, the tenant namespace, the Gateway and its `Route` | **Preserved** — delete manually if no longer needed |

```bash
# Review what's in the tenant namespace first (optional)
oc get maassubscription,maasauthpolicy,maasmodelref -n "${TENANT_NS}"

# Delete the AITenant — this runs the finalizer (revokes API keys, deletes
# MaasTenantConfig, Roles, AuthPolicy, internal HTTPRoute)
oc delete aitenant "${TENANT}" -n ai-tenants

# Monitor — shows Terminating, then disappears when the finalizer completes
oc get aitenant "${TENANT}" -n ai-tenants -w

# Optional cleanup of preserved resources
oc get rolebinding -n "${TENANT_NS}"          # review before deleting
oc delete rolebinding <rolebinding-name> -n "${TENANT_NS}"
oc delete gateway "${TENANT}-gateway" -n openshift-ingress
oc delete route "${TENANT}-gateway" -n openshift-ingress
oc delete namespace "${TENANT_NS}"            # only if no tenant data needs to be retained
```

> **Warning (from the official docs):** user-created `RoleBinding`s in the tenant namespace are
> **not** deleted with the `AITenant`. If you re-create a tenant with the same name later, those
> stale `RoleBinding`s reference the newly re-created Role of the same name and silently
> re-enable access for whoever was bound before. Always review and remove stale `RoleBinding`s
> before or after deleting a tenant, especially if you plan to reuse the tenant name.

---

## Known gotchas

- **One `Gateway` per `AITenant`, strictly enforced by an admission webhook.** There is no
  workaround — a tenant cannot share a gateway, even temporarily during migration. Always deploy
  the tenant's `Gateway` (Step 1) before creating its `AITenant` (Step 2).
- **Tenant namespace naming is `ai-tenant-<name>` for every tenant created via this phase** — but
  the Phase 6 default tenant (`models-as-a-service`) is a special legacy-migration case whose
  tenant namespace equals its own name with no prefix. Don't assume the default tenant's naming
  generalizes.
- **`spec.rbac.admins` on `AITenant` is deprecated and silently ignored** — the controller creates
  the `aitenant-<name>-tenant-admin` Role regardless, but never a `RoleBinding`. Always do Step 3
  manually, even if `spec.rbac.admins` is set in the manifest.
- **`MaaSSubscription`/`MaaSAuthPolicy` for a tenant must live in that tenant's own namespace**,
  not in `models-as-a-service` — they're scoped by the tenant's RBAC Role, which only grants
  `create`/`update`/`delete` on those kinds inside the tenant's own namespace.
- **TelemetryPolicy name collision** if two gateways in the same namespace both have
  `telemetry.enabled=true` and the chart predates the `{{ .Values.gateway.name }}-telemetry`
  fix — the second `helm template | oc apply` silently redirects the first gateway's telemetry.
- **GatewayClass and the cluster-wide Limitador patch are shared/idempotent** — re-applying the
  gateway chart for a second tenant does not conflict with the first tenant's `GatewayClass` or
  `Limitador` CR as long as `gateway.className` is left at its default.
- **`maas-api-<tenant>` Deployments share an identical pod selector across every tenant**
  (`app.kubernetes.io/name: maas-api`, `component: api`, `part-of: models-as-a-service` — no
  tenant-distinguishing label). Confirmed live: `oc logs deployment/maas-api-team-alpha` matched
  **7 pods** — every tenant's `maas-api` plus `maas-api-key-cleanup` CronJob pods — not just that
  tenant's. `oc get deployment` itself correctly shows one pod owned per Deployment, but log/exec
  commands that resolve pods by label will cross tenant boundaries. Always get the exact pod name
  first (`oc get pods -n redhat-ai-gateway-infra | grep <tenant>`) and target it directly, e.g.
  `oc logs pod/maas-api-team-alpha-<hash> -n redhat-ai-gateway-infra`.
- **The chart's `LLMInferenceService`/connection `Secret` templates used to omit
  `metadata.namespace`** (fixed — see the note in Step 4). If you're on an older checkout of this
  repo without the fix, always pipe into `oc apply -n "${TENANT_NS}" -f -`, never a bare
  `oc apply -f -`.
- **New group membership takes 2–3 minutes to propagate** into `TokenReview` results — see the
  warning in Step 3. Don't assume `invalid_subscription` right after adding a user to a group
  means the subscription/auth-policy config is wrong; wait and retry first.
- **Gateway chart used to leak the default tenant's namespaces onto every tenant gateway**
  (fixed — see the note in Step 1). `models-as-a-service`/`redhat-ods-applications` are no
  longer hardcoded into `allowedRoutes`; only pass a tenant's own namespace in
  `modelNamespaces` for its gateway.
- **`ExternalModel` is supported for the default tenant only** (per official RHOAI 3.5 docs,
  not independently re-verified on this cluster). The controller injects
  `DISABLE_EXTERNAL_MODEL_CONTROLLER=true` for non-default tenants to prevent `HTTPRoute`
  `parentRef` flapping between tenant gateways. If you need [ExternalModel](../reference/external-models.md)
  routing, access it through the default tenant's gateway (`maas-default-gateway`), not a
  Phase 7 tenant's gateway.

**End of Phase 7:** Stop here and report, per tenant: the `AITenant` `Ready` status, the smoke
test results (API key HTTP 201, inference HTTP 200 on the tenant's own gateway), and the
cross-tenant isolation check (403/404 on another tenant's gateway).
