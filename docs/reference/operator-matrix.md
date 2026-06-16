# Operator Dependency Matrix

| Operator | llm-d | GPUaaS / Distributed Workloads | Notes |
|---|---|---|---|
| **Connectivity Link** (Authorino + Limitador) | Required | Required | KServe auth, llm-d gateway, MaaS; Authorino is the token-auth piece. Installing the operator alone is not enough — a `Kuadrant` CR must also be created in `kuadrant-system` (`gitops/instance/maas/connectivity-link`) to deploy the actual operands. |
| **LeaderWorkerSet** | Required | Required | Multi-node MoE and P/D disaggregation |
| **Red Hat Build of Kueue** | Not required | Required | Do NOT install for llm-d-only setups — causes namespace label conflicts |
| **NFD + NVIDIA GPU Operator** | Required | Required | GPU node detection and drivers |
| **cert-manager** (Operator for Red Hat OpenShift) | Recommended | Recommended | Automates TLS for RHOAI, llm-d, OTel, and related components; manual certs are valid if you manage them yourself |

> **Kueue warning:** Installing the Kueue operator (even with `managementState: Removed` in the DSC)
> causes the RHOAI dashboard to label every new project with `kueue.openshift.io/managed=true`.
> This makes hardware profiles with `scheduling.type: Node` invisible in those projects.
> Only install Kueue if you specifically need GPUaaS or distributed workload queue management.
