#!/bin/bash
NS="llm-d-demo"
ISVC="qwen3-8b"
MODEL="alibaba/qwen3-8b"   # ← the actual served model name

POD=$(oc get pods -n "$NS" -l kserve.io/component=workload -o jsonpath='{.items[0].metadata.name}')
URL=$(oc get llminferenceservice "$ISVC" -n "$NS" -o jsonpath='{.status.url}')
TOKEN=$(oc whoami -t)

echo "── prefix cache counters BEFORE ──"
oc exec -n "$NS" "$POD" -c main -- sh -c 'curl -sk https://localhost:8000/metrics || curl -s http://localhost:8000/metrics' \
  | grep -E "^vllm:prefix_cache_(hits|queries)_total"

echo "── sending 20 shared-prefix requests ──"
for i in $(seq 1 20); do
  curl -sk --max-time 60 "$URL/v1/chat/completions" \
    -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"You are a helpful assistant analyzing OpenShift cluster telemetry for capacity planning. Question $i: what is 2+$i?\"}],\"max_tokens\":10}" \
    -o /dev/null -w "req=$i status=%{http_code}\n"
done

sleep 5
echo "── prefix cache counters AFTER (queries should jump, hits should climb) ──"
oc exec -n "$NS" "$POD" -c main -- sh -c 'curl -sk https://localhost:8000/metrics || curl -s http://localhost:8000/metrics' \
  | grep -E "^vllm:prefix_cache_(hits|queries)_total"

echo "── EPP routing decisions for this test ──"
oc logs -n "$NS" deploy/${ISVC}-kserve-router-scheduler --since=2m --all-containers 2>/dev/null \
  | grep -E "Request handled" | tail -20
