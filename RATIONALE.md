# Installation Rationale — RHOAI 3.4 + llm-d + MaaS

This document explains **what** is installed in each phase and **why**, so you understand
the reasoning behind every step rather than just running commands blindly. It is an expansion
of the [README.md](README.md) that focuses on the *why* behind every significant architectural
decision, install ordering constraint, and deliberate exclusion.

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

**What:** Check OCP version, admin access, StorageClass, pull secrets, and that no
conflicting operators (ODH, Service Mesh 2.x) are pre-installed.

**Why:**

- **OCP 4.21+ is required.** llm-d uses the OpenShift built-in Gateway API controller
  (`openshift.io/gateway-controller/v1`), which only ships in OCP 4.20+. RHOAI 3.4 is
  validated on 4.21. Running on an older version fails silently at the gateway step.

- **No ODH / no Service Mesh 2.x.** Open Data Hub and RHOAI share many CRDs. Running both
  causes reconciliation conflicts. Service Mesh 2.x ships its own Envoy proxy which conflicts
  with the llm-d gateway sidecar. Neither can be present.

- **Default StorageClass required.** RHOAI components (model registry, PostgreSQL for MaaS)
  need persistent volumes. Without a default StorageClass that supports dynamic provisioning,
  PVCs hang in `Pending` forever.

- **`registry.redhat.io` in the pull secret.** The Qwen3-8B model is distributed as an OCI
  ModelCar image (`oci://registry.redhat.io/rhelai1/...`). Without this registry in the cluster
  pull secret, every GPU node that tries to pull the image gets `ImagePullBackOff`.

---

## Phase 1 — TLS Certificate Automation

### ArgoCD (Red Hat OpenShift GitOps)

**What:** Install the OpenShift GitOps operator, which deploys an ArgoCD instance.

**Why:** ArgoCD provides GitOps-based continuous delivery. For this installation we use
`helm template | oc apply` directly, but ArgoCD is installed because:
1. The cert-manager chart uses it to install ClusterIssuers via an `Application` CR.
2. Once handed over to a team, ArgoCD is the day-2 operations tool for keeping cluster state
   in sync with Git.

### cert-manager (`cloud=aws` or `cloud=none`)

**What:** Install the cert-manager Operator for Red Hat OpenShift. On AWS, the chart also
creates a `CredentialsRequest` that tells the OpenShift Cloud Credential Operator (CCO) to
provision a scoped IAM secret (`aws-creds`) with Route53 permissions.

**Why:**

- **TLS is everywhere.** RHOAI exposes the dashboard, model endpoints, and MaaS API over
  HTTPS. cert-manager automates the full certificate lifecycle: request → DNS-01 challenge →
  issue → renew. Without it you manage certificates by hand, which breaks silently at expiry.

- **`cloud=aws` vs `cloud=none`.** On AWS, cert-manager uses Route53 DNS-01 challenges to
  prove domain ownership to Let's Encrypt. The `CredentialsRequest` gives cert-manager exactly
  the Route53 permissions it needs through CCO's IAM role federation. On bare metal there is no
  cloud credential controller, so `cloud=none` skips the `CredentialsRequest` and you bring
  your own credentials. **This choice must be confirmed with the user — do not default.**

- **Two-pass apply.** The `CertManager` CR is part of the same Helm chart, but its CRD is only
  registered once the operator's CSV reaches `Succeeded`. The first apply always errors on the
  CR — this is expected. The second pass (after waiting for the CSV) applies cleanly.

### Let's Encrypt certificates

**What:** Apply ClusterIssuers (staging + production) and two `Certificate` objects:
- `ocp-ingress` in `openshift-ingress` — replaces the default self-signed wildcard cert for
  `*.apps.<cluster>`, used by every OpenShift Route.
- `ocp-api` in `openshift-config` — replaces the self-signed cert on the API server endpoint.

**Why:**

- **Trust.** Self-signed certificates trigger browser warnings and require `curl -k` everywhere.
  Let's Encrypt certificates are trusted by default — no manual CA import needed.

- **MaaS requires valid TLS.** The Envoy proxy inside the MaaS gateway connects to Authorino
  over gRPC/TLS. Authorino's serving certificate is signed by OpenShift's service-CA. For this
  chain to work, the ingress-level certificate must be valid — a broken wildcard cert causes
  Envoy to reject the TLS handshake before auth is even attempted.

**Human gate:** Both certs must show `READY=True` before moving on. A cert stuck in `False`
means the DNS-01 challenge failed (usually a Route53 permission or propagation issue).

---

## Phase 2 — GPU Nodes + NFD + NVIDIA GPU Operator

### GPU MachineSets (AWS g5.2xlarge — NVIDIA A10G)

**What:** Create `MachineSet` objects in `openshift-machine-api`, one per availability zone.
Each MachineSet provisions one `g5.2xlarge` EC2 instance (24 vCPU, 96 GiB RAM, 1× NVIDIA A10G
24 GiB GPU).

**Why:**

- **Models need GPUs.** Qwen3-8B-FP8 requires ~12 GiB of GPU VRAM. Standard worker nodes are
  CPU-only. Without GPU nodes, `LLMInferenceService` pods are `Pending` forever — no node can
  satisfy the `nvidia.com/gpu: 1` resource request.

- **All 3 AZs for HA.** Spreading across availability zones means a single AZ failure doesn't
  take down all GPU capacity. The scheduler can spread replicas across AZs, reducing blast radius.

- **Start provisioning early.** AWS takes 5–15 minutes to provision a new EC2 instance, boot
  RHCOS, and join the cluster. Starting MachineSets first means the nodes are often ready by the
  time the operators finish installing.

### Node Feature Discovery (NFD)

**What:** Install the NFD operator and apply a `NodeFeatureDiscovery` CR, which runs a DaemonSet
on every node that detects hardware capabilities and labels nodes accordingly.

**Why:**

- **GPU nodes need to be distinguishable.** Once a g5.2xlarge joins the cluster, Kubernetes
  doesn't automatically know it has a GPU. NFD detects the NVIDIA PCI device and adds the label
  `feature.node.kubernetes.io/pci-10de.present=true` (`10de` is NVIDIA's PCI vendor ID).

- **NVIDIA GPU Operator depends on NFD labels.** The ClusterPolicy CR uses a node selector
  based on NFD labels to decide which nodes get the GPU driver DaemonSet. Without NFD labels,
  the driver is never installed and `nvidia.com/gpu` capacity never appears.

### NVIDIA GPU Operator

**What:** Install the GPU Operator and apply a `ClusterPolicy` CR.

**Why:** The GPU Operator is a meta-operator that manages the full GPU software stack on each
GPU node via DaemonSets:

| DaemonSet | Purpose |
|---|---|
| NVIDIA driver | Loads the kernel module so the GPU is accessible from userspace |
| Device plugin | Registers `nvidia.com/gpu` as a schedulable Kubernetes resource |
| Container toolkit | Enables GPU access from containers (mounts device files, configures runtimes) |
| DCGM exporter | Exports GPU metrics (utilization, temperature, memory) to Prometheus |
| MIG manager | Manages Multi-Instance GPU partitioning (not used here but always deployed) |

Without the device plugin, `nvidia.com/gpu` simply doesn't exist as a resource and the
scheduler cannot place GPU workloads.

**Human gate:** At least one node must show `nvidia.com/gpu: "1"` in its capacity before
deploying any model.

---

## Phase 3 — Core Operators + RHOAI

### Red Hat Connectivity Link (RHCL) — Kuadrant stack

**What:** Install the RHCL operator, which brings in three sub-operators:
- **Authorino** — an external authorization server (AuthN/AuthZ via ext-authz protocol)
- **Limitador** — a rate-limiting server (token counting via ext-proc protocol)
- **DNS Operator** — DNS record management for gateway hostnames

Then apply a `Kuadrant` CR in `kuadrant-system` to actually start the Authorino and Limitador
pods (the operator alone installs CRDs but starts nothing).

**Why:**

- **KServe requires Authorino for auth on model endpoints.** When an `LLMInferenceService` has
  `enableAuth: true`, the odh-model-controller creates an `AuthPolicy` CR. Without Authorino
  running, `AuthPolicy` objects are created but never translated into `AuthConfig` — auth is
  silently unenforced.

- **MaaS uses both Authorino (API key validation) and Limitador (token counting).** Every
  request through the MaaS gateway is intercepted by Envoy, which calls Authorino via gRPC/TLS
  to validate the `sk-oai-*` Bearer token, then calls Limitador to check and decrement the
  token quota. Without either, MaaS is either open to anyone or unlimited.

- **The `Kuadrant` CR is mandatory — installing the operator is not enough.** The RHCL operator
  manages CRDs and the Kuadrant controller, but the actual Authorino and Limitador deployments
  are only created when a `Kuadrant` CR exists in `kuadrant-system`.

- **Connectivity Link must be installed before RHOAI.** The DSC reconciler tries to create
  `AuthPolicy` objects during startup. If the `authpolicies.kuadrant.io` CRD isn't registered
  yet, the reconciler crashes in a loop.

### LeaderWorkerSet (LWS) Operator

**What:** Install the LWS operator.

**Why:** LWS is a Kubernetes workload controller designed for multi-node distributed AI
workloads. llm-d uses it for **prefill/decode disaggregation** — a technique where one set of
pods handles the computationally expensive prefill phase and another handles the lower-latency
decode phase, allowing each to scale independently.

For a single-GPU deployment (no disaggregation), LWS is not actively exercised — but it is a
hard dependency of the llm-d controller. Without it, the RHOAI operator refuses to start the
llm-d components.

### RHOAI Operator + DataScienceCluster

**What:** Install the `rhods-operator` via OLM on the `stable-3.x` channel, then apply:
- `DSCInitialization` — cluster-wide RHOAI defaults (namespace, auth mode, monitoring)
- `DataScienceCluster` (DSC) — declares which RHOAI components are active (`Managed` = on)
- `OdhDashboardConfig` — dashboard feature flags
- `HardwareProfile` CRs — GPU node selectors for the dashboard's "deploy model" flow

**Why:**

- **The RHOAI operator is the orchestrator.** It watches the DSC and deploys/reconciles all
  RHOAI components: dashboard, KServe controller, odh-model-controller, maas-api,
  maas-controller, AI Pipelines, model registry, etc.

- **`modelsAsService: false` at this stage (deliberately).** The `maas-api` pod needs both a
  running PostgreSQL database and the `maas-default-gateway` to exist before it can start.
  Enabling MaaS before those are ready leaves the DSC permanently `Not Ready`. Enable it in
  Phase 6 after the gateway and database are deployed.

- **Hardware profiles** tell the RHOAI dashboard how to schedule model serving pods — which
  node selector to use and what GPU resources to request. Without them the dashboard's
  "deploy model" flow has no GPU option to present.

### Monitoring stack (Tempo + OTel + Grafana)

**What:** Install three operators as part of Phase 3:
- **Tempo Operator** — distributed tracing backend (stores and queries traces)
- **OpenTelemetry Operator** — OTel collector (receives spans from RHOAI components)
- **Grafana Operator** — optional dashboard UI (visualizes metrics and traces via Grafana instance)

**Why install these in Phase 3 rather than later?**

- **Observability is cheaper to add now than after a model is live.** Adding tracing after a
  model is in production requires restarting pods and risks a brief outage. Installing the
  operators in Phase 3 means instrumentation can be enabled any time with a label or CR change.

- **Traces show the end-to-end request flow.** A single MaaS request passes through: OCP Route →
  Envoy (gateway) → Authorino (auth) → Limitador (rate-limit) → vLLM (inference). Without
  distributed tracing, debugging latency spikes is guesswork.

---

## Phase 4 — Monitoring Stack (COO + Perses dashboards)

**What:** Enable User Workload Monitoring and install the Cluster Observability Operator (COO),
then deploy a Perses dashboard for llm-d.

**Why this is a separate phase from Phase 3:**

- **User Workload Monitoring (UWM) is the foundation.** OpenShift's built-in Prometheus +
  Thanos already scrapes vLLM and KServe metrics once UWM is enabled with
  `enableUserWorkload: true`. No extra operator is needed for metric collection itself.

- **COO adds Perses dashboard support to the OCP console.** The Cluster Observability Operator
  extends the OpenShift console's **Observe → Dashboards** view with a Perses tab. This means
  llm-d dashboards (TTFT, KV-cache hit rate, token throughput, GPU utilisation) are available
  directly in the OCP console without deploying a separate Grafana instance.

- **LLM inference has unique performance characteristics.** Standard infrastructure dashboards
  don't capture metrics like Time-To-First-Token (TTFT), inter-token latency, KV-cache hit
  rate, or prefix cache efficiency. The llm-d Perses dashboards are purpose-built for these.

- **No Grafana instance required for this path.** COO + Perses is the native OCP console
  integration path. Grafana is available as an alternative (installed in Phase 3 via the
  Grafana Operator) for teams that prefer the Grafana UI or need dashboards beyond what Perses
  currently covers.

---

## Phase 5 — llm-d Quick Start

### llm-d Gateway

**What:** Apply a Helm chart that creates:
- `GatewayClass` — names the OCP built-in Gateway API controller
- `Gateway` (`openshift-ai-inference`) — the L7 entry point in `openshift-ingress`, with a
  TLS listener on port 443
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

**What:** Create the namespace with two labels:
- `modelmesh-enabled=false` — tells RHOAI not to use ModelMesh (legacy multi-model serving)
- `opendatahub.io/dashboard=true` — makes the namespace visible in the RHOAI dashboard

**Why:** Without these labels, either ModelMesh tries to claim the namespace (conflicting with
KServe) or the namespace doesn't appear in the dashboard's project selector.

### LLMInferenceService (Qwen3-8B-FP8 via OCI)

**What:** Deploy a `LLMInferenceService` CR describing the model:
- `storage.type: oci` — pulls model weights from an OCI image (`registry.redhat.io`)
- `replicas: 2` — two vLLM pods for throughput and resilience
- `gpuCount: 1` per pod — one A10G GPU each
- `VLLM_ADDITIONAL_ARGS` — enables tool calling and disables verbose access logs

**Why:**

- **OCI ModelCar vs HuggingFace.** The OCI approach packages model weights as a container
  image layer. The image is cached in the node's container runtime after the first pull —
  subsequent deployments and pod restarts are near-instant. HuggingFace downloads weights from
  the internet on every cold start, which can take 10–20 minutes for an 8B model.

- **`replicas: 2`.** A single vLLM pod is a single point of failure. With two replicas, the
  llm-d scheduler can distribute requests across both and continue serving if one pod restarts
  (e.g. after an OOM kill).

- **`useStartupProbe: true`.** vLLM takes 2–5 minutes to load weights into GPU VRAM before it
  can serve requests. A startup probe tells Kubernetes to wait (rather than kill the pod as
  unhealthy) until the `/health` endpoint responds.

- **`--enable-auto-tool-choice --tool-call-parser hermes`.** Qwen3-8B supports function calling
  (tool use). These flags tell vLLM to parse tool call responses in Hermes format. Without them,
  structured tool calls silently return malformed JSON.

---

## Phase 6 — Model as a Service (MaaS)

MaaS adds a **governed access layer** on top of llm-d. Instead of calling models directly with
an OpenShift token (which grants access to anyone in the cluster with RBAC), external users get
scoped `sk-oai-*` API keys with individual token quotas.

### MaaS Gateway (`maas-default-gateway`)

**What:** Apply a chart that creates a second Gateway (`maas-default-gateway`) in
`openshift-ingress`, plus an OCP Route with hostname `maas.<cluster-domain>`.

**Why a separate gateway for MaaS?**

- **Different policy attachment point.** The MaaS gateway has the annotation
  `security.opendatahub.io/authorino-tls-bootstrap=true`, which triggers the `maas-controller`
  to create an `EnvoyFilter` that wires Envoy → Authorino TLS gRPC. This setup is specific to
  MaaS and would conflict with the llm-d gateway's simpler auth model.

- **`allowedRoutes` namespace selector.** The MaaS gateway only accepts HTTPRoutes from
  explicitly listed namespaces (`gateway.modelNamespaces`). This is a security boundary:
  only models you explicitly publish to MaaS are reachable via the MaaS gateway.

- **Hostname `maas.<cluster-domain>`.** The `maas-ui` sidecar in the RHOAI dashboard is
  hardcoded to call `maas.<cluster-domain>/maas-api/...`. The gateway Route hostname must
  match exactly or the dashboard returns 500 errors on the API keys page.

### MaaS Database (PostgreSQL)

**What:** Deploy a PostgreSQL instance in `redhat-ods-applications` and create a
`maas-db-config` Secret with the `DB_CONNECTION_URL`.

**Why:** `maas-api` stores API keys in PostgreSQL. The key record includes:
- The hashed key value (never stored in plaintext)
- The user identity that created it
- The subscription it's bound to
- Expiry timestamp

Without the database, `maas-api` fails to start — it can't open a connection on boot. The
`maas-db-config` secret must exist in `redhat-ods-applications` before `modelsAsService=true`
is set.

### Enable `modelsAsService=true` in the DataScienceCluster

**What:** Re-apply the RHOAI Helm chart with `--set modelsAsService=true`. This tells the
RHOAI operator to start the `maas-api` and `maas-controller` deployments.

**Why the careful ordering?**

```
Deploy MaaS gateway   ← maas-api needs the gateway to exist at startup
Deploy database       ← maas-api needs maas-db-config Secret at startup
         ↓
Enable modelsAsService=true   ← now maas-api can start successfully
```

Enabling `modelsAsService=true` before the gateway or database are ready leaves `maas-api` in
a crash loop. The operator doesn't retry — you must fix the missing dependency and restart the
pod manually.

### Authorino TLS

**What:** Four sub-steps:
1. Annotate the `authorino-authorino-authorization` Service to request a TLS cert from the
   OpenShift service-CA operator.
2. Patch the `Authorino` CR to enable TLS with that cert secret.
3. Set `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` env vars on the Authorino deployment so it
   trusts the cluster CA bundle.
4. Remove and re-add the `security.opendatahub.io/authorino-tls-bootstrap=true` annotation
   on the MaaS gateway.

**Why:**

- **Envoy requires TLS to talk to Authorino.** The Envoy proxy inside the MaaS gateway calls
  Authorino's gRPC port 50051 to validate every API key. The `EnvoyFilter` named
  `maas-default-gateway-authn-ssl` (created by `maas-controller` in response to the gateway
  annotation) configures the Envoy cluster to use TLS.

- **Why remove and re-add the annotation?** The `maas-controller` only reacts to annotation
  *change events*, not to the annotation's presence at steady state. Remove then re-add forces
  a new change event, causing the controller to regenerate the `EnvoyFilter` with TLS settings.

- **Without this, `POST /maas-api/v1/api-keys` returns 500.** Envoy tries to connect to
  Authorino's gRPC port over plain TCP, Authorino answers with a TLS handshake, Envoy closes
  the connection. The error manifests as a 500 at the API layer.

### Bootstrap `models-as-a-service` Namespace (Tenant CR)

**What:** Create the `models-as-a-service` namespace and a `Tenant` CR named exactly
`default-tenant`.

**Why:**

- **The `maas-controller` only watches `models-as-a-service`.** All MaaS CRs
  (`MaaSModelRef`, `MaaSSubscription`, `MaaSAuthPolicy`) must live in this namespace.

- **`default-tenant` is not just a name — it's a key.** The `maas-controller` looks up a
  Tenant CR named exactly `default-tenant` when bootstrapping. If the name is wrong, the
  controller never initializes and none of the MaaS subscription machinery starts.

- **The Tenant CR references the gateway.** `spec.gatewayRef` tells the controller which
  gateway to attach auth policies to.

### MaaSModelRef, MaaSSubscription, MaaSAuthPolicy

**What:** Create three CRs in the `models-as-a-service` namespace (plus one in the model
namespace):

| CR | What it does |
|---|---|
| `MaaSModelRef` (in model namespace) | Points MaaS at a specific `LLMInferenceService`. The controller verifies the model's HTTPRoute references the MaaS gateway. |
| `MaaSSubscription` | Defines token rate limits per model per group. Translated into a Kuadrant `TokenRateLimitPolicy` in the model namespace. |
| `MaaSAuthPolicy` | Grants OCP groups access to specific models via the MaaS gateway. Translated into a Kuadrant `AuthPolicy` in the model namespace. |

**Why the `maas.enabled=true` re-apply is needed when switching from llm-d to MaaS gateway:**

When the `LLMInferenceService` was first deployed it pointed at the `openshift-ai-inference`
(llm-d) gateway. The `MaaSModelRef` controller checks that the model's HTTPRoute references
`maas-default-gateway`. Re-applying the inference chart with `--set maas.enabled=true` updates
the `LLMInferenceService` spec, which causes `odh-model-controller` to update the HTTPRoute's
`parentRefs` to point at `maas-default-gateway`.

**Why Kuadrant policies live in the model namespace, not `models-as-a-service`:**

Kuadrant policies must be in the same namespace as the HTTPRoute they target. The model's
HTTPRoute is in `llm-d-demo`, so the policies must be there too. The `maas-controller` handles
this automatically — you write your intent in `models-as-a-service` and the controller creates
the enforcement objects where they need to be.

### Dashboard Feature Flags

**What:** Patch `OdhDashboardConfig` to set four boolean flags to `true`.

| Flag | What it unlocks |
|---|---|
| `genAiStudio` | Gen AI Studio section in the dashboard |
| `modelAsService` | MaaS model serving toggle on LLMInferenceService deploy form |
| `maasAuthPolicies` | Settings → Authorization policies tab |
| `vLLMDeploymentOnMaaS` | Gen AI Studio → API keys management tab |

**Why:** RHOAI feature flags control UI visibility independently of backend readiness. This
lets Red Hat ship UI for Technology Preview features without enabling them by default. Without
all four flags, parts of the MaaS dashboard simply don't render — the API is there but the UI
hides it.

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
- A compromised model container cannot bypass auth.
- The same gateway policy works for any model that publishes to MaaS.

---

## What Was Not Installed (and Why)

| Component | Reason skipped |
|---|---|
| **Kueue** | Only needed for distributed training workloads (Ray, PyTorch DDP). Installs namespace labels that break hardware profile visibility for workbenches when Kueue is not fully configured. |
| **Service Mesh 3.x** | Only needed for the Llama Stack Operator. llm-d uses the OCP built-in Gateway API controller, not Istio. |
| **OpenShift Serverless** | Was required for legacy KServe serverless mode in RHOAI 2.x. RHOAI 3.x uses KServe in raw deployment mode and has no Serverless dependency. |
| **Llama Stack Operator** | Out of scope for this installation. Requires Service Mesh 3.x. |
| **MetalLB** | AWS clusters use the cloud-provider LoadBalancer. MetalLB is only needed on bare metal. |
| **Open Data Hub (ODH)** | Shares CRDs with RHOAI. Running both causes reconciliation conflicts — only one can be installed on a cluster. |
