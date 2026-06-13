# Phase 6 — MaaS

> Part of the [llm-d-demo Co-pilot Runbook](../../AGENTS.md). See the
> [Phase Map](../../AGENTS.md#phase-map) for the full sequence.
> See also: [MaaS Troubleshooting](../reference/maas-troubleshooting.md) |
> [ExternalModel Guide](../reference/external-models.md)

**Goal:** Deploy the MaaS gateway, configure Authorino TLS, bootstrap the subscription stack, and verify end-to-end API key creation and model access.

**Pre-flight checks the assistant must run before starting:**
```bash
# Kuadrant CR ready (Authorino + Limitador running)
oc get kuadrant kuadrant -n kuadrant-system
oc get pods -n kuadrant-system

# LLMInferenceService(s) Ready
oc get llminferenceservice -A

# maas-api pod running
oc get pods -n redhat-ods-applications -l app.kubernetes.io/name=maas-api
```

**Steps (follow README §9.2):**

### Step 1 — MaaS Gateway

Apply the gateway chart with your cluster domain and model namespaces:
```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
helm template gitops/instance/maas/gateway --name-template maas-gateway \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --set useOpenShiftRoute=true \
  --set tls.secretName=router-certs-default \
  --set "gateway.modelNamespaces={llm-d-demo}" | oc apply -f -
oc get gateway maas-default-gateway -n openshift-ingress
```

> **Use `router-certs-default`, not `ingress-certs`:** The gateway chart annotates the Gateway Service with `service.beta.openshift.io/serving-cert-secret-name=<tls.secretName>`, which causes the service-ca-operator to create (or overwrite) that secret with a certificate valid only for the internal Service DNS name. If you pass `tls.secretName=ingress-certs`, the service-ca-operator silently replaces it with an internal-only cert. The Envoy pod then presents it to all clients — including the Gen AI Studio backend, which connects to `https://maas.<cluster-domain>/maas-api/...` and receives a certificate that does not cover the public hostname (`x509: certificate is valid for ...openshift-ingress.svc, not maas.<cluster-domain>`). `router-certs-default` already exists in `openshift-ingress` and contains the wildcard cert `*.apps.<cluster-domain>` signed by the OCP ingress operator CA — a CA that is already present in every RHOAI component's trust bundle.

### Step 2 — MaaS Database

Deploy PostgreSQL and create the `maas-db-config` secret **before** enabling `modelsAsService`. The `maas-api` pod will not start without this secret. `helm template` skips `lookup`, so the password must be supplied explicitly:
```bash
DB_PASSWORD=$(openssl rand -base64 18 | tr -d '+/=' | head -c 24)
echo "Save this DB password: ${DB_PASSWORD}"
helm template gitops/instance/maas/database --name-template maas-database \
  --namespace redhat-ods-applications \
  --set db.password="${DB_PASSWORD}" | oc apply -n redhat-ods-applications -f -
oc wait --for=condition=ready pod -l app=maas-db \
  -n redhat-ods-applications --timeout=120s
oc get secret maas-db-config -n redhat-ods-applications
```

### Step 3 — Enable MaaS in the DataScienceCluster

Re-apply the RHOAI instance chart with `modelsAsService=true` **after** the gateway (Step 1) and database (Step 2) are ready. This creates the `maas-controller` and `maas-api` pods:
```bash
helm template rhoai ./gitops/instance/rhoai --set modelsAsService=true | oc apply -f -
oc wait --for=condition=ready pod -l app.kubernetes.io/name=maas-api \
  -n redhat-ods-applications --timeout=120s
```

### Step 4 — Authorino TLS

Must be configured in order (4a → 4b → 4c → 4d). **IMPORTANT:** This step requires the `maas-controller` pod from Step 3 to be running. The maas-controller creates the TLS EnvoyFilter when the gateway annotation changes:
```bash
# 4a. Annotate Authorino service for serving cert
oc annotate service authorino-authorino-authorization \
  -n kuadrant-system \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
  --overwrite

# 4b. Enable TLS on the Authorino CR
oc patch authorino authorino -n kuadrant-system --type=merge --patch '{
  "spec": {
    "listener": {
      "tls": {
        "enabled": true,
        "certSecretRef": {"name": "authorino-server-cert"}
      }
    }
  }
}'

# 4c. Configure Authorino to validate certs using the cluster CA bundle
oc -n kuadrant-system set env deployment/authorino \
  SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
oc rollout status deployment/authorino -n kuadrant-system --timeout=90s

# 4d. Annotate the gateway to trigger maas-controller to create the TLS EnvoyFilter
oc annotate gateway maas-default-gateway -n openshift-ingress \
  security.opendatahub.io/authorino-tls-bootstrap="true" \
  --overwrite

# Verify TLS EnvoyFilter was created
sleep 5
oc get envoyfilter maas-default-gateway-authn-ssl -n openshift-ingress
```

**Verify Authorino TLS is fully configured:**
```bash
oc get service authorino-authorino-authorization -n kuadrant-system \
  -o jsonpath='{.metadata.annotations.service\.beta\.openshift\.io/serving-cert-secret-name}'
# Expected: authorino-server-cert

oc get secret authorino-server-cert -n kuadrant-system
# Expected: kubernetes.io/tls with 2 data entries

oc get authorino authorino -n kuadrant-system -o jsonpath='{.spec.listener.tls.enabled}'
# Expected: true

oc get envoyfilter maas-default-gateway-authn-ssl -n openshift-ingress
# Expected: present (created by maas-controller after annotation)
```

### Step 5 — Bootstrap subscription namespace

`models-as-a-service` namespace + `default-tenant` CR (name is exact):
```bash
# Create namespace
oc create namespace models-as-a-service --dry-run=client -o yaml | oc apply -f -

# Create Tenant CR (global MaaS configuration object)
# The Tenant controls:
#   - API key settings (maxExpirationDays: max lifetime for generated keys)
#   - Gateway reference (which Gateway to use for model routing)
#   - Optional: external OIDC, telemetry config
# The maas-api pod is hardcoded to look for "default-tenant" in models-as-a-service namespace
cat <<'EOF' | oc apply -f -
apiVersion: maas.opendatahub.io/v1alpha1
kind: Tenant
metadata:
  name: default-tenant              # MUST be exactly "default-tenant"
  namespace: models-as-a-service
spec:
  apiKeys:
    maxExpirationDays: 90           # Max API key lifetime (adjust for your security policy)
  gatewayRef:
    name: maas-default-gateway      # Which Gateway to use for model routing
    namespace: openshift-ingress
EOF
```

**Inject the DB connection URL into the maas-api deployment:**
```bash
oc patch deployment maas-api -n redhat-ods-applications --type=json -p='[{
  "op": "add",
  "path": "/spec/template/spec/containers/0/env/-",
  "value": {
    "name": "DB_CONNECTION_URL",
    "valueFrom": {"secretKeyRef": {"name": "maas-db-config", "key": "DB_CONNECTION_URL"}}
  }
}]'
oc rollout status deployment/maas-api -n redhat-ods-applications --timeout=60s
```

### Step 6 — Register models

Create `MaaSModelRef`, `MaaSSubscription`, `MaaSAuthPolicy` in `models-as-a-service`:
```bash
# The MaaSModelRef is created automatically when maas.enabled=true in the inference chart.
# Verify it exists:
oc get maasmodelref -n <model-namespace>

# Create MaaSSubscription (token rate limits per model, per group)
cat <<'EOF' | oc apply -f -
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: default-subscription
  namespace: models-as-a-service
spec:
  owner:
    groups:
    - name: system:authenticated    # MUST be an object with 'name' field, not a bare string
  modelRefs:
  - name: qwen3-8b-maas             # MaaSModelRef name (not LLMInferenceService name)
    namespace: llm-d-demo
    tokenRateLimits:                # REQUIRED field, per-model
    - window: 24h                   # Window: s, m, h (NOT d - use 24h instead)
      limit: 1000                   # Token count limit for this window
EOF

# Create MaaSAuthPolicy (grants groups access to models)
cat <<'EOF' | oc apply -f -
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: default-auth-policy
  namespace: models-as-a-service
spec:
  subjects:
    groups:
    - name: system:authenticated    # MUST match subscription owner groups
  modelRefs:
  - name: qwen3-8b-maas             # MUST match subscription modelRefs
    namespace: llm-d-demo
EOF
```

**Critical schema notes:**
- `owner.groups` is a **list of objects** with `name` field, NOT a list of strings
- `tokenRateLimits` is **required on each modelRef**, with `window` and `limit` fields
- `window` units: `s`, `m`, `h` only — `d` is not supported, use `24h`
- `subjects.groups` in MaaSAuthPolicy must match `owner.groups` in MaaSSubscription

See README §9.2 Step 7 for multi-tier examples with different limits per group.

### Step 7 — Enable dashboard flags

All four must be `true`:
```bash
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge \
  -p '{"spec":{"dashboardConfig":{"genAiStudio":true,"modelAsService":true,"maasAuthPolicies":true,"vLLMDeploymentOnMaaS":true}}}'
oc rollout restart deployment/rhods-dashboard -n redhat-ods-applications
```

### Step 8 — Smoke test

Create an API key and call a model:
```bash
TOKEN=$(oc whoami -t)
MAAS_GW="maas.${CLUSTER_DOMAIN}"
curl -sk -X POST "https://${MAAS_GW}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"test-key","expiresInDays":1}'
```

**Human gate:** API key creation returns HTTP 201 with a `sk-oai-*` key. Model call with that key returns HTTP 200.

---

## Known gotchas

- `POST /maas-api/v1/api-keys` returns `500`: Authorino TLS not configured, or the `maas-default-gateway-authn-ssl` EnvoyFilter is missing. Remove and re-add the `authorino-tls-bootstrap` annotation on the gateway (Step 4 above).
- **500 errors on API keys / authorization policies pages** — gateway OCP Route has wrong hostname. Check: `oc get route maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.host}'` must be `maas.<cluster-domain>`. If it shows `maas-default-gateway-openshift-ingress.<cluster-domain>`, re-apply the gateway chart (the chart had a bug where `useOpenShiftRoute=true` used the wrong hostname format). Symptom in `maas-ui` sidecar logs: `statusCode=503 ... invalid character '<'`.
- Gen AI studio → API keys or Settings → Authorization policies tabs missing in the dashboard: check all four `OdhDashboardConfig` flags — `vLLMDeploymentOnMaaS` is the most commonly missing one.
- `LLMInferenceService` `HTTPRoutesReady: False` — `NotAllowedByListeners`: model namespace not in `gateway.modelNamespaces`. Re-apply the gateway chart with the correct namespace set.
- `MaaSAuthPolicy` status loop in controller logs (`"failed to update MaaSAuthPolicy status"`) — harmless controller/CRD version mismatch. Auth and rate limiting work correctly despite this.
- **EA2 → stable 3.4 migration only:** If `maas-controller` or `maas-api` Deployment shows an immutable selector error in the DSC, delete both Deployments and force a DSC reconcile — see `PATCH-MAAS.md §8`.

For more MaaS troubleshooting, see: [MaaS Troubleshooting Reference](../reference/maas-troubleshooting.md)

**End of Phase 6:** Stop here and report the MaaS smoke test results to the user. Show the API key creation response (must be HTTP 201 with a `sk-oai-*` key) and the model call response (must be HTTP 200). Installation is complete.
