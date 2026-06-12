# vLLM Arguments - Structured Configuration

## Overview

vLLM arguments are now configured using a **structured approach** that separates framework-managed flags from user-specific flags.

## Old Approach (Deprecated)

```yaml
# ❌ OLD: User must manually manage everything
vllmAdditionalArgs: "--enable-prefix-caching --disable-uvicorn-access-log --enable-auto-tool-choice --tool-call-parser hermes"
```

**Problems:**
- Easy to forget `--enable-prefix-caching` for intelligent-inference
- Duplication across per-model values files
- No smart defaults based on deployment type
- Hard to maintain (changing defaults requires updating all values files)

## New Approach (Structured)

```yaml
# ✅ NEW: Framework manages prefix caching, user adds extras
vllm:
  prefixCaching:
    enabled: auto  # auto | true | false
  extraArgs:
    - "--disable-uvicorn-access-log"
    - "--enable-auto-tool-choice"
    - "--tool-call-parser=hermes"
```

**Benefits:**
- ✅ Auto-adds `--enable-prefix-caching` for intelligent-inference
- ✅ User only specifies model-specific flags
- ✅ No duplication (prefix caching is framework-managed)
- ✅ Type-safe (list of strings, not one big string)
- ✅ Self-documenting (enabled: auto explains the behavior)

---

## Configuration Options

### `vllm.prefixCaching.enabled`

Controls whether `--enable-prefix-caching` is added to VLLM_ADDITIONAL_ARGS.

| Value | Behavior |
|-------|----------|
| `auto` (default) | Enabled for `intelligent-inference`, disabled for `pd-disaggregation` |
| `true` | Always enabled (all deployment types) |
| `false` | Always disabled (prefix caching off) |

**Recommendation:** Use `auto` (default) unless you have a specific reason to override.

### `vllm.extraArgs`

List of model-specific vLLM flags appended after framework-managed flags.

**Examples:**
```yaml
vllm:
  extraArgs:
    - "--disable-uvicorn-access-log"          # Suppress HTTP request logs
    - "--enable-auto-tool-choice"             # Auto-detect tool calls
    - "--tool-call-parser=hermes"             # Use Hermes tool call format
    - "--max-model-len=8192"                  # Override max context length
    - "--gpu-memory-utilization=0.9"          # GPU memory allocation
```

---

## Examples

### Example 1: Intelligent Inference with Auto Prefix Caching (Default)

```yaml
# my-model-values.yaml
deploymentType: intelligent-inference
serviceName: my-model

# Prefix caching is auto-enabled - nothing to configure!
# (vllm.prefixCaching.enabled defaults to "auto")

vllm:
  extraArgs:
    - "--disable-uvicorn-access-log"
```

**Result:** `VLLM_ADDITIONAL_ARGS="--enable-prefix-caching --disable-uvicorn-access-log"`

### Example 2: Intelligent Inference WITHOUT Prefix Caching (Not Recommended)

```yaml
# my-model-values.yaml
deploymentType: intelligent-inference
serviceName: my-model

vllm:
  prefixCaching:
    enabled: false  # Explicitly disable (not recommended for intelligent-inference)
  extraArgs:
    - "--disable-uvicorn-access-log"
```

**Result:** `VLLM_ADDITIONAL_ARGS="--disable-uvicorn-access-log"`

⚠️ **Warning:** Disabling prefix caching for intelligent-inference defeats the purpose of the EPP scheduler. Cache hit rate will be 0%.

### Example 3: P/D Disaggregation (Auto Disables Prefix Caching)

```yaml
# my-model-values.yaml
deploymentType: pd-disaggregation
serviceName: my-model

# Prefix caching is auto-disabled for P/D
# (vllm.prefixCaching.enabled defaults to "auto")

vllm:
  extraArgs:
    - "--disable-uvicorn-access-log"
```

**Result:** No `VLLM_ADDITIONAL_ARGS` for prefix caching (P/D has hardcoded KV transfer config).

**Note:** P/D disaggregation template uses hardcoded vLLM args for KV transfer configuration. The `vllm.extraArgs` is not currently used in P/D template.

### Example 4: Force Prefix Caching for P/D (Advanced)

```yaml
# my-model-values.yaml
deploymentType: pd-disaggregation
serviceName: my-model

vllm:
  prefixCaching:
    enabled: true  # Force enable (overrides auto)
```

**Note:** This doesn't currently work for P/D because the template hardcodes `VLLM_ADDITIONAL_ARGS` for KV transfer. To use prefix caching with P/D, you must manually modify the P/D template.

---

## Migration Guide

### From Old `vllmAdditionalArgs` to New `vllm` Structure

**Before:**
```yaml
vllmAdditionalArgs: "--enable-prefix-caching --disable-uvicorn-access-log --enable-auto-tool-choice --tool-call-parser hermes"
```

**After:**
```yaml
vllm:
  prefixCaching:
    enabled: auto  # Or omit entirely (auto is default)
  extraArgs:
    - "--disable-uvicorn-access-log"
    - "--enable-auto-tool-choice"
    - "--tool-call-parser=hermes"
```

**Steps:**
1. Remove the `vllmAdditionalArgs` line from your values file
2. Add `vllm:` section
3. Remove `--enable-prefix-caching` from your flags (it's auto-managed now)
4. Put remaining flags in `extraArgs` as a list

**Verification:**
```bash
# Render the chart and check VLLM_ADDITIONAL_ARGS
helm template my-model ./gitops/instance/llm-d/inference \
  -f my-model-values.yaml | grep -A 2 "VLLM_ADDITIONAL_ARGS"

# Should show:
# - name: VLLM_ADDITIONAL_ARGS
#   value: --enable-prefix-caching <your-extra-args>
```

---

## How It Works

### Template Helper: `inference.vllmArgs`

The chart includes a helper template in `templates/_helpers.tpl`:

```go
{{- define "inference.vllmArgs" -}}
{{- $args := list -}}
{{- /* Determine if prefix caching should be enabled */ -}}
{{- $shouldEnablePrefixCaching := false -}}
{{- $mode := "auto" -}}
{{- if and .Values.vllm (hasKey .Values.vllm "prefixCaching") (hasKey .Values.vllm.prefixCaching "enabled") -}}
{{- $mode = .Values.vllm.prefixCaching.enabled -}}
{{- end -}}
{{- /* Handle mode: true (boolean), false (boolean), auto (string) */ -}}
{{- if kindIs "bool" $mode -}}
{{- $shouldEnablePrefixCaching = $mode -}}
{{- else if eq $mode "auto" -}}
{{- if eq .Values.deploymentType "intelligent-inference" -}}
{{- $shouldEnablePrefixCaching = true -}}
{{- end -}}
{{- end -}}
{{- /* Add prefix caching flag */ -}}
{{- if $shouldEnablePrefixCaching -}}
{{- $args = append $args "--enable-prefix-caching" -}}
{{- end -}}
{{- /* Append user extra args */ -}}
{{- if and .Values.vllm .Values.vllm.extraArgs -}}
{{- range .Values.vllm.extraArgs -}}
{{- $args = append $args . -}}
{{- end -}}
{{- end -}}
{{- join " " $args -}}
{{- end -}}
```

### Usage in Templates

```yaml
# templates/intelligent-inference.yaml
{{- $vllmArgs := include "inference.vllmArgs" . | trim }}
{{- if $vllmArgs }}
  {{- $envVars = append $envVars (dict "name" "VLLM_ADDITIONAL_ARGS" "value" $vllmArgs) }}
{{- end }}
```

---

## Test Results

### ✅ Test 1: Intelligent Inference with Auto (Default)

```bash
helm template test . \
  --set deploymentType=intelligent-inference \
  --set model.name="test" --set storage.type=hf --set storage.uri="hf://test"
```

**Result:** `VLLM_ADDITIONAL_ARGS="--enable-prefix-caching"` ✅

### ✅ Test 2: Intelligent Inference with Auto + Extras

```bash
helm template test . -f qwen3-8b-values.yaml
```

**qwen3-8b-values.yaml:**
```yaml
deploymentType: intelligent-inference
vllm:
  prefixCaching:
    enabled: auto
  extraArgs:
    - "--disable-uvicorn-access-log"
    - "--enable-auto-tool-choice"
    - "--tool-call-parser=hermes"
```

**Result:** `VLLM_ADDITIONAL_ARGS="--enable-prefix-caching --disable-uvicorn-access-log --enable-auto-tool-choice --tool-call-parser=hermes"` ✅

### ✅ Test 3: Intelligent Inference with Explicit False

```bash
helm template test . \
  --set deploymentType=intelligent-inference \
  --set vllm.prefixCaching.enabled=false \
  --set-json 'vllm.extraArgs=["--disable-uvicorn-access-log"]'
```

**Result:** `VLLM_ADDITIONAL_ARGS="--disable-uvicorn-access-log"` (no prefix caching) ✅

---

## Summary

| Scenario | Config | VLLM_ADDITIONAL_ARGS |
|----------|--------|---------------------|
| Intelligent + auto (default) | `vllm.prefixCaching.enabled: auto` | `--enable-prefix-caching` |
| Intelligent + auto + extras | `vllm.prefixCaching.enabled: auto` + `extraArgs: ["--foo"]` | `--enable-prefix-caching --foo` |
| Intelligent + explicit true | `vllm.prefixCaching.enabled: true` | `--enable-prefix-caching` |
| Intelligent + explicit false | `vllm.prefixCaching.enabled: false` | `` (empty) |
| P/D + auto (default) | `vllm.prefixCaching.enabled: auto` | `` (P/D uses hardcoded KV config) |

**Recommendation:** Use `enabled: auto` (default) for all deployments. Override only when you have a specific reason.
