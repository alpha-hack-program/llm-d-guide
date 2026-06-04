# Canary Release Guide for LLMs — RHOAI / llm-d

**Applies to:** RHOAI 3.4 · OCP 4.21 · llm-d GA  
**Prerequisite:** Phase 5 complete — at least one `LLMInferenceService` healthy, `openshift-ai-inference` gateway running.

---

## The Problem with Standard Traffic Splitting

When you migrate between two LLM backends — a model size change, a provider switch, a vLLM upgrade — standard weighted HTTP routing alone is insufficient.

If a client sends `"model": "alibaba/qwen3-8b"` and your canary vLLM only knows about `alibaba/qwen3-14b`, the request fails immediately with `404 Not Found`. The model identifier mismatch kills the canary before a single token is generated.

There is a second failure mode: even if you solve the identifier problem, routing requests for the same logical model to two separate backends without cache isolation corrupts the KV-cache layer. The llm-d prefix-cache scorer assumes that prompt history for a given model stays within one pool. Mixing pods from two distinct model backends under the same pool breaks that assumption silently.

The solution is a two-tier strategy:

| Tier | Mechanism | Purpose |
|---|---|---|
| **Runtime alias** | `--served-model-name stable-id canary-id` vLLM arg | Canary backend silently accepts requests meant for the stable model |
| **InferencePool isolation** | One `LLMInferenceService` per backend | llm-d enforces separate KV-cache layers; prefix-cache scoring never crosses pool boundaries |

---

## How the Generic Blueprint Maps to RHOAI Primitives

The generic approach uses raw `Deployment` + `Service` + `InferencePool`. In RHOAI, you never write those directly. The `LLMInferenceService` controller emits them for you:

| Generic resource | RHOAI equivalent | Notes |
|---|---|---|
| `Deployment` (stable) | `LLMInferenceService` `qwen3-8b` | Controller creates pod, service, InferencePool, EPP scheduler |
| `Deployment` (canary) | `LLMInferenceService` `nemotron-nano-9b-v2-fp8` | Same; alias injected via `VLLM_ADDITIONAL_ARGS` env var |
| `InferencePool pool-stable` | `qwen3-8b-inference-pool` | Auto-named: `<serviceName>-inference-pool` |
| `InferencePool pool-canary` | `nemotron-nano-9b-v2-fp8-inference-pool` | Auto-named same way |
| Custom `HTTPRoute` | New `HTTPRoute` on `openshift-ai-inference` | Created independently — do NOT patch the controller-owned kserve routes |

**Gateway choice:** Use `openshift-ai-inference` for the canary HTTPRoute. The `LLMInferenceService` controller creates its own kserve routes on `maas-default-gateway` — those are controller-owned and patching them is fragile. `openshift-ai-inference` is a clean gateway with no existing inference routes, so there are no conflicts and no ownership issues.

---

## Step 1 — Stable LLMInferenceService (Already Running)

Confirm the stable service and its InferencePool are healthy:

```bash
oc get llminferenceservice qwen3-8b -n llm-d-demo
oc get inferencepool qwen3-8b-inference-pool -n llm-d-demo
```

Expected:
```
NAME       READY
qwen3-8b   True

NAME                      
qwen3-8b-inference-pool  
```

---

## Step 2 — Deploy the Canary LLMInferenceService

Create a values file for the canary. The critical field is `vllmAdditionalArgs`: it injects `--served-model-name` with **both** the canary identifier AND the stable identifier as **space-separated values**.

> **Format note:** vLLM's `--served-model-name` uses `nargs="+"` (argparse), so multiple names are space-separated within the env var string. **Do not use commas** — a comma is treated as part of the model name and produces a single concatenated identifier that resolves nothing.

```bash
cat > /tmp/nemotron-canary-values.yaml << 'EOF'
deploymentType: intelligent-inference
serviceName: nemotron-nano-9b-v2-fp8
replicas: 1

model:
  name: nvidia/Nemotron-Nano-9B-v2-Instruct

storage:
  type: oci
  uri: oci://registry.redhat.io/rhelai1/modelcar-nvidia-nemotron-nano-9b-v2-fp8-dynamic:1.5

resources:
  limits:
    cpu: "1"
    memory: 12Gi
    gpuCount: "1"
  requests:
    cpu: "1"
    memory: 12Gi
    gpuCount: "1"

hardwareProfile:
  namespace: redhat-ods-applications
  name: gpu-profile

# THE ALIAS TRICK — space-separated, not comma-separated:
# The second name makes this vLLM instance accept requests for the stable
# model identifier. Clients never change their model string.
vllmAdditionalArgs: "--disable-uvicorn-access-log --enable-auto-tool-choice --tool-call-parser hermes --trust_remote_code --served-model-name nvidia/Nemotron-Nano-9B-v2-Instruct alibaba/qwen3-8b"

maas:
  enabled: false
EOF
```

Deploy and wait for Ready:

```bash
helm template nemotron-nano-9b-v2-fp8 ./gitops/instance/llm-d/inference \
  -f /tmp/nemotron-canary-values.yaml | oc apply -n llm-d-demo -f -

oc wait --for=condition=ready llminferenceservice/nemotron-nano-9b-v2-fp8 \
  -n llm-d-demo --timeout=600s
```

If updating an existing `LLMInferenceService` to add the alias (no full redeploy needed), patch `VLLM_ADDITIONAL_ARGS` directly:

```bash
oc patch llminferenceservice nemotron-nano-9b-v2-fp8 -n llm-d-demo --type=merge -p '{
  "spec": {
    "template": {
      "containers": [{
        "name": "main",
        "env": [{
          "name": "VLLM_ADDITIONAL_ARGS",
          "value": "--disable-uvicorn-access-log --enable-auto-tool-choice --tool-call-parser hermes --trust_remote_code --served-model-name nvidia/Nemotron-Nano-9B-v2-Instruct alibaba/qwen3-8b"
        }]
      }]
    }
  }
}'

# Wait for the new pod to be ready
oc wait --for=condition=ready llminferenceservice/nemotron-nano-9b-v2-fp8 \
  -n llm-d-demo --timeout=600s
```

---

## Step 3 — Verify the Alias and InferencePool Isolation

```bash
TOKEN=$(oc whoami -t)
GW_HOST=$(oc get gateway openshift-ai-inference -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')

# nemotron must now list BOTH model IDs — hit its kserve route on the inference gateway
curl -sk "https://${GW_HOST}/llm-d-demo/nemotron-nano-9b-v2-fp8/v1/models" \
  -H "Authorization: Bearer ${TOKEN}" | jq '[.data[].id]'
```

Expected — two separate entries:
```json
[
  "nvidia/Nemotron-Nano-9B-v2-Instruct",
  "alibaba/qwen3-8b"
]
```

If you see `"nvidia/Nemotron-Nano-9B-v2-Instruct,alibaba/qwen3-8b"` as a single string, the separator was a comma — re-patch with spaces and wait for the pod to restart.

Both InferencePools must be present:
```bash
oc get inferencepool -n llm-d-demo
# NAME                                   
# nemotron-nano-9b-v2-fp8-inference-pool 
# qwen3-8b-inference-pool                
```

---

## Step 4 — Create the Canary HTTPRoute on `openshift-ai-inference`

The URL pattern for the canary endpoint is `/{namespace}/{hf-org}/{model-name}/v1/...`. A `URLRewrite` filter strips the namespace and model prefix before forwarding to the InferencePool, so the vLLM instances receive standard `/v1/...` paths.

Each rule uses a **distinct path prefix** so that the models discovery rule (with its own weight distribution) is reachable — within a single HTTPRoute, the first matching rule wins, so overlapping prefixes would make later rules dead code.

Get the gateway hostname:

```bash
GW_HOST=$(oc get gateway openshift-ai-inference -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')
echo "Gateway hostname: ${GW_HOST}"
```

Create the canary route. **Do not attach to `maas-default-gateway`** — the controller-created kserve routes live there and will conflict. Use `openshift-ai-inference` which has no existing inference routes.

```bash
NAMESPACE=llm-d-demo
MODEL=alibaba/qwen3-8b   # HuggingFace org/model — used as the URL prefix

cat > /tmp/canary-httproute.yaml << EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: qwen3-8b-canary-rollout
  namespace: llm-d-demo
  annotations:
    llm-d.io/canary-phase: "phase-1"
    llm-d.io/stable-weight: "90"
    llm-d.io/canary-weight: "10"
spec:
  parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: openshift-ai-inference
    namespace: openshift-ingress
  hostnames:
  - "${GW_HOST}"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /${NAMESPACE}/${MODEL}/v1/chat/completions
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /v1/chat/completions
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: qwen3-8b-inference-pool
      port: 8000
      weight: 90
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: nemotron-nano-9b-v2-fp8-inference-pool
      port: 8000
      weight: 10
    timeouts:
      backendRequest: 0s
      request: 0s
  - matches:
    - path:
        type: PathPrefix
        value: /${NAMESPACE}/${MODEL}/v1/completions
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /v1/completions
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: qwen3-8b-inference-pool
      port: 8000
      weight: 90
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: nemotron-nano-9b-v2-fp8-inference-pool
      port: 8000
      weight: 10
    timeouts:
      backendRequest: 0s
      request: 0s
  - matches:
    - path:
        type: PathPrefix
        value: /${NAMESPACE}/${MODEL}/v1/models
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /v1/models
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: qwen3-8b-inference-pool
      port: 8000
      weight: 1
    timeouts:
      backendRequest: 0s
      request: 0s
EOF

oc apply -f /tmp/canary-httproute.yaml
```

Verify the route is accepted:

```bash
oc get httproute qwen3-8b-canary-rollout -n llm-d-demo \
  -o jsonpath='{.status.parents[0].conditions}' \
  | jq '[.[] | {type:.type, status:.status}]'
# Expect: Accepted=True, ResolvedRefs=True
```

---

## Step 5 — Smoke Test the Split

The canary endpoint is `https://<GW_HOST>/<namespace>/<hf-org>/<model>/v1/chat/completions`. The URLRewrite filter strips the prefix before the request reaches vLLM.

```bash
TOKEN=$(oc whoami -t)
NAMESPACE=llm-d-demo
MODEL=alibaba/qwen3-8b
GW_HOST=$(oc get gateway openshift-ai-inference -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')

for i in $(seq 1 20); do
  CONTENT=$(curl -sk "https://${GW_HOST}/${NAMESPACE}/${MODEL}/v1/chat/completions" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"model":"alibaba/qwen3-8b","messages":[{"role":"user","content":"Say hi."}],"max_tokens":20}' \
    | jq -r '.choices[0].message.content // "ERROR"')
  # Qwen3-8B uses chain-of-thought <think> tags; Nemotron does not.
  # This is the observable difference when both pools serve the same model alias.
  if echo "$CONTENT" | grep -q "<think>"; then
    echo "  $i → [STABLE]  qwen3-8b"
  else
    echo "  $i → [CANARY]  nemotron"
  fi
done
```

At 90/10, expect roughly 2 canary hits in 20 requests.

> **Why `model` field isn't useful here:** When the canary vLLM has the alias set, it echoes the requested model name (`alibaba/qwen3-8b`) in the response — same as the stable pool. Use response content characteristics (like `<think>` tags for Qwen3 thinking-mode vs. direct output for Nemotron) to distinguish which backend answered.

---

## Phase Progression

Advance phases by patching weights on the single HTTPRoute. No application changes required at any phase.

| Phase | Stable weight | Canary weight | Observed result (20 requests) |
|---|---|---|---|
| **0 — Baseline** | 100 | 0 | Canary deployed, receiving no traffic |
| **1 — Canary probe** | 90 | 10 | ~2/20 hit canary pool |
| **2 — Even split** | 50 | 50 | ~10/20 each pool |
| **3 — Canary majority** | 10 | 90 | ~18/20 hit canary pool |
| **4 — Complete** | 0 | 100 | All traffic on canary; safe to remove stable |

### Advancing a phase

```bash
# Example: advance to phase 2 (50/50)
oc patch httproute qwen3-8b-canary-rollout -n llm-d-demo --type=json -p '[
  {"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":50},
  {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":50},
  {"op":"replace","path":"/spec/rules/1/backendRefs/0/weight","value":50},
  {"op":"replace","path":"/spec/rules/1/backendRefs/1/weight","value":50},
  {"op":"replace","path":"/metadata/annotations/llm-d.io~1canary-phase","value":"phase-2"},
  {"op":"replace","path":"/metadata/annotations/llm-d.io~1stable-weight","value":"50"},
  {"op":"replace","path":"/metadata/annotations/llm-d.io~1canary-weight","value":"50"}
]'
```

---

## Rollback

One patch, instant effect — the stable pool never stopped running so its KV caches are warm:

```bash
oc patch httproute qwen3-8b-canary-rollout -n llm-d-demo --type=json -p '[
  {"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":100},
  {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":0},
  {"op":"replace","path":"/spec/rules/1/backendRefs/0/weight","value":100},
  {"op":"replace","path":"/spec/rules/1/backendRefs/1/weight","value":0},
  {"op":"replace","path":"/metadata/annotations/llm-d.io~1canary-phase","value":"rollback"},
  {"op":"replace","path":"/metadata/annotations/llm-d.io~1stable-weight","value":"100"},
  {"op":"replace","path":"/metadata/annotations/llm-d.io~1canary-weight","value":"0"}
]'
```

---

## Finalize the Migration (Phase 4)

Once canary is at 100% and stable for your observation period:

```bash
# 1. Set canary to 100%
oc patch httproute qwen3-8b-canary-rollout -n llm-d-demo --type=json -p '[
  {"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":0},
  {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":100},
  {"op":"replace","path":"/spec/rules/1/backendRefs/0/weight","value":0},
  {"op":"replace","path":"/spec/rules/1/backendRefs/1/weight","value":100}
]'

# 2. Delete stable service
oc delete llminferenceservice qwen3-8b -n llm-d-demo

# 3. Remove the alias from canary — it no longer needs to answer for qwen3-8b
oc patch llminferenceservice nemotron-nano-9b-v2-fp8 -n llm-d-demo --type=merge -p '{
  "spec": {"template": {"containers": [{"name": "main", "env": [{"name": "VLLM_ADDITIONAL_ARGS",
    "value": "--disable-uvicorn-access-log --enable-auto-tool-choice --tool-call-parser hermes --trust_remote_code"}]}]}}
}'

# 4. Simplify the route to a single backend
oc patch httproute qwen3-8b-canary-rollout -n llm-d-demo --type=json -p '[
  {"op":"replace","path":"/spec/rules/0/backendRefs","value":[
    {"group":"inference.networking.k8s.io","kind":"InferencePool","name":"nemotron-nano-9b-v2-fp8-inference-pool","port":8000,"weight":1}
  ]},
  {"op":"replace","path":"/spec/rules/1/backendRefs","value":[
    {"group":"inference.networking.k8s.io","kind":"InferencePool","name":"nemotron-nano-9b-v2-fp8-inference-pool","port":8000,"weight":1}
  ]}
]'
```

---

## Known Gotchas

- **`--served-model-name` format:** Space-separated, not comma-separated. Commas produce a single concatenated model name string. Verify with `GET /v1/models` — the response must list two separate `id` entries.
- **Do not patch controller-owned HTTPRoutes:** The kserve routes (`<service>-kserve-route`) are owned by the `LLMInferenceService` controller and live on `maas-default-gateway`. Patching them directly works briefly but the controller reverts them on the next reconcile (triggered by any change to the parent `LLMInferenceService`). Create a new route on `openshift-ai-inference` instead.
- **`model` field in responses is not a reliable split indicator:** Both pools echo the requested model name when the alias is active. Use model-specific response characteristics (e.g., Qwen3's `<think>` chain-of-thought prefix vs. Nemotron's direct output) or EPP scheduler metrics to confirm actual routing distribution.
- **Statistical variance:** At 90/10 you need ~20+ requests to reliably observe canary traffic. At 50/50 the distribution converges faster.
- **Stable pool stays warm:** Never shut down the stable pool until Phase 4 is complete. The instant rollback only works because the stable KV caches are live.

---

## Summary

```
Client sends: POST /llm-d-demo/alibaba/qwen3-8b/v1/chat/completions
              "model": "alibaba/qwen3-8b"  (both unchanged throughout migration)
        │
        ▼
openshift-ai-inference Gateway
  HTTPRoute: qwen3-8b-canary-rollout
  URLRewrite: /llm-d-demo/alibaba/qwen3-8b/v1/... → /v1/...
        │
        ├── weight 90 ──► qwen3-8b-inference-pool     (Qwen3-8B vLLM)
        │                       EPP: prefix-cache, queue, kv-cache scoring
        │
        └── weight 10 ──► nemotron-nano-9b-v2-fp8-inference-pool  (Nemotron vLLM)
                                --served-model-name: accepts "alibaba/qwen3-8b"
                                EPP: cache-isolated from stable pool

Rollback: one oc patch → weights 100/0 → stable serves all traffic instantly
```
