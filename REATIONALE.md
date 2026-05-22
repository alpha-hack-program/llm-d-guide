# Installation Rationale — RHOAI 3.4 + llm-d + MaaS

This document explains **what** was installed in each phase and **why**, so you understand
the reasoning behind every step rather than just running commands blindly.

---

## The Big Picture

Red Hat OpenShift AI (RHOAI) is a platform for serving and managing AI/ML models on OpenShift.
Installing it for production-grade LLM serving involves several layers:

```
┌─────────────────────────────────────────────────────────┐
│  MaaS (Models-as-a-Service)                             │  ← governed API access
│  Subscriptions / API keys / token rate limits           │
├─────────────────────────────────────────────────────────┤
│  llm-d (Distributed Inference)                          │  ← model serving engine
│  LLMInferenceService / Gateway / HTTPRoute              │
├─────────────────────────────────────────────────────────┤
│  RHOAI 3.4 Operator + DataScienceCluster                │  ← platform brain
│  KServe controller / odh-model-controller               │
├─────────────────────────────────────────────────────────┤
│  Core dependencies                                      │  ← prerequisites
│  Connectivity Link · LeaderWorkerSet · cert-manager     │
├─────────────────────────────────────────────────────────┤
│  GPU hardware stack                                     │  ← bare metal concern
│  NFD · NVIDIA GPU Operator · MachineSets                │
├─────────────────────────────────────────────────────────┤
│  OpenShift Container Platform 4.21                      │  ← the foundation
└─────────────────────────────────────────────────────────┘
```

You build bottom-up. Each layer depends on the one below it being healthy.

---

## Phase 0 — Cluster Validation

**What:** Checked OCP version, admin access, StorageClass, pull secrets, and that no
conflicting operators (ODH, Service Mesh 2.x) were pre-installed.

**Why:**

- **OCP 4.20+ is a hard requirement for llm-d.** llm-d uses the OpenShift built-in Gateway API
  controller (`openshift.io/gateway-controller/v1`), which only ships in OCP 4.20+. Running
  on 4.19 would silently fail at the gateway step.

- **No ODH / no Service Mesh 2.x.** Open Data Hub and RHOAI share many CRDs. Running both
  causes reconciliation conflicts. Service Mesh 2.x ships its own Envoy proxy which conflicts
  with the llm-d gateway sidecar. Neither can be present.

- **Default StorageClass required.** Many RHOAI components (model registry, pipelines,
  PostgreSQL for MaaS) need persistent volumes. Without a default StorageClass that supports
  dynamic provisioning, PVCs hang in `Pending` forever.

- **registry.redhat.io in the pull secret.** The Qwen3-8B model is distributed as an OCI
  ModelCar image (`oci://registry.redhat.io/rhelai1/...`). Without this registry in the cluster
  pull secret, every GPU node that tries to pull the image gets `ImagePullBackOff`.

**Cluster:** OCP 4.21.11 on AWS eu-west-1. All checks passed.

---

## Phase 1 — ArgoCD + cert-manager + Let's Encrypt

### ArgoCD (Red Hat OpenShift GitOps)

**What:** Installed the OpenShift GitOps operator, which deploys an ArgoCD instance.

**Why:** ArgoCD provides GitOps-based continuous delivery — it can keep cluster state in sync
with a Git repository. For this installation we used `helm template | oc apply` directly, but
ArgoCD is installed anyway because:
1. It is used by the cert-manager chart to install ClusterIssuers via an `Application` CR.
2. Once the cluster is handed over to a team, they will use ArgoCD for day-2 operations.

### cert-manager (cloud=aws)

**What:** Installed the cert-manager Operator for Red Hat OpenShift. On AWS, the chart also
creates a `CredentialsRequest` that tells the OpenShift Cloud Credential Operator (CCO) to
provision a scoped IAM secret (`aws-creds`) with Route53 permissions.

**Why:**

- **TLS is everywhere.** RHOAI exposes the dashboard, model endpoints, and MaaS API over HTTPS.
  cert-manager automates the full certificate lifecycle: request → DNS-01 challenge → issue →
  renew. Without it you manage certificates by hand, which breaks silently at expiry.

- **`cloud=aws` vs `cloud=none`.** On AWS, cert-manager uses Route53 DNS-01 challenges to
  prove domain ownership to Let's Encrypt. The `CredentialsRequest` gives cert-manager exactly
  the Route53 permissions it needs — no more, no less — through CCO's IAM role federation.
  On bare metal there is no cloud credential controller, so `cloud=none` skips the
  `CredentialsRequest` and you bring your own credentials.

- **Two-pass apply.** The `CertManager` CR is part of the same Helm chart, but its CRD is only
  registered once the operator's CSV reaches `Succeeded`. That's why the first apply always
  errors on the CR — it's expected. The second pass (after waiting for the CSV) applies cleanly.

### Let's Encrypt certificates

**What:** Applied ClusterIssuers (staging + production) and two `Certificate` objects:
- `ocp-ingress` in `openshift-ingress` — replaces the default self-signed wildcard cert for
  `*.apps.<cluster>`, used by every OpenShift Route.
- `ocp-api` in `openshift-config` — replaces the self-signed cert on the API server endpoint.

**Why:**

- **Trust.** Self-signed certificates trigger browser warnings and require `curl -k` everywhere.
  Let's Encrypt certificates are trusted by default — no manual CA import needed.

- **MaaS requires valid TLS.** The Envoy proxy inside the MaaS gateway connects to Authorino
  over gRPC/TLS. Authorino's serving certificate is signed by OpenShift's service-CA. For
  this chain to work, the ingress-level certificate must be valid — a broken wildcard cert
  causes Envoy to reject the TLS handshake before auth is even attempted.

**Human gate:** Both certs must show `READY=True` before moving on. A cert stuck in `False`
means the DNS-01 challenge failed (usually a Route53 permission or propagation issue).

---

## Phase 2 — GPU Nodes + NFD + NVIDIA GPU Operator

### GPU MachineSets (AWS g5.2xlarge — NVIDIA A10G)

**What:** Created three `MachineSet` objects in the `openshift-machine-api` namespace, one per
availability zone (eu-west-1a/b/c). Each MachineSet provisions one `g5.2xlarge` EC2 instance
(24 vCPU, 96 GiB RAM, 1× NVIDIA A10G 24 GiB GPU).

**Why:**

- **Models need GPUs.** Qwen3-8B-FP8 requires ~12 GiB of GPU VRAM. The standard worker nodes
  in this cluster are `m7i.4xlarge` (CPU-only). Without GPU nodes, the LLMInferenceService pods
  will be `Pending` forever — no node can satisfy the `nvidia.com/gpu: 1` resource request.

- **All 3 AZs for HA.** Spreading across availability zones means a single AZ failure doesn't
  take down all GPU capacity. The Kubernetes scheduler can also spread replicas across AZs,
  reducing blast radius.

- **Start provisioning early.** AWS takes 5–15 minutes to provision a new EC2 instance, boot
  RHCOS, and join the cluster. By starting MachineSets first, the nodes are often ready by
  the time the operators finish installing.

### Node Feature Discovery (NFD)

**What:** Installed the NFD operator and applied a `NodeFeatureDiscovery` CR, which runs a
DaemonSet on every node that detects hardware capabilities and labels nodes accordingly.

**Why:**

- **GPU nodes need to be distinguishable.** Once a g5.2xlarge joins the cluster, Kubernetes
  doesn't automatically know it has a GPU. NFD detects the NVIDIA PCI device and adds the label
  `feature.node.kubernetes.io/pci-10de.present=true` (`10de` is NVIDIA's PCI vendor ID).

- **NVIDIA GPU Operator depends on NFD labels.** The ClusterPolicy CR uses a node selector
  based on NFD labels to decide which nodes to deploy the GPU driver DaemonSet on. Without NFD
  labels, the driver never gets installed and `nvidia.com/gpu` capacity never appears.

### NVIDIA GPU Operator

**What:** Installed the GPU Operator and applied a `ClusterPolicy` CR.

**Why:** The GPU Operator is a meta-operator that manages the full GPU software stack on each
GPU node via DaemonSets:

| DaemonSet | Purpose |
|---|---|
| NVIDIA driver | Loads the kernel module so the GPU is accessible from userspace |
| Device plugin | Registers `nvidia.com/gpu` as a schedulable Kubernetes resource |
| Container toolkit | Enables GPU access from containers (mounts device files, configures runtimes) |
| DCGM exporter | Exports GPU metrics (utilization, temperature, memory) to Prometheus |
| MIG manager | Manages Multi-Instance GPU partitioning (not used here but always deployed) |

Without the device plugin, the scheduler cannot place GPU workloads — `nvidia.com/gpu` simply
doesn't exist as a resource.

**Human gate:** At least one node must show `nvidia.com/gpu: "1"` in its capacity before
deploying any model.

---

## Phase 3 — Core Dependencies + RHOAI

### Red Hat Connectivity Link (RHCL) — Kuadrant stack

**What:** Installed the RHCL operator, which brings in three sub-operators:
- **Authorino** — an external authorization server (AuthN/AuthZ via ext-authz protocol)
- **Limitador** — a rate-limiting server (token counting via ext-proc protocol)
- **DNS Operator** — DNS record management for gateway hostnames

Then applied a `Kuadrant` CR in `kuadrant-system` to actually start the Authorino and
Limitador pods (the operator alone installs CRDs but starts nothing).

**Why:**

- **KServe requires Authorino for auth on model endpoints.** When an `LLMInferenceService` has
  `enableAuth: true`, the odh-model-controller creates an `AuthPolicy` CR. Without Authorino
  running, `AuthPolicy` objects are created but never translated into `AuthConfig` — auth is
  silently unenforced.

- **MaaS uses both Authorino (API key validation) and Limitador (token counting).** Every
  request through the MaaS gateway is intercepted by Envoy, which calls Authorino via gRPC
  to validate the `sk-oai-*` Bearer token, then calls Limitador to check and decrement the
  token quota. Without either, MaaS is either open to anyone or unlimited.

- **The `Kuadrant` CR is mandatory — installing the operator is not enough.** This is a common
  gotcha: the RHCL operator manages CRDs and the Kuadrant controller, but the actual Authorino
  and Limitador deployments are only created when a `Kuadrant` CR exists in `kuadrant-system`.

### LeaderWorkerSet (LWS) Operator

**What:** Installed the LWS operator and its CR.

**Why:** LWS is a Kubernetes workload controller designed for multi-node distributed AI
workloads. llm-d uses it for **prefill/decode disaggregation** — a technique where one set of
pods handles the computationally expensive prefill phase and another set handles the
lower-latency decode phase, allowing each to be scaled and scheduled independently.

For the single-GPU Qwen3-8B deployment in this guide (no disaggregation), LWS is not actively
used — but it is a hard dependency of the llm-d controller. Without it, the RHOAI operator
refuses to start the llm-d components.

### RHOAI Operator + DataScienceCluster

**What:** Installed the `rhods-operator` via OLM (Operator Lifecycle Manager) on the
`stable-3.x` channel, then applied:
- `DSCInitialization` — cluster-wide RHOAI defaults (namespace, auth mode, monitoring)
- `DataScienceCluster` (DSC) — declares which RHOAI components are active (`Managed` = on)
- `OdhDashboardConfig` — dashboard feature flags
- `HardwareProfile` CRs — GPU node selectors for the dashboard's "deploy model" flow

**Why:**

- **The RHOAI operator is the orchestrator.** It watches the DSC and deploys/reconciles all
  RHOAI components: dashboard, KServe controller, odh-model-controller, maas-api,
  maas-controller, model registry, etc.

- **`modelsAsService: false` at this stage (deliberately).** The `maas-api` pod needs both a
  running PostgreSQL database and the `maas-default-gateway` to exist before it can start.
  Enabling MaaS before those are ready leaves the DSC permanently `Not Ready`. The guide
  keeps it `false` during the initial install and enables it in Phase 9 after the gateway
  and database are deployed.

- **`authpolicies.kuadrant.io` CRD must exist before DSC.** The DSC reconciler tries to create
  `AuthPolicy` objects during startup. If the Kuadrant CRD isn't registered yet, the
  reconciler crashes in a loop. This is why Connectivity Link is installed before RHOAI.

- **Hardware profiles** tell the RHOAI dashboard how to schedule model serving pods:
  - `gpu-profile` — generic GPU node (any NVIDIA GPU, no specific product selector)
  - `nvidia-a10g-profile` — pins to A10G nodes specifically (useful in mixed-GPU clusters)
  - `gpu-kueue-profile` — reserved for future Kueue-managed scheduling (not enabled)

---

## Phase 4 — Monitoring Stack

**What:** Installed three operators and their instances:
- **Tempo Operator** — distributed tracing backend (stores and queries traces)
- **OpenTelemetry Operator** — OTel collector (receives spans from RHOAI components)
- **Grafana Operator** — dashboard UI (visualizes metrics and traces)

**Why:**

- **LLM inference has unique performance characteristics.** Unlike traditional microservices,
  LLM serving performance is dominated by GPU-specific metrics: Time-To-First-Token (TTFT),
  inter-token latency, KV-cache hit rate, and GPU memory utilization. Standard Prometheus/
  Grafana dashboards don't capture these — the llm-d monitoring stack ships purpose-built
  dashboards for them.

- **Traces show end-to-end request flow.** A single MaaS request passes through: OCP Route →
  Envoy (gateway) → Authorino (auth) → Limitador (rate-limit) → vLLM (inference). Without
  distributed tracing, debugging latency spikes is guesswork.

- **Observability is cheaper to add now than later.** Adding tracing after a model is in
  production requires restarting pods and risks a brief outage. Installing the operators now
  means you can enable instrumentation any time with a label change.

---

## Phase 5 — llm-d Quick Start

### llm-d Gateway

**What:** Applied a Helm chart that creates:
- `GatewayClass` — names the OCP built-in Gateway API controller
- `Gateway` (openshift-ai-inference) — the L7 entry point in `openshift-ingress`, with a
  TLS listener on port 443 (self-signed cert generated by cert-manager)
- OCP `Route` — exposes the gateway via the OpenShift router

**Why:**

- **The Gateway API is the new Ingress.** Kubernetes is moving from `Ingress` objects to the
  Gateway API (`Gateway`, `HTTPRoute`, `GRPCRoute`). llm-d uses Gateway API natively because
  it needs features Ingress doesn't support: path-based routing to multiple models, header
  manipulation, and policy attachment (for auth and rate limiting).

- **`odh-model-controller` auto-creates HTTPRoutes.** When you create an `LLMInferenceService`,
  the odh-model-controller creates an `HTTPRoute` that attaches to the gateway and routes
  `/<namespace>/<model-name>/*` to the model's Service. You never write HTTPRoutes by hand.

- **The Gateway lives in `openshift-ingress`.** This is the namespace the OCP router (HAProxy)
  manages. Placing the Gateway here gives it a stable address via the router's LoadBalancer.

### `llm-d-demo` Namespace

**What:** Created the namespace and applied two labels:
- `modelmesh-enabled=false` — tells RHOAI not to use ModelMesh (legacy multi-model serving)
- `opendatahub.io/dashboard=true` — makes the namespace visible in the RHOAI dashboard

**Why:** Without these labels, either ModelMesh tries to claim the namespace (and conflicts with
KServe) or the namespace doesn't appear in the dashboard's project selector.

### LLMInferenceService (Qwen3-8B-FP8 via OCI)

**What:** Deployed a `LLMInferenceService` CR that describes the model:
- `storage.type: oci` — pulls model weights from an OCI image (`registry.redhat.io`)
- `replicas: 2` — two vLLM pods for throughput and resilience
- `gpuCount: 1` per pod — one A10G GPU each
- `VLLM_ADDITIONAL_ARGS` — enables tool calling and disables verbose access logs

**Why:**

- **OCI ModelCar vs HuggingFace.** The OCI approach packages model weights as a container
  image layer. This means the image is cached in the node's container runtime after the first
  pull — subsequent deployments and pod restarts are near-instant. HuggingFace downloads
  weights from the internet on every cold start, which can take 10–20 minutes for an 8B model.

- **`replicas: 2`.** A single vLLM pod is a single point of failure. With two replicas, the
  llm-d router/scheduler can distribute requests across both and continue serving if one pod
  restarts (e.g. after an OOM kill).

- **`useStartupProbe: true`.** vLLM takes 2–5 minutes to load weights into GPU VRAM before it
  can serve requests. A startup probe tells Kubernetes to wait (rather than kill the pod as
  unhealthy) until the `/health` endpoint responds.

- **Why `--enable-auto-tool-choice --tool-call-parser hermes`.** Qwen3-8B supports function
  calling (tool use). These flags tell vLLM to parse tool call responses in Hermes format and
  route them correctly. Without them, structured tool calls silently return malformed JSON.

---

## Phase 9 — Model as a Service (MaaS)

MaaS adds a **governed access layer** on top of llm-d. Instead of calling models directly with
an OpenShift token (which grants access to anyone in the cluster with RBAC), external users get
scoped `sk-oai-*` API keys with individual token quotas.

### Step 1 — Kuadrant CR (done in Phase 3)

Already completed. Kuadrant was `Ready` with Authorino and Limitador running.

### Step 2 — MaaS Gateway (`maas-default-gateway`)

**What:** Applied a chart that creates a second Gateway (`maas-default-gateway`) in
`openshift-ingress` alongside the llm-d gateway, plus an OCP Route with hostname
`maas.<cluster-domain>`.

**Why a separate gateway for MaaS?**

- **Different policy attachment point.** The MaaS gateway has the annotation
  `security.opendatahub.io/authorino-tls-bootstrap=true`, which triggers the `maas-controller`
  to create an `EnvoyFilter` that wires Envoy → Authorino TLS gRPC. This setup is specific
  to MaaS and would conflict with the llm-d gateway's simpler auth model.

- **`allowedRoutes` namespace selector.** The MaaS gateway only accepts HTTPRoutes from
  explicitly listed namespaces (`gateway.modelNamespaces`). This is a security boundary:
  only models you explicitly publish to MaaS are reachable via the MaaS gateway.

- **Hostname `maas.<cluster-domain>`.** The `maas-ui` sidecar in the RHOAI dashboard is
  hardcoded to call `maas.<cluster-domain>/maas-api/...`. The gateway Route hostname must
  match exactly or the dashboard returns 500 errors on the API keys page.

### Step 3 — MaaS Database (PostgreSQL)

**What:** Deployed a PostgreSQL instance in `redhat-ods-applications` and created a
`maas-db-config` Secret with the `DB_CONNECTION_URL`.

**Why:** `maas-api` stores API keys in PostgreSQL. The key record includes:
- The hashed key value (never stored in plaintext)
- The user identity that created it
- The subscription it's bound to
- Expiry timestamp

Without the database, `maas-api` fails to start (it can't open a connection on boot).
The `maas-db-config` secret is the contract between the database and the API: the secret
must exist in `redhat-ods-applications` before `modelsAsService=true` is set.

### Step 4 — Enable `modelsAsService=true` in the DataScienceCluster

**What:** Re-applied the RHOAI Helm chart with `--set modelsAsService=true`. This tells the
RHOAI operator to start the `maas-api` and `maas-controller` deployments.

**Why the careful ordering?**

```
Deploy MaaS gateway   ← maas-api needs the gateway to exist at startup
Deploy database       ← maas-api needs maas-db-config Secret at startup
         ↓
Enable modelsAsService=true   ← now maas-api can start successfully
```

Enabling `modelsAsService=true` before the gateway or database are ready leaves `maas-api`
in a crash loop. The operator doesn't retry — you have to fix the missing dependency and
restart the pod manually.

### Step 4b — Authorino TLS

**What:** Four sub-steps:
1. Annotated the `authorino-authorino-authorization` Service to request a TLS cert from the
   OpenShift service-CA operator.
2. Patched the `Authorino` CR to enable TLS with that cert secret.
3. Set `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` env vars on the Authorino deployment so it
   trusts the cluster CA bundle.
4. Removed and re-added the `security.opendatahub.io/authorino-tls-bootstrap=true` annotation
   on the MaaS gateway.

**Why:**

- **Envoy requires TLS to talk to Authorino.** The Envoy proxy inside the MaaS gateway calls
  Authorino's gRPC port 50051 to validate every API key. When Authorino is in TLS mode, this
  gRPC channel must use TLS. The `EnvoyFilter` named `maas-default-gateway-authn-ssl` (created
  by `maas-controller` in response to the gateway annotation) configures the Envoy cluster to
  use TLS — but only after the annotation triggers the reconcile.

- **Why remove and re-add the annotation?** The `maas-controller` only reacts to annotation
  *change events*, not to the annotation's presence at steady state. If the annotation was
  already set when Authorino TLS was enabled, the controller doesn't re-reconcile and the
  `EnvoyFilter` is never updated. Remove then re-add forces a new change event.

- **Without this, `POST /maas-api/v1/api-keys` returns 500.** Envoy tries to connect to
  Authorino's gRPC port over plain TCP, Authorino answers with a TLS handshake, Envoy closes
  the connection. The error manifests as a 500 at the API layer.

### Step 5 — Bootstrap `models-as-a-service` Namespace (Tenant CR)

**What:** Created the `models-as-a-service` namespace and a `Tenant` CR named exactly
`default-tenant`.

**Why:**

- **The `maas-controller` only watches `models-as-a-service`.** All MaaS CRs
  (`MaaSModelRef`, `MaaSSubscription`, `MaaSAuthPolicy`) must live in this namespace.

- **`default-tenant` is not just a name — it's a key.** The `maas-controller` looks up a
  Tenant CR named exactly `default-tenant` when bootstrapping. If the name is wrong, the
  controller never initializes and none of the MaaS subscription machinery starts.

- **The Tenant CR references the gateway.** `spec.gatewayRef` tells the controller which
  gateway to attach auth policies to. This is how the controller knows to create the
  `EnvoyFilter` in `openshift-ingress`.

### Step 5b — Inject `DB_CONNECTION_URL` into `maas-api`

**What:** Patched the `maas-api` Deployment to add a `DB_CONNECTION_URL` env var sourced
from the `maas-db-config` Secret.

**Why:** The RHOAI operator manages the `maas-api` Deployment but doesn't always inject the
DB env var reference on a fresh install (a known controller/CRD version timing issue).
Without `DB_CONNECTION_URL`, calls to `/v1/api-keys` return 404 — the API boots but can't
reach the database to look up or store keys.

### Step 6 — MaaSModelRef, MaaSSubscription, MaaSAuthPolicy

**What:** Created three CRs in the `models-as-a-service` namespace (and one in `llm-d-demo`):

| CR | What it does |
|---|---|
| `MaaSModelRef` (in model namespace) | Points the MaaS system at a specific `LLMInferenceService`. The controller verifies the model's HTTPRoute references the MaaS gateway. |
| `MaaSSubscription` | Defines token rate limits per model per group. The controller translates this into a Kuadrant `TokenRateLimitPolicy` in the model namespace. |
| `MaaSAuthPolicy` | Grants OCP groups access to specific models via the MaaS gateway. The controller creates a Kuadrant `AuthPolicy` in the model namespace. |

**Why the `maas.enabled=true` re-apply was needed:**

When the `LLMInferenceService` was first deployed, it pointed at the `openshift-ai-inference`
(llm-d) gateway. The `MaaSModelRef` controller checks that the model's HTTPRoute references the
`maas-default-gateway`. Since it didn't, the `MaaSModelRef` failed with:

> `HTTPRoute does not reference gateway (expected: maas-default-gateway, found: openshift-ai-inference)`

Re-applying the inference chart with `--set maas.enabled=true` updates the `LLMInferenceService`
spec, which causes `odh-model-controller` to update the HTTPRoute's `parentRefs` to point at
`maas-default-gateway`. The `MaaSModelRef` then reconciles successfully.

**Why the `TokenRateLimitPolicy` and `AuthPolicy` are in the model namespace (not `models-as-a-service`):**

Kuadrant policies must be in the same namespace as the HTTPRoute they target. The model's
HTTPRoute is in `llm-d-demo`, so the policies must be there too. The `maas-controller` handles
this automatically — you write your intent in `models-as-a-service` and the controller creates
the enforcement objects where they need to be.

### Step 7 — Dashboard Feature Flags

**What:** Patched `OdhDashboardConfig` to set four boolean flags to `true`.

| Flag | What it unlocks |
|---|---|
| `genAiStudio` | Gen AI Studio section in the dashboard |
| `modelAsService` | MaaS model serving toggle on LLMInferenceService deploy form |
| `maasAuthPolicies` | Settings → Authorization policies tab |
| `vLLMDeploymentOnMaaS` | Gen AI Studio → API keys management tab |

**Why:** RHOAI feature flags control UI visibility independently of backend readiness. This
lets Red Hat ship UI for features that are Technology Preview without enabling them by default.
Without all four flags, parts of the MaaS dashboard simply don't render — the API is there
but the UI hides it.

---

## How MaaS Works End-to-End (Request Flow)

```
API client (curl / Python SDK)
       │
       │  Bearer: sk-oai-...
       ▼
OCP Route (maas.apps.<cluster>)
       │
       ▼
Envoy proxy (inside openshift-ingress pod)
       │
       ├── gRPC/TLS → Authorino (validates sk-oai-* key, resolves userid + subscription)
       │
       ├── gRPC → Limitador (checks token quota for userid+subscription, decrements on response)
       │
       ▼
HTTPRoute (qwen3-8b-kserve-route)
       │
       ▼
vLLM pods in llm-d-demo
       │
       ▼
Response (with usage.total_tokens)
       │
       └── Limitador reads total_tokens from response to update quota counters
```

The key insight: **auth and rate limiting are enforced by the gateway infrastructure, not by
the model server.** vLLM knows nothing about API keys or quotas. This separation means:
- You can change rate limits without restarting vLLM.
- A compromised model container can't bypass auth.
- The same gateway policy works for any model that publishes to MaaS.

---

## What Was Not Installed (and Why)

| Component | Reason skipped |
|---|---|
| **Kueue** | Only needed for distributed training workloads (Ray, PyTorch DDP). Installs namespace labels that break hardware profile visibility for workbenches when Kueue is not fully configured. |
| **OpenShift Pipelines** | Only needed if you use Data Science Pipelines (Kubeflow Pipelines). Not required for model serving. |
| **Service Mesh 3.x** | Only needed for the Llama Stack Operator. llm-d uses the OCP built-in Gateway API controller, not Istio. |
| **Llama Stack Operator** | Out of scope for this installation. Requires Service Mesh 3.x. |
| **MetalLB** | AWS clusters use the cloud-provider LoadBalancer. MetalLB is only needed on bare metal. |
