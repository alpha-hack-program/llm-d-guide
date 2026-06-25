# Phase 3 — Core Operators + RHOAI

> Part of the [llm-d-guide Co-pilot Runbook]](../../AGENTS.md). See the
> [Phase Map](../../AGENTS.md#phase-map) for the full sequence.

**Goal:** Install Connectivity Link, LeaderWorkerSet, and RHOAI, then configure the DataScienceCluster.

> **Do NOT install the Kueue operator** unless you specifically need GPUaaS or distributed
> workload queue management (Ray, PyTorch distributed training). Installing Kueue causes the
> RHOAI dashboard to label all new projects with `kueue.openshift.io/managed=true`, which
> breaks hardware profile visibility for workbenches and model serving unless matching
> `Queue`-type hardware profiles and LocalQueues are also configured.

**Install order (sequence matters):**

```
connectivity-link operator  →  Kuadrant CR (Ready=True)  →  leader-worker-set  →  RHOAI operator (OLM subscription)
                                       ↓
                                 (wait for CRDs)
                                       ↓
                                 RHOAI instance (DSCInitialization + DataScienceCluster)
                                       ↓
                                 (wait for controller pods)
                                       ↓
                                 monitoring stack (Tempo, OTel, Grafana)
```

### Step 1 — Connectivity Link (RHCL operator — Authorino + Limitador + Kuadrant CRDs)

```bash
oc apply -k ./gitops/operators/connectivity-link
# InstallPlan may require manual approval due to dependencies
oc get installplan -n openshift-operators | grep -i "requiresapproval"
# If an InstallPlan is pending, approve it:
# oc patch installplan <NAME> -n openshift-operators --type merge -p '{"spec":{"approved":true}}'
oc get csv -n openshift-operators -w | grep -E "rhcl|authorino|limitador"
# Wait for AuthPolicy CRD
oc wait --for=condition=Established crd/authpolicies.kuadrant.io --timeout=300s
```

Create the Kuadrant CR — instantiates the Authorino and Limitador operands:

```bash
helm template gitops/instance/maas/connectivity-link \
  --name-template maas-connectivity-link | oc apply -f -
oc wait kuadrant kuadrant -n kuadrant-system --for=condition=Ready --timeout=5m

# If it stays Not Ready with "istio/envoy gateway not installed",
# the operator just needs a restart to detect the built-in Gateway API controller:
#   oc delete pod -n openshift-operators -l app.kubernetes.io/name=kuadrant-operator
#   oc wait kuadrant kuadrant -n kuadrant-system --for=condition=Ready --timeout=5m
```

> **`Ready: False` with "istio / envoy gateway not installed"** — the built-in Gateway API controller is sufficient; no Service Mesh or separate gateway operator is needed. The Kuadrant operator sometimes misses it on first start. Restart the operator pod (see commented command above) and it will detect the controller on the next reconciliation. Do NOT search the marketplace or install any gateway operator — just restart the pod.

### Step 2 — Leader Worker Set

```bash
until oc apply -k ./gitops/operators/leader-worker-set; do
  echo "Waiting for LeaderWorkerSet CRD to become available..."
  sleep 10
done
oc wait --for=condition=Established crd/leaderworkersetoperators.operator.openshift.io --timeout=300s
oc wait --for=condition=Established crd/leaderworkersets.leaderworkerset.x-k8s.io --timeout=300s
oc get csv -n openshift-lws-operator -w | grep -E "leader-worker-set"
```

### Step 3 — Red Hat OpenShift AI Operator

**Human gate — RHOAI channel:** Before installing, ask the user which OLM profile to use:
- `stable` — GA release on `stable-3.x` (default)
- `ea` — Early Access on `beta` channel

Verify the `startingCSV` matches the live packagemanifest before applying:

```bash
# Check current CSV for the chosen channel
oc get packagemanifest rhods-operator -n openshift-marketplace \
  -o jsonpath='{.status.channels[?(@.name=="<channel>")].currentCSV}'

# If you need to switch channels after a first install, delete the Subscription and CSV first:
#   oc delete subscription rhods-operator -n redhat-ods-operator
#   oc delete csv <previous-csv> -n redhat-ods-operator

RHOAI_OLM_PROFILE="${RHOAI_OLM_PROFILE:-stable}"
helm template rhoai-operator ./gitops/operators/rhoai \
  --set olmProfile="${RHOAI_OLM_PROFILE}" | oc apply -f -
oc get csv -n redhat-ods-operator -w | grep -E "rhods"
```

### Step 4 — Configure OpenShift AI (DSCInitialization + DataScienceCluster)

```bash
oc wait --for=condition=Established crd/dashboards.components.platform.opendatahub.io --timeout=600s

# Render and apply (chart emits resources across multiple namespaces).
# Note: OdhDashboardConfig CRD may not be ready on the first pass. If the apply fails on
# OdhDashboardConfig, wait for the CRD and re-run:
#   oc wait --for=condition=Established crd/odhdashboardconfigs.opendatahub.io --timeout=120s
helm template rhoai ./gitops/instance/rhoai | oc apply -f -

# Wait for LLMInferenceService CRD and controller pods
oc wait --for=condition=Established crd/llminferenceservices.serving.kserve.io --timeout=300s
oc wait --for=condition=ready pod -l control-plane=odh-model-controller \
  -n redhat-ods-applications --timeout=300s
oc wait --for=condition=ready pod -l control-plane=kserve-controller-manager \
  -n redhat-ods-applications --timeout=300s
```

### Step 5 — Monitoring stack

```bash
# a) Tempo Operator (distributed tracing)
oc apply -k gitops/operators/tempo-operator
oc get csv -n openshift-operators -w | grep -E "tempo"

# b) OpenTelemetry Operator
oc apply -k gitops/operators/opentelemetry-operator
oc get csv -n openshift-operators -w | grep -E "opentelemetry"
oc wait --for=condition=Established crd/instrumentations.opentelemetry.io --timeout=120s

# c) Grafana Operator (optional — for custom dashboards)
oc apply -k gitops/operators/grafana-operator
oc get csv -n grafana-operator -w | grep -E "grafana"
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -n grafana-operator \
  -l operators.coreos.com/grafana-operator.grafana-operator= --timeout=300s
```

**Human gate:** All CSVs must show `Succeeded`. Run `./scripts/check-operators.sh` to verify.

---

## Optional — Kueue (GPUaaS / Distributed Workloads only)

> Skip this section entirely if you are only deploying llm-d.
> Only proceed if you need Ray, PyTorch distributed training, or GPU quota management across teams.

**1. Install the Red Hat Build of Kueue operator:**

```bash
# OPTIONAL — only for GPUaaS / distributed workloads
oc apply -k gitops/operators/kueue-operator
oc get csv -n openshift-operators -w | grep kueue
```

**2. Wait for Kueue CRDs:**

```bash
# OPTIONAL — only run if Kueue was installed above
oc wait --for=condition=Established crd/clusterqueues.kueue.x-k8s.io --timeout=600s
oc wait --for=condition=Established crd/resourceflavors.kueue.x-k8s.io --timeout=600s
oc wait --for=condition=Established crd/localqueues.kueue.x-k8s.io --timeout=600s
```

**3. Set Kueue to `Managed` in the DataScienceCluster:**

```bash
# OPTIONAL — only if Kueue operator is installed
oc patch datasciencecluster default-dsc \
  --type='merge' \
  -p '{"spec":{"components":{"kueue":{"managementState":"Managed","defaultClusterQueueName":"default","defaultLocalQueueName":"default"}}}}'
```

**4. Create a ClusterQueue and ResourceFlavor:**

```bash
# OPTIONAL — minimal Kueue setup for a single team/namespace
cat <<EOF | oc apply -f -
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: default-flavor
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: default
spec:
  namespaceSelector: {}
  resourceGroups:
  - coveredResources: ["cpu", "memory", "nvidia.com/gpu"]
    flavors:
    - name: default-flavor
      resources:
      - name: cpu
        nominalQuota: "64"
      - name: memory
        nominalQuota: "256Gi"
      - name: nvidia.com/gpu
        nominalQuota: "8"
EOF
```

**5. Create a LocalQueue in each Kueue-managed namespace:**

```bash
# OPTIONAL — run once per namespace that needs Kueue queue management
cat <<EOF | oc apply -f -
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: default
  namespace: <your-namespace>
spec:
  clusterQueue: default
EOF
```

**6. Create Hardware Profiles with `type: Queue` for Kueue-managed namespaces:**

```bash
# OPTIONAL — Kueue-managed namespaces require Queue-type hardware profiles
# Node-type profiles are invisible in namespaces with kueue.openshift.io/managed=true
cat <<EOF | oc apply -f -
apiVersion: infrastructure.opendatahub.io/v1
kind: HardwareProfile
metadata:
  name: default-cpu-queue
  namespace: redhat-ods-applications
  annotations:
    opendatahub.io/display-name: "Default CPU (Kueue)"
    opendatahub.io/disabled: "false"
spec:
  identifiers:
  - displayName: CPU
    identifier: cpu
    minCount: 1
    maxCount: 4
    defaultCount: 2
    resourceType: CPU
  - displayName: Memory
    identifier: memory
    minCount: 2Gi
    maxCount: 8Gi
    defaultCount: 4Gi
    resourceType: Memory
  scheduling:
    type: Queue
    queue:
      localQueueName: default
EOF
```

> **Known issue:** The RHOAI dashboard does not reload its configuration
> when `disableKueue` is changed in `OdhDashboardConfig`. The dashboard keeps labeling new projects
> with `kueue.openshift.io/managed=true` until it is restarted (`oc rollout restart deployment/rhods-dashboard`).
> Even after restart, the label may persist if the dashboard's internal cache is not cleared.
> Workaround: create namespaces via `oc new-project` when you need to avoid dashboard labelling issues (see below).

**Creating projects for llm-d workloads:**

Create projects normally from the RHOAI dashboard. If you encounter hardware profile visibility
issues after changing Kueue configuration (e.g. switching from Kueue enabled to disabled),
restart the dashboard and verify the `disableKueue` setting is applied. As a temporary workaround
while the dashboard is reloading its config, you can create namespaces directly via `oc`:

```bash
# TEMPORARY WORKAROUND — only if the dashboard is still labeling projects with
# kueue.openshift.io/managed=true after setting disableKueue: true and restarting
oc new-project <project-name>
oc label namespace <project-name> modelmesh-enabled=false opendatahub.io/dashboard=true
```

---

**Human gates:**
- **InstallPlan approvals:** Some operators require manual approval. The assistant should check and list pending plans, but you must confirm before it patches them.
- **CSV verification:** Run `./scripts/check-operators.sh` at the end. All required operators must be `Succeeded` before proceeding.

**Known gotchas:**
- **Connectivity Link install location:** The RHCL operator subscription is in `openshift-operators` (all-namespaces mode), NOT in `kuadrant-system`. The `kuadrant-system` namespace is created by the `Kuadrant` CR (`gitops/instance/maas/connectivity-link`) — it does not exist before that CR is applied.
- Apply connectivity-link first — Authorino must be running before RHOAI configures authentication.
- After the RHCL operator is ready, create the Kuadrant CR: `helm template gitops/instance/maas/connectivity-link --name-template maas-connectivity-link | oc apply -f -`. Without this CR, Authorino and Limitador pods are not deployed and MaaS auth/rate-limiting is silently unenforced.
- **Kuadrant CR `Ready: False` — "istio / envoy gateway not installed"** — the built-in Gateway API controller is sufficient. The Kuadrant operator sometimes fails to detect it on first start. Fix: restart the operator pod (`oc delete pod -n openshift-operators -l app.kubernetes.io/name=kuadrant-operator`) and wait for `Ready: True`. Do NOT search the marketplace or install any gateway operator.
- **`modelsAsService` must be `false` during Phase 3.** The `maas-api` pod requires both the MaaS gateway AND the `maas-db-config` database secret to exist before it can start. Enabling it before Phase 6 Step 4 (after gateway and database are ready) leaves the DataScienceCluster `Not Ready (modelsasservice)` with no maas-api pod. The default in `values.yaml` is already `false`; do not override it to `true` here. Enable it in Phase 6 Step 4 by re-applying the chart.
- `helm template rhoai | oc apply` may fail if CRDs aren't established yet. The wait commands above prevent this, but re-run them if you hit `resource mapping not found`.
- `helm template rhoai | oc apply` may also fail on `OdhDashboardConfig` on the first pass — the CRD is registered only after the Dashboard component initialises. Wait for `oc wait --for=condition=Established crd/odhdashboardconfigs.opendatahub.io` and re-run.
- **`OdhDashboardConfig` apply fails with `DEPRECATED: spec.dashboardConfig.mlflow must be removed`** — the `mlflow` field in `OdhDashboardConfig` was deprecated and the API server now rejects it. Remove the `mlflow:` line from `gitops/instance/rhoai/templates/odh-dashboard-config.yaml` if it is present. The current template has this removed already.
- Switching RHOAI channel in-place (patching the Subscription) is unreliable. If you need to change channels, delete the Subscription and CSV first, then re-apply with the new `olmProfile`.
- Leader Worker Set uses a retry loop (`until oc apply -k ...`) to handle install race conditions — this is expected behaviour, not an error.
- Do NOT install OpenShift Service Mesh 2.x — its CRDs conflict with the llm-d gateway. Service Mesh 3.x is only for **Llama Stack Operator**; it is not required for base RHOAI or llm-d.
- Serverless operator is NOT required for RHOAI 3.x (raw KServe deployment mode).

**End of Phase 3:** Stop here and report operator status to the user. Run `./scripts/check-operators.sh` and show the results. All required operators must be `Succeeded`. Wait for confirmation before proceeding to [Phase 4](04-monitoring.md).
