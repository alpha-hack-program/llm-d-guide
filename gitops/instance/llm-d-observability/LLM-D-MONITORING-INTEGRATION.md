# llm-d Monitoring Integration — Complete Technical Reference

This document provides comprehensive technical details for monitoring llm-d LLMInferenceService deployments.

For deployment commands, see:
- [README.md Step 6](../../../README.md#step-6-deploy-monitoring) — Deployment commands
- [AGENTS.md Phase 4](../../../AGENTS.md#phase-4--monitoring-stack) — Deployment commands
- [EXTERNAL-MONITORING-INTEGRATION.md](EXTERNAL-MONITORING-INTEGRATION.md) — ExternalModel monitoring (different metrics source)

---

## Architecture

### Metrics Flow

```
vLLM pods (port 8000/metrics)
    ↓
ServiceMonitors (created automatically by chart)
    ↓
Prometheus User Workload (scrape every 30s)
    ↓
Thanos Querier (query aggregation)
    ↓
Perses Dashboards (visualization via COO)
```

**Key components:**
1. **vLLM** — exposes Prometheus metrics at `/metrics` on port 8000 (HTTPS)
2. **EPP scheduler** — exposes routing metrics at `/metrics` on port 9090 (HTTP, intelligent-inference only)
3. **ServiceMonitors** — created automatically by inference chart when `monitoring.enabled: true` (default)
4. **User Workload Monitoring** — MANDATORY for Prometheus to scrape user namespaces
5. **Cluster Observability Operator (COO)** — MANDATORY for Perses dashboards (optional for raw metrics)

---

## Prerequisites

### 1. User Workload Monitoring (MANDATORY)

ServiceMonitors require User Workload Monitoring enabled cluster-wide. Without this, Prometheus will not scrape metrics.

**Check status:**
```bash
oc get configmap cluster-monitoring-config -n openshift-monitoring \
  -o jsonpath='{.data.config\.yaml}' | grep enableUserWorkload
# Expected: enableUserWorkload: true
```

**Enable:**
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

# Wait for prometheus-user-workload pods (⏱️ ~5 min)
oc get pods -n openshift-user-workload-monitoring -w
# Expected: prometheus-user-workload-0, prometheus-user-workload-1 Running
```

### 2. Cluster Observability Operator (MANDATORY for Dashboards)

COO is required ONLY if you want Perses dashboards. Metrics collection via ServiceMonitors works without COO — you can query raw Prometheus metrics via `oc exec` or port-forward.

**Install:**
```bash
oc apply -k gitops/operators/cluster-observability-operator

# Wait for operator (⏱️ ~10 min)
oc get csv -n openshift-observability-operator -w | grep cluster-observability-operator
# Expected: Succeeded
```

**Create UIPlugin for Perses integration:**
```bash
cat <<EOF | oc apply -f -
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: logging
spec:
  type: Logging
  logging:
    logsLimit: 50
    timeout: 30s
EOF

# Verify
oc get uiplugin logging -o jsonpath='{.status.conditions[?(@.type=="ReconcileSuccess")].status}'
# Expected: True
```

---

## Automatic ServiceMonitor Creation

The inference chart creates ServiceMonitors automatically when you deploy a model.

### Default Configuration

**values.yaml:**
```yaml
monitoring:
  enabled: true  # ON by default — set false to disable
  serviceMonitor:
    interval: 30s       # Scrape frequency
    scrapeTimeout: 10s  # Max time per scrape
```

### What Gets Created

#### Intelligent Inference (deploymentType: intelligent-inference)

**2 ServiceMonitors:**
1. `<serviceName>-workload-metrics` — vLLM metrics from port 8000 (HTTPS)
   - Prefix cache hits/queries/hit rate
   - TTFT (Time To First Token)
   - E2E request latency
   - Request success/failure rates
   - KV cache utilization
   - GPU utilization (DCGM)
   - Queue depth

2. `<serviceName>-epp-metrics` — EPP scheduler metrics from port 9090 (HTTP)
   - Routing decisions
   - Endpoint health
   - gRPC server stats

#### P/D Disaggregation (deploymentType: pd-disaggregation)

**1 ServiceMonitor:**
1. `<serviceName>-workload-metrics` — vLLM metrics only (no EPP)

---

## Verification

### Step 1: Check ServiceMonitors Created

```bash
oc get servicemonitor -n <namespace> -l app.kubernetes.io/name=<serviceName>

# Example for qwen3-8b in llm-d-demo
oc get servicemonitor -n llm-d-demo -l app.kubernetes.io/name=qwen3-8b
```

**Expected output (intelligent-inference):**
```
NAME                       AGE
qwen3-8b-workload-metrics  1m
qwen3-8b-epp-metrics       1m
```

### Step 2: Check Prometheus Targets Healthy

```bash
# Port-forward to Prometheus
oc port-forward -n openshift-user-workload-monitoring prometheus-user-workload-0 9090:9090 &

# Open browser: http://localhost:9090/targets
# Search for your namespace (e.g., llm-d-demo)
```

**Healthy targets show:**
- State: `UP`
- Last Scrape: < 30s ago
- Labels: `namespace=<your-namespace>`, `job=<serviceName>-...`

### Step 3: Verify Metrics Flowing

```bash
# Query prefix cache metrics
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -- \
  curl -s 'http://localhost:9090/api/v1/query?query=vllm:prefix_cache_hits_total' | \
  jq -r '.data.result[] | select(.metric.namespace=="<your-namespace>") | "Model: \(.metric.model_name), Hits: \(.value[1])"'
```

**Expected:** Model name + hit count (may be 0 if no traffic sent yet)

### Step 4: Send Test Traffic

```bash
INFERENCE_URL=$(oc get llminferenceservice <serviceName> -n <namespace> -o jsonpath='{.status.url}')
SYSTEM_PROMPT="You are a helpful AI assistant specialized in OpenShift and Kubernetes."

for i in {1..10}; do
  curl -sk -X POST "${INFERENCE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"<model-name>\",
      \"messages\": [
        {\"role\": \"system\", \"content\": \"${SYSTEM_PROMPT}\"},
        {\"role\": \"user\", \"content\": \"Question ${i}: What is a pod?\"}
      ],
      \"max_tokens\": 50
    }"
  sleep 1
done
```

### Step 5: Check Cache Hit Rate

```bash
# Wait 30s for Prometheus scrape
sleep 30

# Query cache hit rate
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -- \
  curl -s 'http://localhost:9090/api/v1/query?query=vllm:prefix_cache_hits_total/vllm:prefix_cache_queries_total*100' | \
  jq -r '.data.result[] | select(.metric.namespace=="<your-namespace>") | "Model: \(.metric.model_name), Hit Rate: \(.value[1] | tonumber | floor)%"'
```

**Expected (intelligent-inference with repeated system prompt):** 50-90% cache hit rate

---

## Metrics Reference

### vLLM Workload Metrics (All Deployment Types)

| Metric | Description | Target Value | Notes |
|--------|-------------|--------------|-------|
| `vllm:prefix_cache_hits_total` | Tokens served from cache | Maximize | intelligent-inference only |
| `vllm:prefix_cache_queries_total` | Total tokens queried in cache | N/A | Baseline for hit rate calc |
| `vllm:time_to_first_token_seconds` | TTFT histogram (prefill latency) | P95 < 500ms, P99 < 1s | Lower is better |
| `vllm:e2e_request_latency_seconds` | End-to-end request latency | P95 < 5s, P99 < 10s | Includes prefill + decode |
| `vllm:request_success_total` | Successful requests | > 99.9% | Count of HTTP 200 responses |
| `vllm:request_failure_total` | Failed requests | < 0.1% | Count of HTTP 4xx/5xx |
| `vllm:num_requests_running` | Currently active requests | Monitor | Alert if always > pod capacity |
| `vllm:num_requests_waiting` | Queued requests | Alert if > 10 | Indicates saturation |
| `vllm:kv_cache_usage_perc` | KV cache utilization % | Alert if > 90% | Triggers evictions |
| `vllm:gpu_cache_usage_perc` | GPU cache utilization % | Alert if > 90% | GPU memory pressure |
| `DCGM_FI_DEV_GPU_UTIL` | GPU utilization % | 60-90% ideal | From NVIDIA DCGM exporter |
| `DCGM_FI_DEV_FB_USED` | GPU memory used (MB) | Monitor | From NVIDIA DCGM exporter |

**Metric prefix note:** Metrics may appear as `vllm:*` or `kserve_vllm:*` depending on vLLM version and KServe integration.

### EPP Scheduler Metrics (Intelligent Inference Only)

| Metric | Description | Notes |
|--------|-------------|-------|
| `up{job=~".*epp.*"}` | EPP scheduler health | 1 = healthy, 0 = down |
| gRPC server metrics | Request rate, latency, errors | Standard gRPC instrumentation |

**EPP-specific metrics** (routing decisions, endpoint selection) are not yet exposed in the current llm-d release.

---

## Dashboard Deployment

### Intelligent Inference Dashboard

**Prerequisite:** COO installed, UIPlugin created (see Prerequisites)

```bash
oc apply -f gitops/instance/llm-d-observability/perses-dashboard-intelligent-inference.yaml
```

**Access:**
1. OpenShift Console → **Observe** → **Dashboards** (Perses tab)
2. Select: **"llm-d Intelligent Inference (Prefix Caching + EPP)"**

**7 Panels:**
1. **Prefix Cache Hit Rate %** — Target: > 80% (indicates effective EPP routing)
2. **Cached Tokens Saved** — Business value: tokens not re-processed
3. **TTFT P95** — Target: < 500ms
4. **TTFT P99** — Target: < 1s
5. **KV Cache Utilization %** — Alert if > 90% (triggers evictions)
6. **Queue Depth** — Alert if > 10 (saturation)
7. **Request Rate** — Success vs failure (expect > 99.9% success)

**Dashboard Variables:**
- `Namespace` — Filter by namespace (default: `llm-d-demo`)
- `Model` — Filter by model name (default: all models)

### Legacy Grafana Stack (Optional)

The Perses dashboard (via COO) is recommended. Legacy Grafana is provided for users who prefer Grafana over Perses.

```bash
until oc apply -k gitops/instance/llm-d-monitoring; do : ; done

# Get Grafana URL
oc get route grafana -n llm-d-monitoring -o jsonpath='{.spec.host}'
# Default credentials: admin / admin
```

---

## Prefix Caching Configuration

Prefix caching is **critical** for intelligent-inference. Without it, cache hit rate = 0% and EPP cannot optimize routing.

### Default (Recommended)

```yaml
vllm:
  prefixCaching:
    enabled: auto  # auto = enabled for intelligent-inference, disabled for P/D
```

**How auto works:**
- `deploymentType: intelligent-inference` → `--enable-prefix-caching` added automatically
- `deploymentType: pd-disaggregation` → prefix caching disabled (P/D has different cache architecture)

### Explicitly Enable/Disable

```yaml
vllm:
  prefixCaching:
    enabled: true   # Always enable
    # OR
    enabled: false  # Always disable (NOT recommended for intelligent-inference)
```

### Verify Enabled in Pod

```bash
POD=$(oc get pods -n <namespace> -l llm-d.ai/role=both -o jsonpath='{.items[0].metadata.name}')
oc exec -n <namespace> $POD -c main -- ps aux | grep "enable-prefix-caching"
# Expected: --enable-prefix-caching in the vLLM command
```

**If missing:** Re-deploy with `vllm.prefixCaching.enabled: auto` or `true`

---

## Well-Lit Path Labels

### Automatic Label Propagation

The chart automatically adds `llm-d.ai/well-lit-path: <deploymentType>` to:
1. LLMInferenceService metadata
2. Underlying Kubernetes Services
3. Prometheus metrics (via ServiceMonitor relabeling)

**Result:** Metrics include `{well_lit_path="intelligent-inference"}` label for filtering.

### Dashboard Filtering by Architecture

```promql
# Only intelligent-inference models
vllm:prefix_cache_hits_total{well_lit_path="intelligent-inference"}

# Only P/D disaggregation models (future)
vllm:kv_transfer_latency{well_lit_path="pd-disaggregation"}
```

**Why this matters:** Each well-lit path optimizes for different workloads → different success metrics → different dashboards.

- **Intelligent Inference:** Cache hit rate > 80%, EPP routing effectiveness
- **P/D Disaggregation:** KV transfer latency < 50ms, prefill pod utilization
- **MoE Expert Parallelism** (future): Expert load balance < 20% variance

---

## Comparison: Metrics by Well-Lit Path

| Metric | Intelligent Inference | P/D Disaggregation | Notes |
|--------|----------------------|-------------------|-------|
| **Prefix cache hit rate** | ✅ Primary metric | ❌ Not applicable | P/D uses different cache architecture |
| **TTFT (P95, P99)** | ✅ Primary metric | ✅ Prefill-only TTFT | Different interpretation |
| **E2E latency** | ✅ Full request | ✅ Decode latency | Prefill is separate in P/D |
| **KV cache utilization** | ✅ Single-node cache | ✅ Per-pod cache | P/D splits prefill/decode caches |
| **KV transfer latency** | ❌ Not applicable | ✅ Primary metric | Only P/D transfers KV between pods |
| **EPP scheduler health** | ✅ Required | ❌ Not used | P/D uses different routing |
| **Queue depth** | ✅ Combined queue | ✅ Decode queue | Prefill queue is separate in P/D |
| **GPU utilization** | ✅ Both prefill+decode | ✅ Split by role | P/D monitors prefill/decode separately |

**Future enhancement:** Separate dashboards per well-lit path with architecture-specific metrics.

---

## Troubleshooting

### Problem: No ServiceMonitors Created

**Symptom:** `oc get servicemonitor -n <namespace>` returns empty

**Check 1:** Is monitoring enabled?
```bash
helm template <model> ./gitops/instance/llm-d/inference -f <values>.yaml | \
  grep -A 3 "kind: ServiceMonitor"
# Expected: At least 1 ServiceMonitor
```

**Fix:** Set `monitoring.enabled: true` in values file (default is true — check for explicit `false`)

---

### Problem: ServiceMonitors Created But No Metrics

**Symptom:** Prometheus targets show no data or State: DOWN

**Check 1:** Is User Workload Monitoring enabled?
```bash
oc get pods -n openshift-user-workload-monitoring
# Expected: prometheus-user-workload-0, prometheus-user-workload-1 Running
```

**Fix:** Enable User Workload Monitoring (see Prerequisites)

**Check 2:** Are Prometheus targets healthy?
```bash
oc port-forward -n openshift-user-workload-monitoring prometheus-user-workload-0 9090:9090 &
# Open http://localhost:9090/targets, search for your namespace
```

**Fix if target DOWN:**
- Check pod logs: `oc logs -n <namespace> -l llm-d.ai/role=both -c main`
- Verify Service exists: `oc get service -n <namespace> -l app.kubernetes.io/name=<serviceName>`
- Check ServiceMonitor selector matches Service labels

**Check 3:** Are Services labeled correctly?
```bash
oc get service -n <namespace> -l app.kubernetes.io/name=<serviceName>
# Expected: Services with matching labels
```

**Fix:** Re-apply chart — Services get labels automatically

---

### Problem: 0% Cache Hit Rate

**Symptom:** `vllm:prefix_cache_hits_total / vllm:prefix_cache_queries_total` = 0%

**Check 1:** Is prefix caching enabled in pod?
```bash
POD=$(oc get pods -n <namespace> -l llm-d.ai/role=both -o jsonpath='{.items[0].metadata.name}')
oc exec -n <namespace> $POD -c main -- ps aux | grep "enable-prefix-caching"
# Expected: --enable-prefix-caching in command
```

**Fix:** Re-deploy with:
```yaml
vllm:
  prefixCaching:
    enabled: auto  # or true
```

**Check 2:** Is deploymentType correct?
```bash
oc get llminferenceservice <name> -n <namespace> -o jsonpath='{.metadata.labels.llm-d\.ai/well-lit-path}'
# Expected: intelligent-inference
```

**Fix:** Set `deploymentType: intelligent-inference` in values file

**Check 3:** Is traffic cache-friendly?
- ✅ **Repeated system prompts** trigger caching (same prefix across requests)
- ❌ **Different system prompts every time** = 0% cache hit rate (no shared prefix)

**Example cache-friendly traffic:**
```bash
# Same system prompt in all 10 requests → cache hits on requests 2-10
SYSTEM_PROMPT="You are a helpful AI assistant specialized in OpenShift."
for i in {1..10}; do
  curl ... -d "{\"messages\": [{\"role\": \"system\", \"content\": \"${SYSTEM_PROMPT}\"}, ...]}"
done
```

---

### Problem: Dashboard Shows "No data"

**Symptom:** All panels empty in Perses dashboard

**Check 1:** Is COO installed?
```bash
oc get csv -n openshift-observability-operator | grep cluster-observability-operator
# Expected: Succeeded
```

**Fix:** Install COO (see Prerequisites)

**Check 2:** Did you send traffic to the model?
```bash
# Metrics only populate when requests are processed
# Send test traffic (see Verification Step 4)
```

**Check 3:** Are dashboard queries using correct metric prefix?
- Dashboard should use `vllm:prefix_cache_*` OR `kserve_vllm:prefix_cache_*`
- NOT `vllm:external_prefix_cache_*` (different metric, not related to intelligent-inference)

**Check 4:** Wait for Prometheus scrape interval
```bash
# Default interval: 30s
# After sending traffic, wait 30-60s before checking dashboard
```

---

### Problem: Metrics Missing well_lit_path Label

**Symptom:** `{well_lit_path="..."}` not present in Prometheus queries

**Check Service has label:**
```bash
oc get service -n <namespace> -l app.kubernetes.io/part-of=llminferenceservice \
  -L llm-d.ai/well-lit-path
```

**Expected:** `llm-d.ai/well-lit-path=intelligent-inference` column populated

**Fix (workaround if llm-d controller not propagating):**
```bash
oc label service <serviceName>-kserve-workload-svc -n <namespace> \
  llm-d.ai/well-lit-path=intelligent-inference
```

**Permanent fix:** File bug — llm-d controller should propagate labels from LLMInferenceService to Service

---

## Disabling Monitoring

### Disable for Single Model

```yaml
# my-model-values.yaml
monitoring:
  enabled: false
```

**Created:**
- ✅ LLMInferenceService
- ❌ No ServiceMonitors

**Use case:** Air-gapped environments, cost optimization, external monitoring systems

### Disable for All Models (Template-Level)

**NOT RECOMMENDED** — monitoring overhead is minimal (~1-2% CPU on Prometheus, <100MB memory per model)

Edit `gitops/instance/llm-d/inference/values.yaml`:
```yaml
monitoring:
  enabled: false  # Default is true
```

---

## Architecture Design Notes

### Why ServiceMonitor in Inference Chart?

**ServiceMonitor is namespace-scoped and lifecycle-coupled to the model:**

| Aspect | ServiceMonitor in Chart ✅ | Separate ServiceMonitor ❌ |
|--------|---------------------------|---------------------------|
| **Lifecycle** | Deleted with model | Manual cleanup |
| **GitOps** | One manifest | Two manifests |
| **Namespace** | Same as model | Must match manually |
| **Per-model config** | Easy (values) | Copy-paste template |

**Industry pattern:** Prometheus Operator apps bundle ServiceMonitor with the app (e.g., node-exporter, kube-state-metrics).

### Why Dashboard Separate?

**Dashboards are NOT in chart** because:
- ❌ Dashboards live in different namespace (`redhat-ods-monitoring`)
- ❌ One dashboard can monitor multiple models (shared resource)
- ❌ Creating resources in other namespaces from Helm is complex (requires ClusterRole)
- ✅ Dashboard is cluster-scoped, model is namespace-scoped

**Recommended:** One shared dashboard per well-lit path (e.g., one for all intelligent-inference models).

---

## Related Documentation

- [Helm Chart Monitoring Configuration](../llm-d/inference/docs/MONITORING.md) — Chart-level docs
- [vLLM Args Structured Configuration](../llm-d/inference/docs/VLLM-ARGS-STRUCTURED.md) — How prefix caching is configured
- [Well-Lit Path Labels](../llm-d/inference/docs/WELL-LIT-PATH-LABELS.md) — Label propagation details
- [Prefix Caching Configuration](../llm-d/inference/docs/PREFIX-CACHING-CONFIG.md) — Deep dive on caching
- [Prefix Caching Troubleshooting](../llm-d/inference/docs/ENABLE-PREFIX-CACHING.md) — Step-by-step troubleshooting guide
- [EXTERNAL-MONITORING-INTEGRATION.md](EXTERNAL-MONITORING-INTEGRATION.md) — ExternalModel monitoring (Limitador metrics, not vLLM)

---

## Summary Checklist

**Before deploying models with monitoring:**
- [ ] User Workload Monitoring enabled (`enableUserWorkload: true`)
- [ ] prometheus-user-workload pods Running
- [ ] (Optional) COO installed if you want dashboards
- [ ] (Optional) UIPlugin created for Perses integration

**After deploying a model:**
- [ ] ServiceMonitors created (1 for P/D, 2 for intelligent-inference)
- [ ] Prometheus targets healthy (`oc port-forward ... :9090`, check /targets)
- [ ] Metrics flowing (`oc exec ... curl .../query?query=vllm:prefix_cache_*`)
- [ ] Prefix caching enabled (`oc exec ... ps aux | grep enable-prefix-caching`)
- [ ] Send test traffic to populate metrics
- [ ] Cache hit rate > 50% for intelligent-inference (with repeated system prompt)

**Monitoring is ready when:**
- ✅ Prometheus shows metrics from your model
- ✅ Cache hit rate visible and > 0% (intelligent-inference)
- ✅ Dashboard shows data (if COO installed)
