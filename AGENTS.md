# AGENTS.md — llm-d-demo Co-pilot Runbook

This file gives Claude Code persistent context for installing RHOAI 3.3 with llm-d
on OpenShift 4.20. Work through one phase per session. Always tell Claude which
phase you are on and paste any relevant error output before asking for help.

---

## Repo Layout

```
llm-d-guide/
├── gitops/
│   ├── operators/
│   │   ├── connectivity-link/       # Authorino + Limitador (Kuadrant stack)
│   │   ├── leader-worker-set/       # LeaderWorkerSet operator (required for llm-d)
│   │   ├── kueue-operator/          # Red Hat Build of Kueue (OPTIONAL — only for GPUaaS/distributed workloads)
│   │   ├── rhoai/                   # RHOAI operator subscription
│   │   ├── tempo-operator/          # Distributed tracing
│   │   ├── opentelemetry-operator/  # OTel collector
│   │   ├── grafana-operator/        # Optional dashboards
│   │   └── pipelines/               # OpenShift Pipelines (optional)
│   └── instance/
│       ├── nfd/                     # NodeFeatureDiscovery CR
│       ├── nvidia/                  # ClusterPolicy CR
│       ├── machine-sets/gpu-worker/ # Helm chart for GPU MachineSets (AWS)
│       ├── rhoai/                   # DSCInitialization + DataScienceCluster Helm chart
│       ├── llm-d/
│       │   ├── gateway/             # GatewayClass + Gateway Helm chart
│       │   └── inference/           # LLMInferenceService Helm chart
│       └── llm-d-monitoring/        # Prometheus + Grafana for llm-d metrics
├── metallb/                         # MetalLB config (bare metal only)
├── scripts/
│   ├── check-operators.sh           # Validates all required operators are Succeeded
│   └── preflight-validation.sh      # Pre-flight cluster checks with pass/fail summary
└── README.md                        # Full installation guide
```

---

## Operator Dependency Matrix

| Operator | llm-d | GPUaaS / Distributed Workloads | Notes |
|---|---|---|---|
| **LeaderWorkerSet** | ✅ Required | ✅ Required | Multi-node MoE and P/D disaggregation |
| **Connectivity Link** (Authorino + Limitador) | ✅ Required | ✅ Required | KServe auth + MaaS |
| **Red Hat Build of Kueue** | ❌ Not required | ✅ Required | Do NOT install for llm-d-only setups — causes namespace label conflicts |
| **NFD + NVIDIA GPU Operator** | ✅ Required | ✅ Required | GPU node detection and drivers |
| **cert-manager** | ✅ Required | ✅ Required | TLS lifecycle |

> ⚠️ **Important:** Installing the Kueue operator (even with `managementState: Removed` in the DSC)
> causes the RHOAI dashboard to label every new project with `kueue.openshift.io/managed=true`.
> This makes hardware profiles with `scheduling.type: Node` invisible in those projects.
> Only install Kueue if you specifically need GPUaaS or distributed workload queue management.

---

## Environment Variables

Collect these before starting. Claude will ask for any that are missing.

| Variable | Description | Example |
|---|---|---|
| `CLUSTER_DOMAIN` | Auto-detected via `oc get dns.config/cluster` | `apps.mycluster.example.com` |
| `AWS_REGION` | AWS region for MachineSets and Route53 | `eu-west-1` |
| `AWS_INSTANCE_TYPE` | GPU instance type | `g5.2xlarge` |
| `AMI_ID` | RHCOS AMI for the GPU nodes | `ami-0b8c325b7499597c6` |
| `AWS_INSTANCES_PER_AZ` | GPU nodes per availability zone | `1` |
| `HF_TOKEN` | HuggingFace token for gated models | `hf_...` |
| `GATEWAY_NAME` | Name for the llm-d gateway | `openshift-ai-inference` |
| `PROJECT` | Namespace for llm-d workloads | `llm-d-demo` |

---

## Phase Map

| Phase | Name | Approx. time | Human gate |
|---|---|---|---|
| 0 | Cluster validation | 5 min | Confirm env vars + StorageClass |
| 1 | ArgoCD + cert-manager + Let's Encrypt | 15–20 min | Verify certs `READY=True` |
| 2 | GPU nodes + NFD + NVIDIA GPU Operator | 20–40 min | Confirm GPU nodes are schedulable |
| 3 | Core operators + RHOAI | 20–30 min | Approve InstallPlans; CSVs `Succeeded` |
| 4 | Monitoring stack | 10 min | Optional sign-off |
| 5 | llm-d Quick Start | 15–20 min | Review curl test output |

---

## Phase 0 — Cluster Validation

**Goal:** Confirm the cluster is ready before installing anything.

**Claude should run these checks and report any failures:**

```bash
# OCP version — must be 4.20+
oc version

# Cluster admin access
oc whoami
oc auth can-i '*' '*' --all-namespaces

# Default StorageClass exists
oc get storageclass | grep '(default)'

# No ODH installed (must be absent)
oc get csv -A | grep -i opendatahub

# No Service Mesh 2.x installed (must be absent; SM3 is OK)
oc get csv -A | grep -i servicemeshoperator | grep -v servicemeshoperator3

# DNS base domain
oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}'

# Registry pull access (expect login succeeded)
oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' \
  | base64 -d | jq '.auths | keys'
```

**Human gate:** Confirm env vars, region, and that all checks pass before proceeding.

---

## Phase 1 — ArgoCD + cert-manager + Let's Encrypt

**Goal:** Install the GitOps operator and automate TLS certificate lifecycle.

**Install order:**
1. Red Hat OpenShift GitOps (ArgoCD) — via OperatorHub UI or CLI
2. RBAC for cert-manager (`oc apply -f -` the ClusterRole/Binding from README §3.1)
3. cert-manager operator via ArgoCD Application
4. Let's Encrypt ClusterIssuers + certificates for Ingress and API

**Key wait condition:**
```bash
# All 3 cert-manager pods must be Ready before proceeding
oc get pods -n cert-manager
# controller, cainjector, webhook — all must show 1/1 Running

# Then verify certificates
oc get certificates.cert-manager.io --all-namespaces \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[0].status'
```

**Human gate:** Every certificate must show `READY=True`. Do not proceed with a cert in `False` or `Unknown` state.

**Known gotcha:** If cert-manager webhook is slow to start, ArgoCD sync may fail on the first attempt. Re-sync the ArgoCD application after all 3 pods are Running.

---

## Phase 2 — GPU Nodes + NFD + NVIDIA GPU Operator

**Goal:** Add GPU worker nodes and install the hardware detection and driver stack.

**Install order:**
1. Node Feature Discovery (NFD) operator + `NodeFeatureDiscovery` CR (`oc apply -k gitops/instance/nfd`)
2. NVIDIA GPU Operator + `ClusterPolicy` CR (`oc apply -k gitops/instance/nvidia`)
3. GPU MachineSets (AWS only — use the Helm chart in `gitops/instance/machine-sets/gpu-worker`)

**Key wait conditions:**
```bash
# NFD labels applied to GPU nodes
oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true

# NVIDIA device plugin running on GPU nodes
oc get pods -n nvidia-gpu-operator -w

# GPU capacity visible on nodes
oc get nodes -o json | jq '.items[].status.capacity | select(."nvidia.com/gpu")'
```

**Human gate:** At least one node must show `nvidia.com/gpu` capacity before moving on. If nodes are still provisioning, wait — this can take 10–15 minutes on AWS.

**Known gotcha:** The ClusterPolicy webhook may reject the CR if the NFD labels aren't present yet. Apply NFD first, wait for labels, then apply nvidia.

---

## Phase 3 — Core Operators + RHOAI

**Goal:** Install Connectivity Link, LeaderWorkerSet, and RHOAI, then configure the DataScienceCluster.

> ⚠️ **Do NOT install the Kueue operator** unless you specifically need GPUaaS or distributed
> workload queue management (Ray, PyTorch distributed training). Installing Kueue causes the
> RHOAI dashboard to label all new projects with `kueue.openshift.io/managed=true`, which
> breaks hardware profile visibility for workbenches and model serving unless matching
> `Queue`-type hardware profiles and LocalQueues are also configured.

**Install order (sequence matters):**

```
connectivity-link  →  leader-worker-set  →  rhoai operator
       ↓
  (wait for CRDs)
       ↓
  helm template rhoai (DSCInitialization + DataScienceCluster)
       ↓
  (wait for controller pods)
```

**Key wait conditions:**
```bash
# Connectivity Link — AuthPolicy CRD must exist before RHOAI
oc wait --for=condition=Established crd/authpolicies.kuadrant.io --timeout=300s

# LeaderWorkerSet CRD — required for llm-d multi-node deployments
oc wait --for=condition=Established crd/leaderworkersets.leaderworkerset.x-k8s.io --timeout=300s

# RHOAI Dashboard CRD
oc wait --for=condition=Established crd/odhdashboardconfigs.opendatahub.io --timeout=600s

# After applying the DataScienceCluster:
oc wait --for=condition=Established crd/llminferenceservices.serving.kserve.io --timeout=300s
oc wait --for=condition=ready pod -l control-plane=odh-model-controller \
  -n redhat-ods-applications --timeout=300s
oc wait --for=condition=ready pod -l control-plane=kserve-controller-manager \
  -n redhat-ods-applications --timeout=300s
```

### Optional — Kueue (GPUaaS / Distributed Workloads only)

> ℹ️ Skip this section entirely if you are only deploying llm-d.
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
    opendatahub.io/dashboard-feature-visibility: '["workbench","modelServer"]'
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

> ⚠️ **Known issue (RHOAI 3.3.0):** The RHOAI dashboard does not reload its configuration
> when `disableKueue` is changed in `OdhDashboardConfig`. The dashboard keeps labeling new projects
> with `kueue.openshift.io/managed=true` until it is restarted (`oc rollout restart deployment/rhods-dashboard`).
> Even after restart, the label may persist if the dashboard's internal cache is not cleared.
> Workaround: always create namespaces via `oc new-project` (see below).

**Creating projects for llm-d workloads:**

Create projects normally from the RHOAI dashboard. If you encounter hardware profile visibility
issues after changing Kueue configuration (e.g. switching from Kueue enabled to disabled),
restart the dashboard and verify the `disableKueue` setting is applied. As a temporary workaround
while the dashboard is reloading its config, you can create namespaces directly via `oc`:

```bash
# TEMPORARY WORKAROUND — only if the dashboard is still labeling projects with
# kueue.openshift.io/managed=true after setting disableKueue: true and restarting
oc new-project <project-name>
oc label namespace <project-name> opendatahub.io/dashboard=true
```

**Human gates:**
- **InstallPlan approvals:** Some operators require manual approval. Claude will check and list pending plans, but you must confirm before Claude patches them.
- **CSV verification:** Run `./scripts/check-operators.sh` at the end. All required operators must be `Succeeded` before proceeding.

**Known gotchas:**
- Apply connectivity-link first — Authorino must be running before RHOAI configures authentication.
- `helm template rhoai | oc apply` may fail if CRDs aren't established yet. The wait commands above prevent this, but re-run them if you hit `resource mapping not found`.
- Leader Worker Set uses a retry loop (`until oc apply -k ...`) to handle install race conditions — this is expected behaviour, not an error.
- Do NOT install OpenShift Service Mesh 2.x — its CRDs conflict with the llm-d gateway.
- Serverless operator is NOT required for RHOAI 3.x.

---

## Phase 4 — Monitoring Stack

**Goal:** Install Tempo (tracing), OpenTelemetry (collector), and Grafana (dashboards).

**Install order:**
1. Tempo Operator
2. OpenTelemetry Operator
3. Grafana Operator (optional)

```bash
# All three can be applied in sequence; wait for CRDs between them
oc wait --for=condition=Established crd/instrumentations.opentelemetry.io --timeout=120s
```

**Human gate:** Optional. Confirm Grafana route is accessible if you want dashboards during llm-d testing.

---

## Phase 5 — llm-d Quick Start

**Goal:** Deploy the gateway, a namespace, and an LLMInferenceService, then test the endpoint.

**Pre-flight checks Claude must run before starting:**
```bash
# LLMInferenceService CRD available
oc get crd llminferenceservices.serving.kserve.io

# LeaderWorkerSet CRD available (required for MoE multi-node)
oc get crd leaderworkersets.leaderworkerset.x-k8s.io

# Controller pods running
oc get pods -n redhat-ods-applications \
  -l control-plane=odh-model-controller
oc get pods -n redhat-ods-applications \
  -l control-plane=kserve-controller-manager

# All operators healthy
./scripts/check-operators.sh
```

**Steps:** Follow README Quick Start §1–6 exactly. Claude will:
1. Detect `CLUSTER_DOMAIN` automatically
2. Generate the helm template commands with your env vars filled in
3. Apply and watch pod status
4. Run the `curl` tests and show you the response

**Human gate:** Review the chat completion response from Step 5. If the model returns a coherent answer, the deployment is successful.

**Known gotchas:**
- If the Gateway is not `PROGRAMMED=True`, check that Connectivity Link / Authorino is Running and the `GatewayClass` CR was created.
- If the LLMInferenceService is stuck `Not Ready`, describe it: `oc describe llminferenceservice <name> -n <namespace>` and check events.
- For OCI model images (`registry.redhat.io/rhelai1/...`), ensure the cluster pull secret includes Red Hat registry credentials.
- For MoE models (DeepSeek-R1, Mixtral), use the **Wide Expert-Parallelism** well-lit path which requires LeaderWorkerSet for multi-node orchestration.

---

## How to Start a Session

At the beginning of each Claude Code session, say:

> *"I'm on Phase \<N\>. Here are my env vars: AWS_REGION=... AWS_INSTANCE_TYPE=... [etc.] Let's continue."*

If something went wrong in a previous session, paste the error output and say which command failed. Claude will diagnose before continuing.

---

## Validation Commands (use anytime)

```bash
# All operator CSVs — any non-Succeeded is a problem
oc get csv -A | grep -v Succeeded

# RHOAI pods
oc get pods -n redhat-ods-applications

# llm-d CRDs
oc get crd | grep llminference

# LeaderWorkerSet CRD
oc get crd | grep leaderworkerset

# Gateway status
oc get gateway,httproute -n openshift-ingress

# Active inference services
oc get llminferenceservice -A

# GPU node capacity
oc get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.capacity.nvidia\.com/gpu'

# Hardware profiles visibility check
kubectl get hardwareprofile -n redhat-ods-applications \
  -o custom-columns="NAME:.metadata.name,TYPE:.spec.scheduling.type,VISIBILITY:.metadata.annotations.opendatahub\.io/dashboard-feature-visibility"
```

```bash
# OPTIONAL — Kueue status (only if Kueue was installed for GPUaaS/distributed workloads)
oc get clusterqueue
oc get localqueue -A
oc get resourceflavor
```

---

## Constraints and Rules for Claude

- **Never skip a wait condition** between phases. Timing errors are the most common failure mode.
- **Always check `check-operators.sh`** before starting Phase 5.
- **Always stop and ask** before patching an InstallPlan or applying anything that modifies cluster-wide RBAC.
- **Never install** Service Mesh 2.x, OpenShift Serverless, or Open Data Hub — these conflict with RHOAI 3.x.
- **Do NOT install Kueue** unless explicitly required for GPUaaS or distributed workloads — it causes namespace label conflicts with hardware profiles.
- **Prefer `oc apply -k`** over raw `oc apply -f` for kustomize paths — it respects the overlay ordering.
- If a command produces unexpected output, **stop and report** rather than continuing.