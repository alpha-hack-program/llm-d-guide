#!/bin/bash
set -e

# Test script to generate cache hits (repeated prompts)
# For prefix caching to work, vLLM must be started with --enable-prefix-caching

LLM_NAMESPACE="${1:-llm-d-demo}"
MODEL_SERVICE="qwen3-8b-kserve-workload-svc"
NUM_ROUNDS="${2:-3}"  # How many times to repeat the same prompts

echo "╔════════════════════════════════════════════════════════════════════════╗"
echo "║           Test Cache Hits with Repeated Prompts                       ║"
echo "╚════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Configuration:"
echo "  Namespace:       ${LLM_NAMESPACE}"
echo "  Service:         ${MODEL_SERVICE}"
echo "  Rounds:          ${NUM_ROUNDS}"
echo ""

# Check if vLLM has prefix caching enabled
echo "🔍 Checking if prefix caching is enabled..."
POD=$(oc get pods -n ${LLM_NAMESPACE} -l llm-d.ai/role=both -o name | head -1 | cut -d/ -f2)

if [ -z "$POD" ]; then
    echo "❌ No vLLM pod found with label llm-d.ai/role=both"
    exit 1
fi

VLLM_ARGS=$(oc exec -n ${LLM_NAMESPACE} ${POD} -c main -- ps aux | grep "vllm serve" | grep -v grep)

if echo "$VLLM_ARGS" | grep -q "enable-prefix-caching"; then
    echo "✅ Prefix caching is ENABLED"
else
    echo "⚠️  WARNING: Prefix caching is NOT enabled"
    echo ""
    echo "Current vLLM args:"
    echo "$VLLM_ARGS" | sed 's/.*vllm serve/vllm serve/' | tr ' ' '\n' | grep -E "^--" | head -10
    echo ""
    echo "To enable prefix caching, add to vllmAdditionalArgs in values.yaml:"
    echo "  vllmAdditionalArgs: \"--enable-prefix-caching --disable-uvicorn-access-log ...\""
    echo ""
    echo "Continuing anyway - you'll see how cache WOULD work if enabled..."
    echo ""
fi

# Start port-forward
echo "🔌 Starting port-forward to ${MODEL_SERVICE}..."
oc port-forward -n ${LLM_NAMESPACE} svc/${MODEL_SERVICE} 8000:8000 > /dev/null 2>&1 &
PF_PID=$!
sleep 3

cleanup() {
    echo ""
    echo "🧹 Cleaning up port-forward..."
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

# Test prompts (same prompts repeated each round to generate cache hits)
PROMPTS=(
    "You are a helpful assistant. Please explain what a cache is."
    "You are a helpful assistant. What is the capital of France?"
    "You are a helpful assistant. Write a haiku about programming."
)

SUCCESS=0
TOTAL=0

echo "🚀 Sending ${#PROMPTS[@]} unique prompts, repeated ${NUM_ROUNDS} times..."
echo "   (Total requests: $((${#PROMPTS[@]} * ${NUM_ROUNDS})))"
echo ""

for ROUND in $(seq 1 ${NUM_ROUNDS}); do
    echo "Round ${ROUND}/${NUM_ROUNDS}:"

    for i in "${!PROMPTS[@]}"; do
        PROMPT="${PROMPTS[$i]}"
        TOTAL=$((TOTAL + 1))

        RESPONSE=$(curl -s -X POST "http://localhost:8000/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"alibaba/qwen3-8b\",
                \"messages\": [{\"role\": \"user\", \"content\": \"${PROMPT}\"}],
                \"max_tokens\": 20,
                \"temperature\": 0.0
            }" 2>&1)

        if echo "$RESPONSE" | grep -q '"choices"'; then
            SUCCESS=$((SUCCESS + 1))
            echo "  ✓ Prompt $((i+1))/3 - HTTP 200"
        else
            echo "  ✗ Prompt $((i+1))/3 - FAILED"
            echo "    Response: $(echo $RESPONSE | head -c 100)"
        fi

        sleep 0.5
    done

    echo ""
done

echo "════════════════════════════════════════════════════════════════════════"
echo "Results:"
echo "  ✅ Successful: ${SUCCESS}/${TOTAL}"
echo "  ❌ Failed:     $((TOTAL - SUCCESS))/${TOTAL}"
echo "════════════════════════════════════════════════════════════════════════"
echo ""

if [ ${SUCCESS} -eq ${TOTAL} ]; then
    echo "✅ All requests successful!"
    echo ""
    echo "🎯 Expected behavior with prefix caching ENABLED:"
    echo "   - Round 1: No cache hits (first time seeing these prompts)"
    echo "   - Round 2: High cache hits (same prompts as round 1)"
    echo "   - Round 3: High cache hits (same prompts as rounds 1 & 2)"
    echo ""
    echo "📊 Check dashboard metrics:"
    echo "   - Prefix Cache Hit Rate: Should increase after round 1"
    echo "   - Cached Tokens Saved: Should show tokens NOT recomputed"
    echo ""
    echo "⏱️  Wait 30-60 seconds for Prometheus to scrape, then refresh dashboard"
else
    echo "⚠️  Some requests failed - check model logs:"
    echo "   oc logs -n ${LLM_NAMESPACE} ${POD} -c main --tail=50"
fi
