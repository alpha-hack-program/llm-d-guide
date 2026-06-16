# Repo Layout

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
