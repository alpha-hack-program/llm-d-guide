# AGENTS.md — llm-d-demo Co-pilot Runbook

This file gives assistants (Claude Code, OpenCode, Cursor, and compatible tools) persistent
context for installing **Red Hat OpenShift AI 3.4** (self-managed) with **llm-d** on
**OpenShift Container Platform 4.21**. The canonical, step-by-step manual is [`README.md`](README.md);
use this runbook for phased execution, wait conditions, and human gates. Work through one phase
per session. Always tell the assistant which phase you are on and paste any relevant error output
before asking for help.

---

## Repo Layout

```
llm-d-guide/
├── gitops/
│   ├── operators/
│   │   ├── connectivity-link/       # Authorino + Limitador (Kuadrant stack)
│   │   ├── cert-manager-operator/   # cert-manager subscription (GitOps / Helm)
│   │   ├── cert-manager-route53/    # Let's Encrypt ClusterIssuers + Ingress/API certs
│   │   ├── nfd/                     # Node Feature Discovery operator subscription
│   │   ├── nvidia/                  # NVIDIA GPU Operator subscription
│   │   ├── leader-worker-set/       # LeaderWorkerSet operator (required for llm-d)
│   │   ├── kueue-operator/          # Red Hat Build of Kueue (OPTIONAL — only for GPUaaS/distributed workloads)
│   │   ├── rhoai/                   # RHOAI operator OLM subscription (Helm — channel/CSV presets)
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
│       ├── llm-d-monitoring/        # Prometheus + Grafana for llm-d metrics
│       └── maas/
│           ├── connectivity-link/   # Kuadrant CR (kuadrant-system namespace + Kuadrant instance)
│           ├── gateway/             # GatewayClass + maas-default-gateway Helm chart
│           ├── rbac/                # OpenShift Groups for MaaS subscription-based access control
│           ├── database/            # MaaS API backing store
│           └── monitoring/          # Grafana dashboards + Prometheus rules for MaaS
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
| **Connectivity Link** (Authorino + Limitador) | ✅ Required | ✅ Required | KServe auth, llm-d gateway, MaaS; Authorino is the token-auth piece. Installing the operator alone is not enough — a `Kuadrant` CR must also be created in `kuadrant-system` (`gitops/instance/maas/connectivity-link`) to deploy the actual operands. |
| **LeaderWorkerSet** | ✅ Required | ✅ Required | Multi-node MoE and P/D disaggregation |
| **Red Hat Build of Kueue** | ❌ Not required | ✅ Required | Do NOT install for llm-d-only setups — causes namespace label conflicts |
| **NFD + NVIDIA GPU Operator** | ✅ Required | ✅ Required | GPU node detection and drivers |
| **cert-manager** (Operator for Red Hat OpenShift) | ✅ Recommended | ✅ Recommended | Automates TLS for RHOAI, llm-d, OTel, and related components; manual certs are valid if you manage them yourself |

> ⚠️ **Important:** Installing the Kueue operator (even with `managementState: Removed` in the DSC)
> causes the RHOAI dashboard to label every new project with `kueue.openshift.io/managed=true`.
> This makes hardware profiles with `scheduling.type: Node` invisible in those projects.
> Only install Kueue if you specifically need GPUaaS or distributed workload queue management.

---

## Environment Variables

Collect these before starting. The assistant should ask for any that are missing.

| Variable | Description | Example |
|---|---|---|
| `CLOUD` | Cloud provider for cert-manager chart: `aws` (Route53 DNS-01) or `none` (bare metal / non-AWS). **Must be confirmed with the user before Phase 1 — do not default.** | `aws` |
| `CLUSTER_DOMAIN` | Cluster DNS base domain: from `oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}'` (cert-manager / Route53 flows in README) | `apps.mycluster.example.com` |
| `AWS_REGION` / `AWS_DEFAULT_REGION` | AWS region for GPU MachineSets (`AWS_REGION`) and Let's Encrypt Route53 issuer (`AWS_DEFAULT_REGION` in README examples) | `eu-west-1` |
| `AWS_INSTANCE_TYPE` | GPU instance type | `g5.2xlarge` |
| `AMI_ID` | RHCOS AMI for the GPU nodes | `ami-0b8c325b7499597c6` |
| `AWS_INSTANCES_PER_AZ` | GPU nodes per availability zone | `1` |
| `INFRA_ID` | OpenShift infrastructure name for AWS MachineSet chart (`oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}'`) | `mycluster-abcd123` |
| `HF_TOKEN` | HuggingFace token for gated models | `hf_...` |
| `GATEWAY_NAME` | Name for the llm-d gateway | `openshift-ai-inference` |
| `PROJECT` | Namespace for llm-d workloads | `llm-d-demo` |
| `RHOAI_OLM_PROFILE` | RHOAI **operator** install preset: `stable` (default) = `stable-3.x`; `ea` = `beta` channel. Verify current CSV via `packagemanifest` before use. Passed to `helm template ./gitops/operators/rhoai --set olmProfile=...` | `stable` |

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
| 6 | MaaS — Gateway + Kuadrant CR + publish model | 10–15 min | Verify `LLMInferenceService` `Ready: True` via MaaS route |

---

## Phase 0 — Cluster Validation

**Goal:** Confirm the cluster is ready before installing anything.

**The assistant should run these checks and report any failures:**

```bash
# OCP version — must be 4.21+
oc version

# Cluster admin access
oc whoami
oc auth can-i '*' '*' --all-namespaces

# Default StorageClass exists
oc get storageclass | grep '(default)'

# No ODH installed (must be absent)
oc get csv -A | grep -i opendatahub

# No Service Mesh 2.x installed (must be absent). SM 3.x is only for Llama Stack, not llm-d.
oc get csv -A | grep -i servicemeshoperator | grep -v servicemeshoperator3

# Connected clusters: plan outbound access to registry.redhat.io and quay.io (or mirrors)

# DNS base domain
oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}'

# Registry pull access (expect login succeeded)
oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' \
  | base64 -d | jq '.auths | keys'
```

**Human gate:** Confirm env vars, region, and that all checks pass before proceeding.

**End of Phase 0:** Stop here and report validation results to the user. Wait for confirmation before proceeding to Phase 1.

---

## Phase 1 — ArgoCD + cert-manager + Let's Encrypt

**Goal:** Install the GitOps operator and automate TLS certificate lifecycle.

**Before starting Phase 1 — ask the user:**
> "Is this cluster running on AWS, or on bare metal / a non-AWS cloud?
> - **AWS** → cert-manager will use Route53 DNS-01 via CCO (`cloud=aws`).
> - **Bare metal / non-AWS** → no CredentialsRequest is created (`cloud=none`).
>
> Which is it?"

Do NOT pass `--set cloud=aws` (or `cloud=none`) without an explicit answer from the user.

**MANDATORY: Validate cluster domain extraction (AWS only):**

Before applying the cert-manager-route53 chart, run the validation script to ensure the cluster
domain is extracted correctly:

```bash
./scripts/validate-cluster-domain.sh
```

This script validates by comparing the base domain against the cluster's apps domain:
- Extracts `dns.config/cluster .spec.baseDomain` (cluster base domain)
- Extracts `ingresses.config/cluster .spec.domain` (apps domain)
- Validates that apps domain == `apps.<baseDomain>` (platform-agnostic check)
- Outputs the correct values to use with the cert-manager-route53 chart

**Critical validation:** The value must match what's actually in the cluster's `dns.config/cluster .spec.baseDomain`

The validation compares what you extracted against the cluster's actual apps domain:
- If cluster has: baseDomain=`mycluster.example.com`, apps=`apps.mycluster.example.com`
  - ✅ Correct extraction: `mycluster.example.com` (matches cluster)
  - ❌ Wrong extraction: `example.com` (doesn't match - you got the parent domain instead)

The validation works for ANY OpenShift cluster by checking internal consistency.

If the validation script fails, **stop** and fix the domain extraction before proceeding.

**⚠️ CRITICAL — Confirm cluster domain with the user:**

After running the validation script, **STOP and ask the user to confirm** that the extracted cluster domain is correct:

> "The validation script extracted the cluster base domain as: `<extracted-domain>`
> 
> Is this correct? This value is CRITICAL for Let's Encrypt certificate issuance. If wrong, certificates will fail to validate and Phase 1 cannot succeed.
> 
> Please confirm before I proceed with cert-manager-route53 installation."

Do NOT proceed with applying the cert-manager-route53 chart until the user explicitly confirms the domain is correct.

**Route53 zone accessibility check (AWS only):**

After validation, verify that Route53 zones are accessible via the cluster's AWS credentials:
- The OpenShift installer creates a **private** hosted zone for the cluster base domain
- The **public parent zone** must be accessible for DNS-01 challenges to work
- For AWS IPI clusters, both zones are typically in the same AWS account

If Route53 zones are not accessible (e.g., DNS hosted externally), **stop here** and ask the user whether to:
1. Switch to `cloud=none` and manual certificates
2. Use HTTP-01 challenges instead of DNS-01 (if applicable)
3. Skip TLS automation for this phase

**Install order:**
1. *(Optional)* Red Hat OpenShift GitOps (ArgoCD) — via OperatorHub UI or CLI. Not required if applying manifests directly with `helm template | oc apply`.
2. cert-manager operator — `helm template gitops/operators/cert-manager-operator --set cloud=${CLOUD} | oc apply -f -` where `CLOUD` is `aws` or `none` (confirmed with user above). ArgoCD `Application` path documented in README section 3.1 as an alternative.
3. Let's Encrypt ClusterIssuers + certificates for Ingress and API — `helm template gitops/operators/cert-manager-route53 --set clusterDomain=<base-domain> --set route53.region=<region> | oc apply -f -` (where `base-domain` is from `oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}'`, NOT the apps ingress domain)

**Key wait condition:**
```bash
# All 3 cert-manager pods must be Ready before proceeding
oc get pods -n cert-manager
# controller, cainjector, webhook — all must show 1/1 Running

# Then verify certificates (README section 3.1 uses STATUS + READY columns)
oc get certificates.cert-manager.io --all-namespaces \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[0].type,READY:.status.conditions[0].status'
```

**Human gate:** Every certificate must show `READY=True`. Do not proceed with a cert in `False` or `Unknown` state.

**Known gotchas:**
- The first `helm template | oc apply` will fail on the `CertManager` CR because the operator CRD isn't registered until the CSV reaches `Succeeded`. Wait for `Succeeded`, then re-run the same command — it applies cleanly on the second pass.
- If using ArgoCD: if the cert-manager webhook is slow to start, the ArgoCD sync may fail on the first attempt. Re-sync after all 3 pods are Running.

**End of Phase 1:** Stop here and report certificate status to the user. All certificates must show `READY=True`. Wait for confirmation before proceeding to Phase 2.

---

## Phase 2 — GPU Nodes + NFD + NVIDIA GPU Operator

**Goal:** Add GPU worker nodes and install the hardware detection and driver stack.

**Before starting Phase 2 — ask the user:**
> "How many availability zones do you want GPU nodes in?
> - **All 3 AZs** (a, b, c) — recommended for production; 3 GPU nodes total (1 per AZ).
> - **Single AZ** — sufficient for a single-model test; cheaper, faster to provision.
> Which would you like?"

Do NOT decide this yourself — the number of GPU nodes affects cost and scheduling decisions that belong to the user.

**Install order:**
1. GPU MachineSets (AWS only) — start node provisioning first so nodes are ready by the time operators finish installing:
   ```bash
   export INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
   export AWS_REGION="${AWS_REGION:=eu-west-1}"
   export AMI_ID=$(oc get machineset -n openshift-machine-api \
     -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.ami.id}')
   export AWS_INSTANCE_TYPE="${AWS_INSTANCE_TYPE:=g5.2xlarge}"
   export AWS_INSTANCES_PER_AZ=1

   # All 3 AZs → 3 MachineSets, one per AZ (3 GPU nodes total)
   # Single AZ → replace "a b c" with just "a" (or the user's chosen AZ)
   for AZ in a b c; do
     helm template gpu-worker ./gitops/instance/machine-sets/gpu-worker \
       --set infrastructureId="${INFRA_ID}" \
       --set region=${AWS_REGION} \
       --set instanceType=${AWS_INSTANCE_TYPE} \
       --set amiId="${AMI_ID}" \
       --set devicePluginConfig="" \
       --set az=${AZ} | oc apply -f -
   done
   ```
   Use the AZ choice the user confirmed above. **Do not default to a single AZ** without explicit user approval — 3 AZs means 3 separate MachineSets, 3 GPU nodes.
2. NFD operator — `bash gitops/operators/nfd/install.sh` (dynamically resolves channel + CSV from `packagemanifest`; or via OperatorHub: search "Node Feature Discovery", namespace `openshift-nfd`)
3. NVIDIA GPU Operator — `bash gitops/operators/nvidia/install.sh` (dynamically resolves channel + CSV; or via OperatorHub: search "NVIDIA GPU Operator", namespace `nvidia-gpu-operator`)
4. `NodeFeatureDiscovery` CR — `oc apply -k gitops/instance/nfd` (after NFD CSV is `Succeeded`)
5. `ClusterPolicy` CR — `oc apply -k gitops/instance/nvidia` (after NVIDIA CSV is `Succeeded`)

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

**End of Phase 2:** Stop here and report GPU node status to the user. Show the output of the GPU capacity check. Wait for confirmation before proceeding to Phase 3.

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
connectivity-link  →  leader-worker-set  →  helm template rhoai-operator (OLM subscription)
       ↓
  (wait for CRDs)
       ↓
  helm template rhoai (DSCInitialization + DataScienceCluster)
       ↓
  (wait for controller pods)
```

**Human gate — RHOAI channel:** Before installing the RHOAI operator, ask the user which OLM profile to use:
- `stable` — GA release on `stable-3.x` (default)
- `ea` — Early Access on `beta` channel

Verify the `startingCSV` in `gitops/operators/rhoai/values.yaml` matches the live packagemanifest before applying:
```bash
oc get packagemanifest rhods-operator -n openshift-marketplace \
  -o jsonpath='{.status.channels[?(@.name=="<channel>")].currentCSV}'
```
Then apply: `helm template rhoai-operator gitops/operators/rhoai --set olmProfile=<stable|ea> | oc apply -f -`

**Key wait conditions:**
```bash
# Connectivity Link — AuthPolicy CRD must exist before RHOAI
oc wait --for=condition=Established crd/authpolicies.kuadrant.io --timeout=300s

# Leader Worker Set — README applies with `until oc apply -k ./gitops/operators/leader-worker-set`
# Operator CRD (subscription/CSV in openshift-lws-operator); workload CRD for LWS objects:
oc wait --for=condition=Established crd/leaderworkersetoperators.operator.openshift.io --timeout=300s
oc wait --for=condition=Established crd/leaderworkersets.leaderworkerset.x-k8s.io --timeout=300s

# RHOAI — wait before `helm template rhoai ./gitops/instance/rhoai | oc apply -f -`
oc wait --for=condition=Established crd/dashboards.components.platform.opendatahub.io --timeout=600s

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

> ⚠️ **Known issue:** The RHOAI dashboard does not reload its configuration
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

### Optional — OpenShift Pipelines (Data Science Pipelines only)

> ℹ️ Skip if you only need llm-d inference. Install when using **Data Science Pipelines** in RHOAI.

```bash
oc apply -k gitops/operators/pipelines
# InstallPlan may require manual approval (wait for the InstallPlan to appear):
INSTALLPLAN_NAME=$(oc get installplan -n openshift-operators -o json | \
  jq -r '.items[] | select(.spec.clusterServiceVersionNames[]? | contains("openshift-pipelines-operator-rh")) | .metadata.name')
oc patch installplan "$INSTALLPLAN_NAME" -n openshift-operators \
  --type merge --patch '{"spec":{"approved":true}}'
oc get csv -n openshift-operators -w | grep -E "pipelines"
```

**Human gates:**
- **InstallPlan approvals:** Some operators require manual approval. The assistant should check and list pending plans, but you must confirm before it patches them.
- **CSV verification:** Run `./scripts/check-operators.sh` at the end. All required operators must be `Succeeded` before proceeding.

**Known gotchas:**
- **Connectivity Link install location:** The RHCL operator subscription is in `openshift-operators` (all-namespaces mode), NOT in `kuadrant-system`. The `kuadrant-system` namespace is created by the `Kuadrant` CR (`gitops/instance/maas/connectivity-link`) — it does not exist before that CR is applied.
- Apply connectivity-link first — Authorino must be running before RHOAI configures authentication.
- After the RHCL operator is ready, create the Kuadrant CR: `helm template gitops/instance/maas/connectivity-link --name-template maas-connectivity-link | oc apply -f -`. Without this CR, Authorino and Limitador pods are not deployed and MaaS auth/rate-limiting is silently unenforced. If the CR stays `Ready: False` with `MissingDependency (istio/envoy gateway)` on OCP 4.19+, delete and restart the operator pod — it will detect the OCP built-in Gateway API on the next start.
- **`modelsAsService` must be `false` during Phase 3.** The `maas-api` pod requires both the MaaS gateway AND the `maas-db-config` database secret to exist before it can start. Enabling it before Phase 6 Step 4 (after gateway and database are ready) leaves the DataScienceCluster `Not Ready (modelsasservice)` with no maas-api pod. The default in `values.yaml` is already `false`; do not override it to `true` here. Enable it in Phase 6 Step 4 by re-applying the chart.
- `helm template rhoai | oc apply` may fail if CRDs aren't established yet. The wait commands above prevent this, but re-run them if you hit `resource mapping not found`.
- `helm template rhoai | oc apply` may also fail on `OdhDashboardConfig` on the first pass — the CRD is registered only after the Dashboard component initialises. Wait for `oc wait --for=condition=Established crd/odhdashboardconfigs.opendatahub.io` and re-run.
- **`OdhDashboardConfig` apply fails with `DEPRECATED: spec.dashboardConfig.mlflow must be removed`** — the `mlflow` field in `OdhDashboardConfig` was deprecated and the API server now rejects it. Remove the `mlflow:` line from `gitops/instance/rhoai/templates/odh-dashboard-config.yaml` if it is present. The current template has this removed already.
- Switching RHOAI channel in-place (patching the Subscription) is unreliable. If you need to change channels, delete the Subscription and CSV first, then re-apply with the new `olmProfile`.
- Leader Worker Set uses a retry loop (`until oc apply -k ...`) to handle install race conditions — this is expected behaviour, not an error.
- Do NOT install OpenShift Service Mesh 2.x — its CRDs conflict with the llm-d gateway. Service Mesh 3.x is only for **Llama Stack Operator**; it is not required for base RHOAI or llm-d.
- Serverless operator is NOT required for RHOAI 3.x (raw KServe deployment mode).

**End of Phase 3:** Stop here and report operator status to the user. Run `./scripts/check-operators.sh` and show the results. All required operators must be `Succeeded`. Wait for confirmation before proceeding to Phase 4.

---

## Phase 4 — Monitoring Stack

**Goal:** Install COO for llm-d metrics dashboards.

```bash
# Enable User Workload Monitoring (MANDATORY)
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF

# Install Cluster Observability Operator
oc apply -k gitops/operators/cluster-observability-operator

# Deploy Perses dashboard
oc apply -f gitops/instance/llm-d-observability/perses-dashboard-intelligent-inference.yaml
```

**Access:** OpenShift Console → **Observe** → **Dashboards** (Perses tab)

For complete setup and troubleshooting:  
[gitops/instance/llm-d-observability/LLM-D-MONITORING-INTEGRATION.md](gitops/instance/llm-d-observability/LLM-D-MONITORING-INTEGRATION.md)

**End of Phase 4:** Stop here and report monitoring stack status to the user. Verify COO CSV is Succeeded. Wait for confirmation before proceeding to Phase 5.

---

## Phase 5 — llm-d Quick Start

**Goal:** Deploy the gateway, a namespace, and an LLMInferenceService, then test the endpoint.

**Pre-flight checks the assistant must run before starting:**
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

# User Workload Monitoring enabled (MANDATORY for metrics)
oc get configmap cluster-monitoring-config -n openshift-monitoring \
  -o jsonpath='{.data.config\.yaml}' | grep enableUserWorkload
# Expected: enableUserWorkload: true
# If not enabled, STOP and enable it (see README §8 Step 6.2) before proceeding

# Prometheus user-workload pods running
oc get pods -n openshift-user-workload-monitoring | grep prometheus-user-workload
# Expected: prometheus-user-workload-0 and prometheus-user-workload-1 Running
```

**Steps:** Follow README **Quick Start** (Steps 1–6: Gateway, namespace, LLMInferenceService, verify, curl tests, optional monitoring). The assistant should:
1. Set gateway **`clusterDomain`** from `oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'` (README Step 1 — apps ingress domain), not from `dns.config` unless you intentionally unify them
2. **Gateway TLS:** if Let's Encrypt `ingress-certs` already exists in `openshift-ingress` (Phase 1 complete), use `--set tls.secretName=ingress-certs` — no need to generate a new cert
3. Create the workload namespace with `modelmesh-enabled=false` and `opendatahub.io/dashboard=true` (README Step 2)
4. **Ask the user which model/storage type to deploy** before generating the inference chart: OCI (`registry.redhat.io/rhelai1/...` — no HF token needed, pull secret must include `registry.redhat.io`) or HuggingFace (requires `HF_TOKEN` for gated models)
5. Generate `helm template` / `oc apply` for gateway and inference with your env vars
6. Apply and watch pod / `LLMInferenceService` status
7. Run the README `curl` tests (models, completions, chat completions) and show the response
8. Optionally apply `gitops/instance/llm-d-monitoring` per README Step 6

**Human gate:** Review the chat completion response from the Quick Start test step. If the model returns a coherent answer, the deployment is successful.

**Known gotchas:**
- If the Gateway is not `PROGRAMMED=True`, check that Connectivity Link / Authorino is Running and the `GatewayClass` CR was created.
- If the LLMInferenceService is stuck `Not Ready`, describe it: `oc describe llminferenceservice <name> -n <namespace>` and check events.
- If `HTTPRoutesReady: False` with `NotAllowedByListeners`: the model namespace is missing from the MaaS gateway's `allowedRoutes`. Re-apply the gateway chart with `--set "gateway.modelNamespaces={<namespace>}"` (see README §9.2).
- **Hardware profile name:** The admission webhook `hardwareprofile-llmisvc-injector.opendatahub.io` validates the profile name against existing `HardwareProfile` CRs in `redhat-ods-applications`. The chart in `gitops/instance/rhoai` creates three profiles: `gpu-profile`, `gpu-kueue-profile`, and `nvidia-a10g-profile`. The pre-existing `qwen3-8b-values.yaml` references `nvidia-a10g-profile`. Verify available profiles with `oc get hardwareprofile -n redhat-ods-applications` before applying the inference chart.
  - `gpu-profile` — generic GPU, `scheduling.type: Node`, GPU toleration only, no Kueue dependency.
  - `gpu-kueue-profile` — `scheduling.type: Queue`; requires Kueue and a `LocalQueue` named `default` in the workload namespace.
  - `nvidia-a10g-profile` — `scheduling.type: Node` with `nodeSelector: nvidia.com/gpu.product: NVIDIA-A10G`; use on mixed-GPU clusters to pin to A10G nodes.
- **Re-applying LLMInferenceService drops unlisted env vars:** `oc apply` uses strategic merge patch — the `env` list is replaced, not merged. Any env var absent from the rendered YAML (including `VLLM_ADDITIONAL_ARGS`) is silently removed. Always pass the per-model values file with `-f` on every `helm template … | oc apply`.
- **`LLMInferenceService` API version:** The inference chart generates `apiVersion: serving.kserve.io/v1alpha2`. Resources applied with `v1alpha1` will not show the MaaS toggle or other advanced fields in the RHOAI dashboard edit form.
- **GPU update strategy — not configurable via CRD:** The scheduler Deployment is always `Recreate`; the main workload is always `RollingUpdate`. The `updateStrategy` value in the inference chart is silently dropped by the API server.
- **`maas.enabled` in per-model values files:** Set `maas.enabled: false` when deploying in Phase 5 (llm-d only). Setting it `true` before the MaaS gateway and Kuadrant policies are in place (Phase 6) triggers reconcile errors in the maas-controller and does not enable MaaS. Flip it to `true` only during Phase 6 when publishing the model to MaaS.
- For OCI model images (`registry.redhat.io/rhelai1/...`), ensure the cluster pull secret includes Red Hat registry credentials.
- For MoE models (DeepSeek-R1, Mixtral), use the **Wide Expert-Parallelism** well-lit path which requires LeaderWorkerSet for multi-node orchestration.
- **Model Registry / model-catalog API 500:** If migrations did not apply, restart model-catalog: `oc rollout restart deployment/model-catalog -n rhoai-model-registries` (README Appendix B).

**Verify intelligent routing is working (recommended):**

Run the verification script to confirm EPP scheduler is making routing decisions and prefix cache is operational:

```bash
./scripts/verify-intelligent-router.sh
```

**Expected output:**
- 20/20 requests return HTTP 200
- Prefix cache queries increase by ~680 tokens
- Prefix cache hits increase by ~640 tokens (~94% hit rate)
- EPP logs show 20 "Request handled" routing decisions with selected endpoints

**What this proves:**
- ✅ Gateway routes through InferencePool (not basic Service LB)
- ✅ EPP scheduler making per-request routing decisions via gRPC
- ✅ Prefix cache optimization active (94% hit rate)
- ✅ Full llm-d intelligent routing stack operational

For detailed explanation, architecture diagrams, troubleshooting, and multi-replica testing, see: [llm-d Intelligent Routing Verification Guide](LLMD-INTELLIGENT-ROUTING-VERIFICATION.md)

---

**Verify monitoring integration (MANDATORY if User Workload Monitoring is enabled):**

The inference chart automatically creates ServiceMonitors. Verify they are scraping metrics:

```bash
# 1. Check ServiceMonitors were created
oc get servicemonitor -n <namespace> -l app.kubernetes.io/name=<serviceName>
# Expected for intelligent-inference: 2 ServiceMonitors (workload + EPP)
# Expected for P/D disaggregation: 1 ServiceMonitor (workload only)

# 2. Verify Prometheus targets are healthy
oc port-forward -n openshift-user-workload-monitoring prometheus-user-workload-0 9090:9090 &
# Open http://localhost:9090/targets and search for your namespace
# Expected: State: UP for all targets

# 3. Send test traffic to generate metrics
INFERENCE_URL=$(oc get llminferenceservice <serviceName> -n <namespace> -o jsonpath='{.status.url}')
SYSTEM_PROMPT="You are a helpful AI assistant specialized in OpenShift and Kubernetes."

for i in {1..10}; do
  curl -sk -X POST "${INFERENCE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"<model-name>\",
      \"messages\": [
        {\"role\": \"system\", \"content\": \"${SYSTEM_PROMPT}\"},
        {\"role\": \"user\", \"content\": \"Question ${i}: What is a pod?\"}
      ],
      \"max_tokens\": 50
    }"
  sleep 1
done

# 4. Wait for Prometheus to scrape (30s)
sleep 30

# 5. Query cache hit rate
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -- \
  curl -s 'http://localhost:9090/api/v1/query?query=vllm:prefix_cache_hits_total/vllm:prefix_cache_queries_total*100' | \
  jq -r '.data.result[] | select(.metric.namespace=="<namespace>") | "Cache Hit Rate: \(.value[1] | tonumber | floor)%"'
# Expected for intelligent-inference: 50-90% cache hit rate
```

**What this proves:**
- ✅ ServiceMonitors created automatically with model deployment
- ✅ Prometheus scraping vLLM metrics
- ✅ Prefix caching enabled and working (hit rate > 0%)
- ✅ Metrics pipeline functional

**Troubleshooting:**
- **0% cache hit rate:** Verify prefix caching is enabled in the pod:
  ```bash
  POD=$(oc get pods -n <namespace> -l llm-d.ai/role=both -o jsonpath='{.items[0].metadata.name}')
  oc exec -n <namespace> $POD -c main -- ps aux | grep "enable-prefix-caching"
  # Expected: --enable-prefix-caching in the command line
  ```
  If missing, the pod was deployed with an old chart version. Re-deploy with the current chart (prefix caching is auto-enabled for intelligent-inference).

- **No metrics in Prometheus:** Check User Workload Monitoring is enabled (see pre-flight checks above).

For complete monitoring setup and troubleshooting, see: [MONITORING-INTEGRATION.md](MONITORING-INTEGRATION.md)

---

**End of Phase 5:** Stop here and report the llm-d Quick Start test results to the user. Show:
1. ✅ Chat completion response (model is responding)
2. ✅ Intelligent routing verification (EPP + prefix cache working)
3. ✅ Monitoring verification (ServiceMonitors + metrics flowing)

Wait for confirmation before proceeding to Phase 6.

---

## Phase 6 — MaaS

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

1. **MaaS Gateway** — apply the gateway chart with your cluster domain and model namespaces:
   ```bash
   CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
   helm template gitops/instance/maas/gateway --name-template maas-gateway \
     --set clusterDomain="${CLUSTER_DOMAIN}" \
     --set useOpenShiftRoute=true \
     --set tls.secretName=ingress-certs \
     --set "gateway.modelNamespaces={llm-d-demo}" | oc apply -f -
   oc get gateway maas-default-gateway -n openshift-ingress
   ```

2. **MaaS Database** — deploy PostgreSQL and create the `maas-db-config` secret **before** enabling `modelsAsService`. The `maas-api` pod will not start without this secret. `helm template` skips `lookup`, so the password must be supplied explicitly:
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

3. **Enable MaaS in the DataScienceCluster** — re-apply the RHOAI instance chart with `modelsAsService=true` **after** the gateway (Step 1) and database (Step 2) are ready. This creates the `maas-controller` and `maas-api` pods:
   ```bash
   helm template rhoai ./gitops/instance/rhoai --set modelsAsService=true | oc apply -f -
   oc wait --for=condition=ready pod -l app.kubernetes.io/name=maas-api \
     -n redhat-ods-applications --timeout=120s
   ```

4. **Authorino TLS** — must be configured in order (4a → 4b → 4c → 4d). **IMPORTANT:** This step requires the `maas-controller` pod from Step 3 to be running. The maas-controller creates the TLS EnvoyFilter when the gateway annotation changes:
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

5. **Bootstrap subscription namespace** — `models-as-a-service` namespace + `default-tenant` CR (name is exact):
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

6. **Register models** — create `MaaSModelRef`, `MaaSSubscription`, `MaaSAuthPolicy` in `models-as-a-service`:
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

7. **Enable dashboard flags** — all four must be `true`:
   ```bash
   oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge \
     -p '{"spec":{"dashboardConfig":{"genAiStudio":true,"modelAsService":true,"maasAuthPolicies":true,"vLLMDeploymentOnMaaS":true}}}'
   oc rollout restart deployment/rhods-dashboard -n redhat-ods-applications
   ```

8. **Smoke test** — create an API key and call a model:
   ```bash
   TOKEN=$(oc whoami -t)
   MAAS_GW="maas.${CLUSTER_DOMAIN}"
   curl -sk -X POST "https://${MAAS_GW}/maas-api/v1/api-keys" \
     -H "Authorization: Bearer ${TOKEN}" \
     -H "Content-Type: application/json" \
     -d '{"name":"test-key","expiresInDays":1}'
   ```

**Human gate:** API key creation returns HTTP 201 with a `sk-oai-*` key. Model call with that key returns HTTP 200.

**Known gotchas:**
- `POST /maas-api/v1/api-keys` returns `500`: Authorino TLS not configured, or the `maas-default-gateway-authn-ssl` EnvoyFilter is missing. Remove and re-add the `authorino-tls-bootstrap` annotation on the gateway (Step 2 above).
- **500 errors on API keys / authorization policies pages** — gateway OCP Route has wrong hostname. Check: `oc get route maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.host}'` must be `maas.<cluster-domain>`. If it shows `maas-default-gateway-openshift-ingress.<cluster-domain>`, re-apply the gateway chart (the chart had a bug where `useOpenShiftRoute=true` used the wrong hostname format). Symptom in `maas-ui` sidecar logs: `statusCode=503 ... invalid character '<'`.
- Gen AI studio → API keys or Settings → Authorization policies tabs missing in the dashboard: check all four `OdhDashboardConfig` flags — `vLLMDeploymentOnMaaS` is the most commonly missing one.
- `LLMInferenceService` `HTTPRoutesReady: False` — `NotAllowedByListeners`: model namespace not in `gateway.modelNamespaces`. Re-apply the gateway chart with the correct namespace set.
- `MaaSAuthPolicy` status loop in controller logs (`"failed to update MaaSAuthPolicy status"`) — harmless controller/CRD version mismatch. Auth and rate limiting work correctly despite this.
- **EA2 → stable 3.4 migration only:** If `maas-controller` or `maas-api` Deployment shows an immutable selector error in the DSC, delete both Deployments and force a DSC reconcile — see `PATCH-MAAS.md §8`.

**End of Phase 6:** Stop here and report the MaaS smoke test results to the user. Show the API key creation response (must be HTTP 201 with a `sk-oai-*` key) and the model call response (must be HTTP 200). Installation is complete.

---

## MaaS — Key Facts and Gotchas

### `modelsAsService` ordering

`gitops/instance/rhoai/values.yaml` defaults to `modelsAsService: false`. Do NOT enable it during
Phase 3. The `maas-api` pod requires both the MaaS gateway AND the `maas-db-config` Secret before
it can start. Correct order: gateway (Phase 6 Step 1) → database (Phase 6 Step 2) → enable
`modelsAsService=true` (Phase 6 Step 4).

### Kuadrant CR is mandatory

The RHCL operator installs CRDs but does **not** deploy Authorino or Limitador until a `Kuadrant`
CR exists in `kuadrant-system`. Without it, `AuthPolicy` and `TokenRateLimitPolicy` resources are
created but never translated into `AuthConfig` — auth is silently unenforced.

Apply: `helm template gitops/instance/maas/connectivity-link --name-template maas-connectivity-link | oc apply -f -`

Verify: `oc get kuadrant -n kuadrant-system` must show `Ready: True`.

### Kuadrant `MissingDependency` on OCP 4.19+

If the Kuadrant CR stays `Ready: False` with `[Gateway API provider (istio / envoy gateway)] is not installed`:
on OCP 4.19+ the OCP built-in Gateway API controller is sufficient — no Service Mesh needed. Delete
the operator pod to force a restart and let it detect the built-in controller:

```bash
oc delete pod -n openshift-operators -l app.kubernetes.io/name=kuadrant-operator
```

### Gateway `allowedRoutes` — model namespaces

Every namespace containing MaaS-published models must be in the gateway's `allowedRoutes` selector,
or HTTPRoutes are rejected with `NotAllowedByListeners`. Add namespaces via:

```bash
helm template gitops/instance/maas/gateway --name-template maas-gateway \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --set useOpenShiftRoute=true \
  --set tls.secretName=ingress-certs \
  --set "gateway.modelNamespaces={llm-d-demo,other-ns}" | oc apply -f -
```

### MaaSModelRef must exist before subscriptions

The `MaaSSubscription` controller resolves model references at creation time. If the `MaaSModelRef`
is missing, subscriptions enter `Failed` phase immediately. The inference chart
(`gitops/instance/llm-d/inference`) creates the `MaaSModelRef` automatically when `maas.enabled=true`.
For a clean-slate reset, re-apply with `--set maas.enabled=true` before creating subscriptions.

### Subscription management UI only shows published models

The RHOAI dashboard "Add models" dialog in subscription management queries existing `MaaSModelRef`
objects — not raw `LLMInferenceService` resources. A model must be published (MaaSModelRef created)
before it appears in the subscription picker. There is no way to create a MaaSModelRef from the
subscription page itself; use the model deployment page's **Publish as MaaS endpoint** toggle, or
set `maas.enabled=true` in the inference chart.

### Authorino TLS is mandatory for the API key endpoint

Without Authorino TLS, `POST /maas-api/v1/api-keys` returns `500`. The gateway annotation must be
applied (or removed and re-applied) **after** Authorino TLS is configured — the maas-controller
creates the `maas-default-gateway-authn-ssl` EnvoyFilter only in reaction to an annotation change.

Steps in order:
1. Annotate the Authorino service with `service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert`
2. Patch Authorino CR: `spec.listener.tls.enabled: true` with `certSecretRef.name: authorino-server-cert`
3. Set `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` env vars on the `authorino` deployment
4. Remove then re-add the gateway annotation: `security.opendatahub.io/authorino-tls-bootstrap="true"`

Verify: `oc get envoyfilter maas-default-gateway-authn-ssl -n openshift-ingress`

### Token rate limiting — rules and schema

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
- ❌ `groups: ["my-group"]` → ✅ `groups: [{name: "my-group"}]`
- ❌ `tokenRateLimitPolicy.daily: 1000` → ✅ `tokenRateLimits: [{window: "24h", limit: 1000}]`
- ❌ `window: 1d` → ✅ `window: 24h` (days not supported)
- ❌ Missing `tokenRateLimits` → API rejects with "Required value"

### Token rate limiting does not support streaming requests

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

### `maas-ui` sidecar 500 errors — wrong gateway hostname

Symptom: API keys / authorization policies pages fail; sidecar logs show
`statusCode=503 ... invalid character '<'`. The OCP Route host must be exactly `maas.<cluster-domain>`.
Fix: re-apply the gateway chart (hostname is now always set to `subdomain.<clusterDomain>`).

Check: `oc get route -n openshift-ingress -l app.opendatahub.io/modelsasservice=true -o jsonpath='{.items[0].spec.host}'`

### MaaS dashboard flags

All four `OdhDashboardConfig` flags must be `true`:

```bash
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge \
  -p '{"spec":{"dashboardConfig":{"genAiStudio":true,"modelAsService":true,"maasAuthPolicies":true,"vLLMDeploymentOnMaaS":true}}}'
```

The inference chart sets these automatically when `modelsAsService=true` in the RHOAI values.

### MaaSAuthPolicy subjects must match MaaSSubscription owner groups

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

### Model missing from AI assets view — no `MaaSModelRef`

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

### Models missing from AI assets view — `gen-ai-ui` crash loop

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

### MaaSAuthPolicy status loop — harmless

The maas-controller may log `"failed to update MaaSAuthPolicy status"` in a tight loop. This is a
controller/CRD version mismatch (controller writes `accepted`/`enforced`; CRD requires `ready`).
Auth and rate limits work correctly — ignore this log noise.

---

## ExternalModel — Credential Injection

An `ExternalModel` CR points the MaaS gateway at any OpenAI-compatible endpoint. The
`payload-processing` ext_proc service (pod in `openshift-ingress`) has two controllers: one for
`ExternalModel` CRs (routing/model-store) and one for `Secret` CRs (credential-store).

### Critical Requirements

**1. MaaSModelRef name MUST match ExternalModel name exactly.**

This is a mandatory constraint. Unlike `LLMInferenceService` where the MaaSModelRef can have a
different name, for ExternalModel the names must be identical:

```yaml
# ExternalModel
apiVersion: maas.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: qwen3-14b              # ← This name
  namespace: maas-demo
spec:
  credentialRef:
    name: litellm-credentials
  endpoint: litellm-prod.apps.maas.redhatworkshops.io
  provider: openai
  targetModel: qwen3-14b

---
# MaaSModelRef MUST have the same name
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: qwen3-14b              # ← MUST match ExternalModel name exactly
  namespace: maas-demo
spec:
  modelRef:
    kind: ExternalModel
    name: qwen3-14b
```

**2. Credential secret requires the label `inference.networking.k8s.io/bbr-managed: "true"`.**

Secrets without this label are silently ignored — the credential store is never populated and every
request fails with `"provider 'openai' credentials not found"`.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: litellm-credentials
  namespace: maas-demo
  labels:
    inference.networking.k8s.io/bbr-managed: "true"  # ← REQUIRED
type: Opaque
data:
  OPENAI_API_KEY: <base64-encoded-api-key>
```

**3. MaaSModelRef must be created manually.**

Unlike `LLMInferenceService` which auto-creates the MaaSModelRef when `maas.enabled=true`,
ExternalModel requires manual creation of the MaaSModelRef.

**Path format:** The MaaS gateway path for an ExternalModel is `/{namespace}/{ExternalModel.metadata.name}/v1/...`.
Example: `https://maas.<domain>/maas-demo/qwen3-14b/v1/chat/completions`.

**Only llm-d runtime supports MaaS:** The "Publish as MaaS endpoint" toggle in Advanced settings
is only available when **Distributed inference with llm-d** is selected as the serving runtime.

### Monitoring ExternalModels

ExternalModels expose metrics via Limitador, not vLLM. Deploy monitoring:

```bash
oc label namespace kuadrant-system openshift.io/cluster-monitoring=true --overwrite
oc apply -f gitops/instance/llm-d-observability/limitador-servicemonitor.yaml
oc apply -f gitops/instance/llm-d-observability/perses-dashboard-external-models.yaml
```

Dashboard: Console → Observe → Dashboards → "MaaS External Models"

Technical details: `gitops/instance/llm-d-observability/EXTERNAL-MONITORING-INTEGRATION.md`

---

## How to Start a Session

At the beginning of each session, say which tool you use and your phase, for example:

> *"I'm on Phase \<N\> (agent). My env vars: AWS_REGION=... AWS_INSTANCE_TYPE=... [etc.]. Let's continue."*

If something went wrong, paste the failing command and its output and say which phase you were on. The assistant should diagnose without restarting from scratch.

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

# Active inference services and external models
oc get llminferenceservice -A
oc get externalmodel -A

# GPU node capacity
oc get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.capacity.nvidia\.com/gpu'

# Hardware profiles visibility check
kubectl get hardwareprofile -n redhat-ods-applications \
  -o custom-columns="NAME:.metadata.name,TYPE:.spec.scheduling.type,VISIBILITY:.metadata.annotations.opendatahub\.io/dashboard-feature-visibility"

# MaaS core
oc get kuadrant -n kuadrant-system
oc get pods -n kuadrant-system
oc get pods -n redhat-ods-applications -l app.kubernetes.io/name=maas-api
oc get gateway maas-default-gateway -n openshift-ingress
oc get authconfig -A | grep -v "^NAMESPACE"

# MaaS subscription stack
oc get tenant,maasmodelref,maassubscription,maasauthpolicy -A
oc get envoyfilter maas-default-gateway-authn-ssl -n openshift-ingress  # TLS EnvoyFilter
oc get authpolicy,tokenratelimitpolicy -n llm-d-demo                    # Kuadrant policies

# Authorino TLS
oc get authorino authorino -n kuadrant-system -o jsonpath='{.spec.listener.tls.enabled}'
oc get secret authorino-server-cert -n kuadrant-system

# ExternalModel credential secrets (must have bbr-managed label)
oc get secrets -A -l inference.networking.k8s.io/bbr-managed=true
```

```bash
# OPTIONAL — Kueue status (only if Kueue was installed for GPUaaS/distributed workloads)
oc get clusterqueue
oc get localqueue -A
oc get resourceflavor
```

---

## Constraints and Rules for the assistant

- **Never skip a wait condition** between phases. Timing errors are the most common failure mode.
- **Always check `check-operators.sh`** before starting Phase 5.
- **Always stop and ask** before patching an InstallPlan or applying anything that modifies cluster-wide RBAC.
- **Never install** Service Mesh 2.x, OpenShift Serverless, or Open Data Hub — these conflict with RHOAI 3.x. Service Mesh 3.x is only in scope if the user explicitly deploys **Llama Stack Operator** (not part of the default llm-d path).
- **Do NOT install Kueue** unless explicitly required for GPUaaS or distributed workloads — it causes namespace label conflicts with hardware profiles.
- **Prefer `oc apply -k`** over raw `oc apply -f` for kustomize paths — it respects the overlay ordering. The RHOAI **operator** install is an exception: use `helm template rhoai-operator ./gitops/operators/rhoai | oc apply -f -` (see README §2.5).
- If a command produces unexpected output, **stop and report** rather than continuing.