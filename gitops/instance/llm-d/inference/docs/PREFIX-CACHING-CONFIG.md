# Prefix Caching Configuration

## Default Behavior

**Prefix caching is ENABLED by default** in the Helm chart.

**Why:** Prefix caching is the core optimization for the **Intelligent Inference** well-lit path. It enables:
- 75-85% cache hit rate for multi-turn workloads
- 50-80% faster TTFT for cached requests  
- EPP (Endpoint Picker) to route requests based on cache affinity
- Significant GPU hours saved (cached tokens not recomputed)

**Default in `values.yaml`:**
```yaml
vllmAdditionalArgs: "--enable-prefix-caching"
```

---

## When to Keep Prefix Caching Enabled (Recommended)

✅ **Use cases that benefit from prefix caching:**

| Use Case | Why Prefix Caching Helps | Expected Cache Hit Rate |
|----------|--------------------------|-------------------------|
| **Multi-turn conversations** | System prompt cached across turns | 80-90% |
| **RAG (Retrieval Augmented Generation)** | Document context cached, queries vary | 60-80% |
| **Agent/tool calling** | System instructions + tool schemas cached | 70-85% |
| **Batch processing with templates** | Template prefix cached, variables change | 50-70% |
| **Chat applications** | User-specific system prompts cached | 75-90% |

**Keep the default:** `vllmAdditionalArgs: "--enable-prefix-caching ..."`

---

## When to Disable Prefix Caching

❌ **Use cases where prefix caching provides NO benefit:**

| Use Case | Why No Benefit | Recommendation |
|----------|----------------|----------------|
| **Every request is unique** | No repeated prefixes to cache | Disable or leave default (small overhead) |
| **Single-turn completions** | No system prompt, no repetition | Disable or leave default |
| **Streaming-only workloads** | vLLM < v0.6.0 has streaming + caching bugs | Disable if hitting bugs |
| **Very short prompts (< 16 tokens)** | Below cache block size threshold | Disable (no cache benefit) |

**To disable:**

### Option 1: Per-model values file
```yaml
# my-model-values.yaml
vllmAdditionalArgs: "--disable-uvicorn-access-log"  # omit --enable-prefix-caching
```

### Option 2: Helm CLI override
```bash
helm template my-model ./gitops/instance/llm-d/inference \
  -f my-model-values.yaml \
  --set vllmAdditionalArgs="--disable-uvicorn-access-log" \
  | oc apply -f -
```

---

## Adding More vLLM Flags

**Common pattern:** Keep prefix caching enabled, add more flags

### Example 1: Enable prefix caching + tool calling
```yaml
vllmAdditionalArgs: "--enable-prefix-caching --disable-uvicorn-access-log --enable-auto-tool-choice --tool-call-parser hermes"
```

### Example 2: Enable prefix caching + custom max tokens
```yaml
vllmAdditionalArgs: "--enable-prefix-caching --max-model-len 8192"
```

### Example 3: Disable prefix caching but keep other flags
```yaml
# Omit --enable-prefix-caching from the string
vllmAdditionalArgs: "--disable-uvicorn-access-log --enable-auto-tool-choice"
```

---

## Verifying Prefix Caching Status

### Check if enabled in running pod

```bash
POD=$(oc get pods -n <namespace> -l llm-d.ai/role=both -o name | head -1 | cut -d/ -f2)

# Check vLLM command line
oc exec -n <namespace> $POD -c main -- ps aux | grep "vllm serve" | grep "enable-prefix-caching"
```

**If enabled:** You'll see `--enable-prefix-caching` in the output  
**If disabled:** No output (grep finds nothing)

### Check vLLM logs

```bash
oc logs -n <namespace> $POD -c main | grep -i "prefix caching"
```

**If enabled:** You'll see:
```
INFO:     Automatic prefix caching is enabled.
```

**If disabled:** No mention of prefix caching in logs

---

## Impact on Metrics

### With Prefix Caching Enabled (Default)

**Dashboard metrics:**
```
Prefix Cache Hit Rate:  75-85% (multi-turn workloads)
Cached Tokens Saved:    5000-10000 tokens/min
TTFT P95:               100-150ms (60% faster than uncached)
```

### With Prefix Caching Disabled

**Dashboard metrics:**
```
Prefix Cache Hit Rate:  0% (no caching)
Cached Tokens Saved:    0 tokens/min
TTFT P95:               250-300ms (all prompts computed from scratch)
```

**EPP Scheduler Impact:**
- **Enabled:** Routes requests to pods with best cache affinity
- **Disabled:** Random routing (no cache benefit to optimize for)

---

## Migration from Disabled to Enabled

**If you previously disabled prefix caching and want to enable it:**

### 1. Update values file

```yaml
# Before
vllmAdditionalArgs: "--disable-uvicorn-access-log"

# After
vllmAdditionalArgs: "--enable-prefix-caching --disable-uvicorn-access-log"
```

### 2. Re-deploy

```bash
helm template my-model ./gitops/instance/llm-d/inference \
  -f my-model-values.yaml \
  | oc apply -f -
```

### 3. Verify

```bash
POD=$(oc get pods -n <namespace> -l llm-d.ai/role=both -o name | head -1 | cut -d/ -f2)
oc exec -n <namespace> $POD -c main -- ps aux | grep "enable-prefix-caching"
# Should show: --enable-prefix-caching
```

### 4. Test cache hits

```bash
cd gitops/instance/llm-d-observability
./test-cache-hits.sh <namespace> 3
```

Send requests with **repeated prompts** - you should see cache hit rate > 0%.

### 5. Check dashboard

After 60s, dashboard should show:
- Prefix Cache Hit Rate > 0%
- Cached Tokens Saved > 0

---

## Performance Considerations

### Memory Impact

**Prefix caching uses KV cache memory:**
- Cached prefixes occupy KV cache slots
- Trade-off: Less memory for new requests, faster for repeated prefixes
- Monitor: `vllm:kv_cache_usage_perc` metric

**If cache is full (> 90% sustained):**
- Option 1: Scale up replicas (distribute cache across more pods)
- Option 2: Reduce `--max-model-len` (smaller KV cache per request)
- Option 3: Disable prefix caching (if not beneficial for your workload)

### Latency Impact

**First request (cache miss):**
- Same latency as without caching (no overhead)

**Subsequent requests (cache hit):**
- 50-80% faster TTFT (tokens not recomputed)

**Cache overhead:**
- Minimal (<5ms) for cache lookup on each request
- Negligible compared to TTFT improvement on cache hits

---

## Best Practices

### DO: Keep Enabled by Default

✅ Leave `vllmAdditionalArgs: "--enable-prefix-caching"` in `values.yaml`  
✅ Per-model values files can override if needed  
✅ Monitor cache hit rate in dashboard to validate benefit  

### DO: Test Your Workload

✅ Deploy with default (enabled)  
✅ Send representative traffic (production-like prompts)  
✅ Check dashboard: Prefix Cache Hit Rate panel  
✅ If > 30% hit rate → keep enabled  
✅ If < 10% hit rate → consider disabling  

### DON'T: Disable Without Testing

❌ Don't assume your workload doesn't benefit  
❌ Don't disable based on theoretical analysis  
❌ Don't disable to "save memory" without measuring  

**Reason:** Even 30% cache hit rate = significant TTFT improvement for those requests.

---

## Examples

### Example 1: Default (Prefix Caching Enabled)

```yaml
# my-model-values.yaml
deploymentType: intelligent-inference
serviceName: my-model
model:
  name: my-org/my-model
vllmAdditionalArgs: "--enable-prefix-caching --disable-uvicorn-access-log"
```

**Result:** Prefix caching enabled, cache hit rate visible in dashboard

### Example 2: Disable for Unique Prompts

```yaml
# unique-prompts-model-values.yaml
deploymentType: intelligent-inference
serviceName: unique-model
model:
  name: my-org/unique-model
vllmAdditionalArgs: "--disable-uvicorn-access-log"  # no --enable-prefix-caching
```

**Result:** No prefix caching, 0% cache hit rate (expected)

### Example 3: Conditional Disable via Helm

```bash
# Enable by default
helm template my-model ./inference -f my-model-values.yaml | oc apply -f -

# Disable for specific deployment (override at deploy time)
helm template my-model ./inference -f my-model-values.yaml \
  --set vllmAdditionalArgs="--disable-uvicorn-access-log" \
  | oc apply -f -
```

---

## Troubleshooting

### "I enabled prefix caching but cache hit rate is still 0%"

**Check:**

1. **Are prompts actually repeating?**
   - Prefix caching requires **repeated prefixes** (same system prompt, RAG context)
   - Completely unique prompts = 0% cache hit rate (expected)

2. **Are prompts > 16 tokens?**
   - Cache block size is typically 16 tokens
   - Prefixes < 16 tokens won't cache
   - Solution: Use longer system prompts

3. **Is temperature > 0?**
   - High temperature can invalidate cache (sampling differences)
   - Solution: Use `temperature: 0.0` for testing

4. **Did vLLM restart?**
   - Cache is in-memory only, lost on restart
   - Solution: Send traffic after pod is ready

### "vLLM fails to start with --enable-prefix-caching"

**Error:** `Automatic prefix caching is not supported for <model-name>`

**Cause:** Not all models support prefix caching (vLLM limitation)

**Solution:** Disable prefix caching for that specific model:
```yaml
vllmAdditionalArgs: "--disable-uvicorn-access-log"  # omit --enable-prefix-caching
```

---

## Summary

| Aspect | Default (Enabled) | Override (Disabled) |
|--------|-------------------|---------------------|
| **values.yaml** | `vllmAdditionalArgs: "--enable-prefix-caching"` | Override in per-model values |
| **Use Case** | Multi-turn, RAG, agents | Unique prompts, single-turn |
| **Cache Hit Rate** | 75-85% (multi-turn) | 0% (no caching) |
| **TTFT** | 50-80% faster (cached) | Baseline (no improvement) |
| **EPP Benefit** | Routes by cache affinity | Random routing |
| **Dashboard** | Shows cache metrics | Shows 0% (expected) |
| **When to Use** | **Recommended default** | Only if workload doesn't benefit |

**Recommendation:** Keep the default (`--enable-prefix-caching`) unless you have specific evidence your workload doesn't benefit from caching.
