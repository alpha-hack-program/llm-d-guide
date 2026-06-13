# Phase 4 — Monitoring Stack

> Part of the [llm-d-demo Co-pilot Runbook](../../AGENTS.md). See the
> [Phase Map](../../AGENTS.md#phase-map) for the full sequence.

**Goal:** Install COO for llm-d metrics dashboards.

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
