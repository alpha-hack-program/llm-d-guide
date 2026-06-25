# Phase 4 — Monitoring Stack

> Part of the [llm-d-guide Co-pilot Runbook]](../../AGENTS.md). See the
> [Phase Map](../../AGENTS.md#phase-map) for the full sequence.

**Goal:** Extend the basic monitoring stack with llm-d Perses dashboards surfaced directly in the OpenShift console.

OpenShift's built-in User Workload Monitoring (Prometheus + Thanos) already scrapes vLLM and KServe metrics once UWM is enabled. This phase layers the **Cluster Observability Operator (COO)** on top, which adds Perses dashboard support to the OCP console's **Observe → Dashboards** view — no separate Grafana instance required.

### Step 1 — Enable User Workload Monitoring (MANDATORY)

```bash
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

# Wait for prometheus-user-workload pods (~5 min)
oc get pods -n openshift-user-workload-monitoring -w
```

### Step 2 — Install Cluster Observability Operator

```bash
oc apply -k gitops/operators/cluster-observability-operator
```

### Step 3 — Enable Perses dashboards in the OpenShift console

The COO requires two `UIPlugin` CRs to surface Perses dashboards in the console:

```bash
# Dashboards UIPlugin — registers the console-dashboards-plugin
cat <<EOF | oc apply -f -
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: dashboards
spec:
  type: Dashboards
EOF

# Monitoring UIPlugin — replaces the built-in monitoring-plugin with the
# COO-enhanced version that renders Perses dashboards
cat <<EOF | oc apply -f -
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: monitoring
spec:
  type: Monitoring
  monitoring:
    perses:
      enabled: true
EOF

# Verify both UIPlugins are Available
oc get uiplugin
# Expected: dashboards and monitoring, both Reconciled + Available

# The console pods will restart automatically (~30s)
```

### Step 4 — Deploy Perses dashboard

```bash
oc apply -f gitops/instance/llm-d-observability/perses-dashboard-intelligent-inference.yaml
```

> **Note:** The dashboard must be in the `openshift-cluster-observability-operator` namespace
> with label `app.kubernetes.io/part-of: monitoring` — the Monitoring UIPlugin only discovers
> dashboards matching these criteria.

**Access:** OpenShift Console → **Observe** → **Dashboards (Perses)** → **"llm-d Intelligent Inference"**

For complete setup and troubleshooting:  
[gitops/instance/llm-d-observability/LLM-D-MONITORING-INTEGRATION.md](../../gitops/instance/llm-d-observability/LLM-D-MONITORING-INTEGRATION.md)

**End of Phase 4:** Stop here and report monitoring stack status to the user. Verify COO CSV is Succeeded. Wait for confirmation before proceeding to [Phase 5](05-llmd-quickstart.md).
