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

---

## Phase 1 — ArgoCD + cert-manager + Let's Encrypt

**Goal:** Install the GitOps operator and automate TLS certificate lifecycle.

**Install order:**
1. *(Optional)* Red Hat OpenShift GitOps (ArgoCD) — via OperatorHub UI or CLI. Not required if applying manifests directly with `helm template | oc apply`.
2. cert-manager operator — `helm template gitops/operators/cert-manager-operator --set cloud=aws | oc apply -f -` (AWS) or `cloud=none` (bare metal). ArgoCD `Application` path documented in README section 3.1 as an alternative.
3. Let's Encrypt ClusterIssuers + certificates for Ingress and API — `helm template gitops/operators/cert-manager-route53 --set clusterDomain=<apps-domain> --set route53.region=<region> | oc apply -f -`

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

---

## Phase 4 — Monitoring Stack

**Goal:** Install Tempo (tracing), OpenTelemetry (collector), and Grafana (dashboards).

**Install order:**
1. Tempo Operator (`gitops/operators/tempo-operator`)
2. OpenTelemetry Operator (`gitops/operators/opentelemetry-operator`)
3. Grafana Operator (`gitops/operators/grafana-operator`, optional dashboards)

```bash
# README section 3.3 monitoring substeps — apply in order; watch CSVs until Succeeded
oc apply -k gitops/operators/tempo-operator
oc apply -k gitops/operators/opentelemetry-operator
oc wait --for=condition=Established crd/instrumentations.opentelemetry.io --timeout=120s
oc apply -k gitops/operators/grafana-operator
```

**Human gate:** Optional. Confirm Grafana route is accessible if you want dashboards during llm-d testing.

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
- **`maas.enabled` in per-model values files:** Set `maas.enabled: false` when deploying in Phase 5 (llm-d only). Setting it `true` before the MaaS gateway and Kuadrant policies are in place (Phase 6) triggers reconcile errors in the maas-controller and does not enable MaaS. Flip it to `true` only during Phase 6 when publishing the model to MaaS.
- For OCI model images (`registry.redhat.io/rhelai1/...`), ensure the cluster pull secret includes Red Hat registry credentials.
- For MoE models (DeepSeek-R1, Mixtral), use the **Wide Expert-Parallelism** well-lit path which requires LeaderWorkerSet for multi-node orchestration.
- **Model Registry / model-catalog API 500:** If migrations did not apply, restart model-catalog: `oc rollout restart deployment/model-catalog -n rhoai-model-registries` (README Appendix B).

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

3. **Authorino TLS** — must be configured in order (4a → 4b → 4c → 4d). If the annotation is already present, remove then re-add it:
   ```bash
   # Remove annotation if already set, to force maas-controller to create the TLS EnvoyFilter
   oc annotate gateway maas-default-gateway -n openshift-ingress \
     security.opendatahub.io/authorino-tls-bootstrap-
   oc annotate gateway maas-default-gateway -n openshift-ingress \
     security.opendatahub.io/authorino-tls-bootstrap="true"
   # Verify TLS EnvoyFilter was created
   oc get envoyfilter maas-default-gateway-authn-ssl -n openshift-ingress
   ```

4. **Enable MaaS in the DataScienceCluster** — re-apply the RHOAI instance chart with `modelsAsService=true` **after** the gateway (Step 1) and database (Step 2) are ready:
   ```bash
   helm template rhoai ./gitops/instance/rhoai --set modelsAsService=true | oc apply -f -
   oc wait --for=condition=ready pod -l app.kubernetes.io/name=maas-api \
     -n redhat-ods-applications --timeout=120s
   ```

5. **Bootstrap subscription namespace** — `models-as-a-service` namespace + `default-tenant` CR (name is exact):
   ```bash
   oc create namespace models-as-a-service --dry-run=client -o yaml | oc apply -f -
   ```

6. **Register models** — create `MaaSModelRef`, `MaaSSubscription`, `MaaSAuthPolicy` in `models-as-a-service` (see README §9.2 Steps 6a–6c).

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

# Active inference services
oc get llminferenceservice -A

# MaaS status
oc get kuadrant -n kuadrant-system
oc get pods -n kuadrant-system
oc get pods -n redhat-ods-applications -l app.kubernetes.io/name=maas-api
oc get authconfig -A | grep -v "^NAMESPACE"
oc get gateway maas-default-gateway -n openshift-ingress

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

## Constraints and Rules for the assistant

- **Never skip a wait condition** between phases. Timing errors are the most common failure mode.
- **Always check `check-operators.sh`** before starting Phase 5.
- **Always stop and ask** before patching an InstallPlan or applying anything that modifies cluster-wide RBAC.
- **Never install** Service Mesh 2.x, OpenShift Serverless, or Open Data Hub — these conflict with RHOAI 3.x. Service Mesh 3.x is only in scope if the user explicitly deploys **Llama Stack Operator** (not part of the default llm-d path).
- **Do NOT install Kueue** unless explicitly required for GPUaaS or distributed workloads — it causes namespace label conflicts with hardware profiles.
- **Prefer `oc apply -k`** over raw `oc apply -f` for kustomize paths — it respects the overlay ordering. The RHOAI **operator** install is an exception: use `helm template rhoai-operator ./gitops/operators/rhoai | oc apply -f -` (see README §2.5).
- If a command produces unexpected output, **stop and report** rather than continuing.