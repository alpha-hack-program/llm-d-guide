# Phase 4 — Monitoring Stack

> Part of the [llm-d-guide Co-pilot Runbook](../../AGENTS.md). See the
> [Phase Map](../../AGENTS.md#phase-map) for the full sequence.

**Goal:** Extend the basic monitoring stack with llm-d Perses dashboards surfaced directly in the OpenShift console.

OpenShift's built-in User Workload Monitoring (Prometheus + Thanos) already scrapes vLLM and KServe metrics once UWM is enabled. This phase layers the **Cluster Observability Operator (COO)** on top, which adds Perses dashboard support to the OCP console's **Observe → Dashboards** view — no separate Grafana instance required.

> **RHOAI 3.5 changes in this phase:**
>
> - **COO version pin removed.** RHOAI 3.4.1 required pinning COO to v1.4.0 because the Perses image did not support newer CLI flags. The Perses image shipped with RHOAI 3.5 is compatible with current COO versions, so the pin is no longer needed.
> - **Observability dashboards auto-installed.** When llm-d is deployed, the operator now auto-creates dashboard ConfigMap objects. Step 5 (manual dashboard deployment) is only needed for custom dashboards or if the auto-created ones need to be overridden.
> - **EPP metrics prefix changed.** The Endpoint Picker metrics prefix changed from `inference_extension_` to `llm_d_epp_`. Any custom Prometheus queries or alerting rules referencing the old prefix must be updated (e.g., `inference_extension_request_duration_seconds` is now `llm_d_epp_request_duration_seconds`).

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

**Note:** In RHOAI 3.4.1 the operator was pinned to COO v1.4.0 because the Perses image did not support newer CLI flags. This pin is removed for RHOAI 3.5 — the updated Perses image supports current COO versions. Install the latest available version from the channel.

**OCP 4.20 and 4.21 (OLMv0):**

> **Note:** On OCP 4.21, use OLMv0 — the web console does not display OLMv1-installed operators.
> The `cluster-extension.yaml` is provided for forward compatibility when the console supports OLMv1.

```bash
oc apply -k gitops/operators/cluster-observability-operator

# The InstallPlan uses Manual approval — approve it:
IP=$(oc get installplan -n openshift-cluster-observability-operator \
  -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}')
[[ -n "$IP" ]] && oc patch installplan "$IP" -n openshift-cluster-observability-operator \
  --type=merge -p '{"spec":{"approved":true}}'

# Wait for COO CSV (poll by name — label may not be applied immediately)
echo "Waiting for COO CSV..."
for i in $(seq 1 60); do
  CSV=$(oc get csv -n openshift-cluster-observability-operator -o name 2>/dev/null | grep cluster-observability || true)
  if [[ -n "$CSV" ]]; then
    echo "Found: $CSV"
    oc wait --for=jsonpath='{.status.phase}'=Succeeded $CSV -n openshift-cluster-observability-operator --timeout=300s
    break
  fi
  sleep 5
done

# Verify COO is installed
oc get csv -n openshift-cluster-observability-operator | grep cluster-observability
# Expected: cluster-observability-operator.v<version>   Succeeded
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

> **RHOAI 3.5:** Observability dashboards are now auto-installed when llm-d is deployed — the
> operator creates dashboard ConfigMap objects automatically. This manual step is only needed
> if you want to deploy a custom dashboard or override the auto-created ones.

```bash
# Check whether dashboards were auto-created before applying manually:
oc get persesdashboard -n openshift-cluster-observability-operator

# If no dashboards exist, apply the bundled one:
oc apply -f gitops/instance/llm-d-observability/perses-dashboard-intelligent-inference.yaml
```

> **Note:** The dashboard must be in the `openshift-cluster-observability-operator` namespace
> with label `app.kubernetes.io/part-of: monitoring` — the Monitoring UIPlugin only discovers
> dashboards matching these criteria.

**Access:** OpenShift Console → **Observe** → **Dashboards (Perses)** → **"llm-d Intelligent Inference"**

For complete setup and troubleshooting:  
[gitops/instance/llm-d-observability/LLM-D-MONITORING-INTEGRATION.md](../../gitops/instance/llm-d-observability/LLM-D-MONITORING-INTEGRATION.md)

### Step 6 — Verify RHOAI dashboard monitoring drawer

The RHOAI dashboard has an integrated monitoring view gated by the `observabilityDashboard` flag. This flag is automatically set to `true` by the RHOAI instance Helm template applied in Phase 3 Step 5. Verify it's enabled:

```bash
# Verify observabilityDashboard is enabled (set by RHOAI instance template in Phase 3)
oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  -o jsonpath='{.spec.dashboardConfig.observabilityDashboard}'
# Expected: true
```

This surfaces a monitoring drawer inside the RHOAI dashboard (distinct from the OCP console's Observe → Dashboards view configured in Steps 3–4). The drawer becomes functional after the full monitoring stack (Tempo, OpenTelemetry, COO) is deployed.

**End of Phase 4:** Stop here and report monitoring stack status to the user. Verify COO is installed (CSV `Succeeded` on OCP 4.20, ClusterExtension `Installed` on OCP 4.21+). Wait for confirmation before proceeding to [Phase 5](05-llmd-quickstart.md).
