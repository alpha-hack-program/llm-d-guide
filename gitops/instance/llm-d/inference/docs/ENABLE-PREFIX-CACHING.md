# Prefix Caching for Intelligent Inference

## Status: ENABLED BY DEFAULT

**As of this version, prefix caching is ENABLED by default** in the Helm chart.

**Default in `values.yaml`:**
```yaml
vllmAdditionalArgs: "--enable-prefix-caching"
```

## If You See 0% Cache Hit Rate

**Possible causes:**

1. **Old deployment** - Deployed before prefix caching was added to defaults
2. **Overridden in per-model values** - Someone explicitly disabled it
3. **vLLM is running without the flag** - Verify actual pod configuration

**Current vLLM command:**
```bash
vllm serve /mnt/models \
  --served-model-name alibaba/qwen3-8b \
  --port 8000 \
  --disable-uvicorn-access-log \
  --enable-auto-tool-choice \
  --tool-call-parser hermes
  # ↑ Missing: --enable-prefix-caching
```

**Verified by checking the running pod:**
```bash
POD=$(oc get pods -n llm-d-demo -l llm-d.ai/role=both -o name | head -1 | cut -d/ -f2)
oc exec -n llm-d-demo $POD -c main -- ps aux | grep "vllm serve"
# Output does NOT include --enable-prefix-caching
```

---

## Solution: Add --enable-prefix-caching to vllmAdditionalArgs

### 1. Update qwen3-8b-values.yaml

**File:** `gitops/instance/llm-d/inference/qwen3-8b-values.yaml`

**Current:**
```yaml
vllmAdditionalArgs: "--disable-uvicorn-access-log --enable-auto-tool-choice --tool-call-parser hermes"
```

**Updated:**
```yaml
vllmAdditionalArgs: "--enable-prefix-caching --disable-uvicorn-access-log --enable-auto-tool-choice --tool-call-parser hermes"
```

### 2. Re-deploy qwen3-8b

```bash
helm template qwen3-8b ./gitops/instance/llm-d/inference \
  -f ./gitops/instance/llm-d/inference/qwen3-8b-values.yaml \
  | oc apply -f -
```

### 3. Wait for Pod Restart

```bash
# Watch pod restart
oc get pods -n llm-d-demo -l app.kubernetes.io/part-of=llminferenceservice -w

# Wait for new pod to be ready (1-2 minutes)
oc wait --for=condition=ready pod \
  -l llm-d.ai/role=both \
  -n llm-d-demo \
  --timeout=180s
```

### 4. Verify Prefix Caching is Enabled

```bash
POD=$(oc get pods -n llm-d-demo -l llm-d.ai/role=both -o name | head -1 | cut -d/ -f2)

# Check vLLM args
oc exec -n llm-d-demo $POD -c main -- ps aux | grep "enable-prefix-caching"
```

**Expected output:**
```
... vllm serve /mnt/models --enable-prefix-caching ...
```

### 5. Test Cache Hits

Send **repeated prompts** to generate cache hits:

```bash
cd gitops/instance/llm-d-observability
./test-cache-hits.sh llm-d-demo 3
```

This sends 3 unique prompts, repeated 3 times each (9 total requests).

**Expected metrics:**
- **Round 1:** 0% cache hit rate (first time seeing prompts)
- **Round 2:** 80-95% cache hit rate (same prompts as round 1)
- **Round 3:** 80-95% cache hit rate (same prompts as rounds 1 & 2)

### 6. Check Dashboard

**OpenShift Console → Observe → Dashboards (Perses) → "llm-d Intelligent Inference"**

After 30-60 seconds, you should see:
- **Prefix Cache Hit Rate %:** 60-80% (aggregate across all rounds)
- **Cached Tokens Saved:** Positive value (tokens NOT recomputed)

---

## Why Prefix Caching Matters for Intelligent Inference

### Without Prefix Caching (current state)

```
User: "You are a helpful assistant. What is 2+2?"
vLLM: Processes entire prompt from scratch → 50 tokens → 200ms

User: "You are a helpful assistant. What is 3+3?"
vLLM: Processes entire prompt from scratch → 50 tokens → 200ms
       ↑ Recomputes "You are a helpful assistant" every time
```

**Cache hit rate:** 0%  
**GPU waste:** High (same system prompt recomputed every request)

### With Prefix Caching (after fix)

```
User: "You are a helpful assistant. What is 2+2?"
vLLM: Processes entire prompt → 50 tokens → 200ms
      Caches "You are a helpful assistant" prefix (30 tokens)

User: "You are a helpful assistant. What is 3+3?"
vLLM: Prefix cache HIT on first 30 tokens → Only processes "What is 3+3?" (20 tokens) → 80ms
       ↑ Saved 30 tokens of computation
```

**Cache hit rate:** 60% (30 cached / 50 total)  
**TTFT reduction:** 60% faster (80ms vs 200ms)  
**GPU savings:** Reused 30 tokens of KV cache, didn't recompute

---

## What Gets Cached

**Prefix caching caches KV states for repeated prompt prefixes:**

| Prompt Part | Cached? | Why |
|-------------|---------|-----|
| System prompt (e.g., "You are a helpful assistant") | ✅ Yes | Same across requests |
| RAG context (e.g., "Here are the docs: ...") | ✅ Yes | Same for queries on same doc set |
| User question (e.g., "What is 2+2?") | ❌ No | Changes every request |

**Best for:**
- Multi-turn conversations (same system prompt)
- RAG workloads (same document context, different queries)
- Repeated tool-calling patterns

**Not useful for:**
- Every request has unique prompts
- Single-turn completions with no system prompt

---

## Verification Steps After Enabling

### 1. Check vLLM Logs for Cache Stats

```bash
POD=$(oc get pods -n llm-d-demo -l llm-d.ai/role=both -o name | head -1 | cut -d/ -f2)

oc logs -n llm-d-demo $POD -c main --tail=100 | grep -i cache
```

**Look for:**
```
INFO:     Automatic prefix caching is enabled.
```

### 2. Query Prometheus for Cache Metrics

```bash
oc port-forward -n openshift-user-workload-monitoring prometheus-user-workload-0 9090:9090 &

# Cache hit count
curl -s 'http://localhost:9090/api/v1/query?query=vllm:prefix_cache_hits_total' | \
  jq '.data.result[0].value[1]'

# Cache miss count  
curl -s 'http://localhost:9090/api/v1/query?query=vllm:prefix_cache_misses_total' | \
  jq '.data.result[0].value[1]'

# Hit rate
curl -s 'http://localhost:9090/api/v1/query?query=sum(rate(vllm:prefix_cache_hits_total[5m]))/sum(rate(vllm:prefix_cache_queries_total[5m]))*100' | \
  jq '.data.result[0].value[1]'
```

### 3. Check Dashboard Panels

All these should show **non-zero values** after sending repeated prompts:

- ✅ **Prefix Cache Hit Rate %** - Should be > 50% after round 2
- ✅ **Cached Tokens Saved** - Positive tokens/min
- ✅ **TTFT P95** - Should be lower for cached requests vs uncached

---

## Troubleshooting

### "Still seeing 0% cache hit rate after enabling"

**Possible causes:**

1. **Prompts are not repeating**
   - The `generate-metrics.sh` script sends **unique prompts** each time
   - Use `test-cache-hits.sh` instead (sends same prompts repeatedly)

2. **Cache block size mismatch**
   - Default: 16 tokens
   - Repeated prefixes < 16 tokens won't cache
   - Solution: Ensure system prompts are > 16 tokens

3. **Temperature > 0**
   - High temperature = different sampling = cache invalidated
   - Solution: Use `temperature: 0.0` for testing

4. **vLLM restarted recently**
   - Cache is in-memory only
   - Solution: Wait for a few requests to build up cache

### "vLLM fails to start with --enable-prefix-caching"

**Check logs:**
```bash
oc logs -n llm-d-demo <pod> -c main --tail=100
```

**Common errors:**
- **"Automatic prefix caching is not supported for ..."** - Model not supported
- **"OutOfMemory"** - Cache + model don't fit in GPU - reduce `max_model_len`

**Solution:** Some models don't support prefix caching. Check vLLM docs for compatibility.

### "Cache hit rate is low (10-20%)"

**Possible causes:**

1. **Prompts have too little repetition**
   - Only the shared prefix caches
   - Example: "Tell me about X" vs "Tell me about Y" - only "Tell me about " caches (3 tokens)

2. **No system prompt**
   - Most cache benefit comes from repeated system prompts
   - Solution: Add a system prompt to all requests

3. **Cache eviction**
   - KV cache is full, evicting old entries
   - Check: `vllm:num_preemptions_total` metric
   - Solution: Reduce `max_model_len` or scale up replicas

---

## Expected Results

### Before (no prefix caching):
```
Prefix Cache Hit Rate: 0%
Cached Tokens Saved: 0 tokens/min
TTFT P95: 250ms
```

### After (with prefix caching):
```
Prefix Cache Hit Rate: 75-85% (multi-turn workloads)
Cached Tokens Saved: 5000-10000 tokens/min
TTFT P95: 80-120ms (60% faster)
```

**Business impact:**
- 75% of tokens NOT recomputed = 75% GPU hours saved on those tokens
- 60% faster TTFT = better user experience
- Same hardware serves 2-3x more requests (cache-friendly workloads)

---

## Next Steps

1. ✅ Update `vllmAdditionalArgs` to include `--enable-prefix-caching`
2. ✅ Re-deploy qwen3-8b
3. ✅ Run `test-cache-hits.sh` with repeated prompts
4. ✅ Verify dashboard shows > 0% cache hit rate
5. ✅ Monitor cache metrics in production workloads

Once prefix caching is working, the **Intelligent Inference dashboard metrics will be meaningful** - you'll see the actual cache efficiency and TTFT improvements that EPP + prefix caching deliver.
