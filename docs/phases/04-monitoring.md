# Phase 4 — Monitoring Stack

> Part of the [llm-d-demo Co-pilot Runbook](../../AGENTS.md). See the
> [Phase Map](../../AGENTS.md#phase-map) for the full sequence.

**Goal:** Extend the basic monitoring stack with llm-d Perses dashboards surfaced directly in the OpenShift console.

OpenShift's built-in User Workload Monitoring (Prometheus + Thanos) already scrapes vLLM and KServe metrics once UWM is enabled. This phase layers the **Cluster Observability Operator (COO)** on top, which adds Perses dashboard support to the OCP console's **Observe → Dashboards** view — no separate Grafana instance required.

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
[gitops/instance/llm-d-observability/LLM-D-MONITORING-INTEGRATION.md](../../gitops/instance/llm-d-observability/LLM-D-MONITORING-INTEGRATION.md)

**End of Phase 4:** Stop here and report monitoring stack status to the user. Verify COO CSV is Succeeded. Wait for confirmation before proceeding to [Phase 5](05-llmd-quickstart.md).
