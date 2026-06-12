#!/bin/bash
set -e

# Generate Test Metrics Script
# Sends requests to llm-d model to populate Perses dashboard with data

# Configuration
LLM_NAMESPACE="${LLM_NAMESPACE:-llm-d-demo}"
MODEL_SERVICE="${MODEL_SERVICE:-qwen3-8b-kserve-workload-svc}"
MODEL_NAME="${MODEL_NAME:-alibaba/qwen3-8b}"
NUM_REQUESTS="${NUM_REQUESTS:-20}"

echo "╔════════════════════════════════════════════════════════════════════════╗"
echo "║              Generate Test Metrics for llm-d Dashboard                ║"
echo "╚════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Configuration:"
echo "  Namespace:       ${LLM_NAMESPACE}"
echo "  Service:         ${MODEL_SERVICE}"
echo "  Model:           ${MODEL_NAME}"
echo "  Requests:        ${NUM_REQUESTS}"
echo ""

# Check prerequisites
if ! command -v oc &> /dev/null; then
    echo "❌ ERROR: oc CLI not found"
    exit 1
fi

if ! oc whoami &> /dev/null; then
    echo "❌ ERROR: Not logged in to OpenShift"
    exit 1
fi

if ! oc get namespace ${LLM_NAMESPACE} &> /dev/null; then
    echo "❌ ERROR: Namespace ${LLM_NAMESPACE} does not exist"
    exit 1
fi

if ! oc get svc ${MODEL_SERVICE} -n ${LLM_NAMESPACE} &> /dev/null; then
    echo "❌ ERROR: Service ${MODEL_SERVICE} not found in namespace ${LLM_NAMESPACE}"
    exit 1
fi

# Start port-forward
echo "🔌 Starting port-forward to ${MODEL_SERVICE}..."
oc port-forward -n ${LLM_NAMESPACE} svc/${MODEL_SERVICE} 8000:8000 > /dev/null 2>&1 &
PF_PID=$!

# Wait for port-forward to establish
sleep 3

# Test connectivity
if ! curl -sk -m 5 https://localhost:8000/ping > /dev/null 2>&1; then
    echo "⚠️  Warning: Could not connect to service health endpoint"
    echo "   Continuing anyway..."
fi

echo ""
echo "🚀 Sending ${NUM_REQUESTS} test requests to generate metrics..."
echo ""

SUCCESS_COUNT=0
FAIL_COUNT=0

for i in $(seq 1 ${NUM_REQUESTS}); do
    RESPONSE=$(curl -sk -m 30 -w "%{http_code}" -o /dev/null -X POST https://localhost:8000/v1/chat/completions \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"${MODEL_NAME}\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Count to ${i}\"}],
        \"max_tokens\": 30
      }" 2>/dev/null)

    if [ "${RESPONSE}" = "200" ]; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        echo "  ✓ Request ${i}/${NUM_REQUESTS} - HTTP ${RESPONSE}"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "  ✗ Request ${i}/${NUM_REQUESTS} - HTTP ${RESPONSE:-timeout/error}"
    fi

    # Small delay between requests
    sleep 0.5
done

# Stop port-forward
kill $PF_PID 2>/dev/null || true

echo ""
echo "════════════════════════════════════════════════════════════════════════"
echo "Results:"
echo "  ✅ Successful: ${SUCCESS_COUNT}/${NUM_REQUESTS}"
echo "  ❌ Failed:     ${FAIL_COUNT}/${NUM_REQUESTS}"
echo "════════════════════════════════════════════════════════════════════════"
echo ""

if [ ${SUCCESS_COUNT} -gt 0 ]; then
    echo "✅ Metrics generated successfully!"
    echo ""
    echo "⏱️  Wait 30-60 seconds for Prometheus to scrape the metrics, then:"
    echo ""
    echo "   1. Open OpenShift Console"
    echo "   2. Go to: Observe → Dashboards (Perses)"
    echo "   3. Select: 'llm-d Performance Metrics'"
    echo "   4. Refresh the page (F5)"
    echo ""
    echo "Expected metrics:"
    echo "  - TTFT Request Count: ~${SUCCESS_COUNT}"
    echo "  - Prompt Tokens Total: ~$((SUCCESS_COUNT * 4))"
    echo ""

    # Show current metrics from Prometheus
    echo "🔍 Current metrics in Prometheus:"
    TTFT_COUNT=$(oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
      promtool query instant 'http://localhost:9090' \
      "kserve_vllm:time_to_first_token_seconds_count{namespace=\"${LLM_NAMESPACE}\"}" 2>/dev/null | \
      grep -oP '=> \K[0-9]+' | head -1 || echo "0")

    echo "  TTFT Count: ${TTFT_COUNT}"

else
    echo "❌ No successful requests. Metrics were not generated."
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check if llm-d pods are running:"
    echo "     oc get pods -n ${LLM_NAMESPACE}"
    echo ""
    echo "  2. Check service exists:"
    echo "     oc get svc ${MODEL_SERVICE} -n ${LLM_NAMESPACE}"
    echo ""
    echo "  3. Check pod logs:"
    echo "     oc logs -n ${LLM_NAMESPACE} -l app.kubernetes.io/name=\$(echo ${MODEL_SERVICE} | cut -d'-' -f1,2) -c main --tail=50"
    echo ""
fi
