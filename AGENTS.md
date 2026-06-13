# AGENTS.md — llm-d-demo Co-pilot Runbook

This file gives assistants (Claude Code, OpenCode, Cursor, and compatible tools) persistent
context for installing **Red Hat OpenShift AI 3.4** (self-managed) with **llm-d** on
**OpenShift Container Platform 4.21**. The canonical, step-by-step manual is [`README.md`](README.md);
use this runbook for phased execution, wait conditions, and human gates. Work through one phase
per session. Always tell the assistant which phase you are on and paste any relevant error output
before asking for help.

Each phase has a **full guide** in [`docs/phases/`](docs/phases/) — the assistant should load the
relevant file when you say which phase you are on. Reference material (validation commands, MaaS
troubleshooting) is in [`docs/reference/`](docs/reference/).

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
├── docs/
│   ├── phases/                      # Step-by-step phase guides (loaded on demand)
│   └── reference/                   # Validation commands, MaaS troubleshooting
└── README.md                        # Full installation guide
```

---

## Operator Dependency Matrix

| Operator | llm-d | GPUaaS / Distributed Workloads | Notes |
|---|---|---|---|
| **Connectivity Link** (Authorino + Limitador) | Required | Required | KServe auth, llm-d gateway, MaaS; Authorino is the token-auth piece. Installing the operator alone is not enough — a `Kuadrant` CR must also be created in `kuadrant-system` (`gitops/instance/maas/connectivity-link`) to deploy the actual operands. |
| **LeaderWorkerSet** | Required | Required | Multi-node MoE and P/D disaggregation |
| **Red Hat Build of Kueue** | Not required | Required | Do NOT install for llm-d-only setups — causes namespace label conflicts |
| **NFD + NVIDIA GPU Operator** | Required | Required | GPU node detection and drivers |
| **cert-manager** (Operator for Red Hat OpenShift) | Recommended | Recommended | Automates TLS for RHOAI, llm-d, OTel, and related components; manual certs are valid if you manage them yourself |

> **Important:** Installing the Kueue operator (even with `managementState: Removed` in the DSC)
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

| Phase | Name | Guide | Approx. time | Human gate |
|---|---|---|---|---|
| 0 | Cluster validation | [docs/phases/00-validation.md](docs/phases/00-validation.md) | 5 min | Confirm env vars + StorageClass |
| 1 | ArgoCD + cert-manager + Let's Encrypt | [docs/phases/01-argocd-certs.md](docs/phases/01-argocd-certs.md) | 15–20 min | Verify certs `READY=True` |
| 2 | GPU nodes + NFD + NVIDIA GPU Operator | [docs/phases/02-gpu-nodes.md](docs/phases/02-gpu-nodes.md) | 20–40 min | Confirm GPU nodes are schedulable |
| 3 | Core operators + RHOAI | [docs/phases/03-operators-rhoai.md](docs/phases/03-operators-rhoai.md) | 20–30 min | Approve InstallPlans; CSVs `Succeeded` |
| 4 | Monitoring stack | [docs/phases/04-monitoring.md](docs/phases/04-monitoring.md) | 10 min | Optional sign-off |
| 5 | llm-d Quick Start | [docs/phases/05-llmd-quickstart.md](docs/phases/05-llmd-quickstart.md) | 15–20 min | Review curl test output |
| 6 | MaaS | [docs/phases/06-maas.md](docs/phases/06-maas.md) | 10–15 min | Verify `LLMInferenceService` `Ready: True` via MaaS route |

---

## Phase Summaries

### Phase 0 — Cluster Validation
Confirm the cluster is ready: OCP 4.21+, cluster admin access, default StorageClass, no ODH or Service Mesh 2.x.
**Critical:** Collect all environment variables before proceeding.
**Full guide:** [docs/phases/00-validation.md](docs/phases/00-validation.md)

### Phase 1 — ArgoCD + cert-manager + Let's Encrypt
Install GitOps operator and automate TLS certificate lifecycle.
**Critical:** Ask the user `cloud=aws` or `cloud=none` before applying. First `helm template | oc apply` will fail on the `CertManager` CR — wait for CSV `Succeeded`, then re-run.
**Full guide:** [docs/phases/01-argocd-certs.md](docs/phases/01-argocd-certs.md)

### Phase 2 — GPU Nodes + NFD + NVIDIA GPU Operator
Add GPU worker nodes and install hardware detection and driver stack.
**Critical:** Ask the user how many AZs (3 for production, 1 for testing). ClusterPolicy webhook may reject the CR if NFD labels aren't present yet — apply NFD first.
**Full guide:** [docs/phases/02-gpu-nodes.md](docs/phases/02-gpu-nodes.md)

### Phase 3 — Core Operators + RHOAI
Install Connectivity Link, LeaderWorkerSet, and RHOAI, then configure the DataScienceCluster.
**Critical:** Do NOT install Kueue unless explicitly required. `modelsAsService` must be `false` during this phase. Apply connectivity-link first — Authorino must be running before RHOAI.
**Full guide:** [docs/phases/03-operators-rhoai.md](docs/phases/03-operators-rhoai.md)

### Phase 4 — Monitoring Stack
Install COO for llm-d metrics dashboards. Enable User Workload Monitoring.
**Full guide:** [docs/phases/04-monitoring.md](docs/phases/04-monitoring.md)

### Phase 5 — llm-d Quick Start
Deploy the gateway, a namespace, and an LLMInferenceService, then test the endpoint.
**Critical:** Set `maas.enabled: false` when deploying in Phase 5. Verify intelligent routing and monitoring integration after deployment.
**Full guide:** [docs/phases/05-llmd-quickstart.md](docs/phases/05-llmd-quickstart.md)

### Phase 6 — MaaS
Deploy the MaaS gateway, configure Authorino TLS, bootstrap the subscription stack, and verify API key creation.
**Critical:** Order matters: gateway → database → enable `modelsAsService=true` → Authorino TLS. Without Authorino TLS, the API key endpoint returns 500.
**Full guide:** [docs/phases/06-maas.md](docs/phases/06-maas.md)

---

## Reference

- [Validation Commands](docs/reference/validation.md) — `oc get` checks for operators, CRDs, gateways, MaaS
- [MaaS Troubleshooting](docs/reference/maas-troubleshooting.md) — Key facts, gotchas, token rate limiting, dashboard flags
- [ExternalModel Guide](docs/reference/external-models.md) — Credential injection, MaaSModelRef naming, monitoring

---

## How to Start a Session

At the beginning of each session, say which tool you use and your phase, for example:

> *"I'm on Phase \<N\> (agent). My env vars: AWS_REGION=... AWS_INSTANCE_TYPE=... [etc.]. Let's continue."*

If something went wrong, paste the failing command and its output and say which phase you were on. The assistant should diagnose without restarting from scratch.

---

## Constraints and Rules for the assistant

- **Never skip a wait condition** between phases. Timing errors are the most common failure mode.
- **Always check `check-operators.sh`** before starting Phase 5.
- **Always stop and ask** before patching an InstallPlan or applying anything that modifies cluster-wide RBAC.
- **Never install** Service Mesh 2.x, OpenShift Serverless, or Open Data Hub — these conflict with RHOAI 3.x. Service Mesh 3.x is only in scope if the user explicitly deploys **Llama Stack Operator** (not part of the default llm-d path).
- **Do NOT install Kueue** unless explicitly required for GPUaaS or distributed workloads — it causes namespace label conflicts with hardware profiles.
- **Prefer `oc apply -k`** over raw `oc apply -f` for kustomize paths — it respects the overlay ordering. The RHOAI **operator** install is an exception: use `helm template rhoai-operator ./gitops/operators/rhoai | oc apply -f -` (see README §2.5).
- If a command produces unexpected output, **stop and report** rather than continuing.
