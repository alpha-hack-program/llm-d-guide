# Operator Dependency Matrix

| Operator | llm-d | GPUaaS / Distributed Workloads | Notes |
|---|---|---|---|
| **Connectivity Link** (Authorino + Limitador) | Required | Required | KServe auth, llm-d gateway, MaaS; Authorino is the token-auth piece. Installing the operator alone is not enough — a `Kuadrant` CR must also be created in `kuadrant-system` (`gitops/instance/maas/connectivity-link`) to deploy the actual operands. Must be installed BEFORE RHOAI. |
| **LeaderWorkerSet** | Required | Required | Multi-node MoE and P/D disaggregation. Must be installed BEFORE RHOAI. |
| **Tempo Operator** | Required | Required | Distributed tracing backend for the monitoring stack. Must be installed BEFORE RHOAI to ensure DSCi monitoring initialization succeeds. |
| **OpenTelemetry Operator** | Required | Required | Telemetry collection for the monitoring stack. Must be installed BEFORE RHOAI to ensure DSCi monitoring initialization succeeds. |
| **Cluster Observability Operator (COO)** | Required | Required | Perses dashboards in OCP console and RHOAI dashboard monitoring drawer. Version pinned to 1.4.0 for RHOAI 3.4.1 compatibility. |
| **Red Hat Build of Kueue** | Not required | Required | Do NOT install for llm-d-only setups — causes namespace label conflicts |
| **NFD + NVIDIA GPU Operator** | Required | Required | GPU node detection and drivers |
| **cert-manager** (Operator for Red Hat OpenShift) | Recommended | Recommended | Automates TLS for RHOAI, llm-d, OTel, and related components; manual certs are valid if you manage them yourself |
| **Grafana Operator** | Optional | Optional | Custom Grafana dashboards. COO provides Perses dashboards which are sufficient for most use cases. |

> **Kueue warning:** Installing the Kueue operator (even with `managementState: Removed` in the DSC)
> causes the RHOAI dashboard to label every new project with `kueue.openshift.io/managed=true`.
> This makes hardware profiles with `scheduling.type: Node` invisible in those projects.
> Only install Kueue if you specifically need GPUaaS or distributed workload queue management.
