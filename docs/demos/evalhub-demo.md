# EvalHub Demo (Level 1) — llm-d Performance Comparison

> **Goal:** Use EvalHub + **GuideLLM** to compare **baseline** vs **llm-d optimized** inference for `qwen3-8b` on MaaS. EvalHub server + PostgreSQL run in the RHOAI platform namespace (`redhat-ods-applications`); evaluation workloads run in a labeled tenant namespace (`evalhub-demo`).
>
> **Prerequisites:** Phases 0–6 complete on RHOAI **3.5.x** (this guide targets 3.5 GA). EvalHub features and MLflow URI format require RHOAI 3.5 with RHCL **1.3.5+** (see [RHCL version pin](../reference/rhcl-version-pin.md)). [Phase 6 (MaaS)](../phases/06-maas.md) with `qwen3-8b` `Ready` via MaaS.
>
> **Scope in this document:** **Level 1 only** (performance engineering).  
> After this is validated together, proceed with:
>
> - Level 2: Quality / safety / accuracy CI gate (Garak + lm-eval) + OCI immutable artifacts
> - Level 3: Kueue scaling + protected production model auth

This demo is intentionally practical: you patch the inference stack twice, run the same GuideLLM benchmark each time, and compare throughput and latency in MLflow.

**Demo story:** *"What did intelligent routing, prefix caching, and scale-out actually buy us?"*

---



## Figure 1 — EvalHub architecture

Figure 1 illustrates the EvalHub architecture from [Part 1](https://developers.redhat.com/articles/2026/05/12/how-evalhub-manages-two-layer-kubernetes-control-planes) of the upstream article series.

![Figure 1: EvalHub architecture](assets/evalhub-figure-1.png)

*Figure 1: The EvalHub service orchestrates evaluation jobs by managing data in PostgreSQL and tracking experiment runs in MLflow.*

---



## 0) Demo variables


| Variable                                 | Purpose                                                                       |
| ---------------------------------------- | ----------------------------------------------------------------------------- |
| `EVALHUB_NS`                             | Platform namespace — EvalHub server, PostgreSQL, Route (`opendatahub.io/application-namespace` belongs here only) |
| `EVALHUB_TENANT_NS`                      | Tenant namespace — evaluation Job pods, `evalhub-model-auth`, API client SA (tenant label only — never `application-namespace`) |
| `EVALHUB_NP_NAME`                        | NetworkPolicy in `${EVALHUB_NS}` allowing tenant → EvalHub:8443 (Section 2.1b) |
| `EVALHUB_JOB_SA`                         | Operator-provisioned SA for **job pods only** (do not use for CLI)            |
| `EVALHUB_URL`                            | Route host in `EVALHUB_NS` (Section 3.1)                                      |
| `X-Tenant` / `evalhub config set tenant` | Always `EVALHUB_TENANT_NS`                                                    |
| `MAAS_GW`                                | MaaS gateway Route host (Phase 6)                                             |
| `MAAS_API_KEY`                           | MaaS API key for protected model endpoint — minted below, used in Section 3.3 |


```bash
export EVALHUB_NS=redhat-ods-applications
export EVALHUB_TENANT_NS=evalhub-demo
export EVALHUB_NP_NAME="evalhub-allow-tenant-${EVALHUB_TENANT_NS}"
export EVALHUB_NAME=evalhub
export EVALHUB_JOB_SA="evalhub-${EVALHUB_NS}-job"
export EVALHUB_CLIENT_SA=evalhub-demo-client
export EVAL_COLLECTION_NAME=demo-llm-d-performance-v1
export EVALHUB_PWD=changeme   # PostgreSQL user password + EvalHub db-url secret

# MaaS API key — required for GuideLLM jobs against the protected qwen3-8b endpoint (Phase 6).
export MAAS_GW=$(oc get route maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.host}')
export MAAS_API_KEY=$(curl -sk -X POST "https://${MAAS_GW}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{"name":"evalhub-demo","expiresInDays":7}' | jq -r '.key // .apiKey')
echo "MAAS_API_KEY prefix: ${MAAS_API_KEY:0:12}..."
```

---



## 1) Hard prerequisites check

Run this block first. It produces a **GO/NO-GO** decision and tells you exactly what to do next.

Source Section 0 variables before running:

```bash
# export EVALHUB_NS=... EVALHUB_TENANT_NS=...  (Section 0)
```

```bash
echo "=== Cluster access ==="
oc whoami
oc version | rg 'Client Version|Server Version'

missing=0

echo
echo "=== Check 1: TrustyAI/EvalHub CRDs ==="
if oc get crd | rg -qi 'trustyai|evalhub'; then
  echo "PASS: Found TrustyAI/EvalHub CRDs"
else
  echo "FAIL: Missing TrustyAI/EvalHub CRDs"
  missing=$((missing+1))
fi

echo
echo "=== Check 2: EvalHub CR in platform namespace ==="
if oc get evalhub "${EVALHUB_NAME:-evalhub}" -n "${EVALHUB_NS:-redhat-ods-applications}" >/dev/null 2>&1; then
  echo "PASS: EvalHub CR found in ${EVALHUB_NS:-redhat-ods-applications}"
  oc get evalhub -n "${EVALHUB_NS:-redhat-ods-applications}"
else
  echo "FAIL: No EvalHub CR in ${EVALHUB_NS:-redhat-ods-applications}"
  missing=$((missing+1))
fi

echo
echo "=== Check 3: DataScienceCluster ready ==="
if oc get dsc default-dsc -o jsonpath='{.status.phase}' 2>/dev/null | rg -q '^Ready$'; then
  echo "PASS: default-dsc phase=Ready"
else
  echo "FAIL: default-dsc not Ready — oc get dsc default-dsc -o yaml | rg -A2 'type: Ready'"
  missing=$((missing+1))
fi

echo
echo "=== Check 4: Platform application namespace label ==="
if oc get ns "${EVALHUB_NS:-redhat-ods-applications}" -o jsonpath='{.metadata.labels.opendatahub\.io/application-namespace}' 2>/dev/null | rg -q 'true'; then
  echo "PASS: ${EVALHUB_NS:-redhat-ods-applications} has opendatahub.io/application-namespace (DSC-managed)"
else
  echo "FAIL: ${EVALHUB_NS:-redhat-ods-applications} missing opendatahub.io/application-namespace=true (DSCI requirement)"
  missing=$((missing+1))
fi

echo
echo "=== Check 5: Tenant namespace labeled ==="
if oc get ns "${EVALHUB_TENANT_NS:-evalhub-demo}" -o jsonpath='{.metadata.labels.evalhub\.trustyai\.opendatahub\.io/tenant}' 2>/dev/null | rg -q '.'; then
  echo "PASS: ${EVALHUB_TENANT_NS:-evalhub-demo} has evalhub tenant label"
else
  echo "FAIL: ${EVALHUB_TENANT_NS:-evalhub-demo} missing evalhub.trustyai.opendatahub.io/tenant label"
  missing=$((missing+1))
fi
if oc get ns "${EVALHUB_TENANT_NS:-evalhub-demo}" -o jsonpath='{.metadata.labels.opendatahub\.io/application-namespace}' 2>/dev/null | rg -q 'true'; then
  echo "FAIL: ${EVALHUB_TENANT_NS:-evalhub-demo} must NOT have opendatahub.io/application-namespace (breaks RHOAI 3.5 gateway — Section 2.1)"
  missing=$((missing+1))
else
  echo "PASS: tenant does not carry application-namespace label"
fi

echo
echo "=== Check 6: EvalHub callback NetworkPolicy ==="
if oc get networkpolicy "evalhub-allow-tenant-${EVALHUB_TENANT_NS:-evalhub-demo}" \
  -n "${EVALHUB_NS:-redhat-ods-applications}" >/dev/null 2>&1; then
  echo "PASS: ${EVALHUB_NP_NAME:-evalhub-allow-tenant-evalhub-demo} exists in ${EVALHUB_NS:-redhat-ods-applications}"
else
  echo "FAIL: missing NetworkPolicy evalhub-allow-tenant-${EVALHUB_TENANT_NS:-evalhub-demo} (Section 2.1b)"
  missing=$((missing+1))
fi

echo
echo "=== Check 7: Operator provisioned job ServiceAccount in tenant ==="
if oc get sa "evalhub-${EVALHUB_NS:-redhat-ods-applications}-job" \
  -n "${EVALHUB_TENANT_NS:-evalhub-demo}" >/dev/null 2>&1; then
  echo "PASS: Job SA exists in tenant namespace (operator convergence)"
else
  echo "WARN: Job SA not found yet — label tenant after EvalHub CR is Ready (Section 2)"
fi

echo
echo "=== Check 8: EvalHub service endpoint exists ==="
if oc get svc -A | rg -qi 'evalhub|trustyai'; then
  echo "PASS: Found candidate EvalHub/TrustyAI service(s)"
  oc get svc -A | rg -i 'evalhub|trustyai'
else
  echo "FAIL: No EvalHub/TrustyAI service found"
  missing=$((missing+1))
fi

echo
echo "=== Check 9: MLflow service presence ==="
if oc get svc -A | rg -qi 'mlflow'; then
  echo "PASS: Found MLflow service(s)"
  oc get svc -A | rg -i 'mlflow'
else
  echo "FAIL: No MLflow service found"
  missing=$((missing+1))
fi

echo
if [[ "$missing" -eq 0 ]]; then
  echo "GO: Prerequisites satisfied. Skip Section 2 and continue with Section 3."
else
  echo "NO-GO: ${missing} prerequisite check(s) failed."
  echo "Proceed to Section 2: Install missing prerequisites."
fi
```

**Gate rule to proceed with Level 1:**

- `default-dsc` phase is **Ready**.
- `EvalHub` CRD exists.
- `EvalHub` CR is **Ready** in `${EVALHUB_NS}` (platform namespace — required for RHOAI dashboard integration).
- `${EVALHUB_NS}` has `opendatahub.io/application-namespace=true` (DSC-managed — do not add this label to tenant namespaces).
- PostgreSQL is running in `${EVALHUB_NS}` (Section 2.2).
- `${EVALHUB_TENANT_NS}` is labeled `evalhub.trustyai.opendatahub.io/tenant=true` only (Section 2.1).
- NetworkPolicy `${EVALHUB_NP_NAME}` exists in `${EVALHUB_NS}` (Section 2.1b).
- Operator has provisioned `${EVALHUB_JOB_SA}` in `${EVALHUB_TENANT_NS}`.
- EvalHub Route reachable; MLflow in `${EVALHUB_NS}`.

---



## 2) Install missing prerequisites (if checks fail)

> The product docs place EvalHub under TrustyAI on OpenShift AI 3.4+.  
> TrustyAI is managed by the Red Hat OpenShift AI operator via `DataScienceCluster`.

**Recommended order:** Section 2.0 (TrustyAI + DSC) → 2.2–2.3 (server + DB in `${EVALHUB_NS}`) → 2.1 (label `${EVALHUB_TENANT_NS}`) → 2.1b (NetworkPolicy) → 2.4 (wait for both). You may label the tenant before the EvalHub CR; the operator converges once both exist.

> **RHOAI 3.5 — do not label the tenant with `opendatahub.io/application-namespace`.** That label belongs on `${EVALHUB_NS}` only. Putting it on a tenant namespace reprovisions the data-science gateway into the tenant, breaks the OpenShift AI dashboard (`rh-ai.apps...` 404), and can leave `default-dsc` **Not Ready**. Use the targeted NetworkPolicy in Section 2.1b for EvalHub job callbacks instead.

### 2.0 Preferred path on OpenShift AI 3.4+: check TrustyAI in DSC

```bash
oc get dsc default-dsc -n redhat-ods-operator -o jsonpath='{.spec.components.trustyai.managementState}{"\n"}'
```

If TrustyAI is not managed, patch DSC first:

```bash
oc patch datasciencecluster default-dsc -n redhat-ods-operator --type=merge -p '{
  "spec": {
    "components": {
      "trustyai": {
        "managementState": "Managed"
      }
    }
  }
}'
```

Verify TrustyAI reconciliation:

```bash
# Must print: Managed
oc get dsc default-dsc -n redhat-ods-operator -o jsonpath='{.spec.components.trustyai.managementState}{"\n"}'

# Wait for TrustyAI operator deployment and pod readiness
echo "Wait for TrustyAI operator deployment and pod readiness"
oc wait --for=condition=Available deployment/trustyai-service-operator-controller-manager \
  -n redhat-ods-applications --timeout=300s
oc get pods -n redhat-ods-applications | rg 'trustyai-service-operator-controller-manager'
```

Only proceed when:

- `managementState` is `Managed`
- `trustyai-service-operator-controller-manager` is `Running`
- `default-dsc` phase is `Ready`:

```bash
oc get dsc default-dsc -o jsonpath='{.status.phase}{"\n"}'   # Expected: Ready
```

Verify `${EVALHUB_NS}` carries the platform application-namespace label (DSC sets this during normal install — do not copy it to tenant namespaces):

```bash
oc get ns "${EVALHUB_NS}" -o jsonpath='{.metadata.labels.opendatahub\.io/application-namespace}{"\n"}'   # Expected: true
```



### 2.1 Create tenant namespace

`redhat-ods-applications` already exists on RHOAI — do **not** create it here. Create only the **tenant** project where evaluation Job pods will run.

When you label the namespace, the TrustyAI operator provisions tenant-scoped resources (job ServiceAccount, RoleBindings, MLflow access) in that namespace. You can label the tenant before or after the EvalHub CR; the operator converges once both exist.

**One label on the tenant namespace:**

| Label | Purpose |
| ----- | ------- |
| `evalhub.trustyai.opendatahub.io/tenant=true` | Registers the namespace as an EvalHub tenant (operator provisions job SA, RBAC) |

EvalHub job pods must reach the EvalHub API in `${EVALHUB_NS}` on port **8443**. The platform NetworkPolicy blocks tenant ingress by default — Section **2.1b** adds a narrow allow rule. **Do not** label `${EVALHUB_TENANT_NS}` with `opendatahub.io/application-namespace` (see warning above).

```bash
oc new-project "${EVALHUB_TENANT_NS}" 2>/dev/null || oc project "${EVALHUB_TENANT_NS}"

oc label namespace "${EVALHUB_TENANT_NS}" \
  evalhub.trustyai.opendatahub.io/tenant=true --overwrite
```



### 2.1b Allow tenant → EvalHub callbacks (NetworkPolicy)

Evaluation Job sidecars POST status to `https://evalhub.${EVALHUB_NS}.svc.cluster.local:8443`. Without ingress from the tenant namespace, the CLI shows **pending** while the adapter may still run. MLflow has its own permissive NetworkPolicy; EvalHub does not.

Apply a **tenant-scoped** NetworkPolicy in `${EVALHUB_NS}` (safe on RHOAI 3.5 — unlike labeling the tenant with `application-namespace`):

```bash
cat <<EOF | oc apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${EVALHUB_NP_NAME}
  namespace: ${EVALHUB_NS}
spec:
  podSelector:
    matchLabels:
      app: evalhub
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ${EVALHUB_TENANT_NS}
      ports:
        - protocol: TCP
          port: 8443
EOF

oc get networkpolicy "${EVALHUB_NP_NAME}" -n "${EVALHUB_NS}"
```



### 2.2 Deploy PostgreSQL (EvalHub backing store)

EvalHub requires PostgreSQL. Deploy a single-instance database in `${EVALHUB_NS}` using the same dev/test chart as MaaS (not intended for production).

`EVALHUB_PWD` from Section 0 is used for the database user password. The chart creates a bootstrap Secret for the PostgreSQL pod; EvalHub reads a separate Secret with a `db-url` key in the next step.

```bash
helm template evalhub-database ./gitops/instance/maas/database \
  --namespace "${EVALHUB_NS}" \
  --set db.name=evalhub \
  --set db.user=evalhub \
  --set db.password="${EVALHUB_PWD}" \
  --set db.service.name=postgresql \
  --set db.secretName=postgresql-init \
  | oc apply -f -

oc wait --for=condition=ready pod -l app=postgresql \
  -n "${EVALHUB_NS}" --timeout=120s

oc get pods,svc -n "${EVALHUB_NS}" | rg -i postgresql
```



### 2.3 Create EvalHub database secret and `EvalHub` CR

Create a Secret containing the PostgreSQL connection string. The Secret must contain a `db-url` key with a valid PostgreSQL connection URI pointing at the in-cluster service from Section 2.2.

`MLFLOW_TRACKING_URI` must match the MLflow CR's in-cluster address. MLflow is the experiment store for EvalHub runs (Garak/lm-eval write runs; GuideLLM metrics stay in EvalHub results).

On **RHOAI 3.4+**, MLflow runs in `${EVALHUB_NS}`. The in-cluster Service listens on **8443 with HTTPS** — do not use `http://` or port `5000` (that causes `EOF` / `mlflow_request_failed` at job submit).

**RHOAI 3.5 change:** the tracking URI must include the `/mlflow` path suffix. Use the MLflow CR `status.address.url` — do not truncate it.

Verify and export before applying the `EvalHub` CR:

```bash
oc get svc mlflow -n "${EVALHUB_NS}"
export MLFLOW_TRACKING_URI=$(oc get mlflow mlflow -n "${EVALHUB_NS}" -o jsonpath='{.status.address.url}')
echo "MLFLOW_TRACKING_URI=${MLFLOW_TRACKING_URI}"
# RHOAI 3.4: https://mlflow.redhat-ods-applications.svc:8443
# RHOAI 3.5: https://mlflow.redhat-ods-applications.svc:8443/mlflow
```

Now define the secret for the db connection: 

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: evalhub-db-credentials
  namespace: ${EVALHUB_NS}
type: Opaque
stringData:
  db-url: "postgres://evalhub:${EVALHUB_PWD}@postgresql.${EVALHUB_NS}.svc:5432/evalhub?sslmode=disable"
EOF
```

Apply the `EvalHub` CR:

```bash
cat <<EOF | oc apply -f -
apiVersion: trustyai.opendatahub.io/v1alpha1
kind: EvalHub
metadata:
  name: ${EVALHUB_NAME}
  namespace: ${EVALHUB_NS}
spec:
  replicas: 1
  database:
    type: postgresql
    secret: evalhub-db-credentials
  providers:
    - lm-evaluation-harness
    - garak
    - guidellm
  collections:
    - safety-and-fairness-v1
  env:
    - name: MLFLOW_TRACKING_URI
      value: "${MLFLOW_TRACKING_URI}"
EOF
```

If the `EvalHub` CR already exists with a wrong URI (missing `/mlflow` on 3.5), patch it:

```bash
oc patch evalhub "${EVALHUB_NAME}" -n "${EVALHUB_NS}" --type=merge -p "$(cat <<EOF
spec:
  env:
    - name: MLFLOW_TRACKING_URI
      value: "${MLFLOW_TRACKING_URI}"
EOF
)"
```



### 2.4 Wait for EvalHub and tenant convergence

```bash
oc wait evalhub/"${EVALHUB_NAME}" -n "${EVALHUB_NS}" \
  --for=jsonpath='{.status.ready}'=True --timeout=600s
```

When the `EvalHub` CR reports Ready, verify the server pod, Route, and tenant onboarding:

```bash
oc get pods -n "${EVALHUB_NS}" -l app=eval-hub
oc wait --for=condition=ready pod -l app=eval-hub \
  -n "${EVALHUB_NS}" --timeout=300s

oc get route evalhub -n "${EVALHUB_NS}"

# Operator provisions this SA in the tenant namespace — used by evaluation Job pods, not the CLI.
oc get sa "${EVALHUB_JOB_SA}" -n "${EVALHUB_TENANT_NS}"
oc get rolebinding -n "${EVALHUB_TENANT_NS}" | rg evalhub
oc get networkpolicy "${EVALHUB_NP_NAME}" -n "${EVALHUB_NS}"
```

Proceed to Section 3 when the `evalhub` Route exists, server pods are Ready, `${EVALHUB_JOB_SA}` exists in `${EVALHUB_TENANT_NS}`, and `${EVALHUB_NP_NAME}` is present in `${EVALHUB_NS}`.

---



## 3) Level 1 demo run (core path)

EvalHub is multi-tenant. Every API call **except** `/api/v1/health` requires:

- `Authorization: Bearer ${TOKEN}` — API client identity (see below)
- `X-Tenant: ${EVALHUB_TENANT_NS}` — scopes the request to the tenant namespace



### Who runs what


| Actor                               | Namespace              | Role                                                                       |
| ----------------------------------- | ---------------------- | -------------------------------------------------------------------------- |
| EvalHub server + PostgreSQL         | `${EVALHUB_NS}`        | Schedules jobs, serves API, stores metadata                                |
| `${EVALHUB_JOB_SA}` (operator)      | `${EVALHUB_TENANT_NS}` | Identity for **evaluation Job pods** — status callbacks, MLflow job access |
| `${EVALHUB_CLIENT_SA}` (you create) | `${EVALHUB_TENANT_NS}` | Identity for **CLI / CI** — submit jobs, manage collections                |
| `evalhub-model-auth` Secret         | `${EVALHUB_TENANT_NS}` | MaaS API key mounted into Job pods                                         |
| MLflow                              | `${EVALHUB_NS}`        | Experiment tracking                                                        |




### Operator job SA vs API client SA

When you label `${EVALHUB_TENANT_NS}`, the operator creates `${EVALHUB_JOB_SA}` (for example `evalhub-redhat-ods-applications-job` in `evalhub-demo`). That ServiceAccount is **not** for human or CI API access.

It exists so **evaluation Job pods** can:

- Post **status events** back to the EvalHub server (`status-events` create)
- Reach **MLflow** with tenant-scoped credentials (operator ClusterRoleBindings)
- Pull adapter images (registry pull Secret)

It does **not** grant permission to submit evaluations, create collections, or call the EvalHub REST API. For that you need a separate **API client** ServiceAccount with the `evalhub-evaluator` Role (below), or your own user token (`oc whoami -t`) with equivalent RBAC.

Create a dedicated API client ServiceAccount and grant EvalHub virtual-resource access (product docs Section 2.27):

```bash
oc create sa "${EVALHUB_CLIENT_SA}" -n "${EVALHUB_TENANT_NS}" --dry-run=client -o yaml | oc apply -f -

cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: evalhub-evaluator
  namespace: ${EVALHUB_TENANT_NS}
rules:
  - apiGroups: ["trustyai.opendatahub.io"]
    resources: ["evaluations", "collections", "providers"]
    verbs: ["get", "list", "create", "update", "delete"]
  - apiGroups: ["mlflow.kubeflow.org"]
    resources: ["experiments"]
    verbs: ["create", "get"]
  # Required when job specs use model.auth.secret_ref (Section 3.3 Step 0): EvalHub checks
  # that the API caller can read the referenced Secret before accepting the job.
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["evalhub-model-auth"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${EVALHUB_CLIENT_SA}-access
  namespace: ${EVALHUB_TENANT_NS}
subjects:
  - kind: ServiceAccount
    name: ${EVALHUB_CLIENT_SA}
    namespace: ${EVALHUB_TENANT_NS}
roleRef:
  kind: Role
  name: evalhub-evaluator
  apiGroup: rbac.authorization.k8s.io
EOF

export TOKEN=$(oc create token "${EVALHUB_CLIENT_SA}" -n "${EVALHUB_TENANT_NS}" --duration=24h)
```

> **Note:** Interactive `oc whoami -t` also works if your user has the same Role rules.



### 3.1 Reach the EvalHub API (operator Route)

The TrustyAI operator exposes EvalHub automatically — no manual Route, Ingress, or port-forward is required. When the `EvalHub` CR is Ready, the operator creates a Route named `evalhub` in `${EVALHUB_NS}`.

Confirm the Route and note `reencrypt` termination on port `https`:

```bash
oc get route -n "${EVALHUB_NS}"
```

Example (host varies by cluster):

```text
NAME      HOST/PORT                                                              PATH   SERVICES   PORT    TERMINATION          WILDCARD
evalhub   evalhub-redhat-ods-applications.apps.<cluster-domain>                         evalhub    https   reencrypt/Redirect   None
```

Set the API base URL from the route host and verify health (the only **unauthenticated** endpoint):

```bash
export EVALHUB_URL="https://$(oc get route evalhub -n "${EVALHUB_NS}" -o jsonpath='{.spec.host}')"
echo "EVALHUB_URL=${EVALHUB_URL}"

curl -s "${EVALHUB_URL}/api/v1/health" | jq .
```



### 3.2 Install EvalHub CLI and list providers

At this point the EvalHub server is ready. Install the CLI and point it at the **platform Route**, **API client token**, and **tenant** namespace:

```bash
pip install "eval-hub-sdk[cli]"

evalhub config set base_url "${EVALHUB_URL}"
evalhub config set token "${TOKEN}"
evalhub config set tenant "${EVALHUB_TENANT_NS}"

# OpenShift reencrypt Routes can trigger Python/httpx SSL handshake errors
# (e.g. UNEXPECTED_EOF_WHILE_READING) even when curl works. For lab clusters set the following:
evalhub config set insecure true

evalhub health

evalhub providers list
evalhub providers describe guidellm
```

List providers and benchmarks of a provider via REST API (optional cross-check):

```bash
curl -s -H "Authorization: Bearer ${TOKEN}" -H "X-Tenant: ${EVALHUB_TENANT_NS}" \
  "${EVALHUB_URL}/api/v1/evaluations/providers" | jq .

curl -s -H "Authorization: Bearer ${TOKEN}" -H "X-Tenant: ${EVALHUB_TENANT_NS}" \
  "${EVALHUB_URL}/api/v1/evaluations/providers/guidellm" | jq .benchmarks
```



### 3.3 Run an evaluation (EvalHub CLI)

> **Resume checkpoint: if you're starting from here in a next session:** Re-source Section 0 vars, confirm EvalHub is healthy (`EVALHUB_URL` in `${EVALHUB_NS}`, `evalhub config set tenant ${EVALHUB_TENANT_NS}`, `evalhub health`), then **start here at Section 3.3 Step 0**.

The steps below use only the EvalHub CLI. They follow product docs §2.8 (submit job), §2.10 (status/results), §2.11 (cancel/delete), §2.12–§2.13 (collections), and §2.14 (model API key auth).  

Demo playbook:  patch `qwen3-8b` to a **baseline** stack → GuideLLM run → restore the **optimized** Phase 5/6 stack → GuideLLM run again → compare in MLflow.

Derive paths and the MaaS model URL once (`MAAS_GW` is set in Section 0):

```bash
export LLM_D_NS=llm-d-demo
export INFERENCE_CHART=./gitops/instance/llm-d/inference
export INFERENCE_VALUES=gitops/instance/llm-d/inference/qwen3-8b-values.yaml
export MAAS_MODEL_URL="https://${MAAS_GW}/llm-d-demo/qwen3-8b/v1"
# GuideLLM jobs: use the in-cluster vLLM URL (see callout below). MaaS smoke tests still use MAAS_MODEL_URL.
export GUIDELLM_MODEL_URL="https://qwen3-8b-kserve-workload-svc.${LLM_D_NS}.svc:8000/v1"
```

> **GuideLLM + MaaS auth gap (RHOAI 3.4):** `community-guidellm:v0.2.0` mounts `evalhub-model-auth` at `/var/run/secrets/model` but **does not** pass `api_key` to GuideLLM (`--backend-kwargs`). Against a protected MaaS route, backend validation fails with **401** on `/health` even when `MaaSModelRef` is `Ready`. Garak and lm-eval adapters wire the secret correctly; GuideLLM does not. **Workaround for Steps 4 and 6:** point jobs at `${GUIDELLM_MODEL_URL}` (in-cluster vLLM, no MaaS auth). Baseline vs optimized throughput comparison is still valid — only the auth/gateway hop is skipped. Keep `${MAAS_MODEL_URL}` for the Step 3 smoke test and for Garak/lm-eval in Level 2.

> **Rate limits:** GuideLLM generates sustained load. Raise the MaaS token limit for `qwen3-8b` before Step 4 (see [Section 5 — 429](#429-too-many-requests-from-model-endpoint)).



#### Step 0 — Configure API key authentication for model endpoints

Create a Secret in the tenant namespace with `${MAAS_API_KEY}` from Section 0 (product docs §2.14). EvalHub evaluation Job pods read this Secret via `model.auth.secret_ref` in the job spec.

```bash
oc create secret generic evalhub-model-auth -n "${EVALHUB_TENANT_NS}" \
  --from-literal=api-key="${MAAS_API_KEY}" \
  --dry-run=client -o yaml | oc apply -f -

oc get secret evalhub-model-auth -n "${EVALHUB_TENANT_NS}" -o jsonpath='{.data}' | jq 'keys'
#Expected: "api-key" mint a fresh token (RBAC changes apply to new tokens):
```

If you need, mint a fresh token (RBAC changes apply to new tokens or if you are running this section after a while your current token might have already expired):

```bash
export TOKEN=$(oc create token "${EVALHUB_CLIENT_SA}" -n "${EVALHUB_TENANT_NS}" --duration=24h)
evalhub config set token "${TOKEN}"
```



#### Step 1 — Describe the GuideLLM provider

GuideLLM benchmarks **inference performance** (throughput, time-to-first-token, inter-token latency). Level 2 uses Garak and lm-eval for quality/safety gates — not this provider.

```bash
evalhub providers describe guidellm
```

For live demos, use benchmark `quick_perf_test` with the timing parameters below (~5–7 min per run, enough load to show baseline vs optimized delta). Use `throughput` when you have more time for maximum-throughput discovery.

> **Demo timing and load (read before Steps 4/6):** `quick_perf_test` defaults to GuideLLM's **sweep** profile. Key parameters (passed via `collection.benchmarks[].parameters`):
>
>
> | Parameter      | Meaning                                                                 | Demo value                           |
> | -------------- | ----------------------------------------------------------------------- | ------------------------------------ |
> | `rate`         | **Sweep stage count** (`--rate` for `profile=sweep`) — not requests/sec | `5`                                  |
> | `max_seconds`  | Per-stage time cap                                                      | `45`                                 |
> | `max_requests` | Per-stage request ceiling (whichever limit hits first)                  | `60`                                 |
> | `data`         | Synthetic payload size                                                  | `prompt_tokens=128,output_tokens=64` |
>
>
> **Wall-clock estimate:** `rate × max_seconds` ≈ **5 × 45s ≈ 4–5 min** per stage budget, plus ~1–2 min overhead → **~6–7 min total**.
>
> **Why lighter tokens:** a completed run with `prompt_tokens=256,output_tokens=128` and only `max_seconds: 30` produced **12 total requests** in ~6 min — too few for stable throughput comparison. `128/64` yields more requests per stage while still stressing the GPU.
>
> **Verify before presenting:** adapter logs must show `--rate 5 --max-seconds 45 --max-requests 60`. After Step 6, compare `output_tokens_per_second` and `mean_ttft_ms` (not just aggregate `requests_per_second`).

Set once before Steps 2, 4, and 6:

```bash
export EVAL_GUIDELLM_RATE=6
export EVAL_GUIDELLM_MAX_SECONDS=60
export EVAL_GUIDELLM_MAX_REQUESTS=40
export EVAL_GUIDELLM_DATA="prompt_tokens=256,output_tokens=128,prefix_tokens=512,prefix_count=8"
```



#### Step 2 — Create a custom performance collection

Register a **GuideLLM performance** collection (product docs §2.13). The default benchmark is `quick_perf_test`; swap the `id` to `throughput` for a longer characterization run.

GuideLLM reports `requests_per_second`, `mean_ttft_ms`, and related metrics — **higher throughput is better**; **lower latency is better**. Level 1 uses `requests_per_second` as the primary score for collection display (informational — the real comparison is baseline vs optimized in MLflow).

```bash
cat > /tmp/evalhub-collection.yaml <<EOF
name: ${EVAL_COLLECTION_NAME}
category: demo
description: GuideLLM performance collection (llm-d baseline vs optimized)
tags:
  - demo
  - level1
  - guidellm
  - performance
benchmarks:
  - id: quick_perf_test
    provider_id: guidellm
    weight: 1.0
    parameters:
      rate: ${EVAL_GUIDELLM_RATE}
      max_seconds: ${EVAL_GUIDELLM_MAX_SECONDS}
      max_requests: ${EVAL_GUIDELLM_MAX_REQUESTS}
      data: "${EVAL_GUIDELLM_DATA}"
      request_type: chat_completions
      processor: gpt2
    primary_score:
      metric: requests_per_second
      lower_is_better: false
    pass_criteria:
      threshold: 0.0
EOF

evalhub collections create --file /tmp/evalhub-collection.yaml --format json \
  | tee /tmp/evalhub-collection-create.out

# CLI always prints a human header on stdout before JSON:
#   Collection created: <uuid>
export COLLECTION_ID=$(awk '/^Collection created:/ {print $3}' /tmp/evalhub-collection-create.out)
echo "COLLECTION_ID=${COLLECTION_ID}"
```

Verify the collection before submitting jobs:

```bash
evalhub collections describe "${COLLECTION_ID}"
```



#### Step 3 — Patch `qwen3-8b` to baseline (minimal llm-d optimizations)

Temporarily downgrade the serving stack so the optimized run shows a clear delta:

- **1 replica** (no multi-replica scale-out)
- **Simple scheduler** (`intelligentInferenceSimple: true` — no EPP prefix-cache / queue / KV scoring)
- **Prefix caching disabled**
- **MaaS routing preserved** (`maas.enabled=true` — same as Phase 6)

```bash
helm template inference "${INFERENCE_CHART}" \
  -n "${LLM_D_NS}" \
  -f "${INFERENCE_VALUES}" \
  --set replicas=1 \
  --set intelligentInferenceSimple=true \
  --set vllm.prefixCaching.enabled=false \
  --set maas.enabled=true \
  | oc apply -n "${LLM_D_NS}" -f -

oc wait llminferenceservice/qwen3-8b -n "${LLM_D_NS}" \
  --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True --timeout=600s

oc wait maasmodelref/qwen3-8b -n "${LLM_D_NS}" \
  --for=jsonpath='{.status.phase}'=Ready --timeout=300s
```

Confirm **one workload pod** and MaaS routing before submitting the baseline job:

```bash
oc get llminferenceservice qwen3-8b -n "${LLM_D_NS}"
oc get maasmodelref qwen3-8b -n "${LLM_D_NS}"
oc get pods -n "${LLM_D_NS}" 

#Expected: 
#NAME                                                READY   STATUS    #RESTARTS   AGE
#qwen3-8b-kserve-66b9cfb85-gdwxj                     2/2     Running
#qwen3-8b-kserve-router-scheduler-659f678dfd-xfhvl   3/3     Running

# MaaS smoke test — must return HTTP 200 before Step 4
curl -sk -o /dev/null -w 'MaaS models HTTP=%{http_code}\n' \
  -H "Authorization: Bearer ${MAAS_API_KEY}" \
  "${MAAS_MODEL_URL}/models"
```



#### Step 4 — Submit the baseline GuideLLM job

Same collection as the optimized run — only the **cluster serving config** differs. Use the shared parameter block from Step 1 (override in the job spec even if the collection already has them).

```bash
cat > /tmp/evalhub-job-baseline.yaml <<EOF
name: evalhub-level1-baseline
model:
  url: ${GUIDELLM_MODEL_URL}
  name: alibaba/qwen3-8b
collection:
  id: ${COLLECTION_ID}
  benchmarks:
    - id: quick_perf_test
      provider_id: guidellm
      parameters:
        rate: 8
        max_seconds: 90
        max_requests: 200
        data: "prompt_tokens=256,output_tokens=128,prefix_tokens=512,prefix_count=8"
        profile: concurrent
        request_type: chat_completions
        processor: gpt2
experiment:
  name: evalhub-level1-baseline
EOF

evalhub eval run --config /tmp/evalhub-job-baseline.yaml --format json \
  | tee /tmp/evalhub-job-baseline-submit.json
export JOB_ID_BASELINE=$(jq -r '.[0].resource.id // .[0].id' /tmp/evalhub-job-baseline-submit.json)
echo "JOB_ID_BASELINE=${JOB_ID_BASELINE}"

evalhub eval status "${JOB_ID_BASELINE}" --watch
evalhub eval results "${JOB_ID_BASELINE}" --format table
```



#### Step 5 — Restore the optimized Phase 5/6 stack

Re-apply the canonical values from the guide — **required** before the optimized run and before leaving the cluster. Do not proceed to the next step until the expcted pods status is achieved

```bash
helm template inference "${INFERENCE_CHART}" \
  -n "${LLM_D_NS}" \
  -f "${INFERENCE_VALUES}" \
  --set maas.enabled=true \
  | oc apply -n "${LLM_D_NS}" -f -

oc wait llminferenceservice/qwen3-8b -n "${LLM_D_NS}" \
  --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True --timeout=600s

oc wait maasmodelref/qwen3-8b -n "${LLM_D_NS}" \
  --for=jsonpath='{.status.phase}'=Ready --timeout=300s

oc get pods -n "${LLM_D_NS}" 

#Expected:
#NAME                                                READY   STATUS
#qwen3-8b-kserve-686ddc5d89-jl9mn                    2/2     Running 
#qwen3-8b-kserve-686ddc5d89-kmrf9                    2/2     Running
#qwen3-8b-kserve-router-scheduler-588fbfb988-wb45t   3/3     Running

```

You should see multiple GPU replicas and the EPP router-scheduler pod when the optimized stack is back.

#### Step 6 — Submit the optimized GuideLLM job

```bash
cat > /tmp/evalhub-job-optimized.yaml <<EOF
name: evalhub-level1-optimized
model:
  url: ${GUIDELLM_MODEL_URL}
  name: alibaba/qwen3-8b
collection:
  id: ${COLLECTION_ID}
  benchmarks:
    - id: quick_perf_test
      provider_id: guidellm
      parameters:
        rate: 8
        max_seconds: 90
        max_requests: 200
        data: "prompt_tokens=256,output_tokens=128,prefix_tokens=512,prefix_count=8"
        profile: concurrent
        request_type: chat_completions
        processor: gpt2
experiment:
  name: evalhub-level1-optimized
EOF

evalhub eval run --config /tmp/evalhub-job-optimized.yaml --format json \
  | tee /tmp/evalhub-job-optimized-submit.json
export JOB_ID_OPTIMIZED=$(jq -r '.[0].resource.id // .[0].id' /tmp/evalhub-job-optimized-submit.json)
echo "JOB_ID_OPTIMIZED=${JOB_ID_OPTIMIZED}"

evalhub eval status "${JOB_ID_OPTIMIZED}" --watch
evalhub eval results "${JOB_ID_OPTIMIZED}" --format table
```



#### Step 7 — Compare baseline vs optimized

Read the results table for both jobs. On the optimized stack you typically see:

- **Higher** `requests_per_second`
- **Lower** `mean_ttft_ms` and `mean_itl_ms`

```bash
echo "=== Baseline ==="
evalhub eval results "${JOB_ID_BASELINE}" --format table

echo "=== Optimized (llm-d) ==="
evalhub eval results "${JOB_ID_OPTIMIZED}" --format table
```

Compare `output_tokens_per_second` (higher on optimized) and `mean_ttft_ms` (lower on optimized). Confirm Step 5 converged before Step 6 (`oc get pods -n llm-d-demo | rg qwen3-8b` — expect multiple GPU replicas and an EPP scheduler pod).

**Sample output** (concurrent profile, `rate: 8`, prefix-cache workload — values vary by cluster):

```text
=== Baseline ===
┏━━━━━━━━━━━━━━━━━┳━━━━━━━━━━┳━━━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━━━━━━━┓
┃ BENCHMARK       ┃ PROVIDER ┃ METRIC                   ┃ VALUE              ┃
┡━━━━━━━━━━━━━━━━━╇━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━┩
│ quick_perf_test │ guidellm │ mean_itl_ms              │ 22.42              │
│ quick_perf_test │ guidellm │ mean_ttft_ms             │ 448.91             │
│ quick_perf_test │ guidellm │ output_tokens_per_second │ 225.41             │
│ quick_perf_test │ guidellm │ prompt_tokens_per_second │ 1462.47            │
│ quick_perf_test │ guidellm │ requests_per_second      │ 1.70               │
└─────────────────┴──────────┴──────────────────────────┴────────────────────┘

=== Optimized (llm-d) ===
┏━━━━━━━━━━━━━━━━━┳━━━━━━━━━━┳━━━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━━━━━━━┓
┃ BENCHMARK       ┃ PROVIDER ┃ METRIC                   ┃ VALUE              ┃
┡━━━━━━━━━━━━━━━━━╇━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━┩
│ quick_perf_test │ guidellm │ mean_itl_ms              │ 20.38              │
│ quick_perf_test │ guidellm │ mean_ttft_ms             │ 125.84             │
│ quick_perf_test │ guidellm │ output_tokens_per_second │ 270.24             │
│ quick_perf_test │ guidellm │ prompt_tokens_per_second │ 1780.44            │
│ quick_perf_test │ guidellm │ requests_per_second      │ 2.10               │
└─────────────────┴──────────┴──────────────────────────┴────────────────────┘
```


| Metric                     | Baseline | Optimized | Change                     |
| -------------------------- | -------- | --------- | -------------------------- |
| `requests_per_second`      | 1.70     | 2.10      | **+24%**                   |
| `output_tokens_per_second` | 225      | 270       | **+20%**                   |
| `prompt_tokens_per_second` | 1462     | 1780      | **+22%**                   |
| `mean_ttft_ms`             | 449      | 126       | **−72%** (lower is better) |
| `mean_itl_ms`              | 22.4     | 20.4      | **−9%** (lower is better)  |


> **MLflow UI shows empty experiments:** On RHOAI 3.4, EvalHub creates MLflow experiment shells at job submit (`evalhub-level1-baseline`, `evalhub-level1-optimized`) but the **GuideLLM adapter reports metrics to EvalHub only**. Garak/lm-eval jobs do write runs has you will see in the level 2 demo. 

**Optional — longer benchmark:** edit the collection (Step 2) to use `throughput` instead of `quick_perf_test`, or override a single job:

```bash
cat > /tmp/evalhub-job-optimized-throughput.yaml <<EOF
name: evalhub-level1-optimized-throughput
model:
  url: ${GUIDELLM_MODEL_URL}
  name: alibaba/qwen3-8b
collection:
  id: ${COLLECTION_ID}
  benchmarks:
    - id: throughput
      provider_id: guidellm
experiment:
  name: evalhub-level1-optimized
EOF
```



#### Step 8 — Cancel or permanently delete jobs

```bash
evalhub eval cancel "${JOB_ID_BASELINE}" --hard-delete --yes 2>/dev/null || true
evalhub eval cancel "${JOB_ID_OPTIMIZED}" --hard-delete --yes 2>/dev/null || true
evalhub collections delete "${COLLECTION_ID}" --yes 2>/dev/null || true

rm -f /tmp/evalhub-collection.yaml /tmp/evalhub-collection-create.out \
      /tmp/evalhub-job-baseline.yaml /tmp/evalhub-job-baseline-submit.json \
      /tmp/evalhub-job-optimized.yaml /tmp/evalhub-job-optimized-submit.json
```

**Do not skip:** if Step 3 baseline patch is still active, re-run Step 5 before ending the session.

---



## 4) Validation checklist (must pass)

- `default-dsc` phase is **Ready**.
- Tenant namespace has `evalhub.trustyai.opendatahub.io/tenant=true` and does **not** have `opendatahub.io/application-namespace`.
- NetworkPolicy `${EVALHUB_NP_NAME}` exists in `${EVALHUB_NS}` (Section 2.1b).
- `EvalHub` CR `MLFLOW_TRACKING_URI` matches `oc get mlflow mlflow -n ${EVALHUB_NS} -o jsonpath='{.status.address.url}'` (includes `/mlflow` on RHOAI 3.5).
- EvalHub CLI connects (`evalhub health` in Section 3.2).
- GuideLLM provider lists `quick_perf_test` (`evalhub providers describe guidellm`).
- Custom performance collection is created and describable (`COLLECTION_ID` set).
- Baseline `LLMInferenceService` patch converges (`oc get llminferenceservice qwen3-8b -n llm-d-demo`).
- `MaaSModelRef/qwen3-8b` is `Ready` after Steps 3 and 5 (`oc get maasmodelref qwen3-8b -n llm-d-demo`).
- MaaS smoke test returns HTTP 200 (`curl ... ${MAAS_MODEL_URL}/models` with `${MAAS_API_KEY}`).
- Both jobs reach `completed` (`JOB_ID_BASELINE`, `JOB_ID_OPTIMIZED`).
- Results show GuideLLM metrics (`requests_per_second`, `mean_ttft_ms`) with **higher RPS / lower latency** on optimized vs baseline.
- Optimized stack restored (`qwen3-8b-values.yaml` re-applied; multiple replicas + EPP scheduler).
- MLflow experiment URLs appear in results (if MLflow is configured).

---



## 5) Troubleshooting quick fixes



### 401 Unauthorized from EvalHub API

- Mint a fresh ServiceAccount token:
`export TOKEN=$(oc create token "${EVALHUB_CLIENT_SA}" -n "${EVALHUB_TENANT_NS}" --duration=24h)`
- Confirm the RoleBinding exists:
`oc get rolebinding ${EVALHUB_CLIENT_SA}-access -n "${EVALHUB_TENANT_NS}"`



### 400 Bad request — missing `X-Tenant`

- Add `-H "X-Tenant: ${EVALHUB_TENANT_NS}"` to every request except `/api/v1/health`
- Set `evalhub config set tenant "${EVALHUB_TENANT_NS}"` — not `${EVALHUB_NS}`



### Job stuck **pending** — `Failed to send status to evalhub: timed out`

Evaluation Job pods report status to EvalHub through the **sidecar** → `https://evalhub.${EVALHUB_NS}.svc.cluster.local:8443`. The `${EVALHUB_NS}` NetworkPolicy blocks ingress from tenant namespaces unless you applied Section **2.1b**.

Symptoms:

- `evalhub eval status` shows **pending** while the job pod is **Running**
- Adapter logs: `Failed to send status to evalhub: timed out`
- Sidecar logs: `context deadline exceeded` on `POST .../api/v1/evaluations/jobs/.../events`

Fix — re-apply the NetworkPolicy (Section 2.1b):

```bash
oc get networkpolicy "${EVALHUB_NP_NAME}" -n "${EVALHUB_NS}" \
  || { echo "Missing — re-run Section 2.1b"; exit 1; }
```

**Do not** fix this by labeling `${EVALHUB_TENANT_NS}` with `opendatahub.io/application-namespace` — on RHOAI 3.5 that breaks the OpenShift AI dashboard and can leave `default-dsc` **Not Ready** (see Section 2 warning).

Verify from a running job pod (port must be open; health may return 401 without a token):

```bash
K8S_JOB=$(oc get job -n "${EVALHUB_TENANT_NS}" -l "job_id=${JOB_ID}" -o jsonpath='{.items[0].metadata.name}')
POD=$(oc get pods -n "${EVALHUB_TENANT_NS}" -l "job-name=${K8S_JOB}" -o jsonpath='{.items[0].metadata.name}')
oc exec -n "${EVALHUB_TENANT_NS}" "${POD}" -c sidecar -- \
  curl -sk --max-time 5 -o /dev/null -w 'health HTTP %{http_code}\n' \
  --cacert /etc/pki/ca-trust/source/anchors/service-ca.crt \
  "https://evalhub.${EVALHUB_NS}.svc.cluster.local:8443/health"
```



### 400 `mlflow_request_failed` — 404 HTML (wrong `MLFLOW_TRACKING_URI`)

On **RHOAI 3.5**, `MLFLOW_TRACKING_URI` must include the `/mlflow` suffix. A bare `https://mlflow....svc:8443` returns 404 HTML at job submit.

```bash
export MLFLOW_TRACKING_URI=$(oc get mlflow mlflow -n "${EVALHUB_NS}" -o jsonpath='{.status.address.url}')
echo "${MLFLOW_TRACKING_URI}"   # must end with /mlflow

oc patch evalhub "${EVALHUB_NAME}" -n "${EVALHUB_NS}" --type=merge -p "$(cat <<EOF
spec:
  env:
    - name: MLFLOW_TRACKING_URI
      value: "${MLFLOW_TRACKING_URI}"
EOF
)"
```



### 500 on `evalhub eval run` — not permitted to access secret `evalhub-model-auth`

EvalHub validates that the **API client** ServiceAccount (`${EVALHUB_CLIENT_SA}`) can `get` the
Secret named in `model.auth.secret_ref` **at job submit time** — before evaluation Job pods start.

- Confirm the Role includes the scoped rule from Section 3 (or run the Step 0 patch block).
- Confirm binding: `oc auth can-i get secret/evalhub-model-auth -n "${EVALHUB_TENANT_NS}" --as "system:serviceaccount:${EVALHUB_TENANT_NS}:${EVALHUB_CLIENT_SA}"`
— must print `yes`.
- Mint a fresh token after patching RBAC and update `evalhub config set token`.



### 401 Unauthorized from model endpoint

- Confirm `evalhub-model-auth` exists and contains the `api-key` key.
- Verify `${MAAS_API_KEY}` is valid for the MaaS route and model path.
- If using protected internal model: add RoleBinding for the evaluation job ServiceAccount to the model view role.

**GuideLLM-specific (**`401` **on** `/health`**,** `MaaSModelRef` **already** `Ready`**):** adapter logs show:

```text
httpx.HTTPStatusError: Client error '401 Unauthorized' for url '.../qwen3-8b/health'
```

`community-guidellm:v0.2.0` mounts the secret but never passes `api_key` to GuideLLM. Re-submit Steps 4/6 with `${GUIDELLM_MODEL_URL}` (in-cluster vLLM) instead of `${MAAS_MODEL_URL}`. Confirm the adapter command no longer hits the MaaS host:

```bash
oc logs -n "${EVALHUB_TENANT_NS}" <job-pod> -c adapter | rg 'Running command'
```



### 429 Too Many Requests from model endpoint

EvalHub jobs hammer the MaaS route with hundreds or thousands of inference calls. The Phase 6 example subscription (`1000` tokens / `24h`) is far too low.

- Check the active limit: `oc get maassubscription default-subscription -n models-as-a-service -o yaml | rg -A3 tokenRateLimits`
- Raise it before running evals (example for demos):

```bash
oc patch maassubscription default-subscription -n models-as-a-service --type=merge -p '{
  "spec": {
    "modelRefs": [{
      "name": "qwen3-8b",
      "namespace": "llm-d-demo",
      "tokenRateLimits": [{"window": "1h", "limit": 10000000}]
    }]
  }
}'
```

- Verify Limitador picked it up: `oc get tokenratelimitpolicy maas-trlp-qwen3-8b -n llm-d-demo -o yaml | rg -A2 'limit:|window:'`
- Cancel stuck jobs, then re-submit after the limit increase.

### OpenShift AI dashboard 404 / `default-dsc` Not Ready (mislabeled tenant)

If `${EVALHUB_TENANT_NS}` was labeled `opendatahub.io/application-namespace=true`, the gateway operator may provision `dashboard-redirect` in the tenant, the `rh-ai.apps...` dashboard returns **404**, and `default-dsc` can report **Not Ready** with `unknown namespace for the cache`.

Recovery:

```bash
# 1) Remove the label from the tenant (never add it back)
oc label namespace "${EVALHUB_TENANT_NS}" opendatahub.io/application-namespace- 2>/dev/null || true

# 2) Ensure the platform namespace has the label (DSC-managed)
oc get ns "${EVALHUB_NS}" -o jsonpath='{.metadata.labels.opendatahub\.io/application-namespace}{"\n"}'   # Expected: true

# 3) Delete stray gateway resources from the tenant
oc delete deploy dashboard-redirect -n "${EVALHUB_TENANT_NS}" --ignore-not-found
oc delete route data-science-gateway rhods-dashboard -n "${EVALHUB_TENANT_NS}" --ignore-not-found

# 4) Wait for operator reconcile (or restart if DSC stays Not Ready)
oc rollout status deploy/rhods-operator -n redhat-ods-operator --timeout=180s
oc get dsc default-dsc -o jsonpath='{.status.phase}{"\n"}'   # Expected: Ready
oc get httproute rhods-dashboard -n "${EVALHUB_NS}" -o jsonpath='{range .status.parents[*].conditions[?(@.type=="Accepted")]}{.status}{"\n"}{end}'
```

Then apply Section **2.1b** if job callbacks still time out.

### MLflow UI — experiments exist but no runs/metrics (GuideLLM)

EvalHub pre-creates an MLflow experiment when you submit a job. For **GuideLLM** on RHOAI 3.4, completed metrics are stored in **EvalHub's results API** (`evalhub eval results`) — not as MLflow runs. The experiment page looks empty even though the job succeeded.

Confirm:

```bash
# EvalHub has metrics (authoritative for GuideLLM)
evalhub eval results "${JOB_ID_BASELINE}" --format table

# MLflow DB shows experiment shell but zero runs for GuideLLM
oc exec -n redhat-ods-applications deploy/mlflow -- sqlite3 /mlflow/mlflow.db \
  "SELECT e.name, COUNT(r.run_uuid) AS runs FROM experiments e \
   LEFT JOIN runs r ON r.experiment_id=e.experiment_id \
   WHERE e.name IN ('evalhub-level1-baseline','evalhub-level1-optimized') \
   GROUP BY e.experiment_id;"
```

Garak/lm-eval runs under the same workspace **do** populate MLflow — filter by workspace `evalhub-demo` in the dashboard if you expect to see those.

### 400 `mlflow_request_failed` — `RESOURCE_ALREADY_EXISTS` (experiment name)

EvalHub creates an MLflow experiment at job submit time. On RHOAI 3.4, MLflow stores experiments in a
tenant **workspace** (same value as `${EVALHUB_TENANT_NS}`) with a `UNIQUE(workspace, name)` constraint.
Soft-deleting an experiment (`lifecycle_stage=deleted`) does **not** free the name — a previous demo run
that was cancelled or cleaned up can leave ghost rows and block re-submit with the same `experiment.name`.

Purge stale Level 1 demo experiments from the MLflow SQLite store (irreversible):

```bash
# Inspect what will be removed
oc exec -n redhat-ods-applications deploy/mlflow -- sqlite3 /mlflow/mlflow.db \
  "SELECT experiment_id, name, lifecycle_stage FROM experiments \
   WHERE workspace='${EVALHUB_TENANT_NS}' AND name LIKE 'evalhub-level1%';"

# Purge demo experiments + runs for this tenant
oc exec -n redhat-ods-applications deploy/mlflow -- sqlite3 /mlflow/mlflow.db "
DELETE FROM metrics WHERE run_uuid IN (
  SELECT run_uuid FROM runs WHERE experiment_id IN (
    SELECT experiment_id FROM experiments
    WHERE workspace='${EVALHUB_TENANT_NS}' AND name LIKE 'evalhub-level1%'));
DELETE FROM params WHERE run_uuid IN (
  SELECT run_uuid FROM runs WHERE experiment_id IN (
    SELECT experiment_id FROM experiments
    WHERE workspace='${EVALHUB_TENANT_NS}' AND name LIKE 'evalhub-level1%'));
DELETE FROM tags WHERE run_uuid IN (
  SELECT run_uuid FROM runs WHERE experiment_id IN (
    SELECT experiment_id FROM experiments
    WHERE workspace='${EVALHUB_TENANT_NS}' AND name LIKE 'evalhub-level1%'));
DELETE FROM runs WHERE experiment_id IN (
  SELECT experiment_id FROM experiments
  WHERE workspace='${EVALHUB_TENANT_NS}' AND name LIKE 'evalhub-level1%');
DELETE FROM experiment_tags WHERE experiment_id IN (
  SELECT experiment_id FROM experiments
  WHERE workspace='${EVALHUB_TENANT_NS}' AND name LIKE 'evalhub-level1%');
DELETE FROM experiments
  WHERE workspace='${EVALHUB_TENANT_NS}' AND name LIKE 'evalhub-level1%';
"
```

Then re-run Section 3.3. The same purge is part of soft cleanup (Section 6.1) — run it before each re-run of
this demo to avoid the collision.

---



## 6) Cleanup



### 6.1 Soft cleanup (keep EvalHub installed)

Run Step 8 from Section 3.3 if you have not already, then **restore the optimized inference stack** (mandatory if the baseline patch from Step 3 is still active):

```bash
helm template inference ./gitops/instance/llm-d/inference \
  -n llm-d-demo \
  -f gitops/instance/llm-d/inference/qwen3-8b-values.yaml \
  --set maas.enabled=true \
  | oc apply -n llm-d-demo -f -

oc wait llminferenceservice/qwen3-8b -n llm-d-demo \
  --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True --timeout=600s

oc wait maasmodelref/qwen3-8b -n llm-d-demo \
  --for=jsonpath='{.status.phase}'=Ready --timeout=300s
```

```bash
evalhub eval cancel "${JOB_ID_BASELINE}" --hard-delete --yes 2>/dev/null || true
evalhub eval cancel "${JOB_ID_OPTIMIZED}" --hard-delete --yes 2>/dev/null || true
evalhub collections delete "${COLLECTION_ID}" --yes 2>/dev/null || true

rm -f /tmp/evalhub-collection.yaml /tmp/evalhub-collection-create.out \
      /tmp/evalhub-job-baseline.yaml /tmp/evalhub-job-baseline-submit.json \
      /tmp/evalhub-job-optimized.yaml /tmp/evalhub-job-optimized-submit.json

oc delete secret evalhub-model-auth -n "${EVALHUB_TENANT_NS}" --ignore-not-found=true
```

**MLflow experiment purge (required before re-running the demo):**

`evalhub eval cancel --hard-delete` removes the EvalHub job record but does **not** purge MLflow
experiments. ODH MLflow soft-deletes experiment names without releasing the `(workspace, name)` slot, so
the next run with the same `experiment.name` fails with `RESOURCE_ALREADY_EXISTS` unless you purge stale
rows first.

```bash
oc exec -n redhat-ods-applications deploy/mlflow -- sqlite3 /mlflow/mlflow.db "
DELETE FROM metrics WHERE run_uuid IN (
  SELECT run_uuid FROM runs WHERE experiment_id IN (
    SELECT experiment_id FROM experiments
    WHERE workspace='${EVALHUB_TENANT_NS}' AND name LIKE 'evalhub-level1%'));
DELETE FROM params WHERE run_uuid IN (
  SELECT run_uuid FROM runs WHERE experiment_id IN (
    SELECT experiment_id FROM experiments
    WHERE workspace='${EVALHUB_TENANT_NS}' AND name LIKE 'evalhub-level1%'));
DELETE FROM tags WHERE run_uuid IN (
  SELECT run_uuid FROM runs WHERE experiment_id IN (
    SELECT experiment_id FROM experiments
    WHERE workspace='${EVALHUB_TENANT_NS}' AND name LIKE 'evalhub-level1%'));
DELETE FROM runs WHERE experiment_id IN (
  SELECT experiment_id FROM experiments
  WHERE workspace='${EVALHUB_TENANT_NS}' AND name LIKE 'evalhub-level1%');
DELETE FROM experiment_tags WHERE experiment_id IN (
  SELECT experiment_id FROM experiments
  WHERE workspace='${EVALHUB_TENANT_NS}' AND name LIKE 'evalhub-level1%');
DELETE FROM experiments
  WHERE workspace='${EVALHUB_TENANT_NS}' AND name LIKE 'evalhub-level1%';
"
```



### 6.2 Full cleanup (remove tenant + server)

***DO NOT RUN THIS IF YOU WANT TO RUN THE EVALHUB-DEMO-LEVEL2***

Removes demo evaluation data and the EvalHub server. **Does not** delete the platform namespace `redhat-ods-applications`.

```bash
# Tenant namespace (job SA, secrets, completed job artifacts)
oc delete networkpolicy "${EVALHUB_NP_NAME}" -n "${EVALHUB_NS}" --ignore-not-found=true
oc delete namespace "${EVALHUB_TENANT_NS}" --ignore-not-found=true

# EvalHub server + demo PostgreSQL in platform namespace
oc delete evalhub "${EVALHUB_NAME}" -n "${EVALHUB_NS}" --ignore-not-found=true
oc delete secret evalhub-db-credentials postgresql-init -n "${EVALHUB_NS}" --ignore-not-found=true
oc delete deploy,svc,pvc -l app=postgresql -n "${EVALHUB_NS}" --ignore-not-found=true
```

---



## 7) What to do next

After Level 1 is validated (GuideLLM baseline vs optimized, optimized stack restored per §6.1), proceed with:

1. **Level 2:** Quality / safety / accuracy CI gate (Garak + lm-eval) + OCI immutable artifact persistence — [evalhub-demo-level2.md](evalhub-demo-level2.md).
  **Level 2 prerequisites (from this guide):**
  - EvalHub CR **Ready** in `redhat-ods-applications` (§2) — skip if you only ran §6.1 soft cleanup
  - Tenant namespace `evalhub-demo` labeled with `evalhub.trustyai.opendatahub.io/tenant=true`, NetworkPolicy `${EVALHUB_NP_NAME}` in `${EVALHUB_NS}`, `${EVALHUB_CLIENT_SA}`, `${EVALHUB_JOB_SA}`, and `evalhub-model-auth`
  - `evalhub config set tenant evalhub-demo` and `evalhub health` succeed
  - At least one successful Level 1 GuideLLM job (`evalhub eval results` shows metrics)
  - ++If you ran **§6.2 full cleanup**, reinstall EvalHub (§2) and recreate the tenant before Level 2++
2. ++**Level 3:** Kueue queueing/preemption + protected production endpoint auth patterns.++

---



## References



### Primary product docs

- [Red Hat OpenShift AI Self-Managed 3.4: Evaluating AI systems (PDF)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/pdf/evaluating_ai_systems/Red_Hat_OpenShift_AI_Self-Managed-3.4-Evaluating_AI_systems-en-US.pdf)
- [Red Hat OpenShift AI Self-Managed 3.5: Evaluating AI systems — OCI export (§2.19)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html-single/evaluating_ai_systems/index#evalhub-export-evaluation-results-to-oci-registry_evaluate)



### EvalHub blog series

- [Part 1: How EvalHub manages two-layer Kubernetes control planes](https://developers.redhat.com/articles/2026/05/12/how-evalhub-manages-two-layer-kubernetes-control-planes)
- [Part 2: EvalHub: Because "looks good to me" isn't a benchmark](https://developers.redhat.com/articles/2026/05/19/evalhub-because-looks-good-me-isnt-benchmark)
- [Part 3: Evaluation-driven development with EvalHub](https://developers.redhat.com/articles/2026/06/02/evaluation-driven-development-evalhub)
- [Part 4: Understanding evaluation collections in EvalHub](https://developers.redhat.com/articles/2026/06/04/understanding-evaluation-collections-evalhub)
- [Part 5: Bring your own evaluation framework to EvalHub](https://developers.redhat.com/articles/2026/06/09/bring-your-own-evaluation-framework-evalhub)
- [Part 6: Add automated AI evaluations to your CI/CD pipeline](https://developers.redhat.com/articles/2026/06/11/add-automated-ai-evaluations-your-cicd-pipeline)
- [Part 7: Store immutable AI evaluation records with EvalHub and OCI](https://developers.redhat.com/articles/2026/06/16/store-immutable-ai-evaluation-records-evalhub-oci)
- [Part 8: Manage LLM evaluation workloads at scale with EvalHub and Kueue](https://developers.redhat.com/articles/2026/06/18/manage-llm-evaluation-workloads-scale-evalhub-and-kueue)
- [Part 9: Connect EvalHub to protected production model servers](https://developers.redhat.com/articles/2026/06/23/connect-evalhub-protected-production-model-servers)

