# Monitoring Integration - ServiceMonitor in Helm Chart

## Overview

As of this version, the llm-d inference Helm chart **automatically creates ServiceMonitor resources** to enable Prometheus metrics scraping.

**What this means:**
- ✅ One command deploys model + monitoring (no separate steps)
- ✅ ServiceMonitor lifecycle tied to model lifecycle (delete model = delete monitoring)
- ✅ Well-lit path label automatically propagated to metrics
- ✅ Works with OpenShift User Workload Monitoring out of the box

---

## Default Behavior

**Monitoring is ENABLED by default.**

```yaml
# values.yaml (default)
monitoring:
  enabled: true
  serviceMonitor:
    interval: 30s
    scrapeTimeout: 10s
```

When you deploy a model, **two ServiceMonitors** are created (for intelligent-inference):

1. **`<serviceName>-workload-metrics`** - Scrapes vLLM metrics from inference pods
2. **`<serviceName>-epp-metrics`** - Scrapes EPP (Endpoint Picker) scheduler metrics

For **P/D disaggregation**, only the workload ServiceMonitor is created (no EPP).

---

## Prerequisites

**User Workload Monitoring must be enabled on your cluster:**

```bash
# Check if enabled
oc get configmap cluster-monitoring-config -n openshift-monitoring \
  -o jsonpath='{.data.config\.yaml}' | grep enableUserWorkload

# If not enabled, enable it:
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

# Wait for prometheus-user-workload pods
oc get pods -n openshift-user-workload-monitoring -w
```

---

## Usage

### Deploy Model with Monitoring (Default)

```bash
# Monitoring is enabled by default - just deploy normally
helm template qwen3-8b ./gitops/instance/llm-d/inference \
  -f ./gitops/instance/llm-d/inference/qwen3-8b-values.yaml \
  | oc apply -f -
```

**Created resources:**
- LLMInferenceService: `qwen3-8b`
- ServiceMonitor: `qwen3-8b-workload-metrics`
- ServiceMonitor: `qwen3-8b-epp-metrics` (intelligent-inference only)

**Verify ServiceMonitors:**
```bash
oc get servicemonitor -n llm-d-demo -l app.kubernetes.io/name=qwen3-8b
```

Expected output:
```
NAME                          AGE
qwen3-8b-workload-metrics     1m
qwen3-8b-epp-metrics          1m
```

### Disable Monitoring

**Use case:** Air-gapped environments, cost optimization, already have external monitoring

**Option 1: Override in values file**

```yaml
# my-model-values.yaml
monitoring:
  enabled: false  # Skip ServiceMonitor creation
```

**Option 2: Override via Helm CLI**

```bash
helm template my-model ./gitops/instance/llm-d/inference \
  -f my-model-values.yaml \
  --set monitoring.enabled=false \
  | oc apply -f -
```

**Result:** Model deployed, no ServiceMonitors created.

### Customize Scrape Interval

```yaml
# my-model-values.yaml
monitoring:
  enabled: true
  serviceMonitor:
    interval: 15s       # Scrape every 15s (default: 30s)
    scrapeTimeout: 5s   # Timeout after 5s (default: 10s)
```

**When to use:**
- High-frequency scraping: Set `interval: 15s` for dashboards with 5m windows
- Low-frequency scraping: Set `interval: 60s` to reduce Prometheus load

---

## What Metrics Are Scraped

### vLLM Workload Metrics (Port 8000)

| Metric | Description |
|--------|-------------|
| `kserve_vllm:prefix_cache_hits_total` | Prefix cache hits (Intelligent Inference) |
| `kserve_vllm:prefix_cache_queries_total` | Prefix cache queries |
| `kserve_vllm:prompt_tokens_cached_total` | Tokens served from cache |
| `kserve_vllm:time_to_first_token_seconds_bucket` | TTFT histogram |
| `kserve_vllm:e2e_request_latency_seconds_bucket` | End-to-end latency |
| `kserve_vllm:request_success_total` | Successful requests |
| `kserve_vllm:request_failure_total` | Failed requests |
| `kserve_vllm:num_requests_running` | Active requests |
| `kserve_vllm:num_requests_waiting` | Queued requests |
| `kserve_vllm:kv_cache_usage_perc` | KV cache utilization % |

**Full list:** Query Prometheus for `kserve_vllm:*`

### EPP Scheduler Metrics (Port 9090, Intelligent Inference only)

| Metric | Description |
|--------|-------------|
| `up{job=~".*epp.*"}` | EPP scheduler health |
| gRPC server metrics | Request rate, latency |

---

## Well-Lit Path Label Propagation

**Automatic feature:** The ServiceMonitor adds the `well_lit_path` label to all metrics.

**How it works:**

1. Chart adds `llm-d.ai/well-lit-path` label to LLMInferenceService (from `deploymentType`)
2. Label propagates to underlying Kubernetes Services
3. ServiceMonitor reads Service label and adds it to metrics via relabeling:

```yaml
relabelings:
- sourceLabels: [__meta_kubernetes_service_label_llm_d_ai_well_lit_path]
  targetLabel: well_lit_path
  action: replace
```

4. Prometheus metrics include `{well_lit_path="intelligent-inference"}`

**Dashboard benefit:** Filter metrics by architecture:

```promql
# Only intelligent-inference models
kserve_vllm:prefix_cache_hits_total{well_lit_path="intelligent-inference"}

# Only P/D disaggregation models
kserve_vllm:kv_transfer_latency{well_lit_path="pd-disaggregation"}
```

---

## Verification

### Check ServiceMonitor Targets in Prometheus

```bash
# Port-forward to Prometheus
oc port-forward -n openshift-user-workload-monitoring prometheus-user-workload-0 9090:9090 &

# Open browser
open http://localhost:9090/targets
# Search for your model namespace (e.g., llm-d-demo)
```

**Healthy targets show:**
- State: `UP`
- Last Scrape: < 30s ago
- Labels: `namespace=llm-d-demo`, `job=...`, `well_lit_path=intelligent-inference`

### Query Metrics

```bash
# Check if metrics are being scraped
curl -s 'http://localhost:9090/api/v1/query?query=kserve_vllm:prefix_cache_hits_total{namespace="llm-d-demo"}' | \
  jq '.data.result[] | {model: .metric.model_name, hits: .value[1]}'
```

**Expected:** JSON with model name and cache hit count.

### Check Dashboard

**OpenShift Console → Observe → Dashboards (Perses) → "llm-d Intelligent Inference"**

If ServiceMonitor is working:
- ✅ Prefix Cache Hit Rate shows data
- ✅ TTFT metrics populate
- ✅ Request rate visible

---

## Troubleshooting

### ServiceMonitor created but no metrics in Prometheus

**Check 1: Is User Workload Monitoring enabled?**

```bash
oc get pods -n openshift-user-workload-monitoring
# Should show: prometheus-user-workload-0, prometheus-user-workload-1
```

**Fix:** Enable User Workload Monitoring (see Prerequisites section).

**Check 2: Are the Services labeled correctly?**

```bash
oc get service -n llm-d-demo -l app.kubernetes.io/part-of=llminferenceservice \
  -L llm-d.ai/well-lit-path
```

**Expected:** Services show `llm-d.ai/well-lit-path` label.

**Fix:** Re-deploy model with updated chart (label propagation added).

**Check 3: Are ServiceMonitor selectors matching Services?**

```bash
# Check what ServiceMonitor is looking for
oc get servicemonitor qwen3-8b-workload-metrics -n llm-d-demo -o yaml | \
  grep -A 5 "matchLabels:"

# Check if Services have those labels (model-specific selector)
oc get service -n llm-d-demo -l 'app.kubernetes.io/name=qwen3-8b,app.kubernetes.io/component=llminferenceservice-workload'
```

**Expected:** Each ServiceMonitor matches exactly ONE service (its own model's service).

**Fix:** Ensure labels match between ServiceMonitor and Service. The selector is model-specific via `app.kubernetes.io/name={{ serviceName }}`.

### Dashboard shows "No data"

**Check 1: Did you send traffic to the model?**

Metrics only populate when requests are processed.

```bash
# Send test traffic
curl -X POST "https://<your-model-url>/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model": "...", "messages": [{"role": "user", "content": "test"}]}'
```

**Check 2: Are dashboard queries using correct metric prefix?**

Dashboard should use `kserve_vllm:` prefix, not `vllm:`.

**Fix:** Update dashboard queries (see `perses-dashboard-intelligent-inference.yaml`).

### "Error creating ServiceMonitor: Forbidden"

**Cause:** ServiceMonitor CRD not installed (Prometheus Operator missing).

**Check:**
```bash
oc get crd servicemonitors.monitoring.coreos.com
```

**Fix:** Install Prometheus Operator (usually part of OpenShift Monitoring).

---

## Migration from Separate ServiceMonitor

**If you previously deployed ServiceMonitors separately:**

### Option 1: Keep Separate (No Change)

Deploy model with `monitoring.enabled=false`:

```bash
helm template qwen3-8b ... --set monitoring.enabled=false | oc apply -f -
```

Keep your existing ServiceMonitors in `gitops/instance/llm-d-observability/`.

### Option 2: Migrate to Chart (Recommended)

1. **Delete old ServiceMonitors:**

```bash
oc delete servicemonitor llm-d-workload-metrics -n llm-d-demo
oc delete servicemonitor llm-d-epp-metrics -n llm-d-demo
```

2. **Re-deploy model with chart-managed ServiceMonitors:**

```bash
helm template qwen3-8b ./gitops/instance/llm-d/inference \
  -f qwen3-8b-values.yaml \
  | oc apply -f -
```

3. **Verify new ServiceMonitors:**

```bash
oc get servicemonitor -n llm-d-demo
# Should show: qwen3-8b-workload-metrics, qwen3-8b-epp-metrics
```

**Benefit:** ServiceMonitors managed with model lifecycle (GitOps-friendly).

---

## Architecture: Why ServiceMonitor in the Inference Chart?

### Design Decision

**ServiceMonitor is namespace-scoped and lifecycle-coupled to the model:**

| Aspect | ServiceMonitor in Chart | Separate ServiceMonitor |
|--------|-------------------------|-------------------------|
| **Lifecycle** | Deleted with model ✅ | Manual cleanup ❌ |
| **GitOps** | One manifest ✅ | Two manifests ❌ |
| **Namespace** | Same as model ✅ | Must match manually ❌ |
| **Per-model config** | Easy (values) ✅ | Copy-paste template ❌ |
| **User experience** | One command ✅ | Two commands ❌ |

**Industry pattern:** Prometheus Operator apps bundle ServiceMonitor with the app.

### What About Dashboard?

**Dashboard is NOT in the chart** because:

- ❌ Dashboards live in different namespace (`redhat-ods-monitoring`)
- ❌ One dashboard can monitor multiple models (shared resource)
- ❌ Creating resources in other namespaces from Helm is complex
- ✅ Dashboard is cluster-scoped, model is namespace-scoped

**Recommended:** Keep dashboard separate (one shared dashboard per well-lit path).

---

## Examples

### Example 1: Deploy Intelligent Inference with Monitoring (Default)

```bash
helm template qwen3-8b ./gitops/instance/llm-d/inference \
  -f qwen3-8b-values.yaml \
  | oc apply -f -
```

**Created:**
- ✅ LLMInferenceService
- ✅ ServiceMonitor (workload)
- ✅ ServiceMonitor (EPP)
- ✅ Metrics scraped automatically

### Example 2: Deploy P/D with Custom Scrape Interval

```yaml
# llama-70b-values.yaml
deploymentType: pd-disaggregation
monitoring:
  enabled: true
  serviceMonitor:
    interval: 15s  # Faster scraping
```

```bash
helm template llama-70b ./gitops/instance/llm-d/inference \
  -f llama-70b-values.yaml \
  | oc apply -f -
```

**Created:**
- ✅ LLMInferenceService
- ✅ ServiceMonitor (workload only, no EPP)
- ✅ Scrapes every 15s

### Example 3: Air-Gapped Deployment (No Monitoring)

```bash
helm template secure-model ./gitops/instance/llm-d/inference \
  -f secure-model-values.yaml \
  --set monitoring.enabled=false \
  | oc apply -f -
```

**Created:**
- ✅ LLMInferenceService
- ❌ No ServiceMonitors

---

## Summary

| Feature | Status |
|---------|--------|
| **ServiceMonitor in chart** | ✅ Enabled by default |
| **Well-lit path label** | ✅ Auto-propagated to metrics |
| **EPP metrics** | ✅ Only for intelligent-inference |
| **Disable option** | ✅ `monitoring.enabled: false` |
| **Custom intervals** | ✅ Configurable via values |
| **Dashboard in chart** | ❌ Kept separate (shared resource) |

**Recommendation:** Use the default (`monitoring.enabled: true`) unless you have a specific reason to disable.
