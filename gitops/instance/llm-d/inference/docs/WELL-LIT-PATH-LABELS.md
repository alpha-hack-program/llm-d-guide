# Well-Lit Path Labels - Automatic via Helm Chart

## Overview

As of this version, the **llm-d inference Helm chart automatically adds the `llm-d.ai/well-lit-path` label** to every `LLMInferenceService` based on the `deploymentType` value.

**You no longer need to manually label models** - the chart does it for you.

---

## How It Works

### 1. Set deploymentType in values.yaml

```yaml
# values.yaml or per-model values file
deploymentType: intelligent-inference  # ← This value becomes the label
```

**Valid values:**
- `intelligent-inference` - EPP + Prefix caching (cache-aware routing)
- `pd-disaggregation` - Prefill/Decode split with KV transfer

### 2. Chart Automatically Adds Label

When you `helm template` or deploy the chart, the generated `LLMInferenceService` includes:

```yaml
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceService
metadata:
  name: qwen3-8b
  labels:
    llm-d.ai/well-lit-path: intelligent-inference  # ← Auto-added from deploymentType
    networking.kserve.io/visibility: exposed
    # ... other labels
```

### 3. Label Propagates to Metrics

The ServiceMonitor in `gitops/instance/llm-d-observability/servicemonitor.yaml` propagates this label to Prometheus metrics:

```yaml
# ServiceMonitor relabeling configuration
relabelings:
- sourceLabels: [__meta_kubernetes_service_label_llm_d_ai_well_lit_path]
  targetLabel: well_lit_path
  action: replace
```

**Result:** All vLLM metrics include `{well_lit_path="intelligent-inference"}` label.

### 4. Dashboard Filters by Well-Lit Path

The Perses dashboard variables allow filtering:

```yaml
# Dashboard variables
- name: well_lit_path
  labelName: well_lit_path
  defaultValue: "intelligent-inference"
  allowAllValue: true

- name: model
  labelName: model_name
  matchers:
    - namespace="$namespace"
    - well_lit_path="$well_lit_path"  # ← Only shows models matching selected path
```

---

## Example Deployment

### Intelligent Inference Model (qwen3-8b)

```bash
# Deploy via Helm
helm template qwen3-8b ./gitops/instance/llm-d/inference \
  -f ./gitops/instance/llm-d/inference/qwen3-8b-values.yaml \
  | oc apply -f -
```

**From qwen3-8b-values.yaml:**
```yaml
deploymentType: intelligent-inference  # ← Label source
serviceName: qwen3-8b
# ... rest of config
```

**Generated LLMInferenceService includes:**
```yaml
labels:
  llm-d.ai/well-lit-path: intelligent-inference
```

**Metrics will have:**
```
vllm:prefix_cache_hits_total{model_name="qwen3-8b", well_lit_path="intelligent-inference"}
```

**Dashboard workflow:**
1. Select `well_lit_path = intelligent-inference`
2. Model dropdown shows: `qwen3-8b` (and any other intelligent-inference models)
3. Panels show cache hit rate, EPP routing, TTFT - metrics relevant to this well-lit path

---

### P/D Disaggregation Model (hypothetical llama-70b)

```yaml
# llama-70b-values.yaml
deploymentType: pd-disaggregation  # ← Different well-lit path
serviceName: llama-70b
model:
  name: meta-llama/Llama-3.3-70B-Instruct
storage:
  type: hf
  uri: hf://meta-llama/Llama-3.3-70B-Instruct
# ... prefill/decode config
```

**Generated label:**
```yaml
labels:
  llm-d.ai/well-lit-path: pd-disaggregation
```

**Dashboard workflow:**
1. Select `well_lit_path = pd-disaggregation`
2. Model dropdown shows: `llama-70b` (qwen3-8b is filtered out)
3. Panels show P/D specific metrics (when P/D dashboard is created)

---

## Multi-Model Namespace Example

**Namespace: `llm-d-demo`**

| Model | deploymentType (values.yaml) | Auto-Generated Label | Dashboard Filter |
|-------|------------------------------|----------------------|------------------|
| qwen3-8b | `intelligent-inference` | `llm-d.ai/well-lit-path: intelligent-inference` | Shows in Intelligent Inference dashboard |
| qwen3-14b | `intelligent-inference` | `llm-d.ai/well-lit-path: intelligent-inference` | Shows in Intelligent Inference dashboard |
| llama-70b | `pd-disaggregation` | `llm-d.ai/well-lit-path: pd-disaggregation` | Shows in P/D dashboard (when created) |

**Dashboard usage:**
- `well_lit_path = intelligent-inference`, `model = All` → Shows qwen3-8b + qwen3-14b aggregated
- `well_lit_path = intelligent-inference`, `model = qwen3-8b` → Shows only qwen3-8b
- `well_lit_path = pd-disaggregation` → Only llama-70b in model dropdown

---

## Verification

### 1. Check LLMInferenceService has label

```bash
oc get llminferenceservice qwen3-8b -n llm-d-demo \
  -o jsonpath='{.metadata.labels.llm-d\.ai/well-lit-path}'
```

**Expected output:**
```
intelligent-inference
```

### 2. List all models with their well-lit path

```bash
oc get llminferenceservice -n llm-d-demo \
  -L llm-d.ai/well-lit-path
```

**Expected output:**
```
NAME         READY   URL                           WELL-LIT-PATH
qwen3-8b     True    https://.../qwen3-8b         intelligent-inference
qwen3-14b    True    https://.../qwen3-14b        intelligent-inference
```

### 3. Check metrics include well_lit_path label

```bash
# Port-forward to Prometheus user-workload
oc port-forward -n openshift-user-workload-monitoring prometheus-user-workload-0 9090:9090 &

# Query metrics
curl -s 'http://localhost:9090/api/v1/query?query=vllm:prefix_cache_hits_total' | \
  jq '.data.result[] | .metric | {model_name, well_lit_path}'
```

**Expected output:**
```json
{
  "model_name": "qwen3-8b",
  "well_lit_path": "intelligent-inference"
}
```

---

## Migration from Manual Labeling

### If you previously used `label-models.sh`

**Before (manual):**
```bash
./label-models.sh llm-d-demo  # Had to run this after deploying
```

**Now (automatic):**
```bash
# Just deploy via Helm - label is automatic
helm template qwen3-8b ... | oc apply -f -
```

**No migration needed** - if you re-apply the chart, the label is set automatically. The Helm chart overrides any manually applied labels.

### Existing models

If you have models already deployed **without** the label, re-apply the Helm chart:

```bash
# Re-render and apply
helm template qwen3-8b ./gitops/instance/llm-d/inference \
  -f ./gitops/instance/llm-d/inference/qwen3-8b-values.yaml \
  | oc apply -f -
```

The label will be added on the next reconciliation.

---

## Troubleshooting

### Label not appearing on LLMInferenceService

**Symptom:**
```bash
oc get llminferenceservice qwen3-8b -n llm-d-demo \
  -o jsonpath='{.metadata.labels.llm-d\.ai/well-lit-path}'
# Returns empty
```

**Solution 1: Check rendered template**
```bash
helm template qwen3-8b ./gitops/instance/llm-d/inference \
  -f ./gitops/instance/llm-d/inference/qwen3-8b-values.yaml \
  | grep -A 5 "kind: LLMInferenceService" | grep "llm-d.ai/well-lit-path"
```

Should show:
```yaml
llm-d.ai/well-lit-path: intelligent-inference
```

If missing, check `deploymentType` is set in values file.

**Solution 2: Re-apply chart**
```bash
helm template ... | oc apply -f -
```

### Metrics missing well_lit_path label

**Symptom:** `vllm:*` metrics don't have `{well_lit_path="..."}` label.

**Root cause:** ServiceMonitor relabeling reads the label from the **Service**, not the LLMInferenceService.

**Check if Service has the label:**
```bash
oc get service -n llm-d-demo -l app.kubernetes.io/part-of=llminferenceservice \
  -L llm-d.ai/well-lit-path
```

**If Service is missing the label:**

The llm-d controller should propagate labels from `LLMInferenceService` to the underlying Service. If it doesn't, this is a controller bug. Workaround:

```bash
# Manually label the Service (temporary workaround)
oc label service qwen3-8b-kserve-workload-svc -n llm-d-demo \
  llm-d.ai/well-lit-path=intelligent-inference
```

**Better fix:** File an issue with llm-d to ensure Service inherits labels from LLMInferenceService.

### Dashboard not filtering correctly

**Symptom:** `well_lit_path = intelligent-inference` but model dropdown shows P/D models.

**Check dashboard variable matchers:**
```bash
oc get persesdashboard llm-d-intelligent-inference -n redhat-ods-monitoring -o yaml | \
  grep -A 5 "name: model"
```

Should include:
```yaml
matchers:
  - namespace="$namespace"
  - well_lit_path="$well_lit_path"  # ← Must be present
```

---

## Benefits Over Manual Labeling

| Aspect | Manual (`label-models.sh`) | Automatic (Helm chart) |
|--------|----------------------------|------------------------|
| **Deployment** | 2 steps: deploy + label | 1 step: deploy |
| **Accuracy** | Manual detection can fail | `deploymentType` is source of truth |
| **Consistency** | Must remember to run script | Label always matches deploymentType |
| **Maintenance** | Script must be updated for new paths | Chart handles all paths |
| **GitOps** | Label not in Git | Label defined in values.yaml (tracked) |

---

## Adding New Well-Lit Paths

When llm-d adds a new well-lit path (e.g. MoE Expert Parallelism):

### 1. Update values.yaml documentation

```yaml
# Deployment type (required; chart fails if not one of these):
# - intelligent-inference:  single pool with full EPP scheduler
# - pd-disaggregation:      split prefill + decode pools
# - expert-parallelism:     Wide MoE (multi-node expert distribution)  # ← Add this
deploymentType: intelligent-inference
```

### 2. Update template validation

In `templates/_helpers.tpl`:

```yaml
{{- if and 
    (ne .Values.deploymentType "intelligent-inference") 
    (ne .Values.deploymentType "pd-disaggregation")
    (ne .Values.deploymentType "expert-parallelism")  # ← Add this
}}
{{- fail (printf "deploymentType must be one of intelligent-inference, pd-disaggregation, expert-parallelism, got %q" .Values.deploymentType) }}
{{- end }}
```

### 3. Create template for new path

```yaml
# templates/expert-parallelism.yaml
{{- if eq .Values.deploymentType "expert-parallelism" }}
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceService
metadata:
  name: {{ .Values.serviceName }}
  labels:
    llm-d.ai/well-lit-path: {{ .Values.deploymentType }}  # ← Same pattern
    # ... other labels
spec:
  # ... MoE config
{{- end }}
```

### 4. Create dashboard for new path

Follow `WELL-LIT-PATH-MONITORING.md` to create `perses-dashboard-expert-parallelism.yaml` with MoE-specific metrics.

---

## Files Reference

| File | Purpose |
|------|---------|
| `values.yaml` | Documents `deploymentType` and label auto-generation |
| `templates/intelligent-inference.yaml` | Adds `llm-d.ai/well-lit-path: {{ .Values.deploymentType }}` label |
| `templates/pd-disaggregation.yaml` | Adds `llm-d.ai/well-lit-path: {{ .Values.deploymentType }}` label |
| `qwen3-8b-values.yaml` | Sets `deploymentType: intelligent-inference` |
| `../llm-d-observability/servicemonitor.yaml` | Propagates label to Prometheus metrics |
| `../llm-d-observability/perses-dashboard-intelligent-inference.yaml` | Filters by `well_lit_path` variable |
| `WELL-LIT-PATH-LABELS.md` | This document |

---

## Key Takeaway

**Set `deploymentType` in your values file → Label is automatic → Dashboard filters work → Correct metrics interpretation.**

No manual labeling scripts needed. The label matches your deployment architecture every time.
