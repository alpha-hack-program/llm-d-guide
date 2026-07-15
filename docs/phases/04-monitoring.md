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

**Important:** The operator is pinned to version 1.4.0 for compatibility with RHOAI 3.4.1. COO 1.5.0 introduces CLI flags that the perses image shipped with RHOAI 3.4.1 does not support, causing the `data-science-perses` pod to crash-loop and breaking the RHOAI dashboard monitoring drawer.

```bash
oc apply -k gitops/operators/cluster-observability-operator

# The InstallPlan uses Manual approval — approve it automatically (version is pinned):
IP=$(oc get installplan -n openshift-cluster-observability-operator \
  -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}')
[[ -n "$IP" ]] && oc patch installplan "$IP" -n openshift-cluster-observability-operator \
  --type=merge -p '{"spec":{"approved":true}}'

# Wait for COO CSV
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv \
  -n openshift-cluster-observability-operator \
  -l operators.coreos.com/cluster-observability-operator.openshift-cluster-observability-operator= \
  --timeout=300s

# Verify COO 1.4.0 is installed
oc get csv -n openshift-cluster-observability-operator | grep cluster-observability
# Expected: cluster-observability-operator.v1.4.0   Succeeded
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

### Step 4 — Verify DCGM exporter ServiceMonitor

The Perses dashboard queries `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_POWER_USAGE`, and
`DCGM_FI_DEV_GPU_TEMP` from the NVIDIA DCGM exporter. A ServiceMonitor for it is included in
`gitops/instance/nvidia` (applied in Phase 2). Verify it exists:

```bash
oc get servicemonitor nvidia-dcgm-exporter -n nvidia-gpu-operator
# Expected: nvidia-dcgm-exporter   <age>

# If missing (e.g. Phase 2 was run before this ServiceMonitor was added), create it:
# oc apply -k gitops/instance/nvidia
```

### Step 5 — Deploy Perses dashboard

```bash
oc apply -f gitops/instance/llm-d-observability/perses-dashboard-intelligent-inference.yaml
```

> **Note:** The dashboard must be in the `openshift-cluster-observability-operator` namespace
> with label `app.kubernetes.io/part-of: monitoring` — the Monitoring UIPlugin only discovers
> dashboards matching these criteria.

**Access:** OpenShift Console → **Observe** → **Dashboards (Perses)** → **"llm-d Intelligent Inference"**

For complete setup and troubleshooting:  
[gitops/instance/llm-d-observability/LLM-D-MONITORING-INTEGRATION.md](../../gitops/instance/llm-d-observability/LLM-D-MONITORING-INTEGRATION.md)

### Step 5 — Verify RHOAI dashboard monitoring drawer

The RHOAI dashboard has an integrated monitoring view gated by the `observabilityDashboard` flag. This flag is automatically set to `true` by the RHOAI instance Helm template applied in Phase 3 Step 5. Verify it's enabled:

```bash
# Verify observabilityDashboard is enabled (set by RHOAI instance template in Phase 3)
oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  -o jsonpath='{.spec.dashboardConfig.observabilityDashboard}'
# Expected: true
```

This surfaces a monitoring drawer inside the RHOAI dashboard (distinct from the OCP console's Observe → Dashboards view configured in Steps 3–4). The drawer becomes functional after the full monitoring stack (Tempo, OpenTelemetry, COO) is deployed.

**End of Phase 4:** Stop here and report monitoring stack status to the user. Verify COO CSV is Succeeded. Wait for confirmation before proceeding to [Phase 5](05-llmd-quickstart.md).
