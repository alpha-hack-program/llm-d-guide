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

**Repo layout:** [docs/reference/repo-layout.md](docs/reference/repo-layout.md) — load only if you need to locate a specific chart or directory.

**Operator dependencies:** [docs/reference/operator-matrix.md](docs/reference/operator-matrix.md) — load at Phase 3 if you need to verify what is required. Key rule: **do NOT install Kueue** unless explicitly required (see Constraints below).

---

## Environment Variables

### Auto-derived — run these commands, never ask the user

| Variable | Command | Used in |
|---|---|---|
| `CLUSTER_DOMAIN` | `oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}'` | Phase 1 |
| `AWS_REGION` | `oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}'` | Phase 1, 2 |
| `INFRA_ID` | `oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}'` | Phase 2 |
| `AMI_ID` | `oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.ami.id}'` | Phase 2 |

> **Note on `AMI_ID`:** Every OCP cluster on AWS already has worker MachineSets whose `providerSpec` contains the exact RHCOS AMI the cluster was installed with — correct image, region, and architecture. Never attempt to discover this via `aws ec2 describe-images`.

### User-provided — must ask the user

| Variable | Description | Example | Used in |
|---|---|---|---|
| `CLOUD` | Cloud provider for cert-manager chart: `aws` (Route53 DNS-01) or `none` (bare metal / non-AWS). **Must be confirmed before Phase 1 — do not default.** | `aws` | Phase 1 |
| `AWS_INSTANCE_TYPE` | GPU instance type | `g5.2xlarge` | Phase 2 |
| `AWS_INSTANCES_PER_AZ` | GPU nodes per availability zone | `1` | Phase 2 |
| `RHOAI_OLM_PROFILE` | RHOAI **operator** install preset: `stable` (default) = `stable-3.x`; `ea` = `beta` channel. Verify current CSV via `packagemanifest` before use. Passed to `helm template ./gitops/operators/rhoai --set olmProfile=...` | `stable` | Phase 3 |
| `HF_TOKEN` | HuggingFace token for gated models | `hf_...` | Phase 5 |
| `GATEWAY_NAME` | Name for the llm-d gateway | `openshift-ai-inference` | Phase 5, 6 |
| `PROJECT` | Namespace for llm-d workloads | `llm-d-demo` | Phase 5, 6 |

> **Critical — confirm `CLOUD` before Phase 1:** Setting `CLOUD=aws` enables Route53 DNS-01 certificate issuance; `CLOUD=none` skips cert-manager entirely (bare metal or self-managed TLS). The wrong value causes a silent mis-configuration that is hard to recover from mid-install. **Do not default or assume — ask the user explicitly.**

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
**Critical:** Derive auto-derived variables from the cluster (see table above). Ask the user only for the user-provided variables — at minimum `CLOUD` and `AWS_INSTANCE_TYPE` for an AWS install.
**Full guide:** [docs/phases/00-validation.md](docs/phases/00-validation.md)

### Phase 1 — ArgoCD + cert-manager + Let's Encrypt
Install GitOps operator and automate TLS certificate lifecycle.
**Critical:**
- Ask the user `cloud=aws` or `cloud=none` before applying. First `helm template | oc apply` will fail on the `CertManager` CR — wait for CSV `Succeeded`, then re-run.
- For `cloud=aws`: run `./scripts/validate-cluster-domain.sh` (mandatory) and **stop to confirm the extracted domain with the user** before applying the cert-manager-route53 chart — a wrong domain causes silent Let's Encrypt failures.
- The human gate requires all certificates to show `READY=True` in the verify command output — `Issuing` means the cert is not done yet; wait until `Ready`.
**Full guide:** [docs/phases/01-argocd-certs.md](docs/phases/01-argocd-certs.md)

### Phase 2 — GPU Nodes + NFD + NVIDIA GPU Operator
Add GPU worker nodes and install hardware detection and driver stack.
**Critical:** Ask the user how many AZs (3 for production, 1 for testing). ClusterPolicy webhook may reject the CR if NFD labels aren't present yet — apply NFD first.
**Full guide:** [docs/phases/02-gpu-nodes.md](docs/phases/02-gpu-nodes.md)

### Phase 3 — Core Operators + RHOAI
Install Connectivity Link, LeaderWorkerSet, and RHOAI, then configure the DataScienceCluster.
**Critical:** Do NOT install Kueue unless explicitly required. `modelsAsService` must be `false` during this phase. Apply connectivity-link first — Authorino must be running before RHOAI.
**Kuadrant `Ready: False` is expected at end of Phase 3** — the GatewayClass Kuadrant needs is created in Phase 5. Do not search the marketplace. Proceed to Phase 4; Phase 5 creates the GatewayClass and restarts the Kuadrant operator pod to force reconciliation.
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

- [Repo Layout](docs/reference/repo-layout.md) — chart and directory map (load only when locating a path)
- [Operator Matrix](docs/reference/operator-matrix.md) — what is required vs optional per workload type (load at Phase 3)
- [Validation Commands](docs/reference/validation.md) — `oc get` checks for operators, CRDs, gateways, MaaS
- [MaaS Troubleshooting](docs/reference/maas-troubleshooting.md) — Key facts, gotchas, token rate limiting, dashboard flags
- [ExternalModel Guide](docs/reference/external-models.md) — Credential injection, MaaSModelRef naming, monitoring

---

## How to Start a Session

At the beginning of each session, say which tool you use and your phase, for example:

> *"I'm on Phase \<N\> (agent). My env vars: CLOUD=aws AWS_INSTANCE_TYPE=g5.2xlarge [etc.]. Let's continue."*
>
> Note: `AWS_REGION`, `AMI_ID`, `INFRA_ID`, and `CLUSTER_DOMAIN` are derived from the cluster — the assistant should run the lookup commands rather than asking for them.

If something went wrong, paste the failing command and its output and say which phase you were on. The assistant should diagnose without restarting from scratch.

---

## Constraints and Rules for the assistant

- **Never skip a wait condition** between phases. Timing errors are the most common failure mode.
- **Always check `check-operators.sh`** before starting Phase 5.
- **Always stop and ask** before patching an InstallPlan or applying anything that modifies cluster-wide RBAC.
- **Never install** Service Mesh 2.x, OpenShift Serverless, or Open Data Hub — these conflict with RHOAI 3.x. Service Mesh 3.x is only in scope if the user explicitly deploys **Llama Stack Operator** (not part of the default llm-d path).
- **Do NOT install Kueue** unless explicitly required for GPUaaS or distributed workloads — it causes namespace label conflicts with hardware profiles.
- **Prefer `oc apply -k`** over raw `oc apply -f` for kustomize paths — it respects the overlay ordering. The RHOAI **operator** install is an exception: use `helm template rhoai-operator ./gitops/operators/rhoai | oc apply -f -` (see README §2.5).
- **Never use `aws ec2 describe-images` to look up `AMI_ID`** — the correct RHCOS AMI is already embedded in the cluster's existing MachineSets; read it with `oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.ami.id}'`.
- **Never ask the user for auto-derived variables** (`AWS_REGION`, `AMI_ID`, `INFRA_ID`, `CLUSTER_DOMAIN`) — always derive them from the cluster using the commands in the Environment Variables table.
- **Always run `./scripts/validate-cluster-domain.sh`** (do not just read it) before applying the cert-manager-route53 chart, and stop to confirm the extracted domain with the user before proceeding.
- **Never re-implement script logic inline** — if a named script exists for a task (e.g. `preflight-validation.sh`, `validate-cluster-domain.sh`), run it. Do not substitute your own commands.
- If a command produces unexpected output, **stop and report** rather than continuing.
