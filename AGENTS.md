# AGENTS.md — llm-d-guide Co-pilot Runbook

This file gives assistants (Claude Code, OpenCode, Cursor, and compatible tools) persistent
context for installing **Red Hat OpenShift AI 3.5** (self-managed) with **llm-d** on
**OpenShift Container Platform 4.20–4.21** (llm-d requires 4.20+). The canonical, step-by-step manual is [`README.md`](README.md);
use this runbook for phased execution, wait conditions, and human gates. Work through one phase
per session. Always tell the assistant which phase you are on and paste any relevant error output
before asking for help.

Each phase has a **full guide** in [`docs/phases/`](docs/phases/) — the assistant should load the
relevant file when you say which phase you are on. Reference material (validation commands, MaaS
troubleshooting) is in [`docs/reference/`](docs/reference/).

**Assistant behavior:**
- **Show the phase summary first.** Before starting any phase, read `docs/phases/summaries/phase-0N.txt` and paste its contents verbatim as a text message to the user. Do not paraphrase, summarize, or regenerate it — copy the file content exactly as-is into your response text so the user can see it. Then load the full guide from `docs/phases/`.
- **Explain before executing.** Before each major step (operator installs, chart applies, config changes), briefly explain what it does and why. Wait for the user to confirm before running it.
- **Never skip optional steps without asking.** If a step is marked optional, ask the user whether to include or skip it.
- **Ask questions directly.** The user is an experienced operator — don't enumerate options with descriptions or explanations. Just ask plainly (e.g., "What cloud provider — `aws` or `none`?"), don't present numbered lists explaining what each choice means.
- **Optional tools go at the end.** ArgoCD (OpenShift GitOps) is the only optional add-on. Don't ask about it during any phase — offer it once after Phase 6 completes: "Do you want to install any additional tools, like ArgoCD?" Optional demos after Phase 6: [MaaS demo](docs/demos/maas-demo.md) → [EvalHub Level 1](docs/demos/evalhub-demo.md) → [EvalHub Level 2](docs/demos/evalhub-demo-level2.md).

---

**Repo layout:** [docs/reference/repo-layout.md](docs/reference/repo-layout.md) — load only if you need to locate a specific chart or directory.

**Operator dependencies:** [docs/reference/operator-matrix.md](docs/reference/operator-matrix.md) — load at Phase 3 if you need to verify what is required. Key rule: **do NOT install Kueue** unless explicitly required (see Constraints below).

---

## Environment Variables

### Optional local env file

Copy [`cluster.env.example`](cluster.env.example) to `cluster.env` (gitignored), set user choices, and
`source ./cluster.env` at the start of each shell session. Sourcing auto-derives `CLUSTER_DOMAIN`,
`AWS_REGION`, `INFRA_ID`, and `AMI_ID` when `oc` is logged in with sufficient access.

Assistants: if `cluster.env` exists, remind the user to source it. Prefer values already set in the
environment over re-asking, but **still confirm** `CLOUD` and `TLS_ISSUER` when unset — never invent
them from example defaults. Do not commit `cluster.env` (it may contain `HF_TOKEN`).

### Auto-derived — run these commands, never ask the user

| Variable | Command | Used in |
|---|---|---|
| `OCP_MINOR` | `oc version -o json \| jq -r '.openshiftVersion' \| cut -d. -f2` | All phases |
| `CLUSTER_DOMAIN` | `oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}'` | Phase 1 |
| `AWS_REGION` | `oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}'` | Phase 1, 2 |
| `INFRA_ID` | `oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}'` | Phase 2 |
| `AMI_ID` | `oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.ami.id}'` | Phase 2 |

> **Note on `OCP_MINOR`:** Determines the operator install method. OCP 4.20 uses OLMv0 (`Subscription` + `InstallPlan`). OCP 4.21+ uses OLMv1 (`ClusterExtension`) for operators whose bundles support `AllNamespaces` install mode. Both systems coexist on 4.21. For Helm charts (cert-manager, RHOAI), pass `--set olmVersion=v1` on OCP 4.21+. For compatible plain-YAML operators (RHCL, COO), apply `cluster-extension.yaml` on 4.21+. **Five operators must always use OLMv0:** NFD, NVIDIA, and LeaderWorkerSet (bundles don't support AllNamespaces mode); Tempo and OpenTelemetry (RHOAI 3.5 detects them via CSV only — OLMv1 installs are invisible to the monitoring controller).

> **Note on `AMI_ID`:** Every OCP cluster on AWS already has worker MachineSets whose `providerSpec` contains the exact RHCOS AMI the cluster was installed with — correct image, region, and architecture. Never attempt to discover this via `aws ec2 describe-images`.

### User-provided — must ask the user

| Variable | Description | Example | Used in |
|---|---|---|---|
| `CLOUD` | Is your infrastructure running on AWS? Set `aws` if yes, `none` otherwise. Controls infrastructure features (CredentialsRequest, MachineSets). **Must be confirmed before Phase 1 — do not default.** | `aws` | Phase 1, 2 |
| `TLS_ISSUER` | TLS certificate issuer: `letsencrypt` (Route53 DNS-01, requires AWS + public DNS) or `local-ca` (local CA chain via cert-manager, works on any platform). **Must be confirmed before Phase 1.** | `letsencrypt` | Phase 1 |
| `AWS_INSTANCE_TYPE` | GPU instance type | `g5.2xlarge` | Phase 2 |
| `AWS_INSTANCES_PER_AZ` | GPU nodes per availability zone | `1` | Phase 2 |
| `RHOAI_OLM_PROFILE` | RHOAI **operator** install preset: `stable` (default) = `stable-3.x`; `ea` = `alpha` channel (the `beta` channel is legacy — do not use). Verify current CSV via `packagemanifest` before use. Passed to `helm template ./gitops/operators/rhoai --set olmProfile=...` | `stable` | Phase 3 |
| `HF_TOKEN` | HuggingFace token for gated models | `hf_...` | Phase 5 |
| `GATEWAY_NAME` | Name for the llm-d gateway | `openshift-ai-inference` | Phase 5, 6 |
| `PROJECT` | Namespace for llm-d workloads | `llm-d-demo` | Phase 5, 6 |

> **Critical — confirm `CLOUD` and `TLS_ISSUER` before Phase 1:**
> 1. Ask: "Is your infrastructure running on AWS?" → set `CLOUD=aws` or `CLOUD=none`. This controls CredentialsRequest creation and MachineSet provisioning — the wrong value causes silent mis-configuration.
> 2. Ask: "Do you want Let's Encrypt (requires Route53 access) or a local CA for TLS?" → set `TLS_ISSUER=letsencrypt` or `TLS_ISSUER=local-ca`. A local CA works on any platform, including AWS — useful for labs, demos, or clusters without public DNS access. Let's Encrypt requires `CLOUD=aws`.
>
> **Do not default or assume either variable — ask the user.**

---

## Phase Map

| Phase | Name | Guide | Approx. time | Human gate |
|---|---|---|---|---|
| 0 | Cluster validation | [docs/phases/00-validation.md](docs/phases/00-validation.md) | 5 min | Confirm env vars + StorageClass |
| 1 | TLS Certificate Automation | [docs/phases/01-tls-cert-automation.md](docs/phases/01-tls-cert-automation.md) | 15–20 min | Verify certs `READY=True` |
| 2 | GPU nodes + NFD + NVIDIA GPU Operator | [docs/phases/02-gpu-nodes.md](docs/phases/02-gpu-nodes.md) | 20–40 min | Confirm GPU nodes are schedulable |
| 3 | Core operators + RHOAI | [docs/phases/03-operators-rhoai.md](docs/phases/03-operators-rhoai.md) | 20–30 min | Approve InstallPlans; CSVs `Succeeded` |
| 4 | Monitoring stack | [docs/phases/04-monitoring.md](docs/phases/04-monitoring.md) | 10 min | Optional sign-off |
| 5 | llm-d Quick Start | [docs/phases/05-llmd-quickstart.md](docs/phases/05-llmd-quickstart.md) | 15–20 min | Review curl test output |
| 6 | MaaS | [docs/phases/06-maas.md](docs/phases/06-maas.md) | 10–15 min | Verify `LLMInferenceService` `Ready: True` via MaaS route |

---

## Phase Summaries

### Phase 0 — Cluster Validation
Confirm the cluster is ready: OCP 4.20–4.21 (llm-d requires 4.20+), cluster admin access, default StorageClass, no ODH or Service Mesh 2.x. Derive `OCP_MINOR` to determine the operator install method: OCP 4.20 uses OLMv0 (`Subscription`), OCP 4.21+ uses OLMv1 (`ClusterExtension`). Each operator directory has both `operator.yaml` (OLMv0) and `cluster-extension.yaml` (OLMv1); Helm charts accept `--set olmVersion=v1`.
**Critical:** Derive auto-derived variables from the cluster (see table above). Ask the user whether their infrastructure is running on AWS. Then ask whether they want Let's Encrypt or a local CA for TLS (see `TLS_ISSUER` in the Environment Variables table). If on AWS, also ask for `AWS_INSTANCE_TYPE`.
**Full guide:** [docs/phases/00-validation.md](docs/phases/00-validation.md)

### Phase 1 — TLS Certificate Automation
Install cert-manager operator and automate TLS certificate lifecycle.
**Critical:**
- Confirm `CLOUD` and `TLS_ISSUER` before applying (see Environment Variables above). On OCP 4.21+, pass `--set olmVersion=v1` to the cert-manager Helm chart. First `helm template | oc apply` will fail on the `CertManager` CR — wait for the operator to be ready (`CSV Succeeded` on 4.20, `ClusterExtension Installed` on 4.21+), then re-run.
- For `TLS_ISSUER=letsencrypt` (requires `CLOUD=aws`): run `./scripts/validate-cluster-domain.sh` (mandatory) and **stop to confirm the extracted domain with the user** before applying the cert-manager-route53 chart — a wrong domain causes silent Let's Encrypt failures.
- For `TLS_ISSUER=local-ca` (works on any platform, including AWS): follow the **local CA** path (Step 2 Alternative in the Phase 1 guide) — it creates a local CA chain via cert-manager that issues properly signed certificates. After applying, the CA must be injected into the cluster trust bundle (`user-ca-bundle` ConfigMap + Proxy patch). This is mandatory for MaaS dashboard compatibility.
- The human gate requires all certificates to show `READY=True` in the verify command output — `Issuing` means the cert is not done yet; wait until `Ready`.
**Full guide:** [docs/phases/01-tls-cert-automation.md](docs/phases/01-tls-cert-automation.md)

### Phase 2 — GPU Nodes + NFD + NVIDIA GPU Operator
Add GPU worker nodes and install hardware detection and driver stack.
**Critical:** Ask the user how many AZs (3 for production, 1 for testing). ClusterPolicy webhook may reject the CR if NFD labels aren't present yet — apply NFD first. **NFD and NVIDIA bundles do not support AllNamespaces install mode** — the `install.sh` scripts always use OLMv0 regardless of OCP version. Wait for CSV `Succeeded` on both 4.20 and 4.21+.
**Full guide:** [docs/phases/02-gpu-nodes.md](docs/phases/02-gpu-nodes.md)

### Phase 3 — Core Operators + RHOAI
Install Connectivity Link (RHCL 1.3.5+, pinned to v1.3.6), LeaderWorkerSet, **monitoring operators (Tempo, OpenTelemetry)**, and RHOAI, then configure the DataScienceCluster.
**Critical:** 
- **Operator install order matters:** Connectivity Link → LeaderWorkerSet → **Tempo + OpenTelemetry (BEFORE RHOAI)** → RHOAI Operator → RHOAI Instance. The monitoring operators must be installed BEFORE RHOAI because the DSCInitialization requires them for monitoring stack initialization.
- **RHCL InstallPlan approvals:** Use `./scripts/approve-rhcl-installplan.sh` only — never bulk-approve all pending plans in `openshift-operators`. See [RHCL version pin](docs/reference/rhcl-version-pin.md).
- **OLMv0 vs OLMv1:** For compatible plain-YAML operators (Connectivity Link), apply `cluster-extension.yaml` on OCP 4.21+ or `operator.yaml` on 4.20. **LeaderWorkerSet does not support AllNamespaces mode** — always use `oc apply -k gitops/operators/leader-worker-set` (OLMv0) regardless of OCP version. **Tempo and OpenTelemetry must also use OLMv0** — RHOAI 3.5's monitoring controller detects these operators via CSV; OLMv1 installs are invisible, causing the monitoring precondition to fail. For RHOAI (Helm chart), pass `--set olmVersion=v1` on 4.21+. Wait conditions differ: on 4.20, wait for `CSV Succeeded`; on 4.21+, wait for `ClusterExtension` condition `Installed=True` (for OLMv1 operators) or `CSV Succeeded` (for OLMv0 operators like LeaderWorkerSet, Tempo, OpenTelemetry).
- Enable Kuadrant observability (`spec.observability.enable: true`) when creating the Kuadrant CR — required for the monitoring stack in Phase 4.
- Do NOT install Kueue unless explicitly required. 
- `modelsAsService` must be `false` during this phase. 
- Apply connectivity-link first — Authorino must be running before RHOAI.
- The DSC spec in RHOAI 3.5 (v2 API) replaces `llamastackoperator` with `ogx`, adds `trainer`, `mcplifecycleoperator`, and `aigateway` components. MaaS moved from `kserve.modelsAsService` to `aigateway.modelsAsAService` (the old field is deprecated but respected through 3.6).
**Kuadrant `Ready: False` after creating the CR** — this is **expected** at this phase. The operator requires a `GatewayClass` to report `Ready: True`, but the GatewayClass is created in Phase 5. Verify Authorino and Limitador pods are running in `kuadrant-system` — that confirms the operator is functional. Kuadrant becomes `Ready` in Phase 5 after the gateway is deployed and the operator pod is restarted. Do not search the marketplace or install any gateway operator.
**Full guide:** [docs/phases/03-operators-rhoai.md](docs/phases/03-operators-rhoai.md)

### Phase 4 — Monitoring Stack
Install COO for llm-d metrics dashboards. Enable User Workload Monitoring.
**Critical:**
- After installing COO, create **two UIPlugin CRs** (`Dashboards` and `Monitoring` with `perses.enabled: true`) — without these the Perses tab does not appear in the console.
- PersesDashboard CRs must be in the `openshift-cluster-observability-operator` namespace with label `app.kubernetes.io/part-of: monitoring` — the Monitoring UIPlugin only discovers dashboards matching these criteria.
- **RHOAI 3.5 change:** Observability dashboards are now installed by default when llm-d is deployed (dashboard ConfigMap objects are auto-created). Custom Perses dashboards remain useful for advanced/custom views.
- **RHOAI 3.5 change:** The EPP metrics prefix changed from `inference_extension_` to `llm_d_epp_`. Update any custom Prometheus dashboards, alerts, or Grafana panels that reference the old prefix.
- Use `vllm.extraArgs` in per-model values files, **not** `env` with `VLLM_ADDITIONAL_ARGS` — the chart auto-generates that env var from `vllm.extraArgs`; setting both causes a duplicate-env rejection.
**Full guide:** [docs/phases/04-monitoring.md](docs/phases/04-monitoring.md)

### Phase 5 — llm-d Quick Start
Deploy the gateway, a namespace, and an LLMInferenceService, then test the endpoint.
**Critical:**
- Set `maas.enabled: false` when deploying in Phase 5.
- Use `vllm.extraArgs` (not `env` with `VLLM_ADDITIONAL_ARGS`) in per-model values — the chart auto-generates that env var and duplicates cause admission errors.
- The default hardware profile is `gpu-profile` (auto-selected when `gpuCount > 0`). Set it explicitly in the per-model values file for clarity.
- **RHOAI 3.5 breaking change:** The API group for `InferenceObjective` and `EndpointPickerConfig` changed from `inference.networking.x-k8s.io` to `llm-d.ai`. The `saturationDetector` field moved to `flowControl.saturationDetector` with a plugin-reference pattern.
- **RHOAI 3.5 change:** The default EPP scheduler adds two new scorers: `kv-cache-utilization-scorer` and `no-hit-lru-scorer` alongside `queue-scorer` and `prefix-cache-scorer`.
- **RHOAI 3.5 change:** vLLM access-log flag `--disable-uvicorn-access-log` is deprecated; use `--disable-access-log-for-endpoints=/health,/metrics,/ping` instead. The old flag still works on vLLM 0.18.0.
- Verify intelligent routing and monitoring integration after deployment.
**Full guide:** [docs/phases/05-llmd-quickstart.md](docs/phases/05-llmd-quickstart.md)

### Phase 6 — MaaS
Deploy the MaaS gateway, configure Authorino TLS, bootstrap the subscription stack, and verify API key creation.
**Critical:** Order matters: gateway → database → enable `modelsAsService=true` (sets `aigateway.modelsAsAService: Managed` in DSC v2) → Authorino TLS. Without Authorino TLS, the API key endpoint returns 500.
**RHOAI 3.5 change:** The default MaaS infrastructure namespace is now `redhat-ai-gateway-infra` (was `redhat-ods-applications` in 3.4). The `maas-db-config` secret and `maas-api` deployment live in this namespace. The `Tenant` CR is deprecated — it will be replaced by `AITenant` + `MaasTenantConfig` in a future release (still functional in 3.5).
**RHOAI 3.5 change:** MaaS now supports OpenAI-compatible body-based model routing (`/v1/chat/completions` with model name in the request body).
**Authorino TLS race condition:** The `odh-model-controller`'s `gateway-auth-bootstrap` controller does a one-shot check when it sees the gateway annotation — if Authorino TLS is not fully active at that moment, it skips EnvoyFilter creation and never retries. Steps 4a–4c must be verified before applying 4d. If the EnvoyFilter is missing after 4d, restart `odh-model-controller`.
**Full guide:** [docs/phases/06-maas.md](docs/phases/06-maas.md)

---

## Reference

- [Repo Layout](docs/reference/repo-layout.md) — chart and directory map (load only when locating a path)
- [Operator Matrix](docs/reference/operator-matrix.md) — what is required vs optional per workload type (load at Phase 3)
- [OLMv1 Migration](docs/reference/olmv1-migration.md) — ClusterExtension CRD, RBAC, catalog mapping, wait conditions (load when `OCP_MINOR >= 21`)
- [Validation Commands](docs/reference/validation.md) — `oc get` checks for operators, CRDs, gateways, MaaS
- [MaaS Troubleshooting](docs/reference/maas-troubleshooting.md) — Key facts, gotchas, token rate limiting, dashboard flags
- [RHCL version pin](docs/reference/rhcl-version-pin.md) — InstallPlan guardrails and downgrade
- [ExternalModel Guide](docs/reference/external-models.md) — Credential injection, MaaSModelRef naming, monitoring
- [EvalHub Demo — Level 1](docs/demos/evalhub-demo.md) — GuideLLM performance comparison on MaaS
- [EvalHub Demo — Level 2](docs/demos/evalhub-demo-level2.md) — CI/CD quality gate + OCI artifacts
- [Migration 3.4 → 3.5](docs/reference/migration-3.4-to-3.5.md) — Breaking changes, MaaS namespace move, vLLM flag deprecation, upgrade checklist

---

## How to Start a Session

At the beginning of each session, say which tool you use and your phase, for example:

> *"I'm on Phase \<N\> (agent). My env vars: CLOUD=aws AWS_INSTANCE_TYPE=g5.2xlarge [etc.]. Let's continue."*
>
> Note: `AWS_REGION`, `AMI_ID`, `INFRA_ID`, and `CLUSTER_DOMAIN` are derived from the cluster — the assistant should run the lookup commands rather than asking for them.

If something went wrong, paste the failing command and its output and say which phase you were on. The assistant should diagnose without restarting from scratch.

**Upgrading this guide:** [docs/reference/guide-upgrade-workflow.md](docs/reference/guide-upgrade-workflow.md) — branch strategy, step-by-step workflow, and what to update when a new RHOAI version is released.

---

## Constraints and Rules for the assistant

- **Never skip a wait condition** between phases. Timing errors are the most common failure mode.
- **Always check `check-operators.sh`** before starting Phase 5.
- **Always stop and ask** before patching an InstallPlan or applying anything that modifies cluster-wide RBAC.
- **Never install** Service Mesh 2.x, OpenShift Serverless, or Open Data Hub — these conflict with RHOAI 3.x. Service Mesh 3.x is only in scope if the user explicitly deploys **Llama Stack Operator** (not part of the default llm-d path).
- **Do NOT install Kueue** unless explicitly required for GPUaaS or distributed workloads — it causes namespace label conflicts with hardware profiles.
- **Prefer `oc apply -k`** over raw `oc apply -f` for kustomize paths — it respects the overlay ordering. The RHOAI **operator** install is an exception: use `helm template rhoai-operator ./gitops/operators/rhoai | oc apply -f -` (see README §2.5).
- **Never use `aws ec2 describe-images` to look up `AMI_ID`** — the correct RHCOS AMI is already embedded in the cluster's existing MachineSets; read it with `oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.ami.id}'`.
- **Never ask the user for auto-derived variables** (`OCP_MINOR`, `AWS_REGION`, `AMI_ID`, `INFRA_ID`, `CLUSTER_DOMAIN`) — always derive them from the cluster using the commands in the Environment Variables table.
- **Use the correct OLM path based on `OCP_MINOR`:** On 4.20, apply `operator.yaml` and wait for `CSV Succeeded`. On 4.21+, apply `cluster-extension.yaml` for compatible operators and wait for `ClusterExtension` condition `Installed=True`. For Helm charts, pass `--set olmVersion=v1` on 4.21+. **Exception — five operators must always use OLMv0:** NFD, NVIDIA, and LeaderWorkerSet (bundles don't support AllNamespaces mode); Tempo and OpenTelemetry (RHOAI 3.5 detects them via CSV only). Never mix OLMv0 and OLMv1 for the same operator.
- **Always run `./scripts/validate-cluster-domain.sh`** (do not just read it) before applying the cert-manager-route53 chart, and stop to confirm the extracted domain with the user before proceeding.
- **Never re-implement script logic inline** — if a named script exists for a task (e.g. `preflight-validation.sh`, `validate-cluster-domain.sh`), run it. Do not substitute your own commands.
- If a command produces unexpected output, **stop and report** rather than continuing.
