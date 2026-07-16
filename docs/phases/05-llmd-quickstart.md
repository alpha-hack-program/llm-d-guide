# Phase 5 — llm-d Quick Start

> Part of the [llm-d-guide Co-pilot Runbook](../../AGENTS.md). See the
> [Phase Map](../../AGENTS.md#phase-map) for the full sequence.

**Goal:** Deploy the gateway, a namespace, and an LLMInferenceService, then test the endpoint.

**Pre-flight checks the assistant must run before starting:**
```bash
# GPU nodes must have nvidia.com/gpu capacity before deploying inference workloads.
# (GPU provisioning started in Phase 2 — it runs in the background during Phases 3–4.)
oc get nodes -o json | jq '.items[] | select(.status.capacity."nvidia.com/gpu") | {name: .metadata.name, gpu: .status.capacity."nvidia.com/gpu"}'
# Expected: at least one node with "gpu": "1" (or more)
# If no nodes show GPU capacity, wait — NVIDIA drivers may still be installing.

# LLMInferenceService CRD available
oc get crd llminferenceservices.serving.kserve.io

# LeaderWorkerSet CRD available (required for MoE multi-node)
oc get crd leaderworkersets.leaderworkerset.x-k8s.io

# Controller pods running
oc get pods -n redhat-ods-applications \
  -l control-plane=odh-model-controller
oc get pods -n redhat-ods-applications \
  -l control-plane=kserve-controller-manager

# All operators healthy
./scripts/check-operators.sh

# User Workload Monitoring enabled (MANDATORY for metrics)
oc get configmap cluster-monitoring-config -n openshift-monitoring \
  -o jsonpath='{.data.config\.yaml}' | grep enableUserWorkload
# Expected: enableUserWorkload: true
# If not enabled, STOP and enable it (see README §8 Step 6.2) before proceeding

# Prometheus user-workload pods running
oc get pods -n openshift-user-workload-monitoring | grep prometheus-user-workload
# Expected: prometheus-user-workload-0 and prometheus-user-workload-1 Running
```

### Step 1 — Configure the Gateway

**Ask the user which gateway exposure method to use:**

**Option A — LoadBalancer with pre-existing certificate:**

Creates a dedicated AWS LoadBalancer with a custom subdomain (`inference.apps.<domain>`).
Requires Phase 1 Let's Encrypt certs.

```bash
APP_NAME=gateway
GATEWAY_NAME=${GATEWAY_NAME:=openshift-ai-inference}
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"

helm template gitops/instance/llm-d/gateway \
  --name-template ${APP_NAME} \
  --set gatewayName="${GATEWAY_NAME}" \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --set subdomain=inference \
  --set useOpenShiftRoute=false \
  --set tls.secretName=ingress-certs \
  --include-crds | oc apply -f -
```

**Option B — OpenShift Route with pre-existing certificate:**

Uses the cluster's default router (no extra LoadBalancer). TLS passthrough to the gateway
using the Phase 1 Let's Encrypt certs. Hostname: `openshift-ai-inference-openshift-ingress.apps.<domain>`.

```bash
APP_NAME=gateway
GATEWAY_NAME=${GATEWAY_NAME:=openshift-ai-inference}
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"

helm template gitops/instance/llm-d/gateway \
  --name-template ${APP_NAME} \
  --set gatewayName="${GATEWAY_NAME}" \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --set subdomain=inference \
  --set useOpenShiftRoute=true \
  --set tls.secretName=ingress-certs \
  --include-crds | oc apply -f -
```

**Option C — OpenShift Route with self-signed certificate:**

Uses the cluster's default router with a generated self-signed cert. No Phase 1 certs required.

```bash
APP_NAME=gateway
GATEWAY_NAME=${GATEWAY_NAME:=openshift-ai-inference}
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"

helm template gitops/instance/llm-d/gateway \
  --name-template ${APP_NAME} \
  --set gatewayName="${GATEWAY_NAME}" \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --set subdomain=inference \
  --set useOpenShiftRoute=true \
  --set tls.secretName="${GATEWAY_NAME}" \
  --set tls.generate=true --include-crds | oc apply -f -
```

Verify the Gateway is ready and confirm Kuadrant has reconciled:

```bash
oc get gateway -n openshift-ingress
# Expected: openshift-ai-inference   openshift-ai-inference-class   True   ...

# The GatewayClass created above resolves the Phase 3 Kuadrant pending state.
# The Kuadrant operator must detect the new GatewayClass — it does NOT watch passively,
# it requires a pod restart to pick it up. Wait 60s first; if still not Ready, restart:
oc wait kuadrant kuadrant -n kuadrant-system --for=condition=Ready --timeout=60s || \
  (oc delete pod -n openshift-operators \
    $(oc get pods -n openshift-operators -o name | grep kuadrant-operator-controller-manager) && \
   oc wait kuadrant kuadrant -n kuadrant-system --for=condition=Ready --timeout=5m)
# Expected: condition met
# If it still does not reach Ready after the restart, check: oc get kuadrant -n kuadrant-system -o yaml
```

### Step 2 — Create Namespace

```bash
PROJECT="llm-d-demo"
oc new-project ${PROJECT}
oc label namespace ${PROJECT} modelmesh-enabled=false opendatahub.io/dashboard=true
```

### Step 3 — Deploy an LLMInferenceService

**Ask the user which model/storage type to deploy** before generating the inference chart:
- **OCI** (`registry.redhat.io/rhelai1/...`) — no HF token needed, pull secret must include `registry.redhat.io`
- **HuggingFace** — requires `HF_TOKEN` for gated models

**Option A — Qwen3-8B-FP8 via OCI ModelCar (recommended):**

```bash
cat <<EOF > qwen3-8b-fp8-dynamic-oci.tmp.yaml
deploymentType: intelligent-inference
serviceName: qwen3-8b
replicas: 2
useStartupProbe: true
hardwareProfile:
  name: gpu-profile
storage:
  type: oci
  uri: oci://registry.redhat.io/rhelai1/modelcar-qwen3-8b-fp8-dynamic:1.5
model:
  name: alibaba/qwen3-8b
resources:
  limits: { cpu: "4", memory: 16Gi, gpuCount: "1" }
  requests: { cpu: "1", memory: 8Gi, gpuCount: "1" }
vllm:
  extraArgs:
    - "--disable-uvicorn-access-log"
    - "--enable-auto-tool-choice"
    - "--tool-call-parser=hermes"
EOF

helm template qwen3-8b gitops/instance/llm-d/inference \
  -n ${PROJECT} \
  -f gitops/instance/llm-d/inference/values.yaml \
  -f qwen3-8b-fp8-dynamic-oci.tmp.yaml \
  --include-crds | oc apply -f -
```

**Option B — Facebook OPT-125m via HuggingFace (quick test):**

```bash
cat <<EOF > facebook-opt-125m-hf.tmp.yaml
deploymentType: intelligent-inference
serviceName: opt-125m
replicas: 1
useStartupProbe: true
storage:
  type: hf
  uri: hf://facebook/opt-125m
model:
  name: facebook/opt-125m
resources:
  limits: { cpu: "2", memory: 8Gi, gpuCount: 1 }
  requests: { cpu: "1", memory: 4Gi, gpuCount: 1 }
EOF

helm template opt-125m gitops/instance/llm-d/inference \
  -n ${PROJECT} \
  -f gitops/instance/llm-d/inference/values.yaml \
  -f facebook-opt-125m-hf.tmp.yaml \
  --include-crds | oc apply -f -
```

### Step 4 — Verify Deployment

```bash
oc get llminferenceservice -w -n ${PROJECT}
# Expected: qwen3-8b   https://<gateway-url>/${PROJECT}/qwen3-8b   True   5m

oc get pods -w -n ${PROJECT}
# Expected: qwen3-8b-kserve pods Running, router-scheduler Running
```

Watch pod logs:

```bash
# vLLM server logs
oc logs -f \
  -l app.kubernetes.io/name=qwen3-8b,app.kubernetes.io/component=llminferenceservice-workload \
  -n ${PROJECT}

# Scheduler logs
oc logs -f \
  -l app.kubernetes.io/name=qwen3-8b,app.kubernetes.io/component=llminferenceservice-router-scheduler \
  -n ${PROJECT}
```

### Step 5 — Test the Endpoint

```bash
INFERENCE_URL=$(oc get gateway openshift-ai-inference -n openshift-ingress \
  -o json | jq -r '.spec.listeners[] | select(.name=="https").hostname')
echo "Inference URL: https://${INFERENCE_URL}"

# List available models
curl -s https://${INFERENCE_URL}/${PROJECT}/qwen3-8b/v1/models | jq

# Send a completion request
curl -s -X POST https://${INFERENCE_URL}/${PROJECT}/qwen3-8b/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "alibaba/qwen3-8b",
    "prompt": "Explain the difference between supervised and unsupervised learning.",
    "max_tokens": 50,
    "temperature": 0.7
  }' | jq '.choices[0].text'

# Send a chat completion request
curl -s -X POST https://${INFERENCE_URL}/${PROJECT}/qwen3-8b/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "alibaba/qwen3-8b",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant. Be VERY concise"},
      {"role": "user", "content": "Answer to the Ultimate Question of Life, the Universe, and Everything."}
    ],
    "max_tokens": 200,
    "temperature": 0.7
  }' | jq '.choices[0].message.content'
```

### Step 6 — Deploy Monitoring

> If you completed Phase 4, UWM, COO, and the UIPlugins are already in place — skip to the
> dashboard apply. If not, follow Phase 4 Steps 1–3 first, then return here.

```bash
# Enable User Workload Monitoring (if not already enabled)
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

# Wait for prometheus-user-workload pods (~5 min)
oc get pods -n openshift-user-workload-monitoring -w

# Install Cluster Observability Operator
oc apply -k gitops/operators/cluster-observability-operator

# Enable Perses dashboards in the console (required for the Perses tab to appear)
cat <<EOF | oc apply -f -
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: dashboards
spec:
  type: Dashboards
---
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: monitoring
spec:
  type: Monitoring
  monitoring:
    perses:
      enabled: true
EOF

# Deploy Perses dashboard
oc apply -f gitops/instance/llm-d-observability/perses-dashboard-intelligent-inference.yaml
```

**Access:** OpenShift Console → **Observe** → **Dashboards (Perses)** → **"llm-d Intelligent Inference"**

For complete setup, troubleshooting, and metrics reference, see:
[gitops/instance/llm-d-observability/LLM-D-MONITORING-INTEGRATION.md](../../gitops/instance/llm-d-observability/LLM-D-MONITORING-INTEGRATION.md)

### Step 7 — Verify Intelligent Routing (Recommended)

After deploying your first model, verify llm-d's KV-cache-aware intelligent routing is operational:

```bash
./scripts/verify-intelligent-router.sh
```

**Expected output:**
- 20/20 HTTP 200 responses
- Prefix cache queries increase by ~680 tokens
- Prefix cache hits increase by ~640 tokens
- EPP logs show 20 "Request handled" routing decisions

For detailed explanation, see: [llm-d Intelligent Routing Verification Guide](../../LLMD-INTELLIGENT-ROUTING-VERIFICATION.md)

**Human gate:** Review the chat completion response. If the model returns a coherent answer and intelligent routing is verified, the deployment is successful.

**Known gotchas:**
- If the Gateway is not `PROGRAMMED=True`, check that Connectivity Link / Authorino is Running and the `GatewayClass` CR was created.
- If the LLMInferenceService is stuck `Not Ready`, describe it: `oc describe llminferenceservice <name> -n <namespace>` and check events.
- If `HTTPRoutesReady: False` with `NotAllowedByListeners`: the model namespace is missing from the MaaS gateway's `allowedRoutes`. Re-apply the gateway chart with `--set "gateway.modelNamespaces={<namespace>}"` (see README §9.2).
- **Hardware profile name:** The admission webhook `hardwareprofile-llmisvc-injector.opendatahub.io` validates the profile name against existing `HardwareProfile` CRs in `redhat-ods-applications`. The chart in `gitops/instance/rhoai` creates three profiles: `gpu-profile`, `gpu-kueue-profile`, and `nvidia-a10g-profile`. The default is `gpu-profile` (auto-selected when `gpuCount > 0`); the pre-existing `qwen3-8b-values.yaml` also uses `gpu-profile`. Verify available profiles with `oc get hardwareprofile -n redhat-ods-applications` before applying the inference chart.
  - `gpu-profile` — generic GPU, `scheduling.type: Node`, GPU toleration only, no Kueue dependency.
  - `gpu-kueue-profile` — `scheduling.type: Queue`; requires Kueue and a `LocalQueue` named `default` in the workload namespace.
  - `nvidia-a10g-profile` — `scheduling.type: Node` with `nodeSelector: nvidia.com/gpu.product: NVIDIA-A10G`; use on mixed-GPU clusters to pin to A10G nodes.
- **Re-applying LLMInferenceService drops unlisted env vars:** `oc apply` uses strategic merge patch — the `env` list is replaced, not merged. Any env var absent from the rendered YAML (including `VLLM_ADDITIONAL_ARGS`) is silently removed. Always pass the per-model values file with `-f` on every `helm template … | oc apply`.
- **`LLMInferenceService` API version:** The inference chart generates `apiVersion: serving.kserve.io/v1alpha2`. Resources applied with `v1alpha1` will not show the MaaS toggle or other advanced fields in the RHOAI dashboard edit form.
- **GPU update strategy — not configurable via CRD:** The scheduler Deployment is always `Recreate`; the main workload is always `RollingUpdate`. The `updateStrategy` value in the inference chart is silently dropped by the API server.
- **`maas.enabled` in per-model values files:** Set `maas.enabled: false` when deploying in Phase 5 (llm-d only). Setting it `true` before the MaaS gateway and Kuadrant policies are in place (Phase 6) triggers reconcile errors in the maas-controller and does not enable MaaS. Flip it to `true` only during Phase 6 when publishing the model to MaaS.
- For OCI model images (`registry.redhat.io/rhelai1/...`), ensure the cluster pull secret includes Red Hat registry credentials.
- For MoE models (DeepSeek-R1, Mixtral), use the **Wide Expert-Parallelism** well-lit path which requires LeaderWorkerSet for multi-node orchestration.
- **Model Registry / model-catalog API 500:** If migrations did not apply, restart model-catalog: `oc rollout restart deployment/model-catalog -n rhoai-model-registries` (README Appendix B).
- **Duplicate `VLLM_ADDITIONAL_ARGS` env var:** The inference chart auto-generates `VLLM_ADDITIONAL_ARGS` from `vllm.extraArgs`. Setting it again via `env` causes a duplicate-env admission error. Always use `vllm.extraArgs` in per-model values files instead of `env: [{name: VLLM_ADDITIONAL_ARGS, ...}]`.
- **Perses dashboards not visible in the console:** Three requirements must all be met: (1) a `UIPlugin` CR of type `Dashboards` must exist, (2) a `UIPlugin` CR of type `Monitoring` with `monitoring.perses.enabled: true` must exist, and (3) `PersesDashboard` CRs must be in the `openshift-cluster-observability-operator` namespace with label `app.kubernetes.io/part-of: monitoring`. Missing any one causes the dashboards to silently not appear.

---

## Verify intelligent routing (recommended)

Run the verification script to confirm EPP scheduler is making routing decisions and prefix cache is operational:

```bash
./scripts/verify-intelligent-router.sh
```

**Expected output:**
- 20/20 requests return HTTP 200
- Prefix cache queries increase by ~680 tokens
- Prefix cache hits increase by ~640 tokens (~94% hit rate)
- EPP logs show 20 "Request handled" routing decisions with selected endpoints

**What this proves:**
- Gateway routes through InferencePool (not basic Service LB)
- EPP scheduler making per-request routing decisions via gRPC
- Prefix cache optimization active (94% hit rate)
- Full llm-d intelligent routing stack operational

For detailed explanation, architecture diagrams, troubleshooting, and multi-replica testing, see: [llm-d Intelligent Routing Verification Guide](../../LLMD-INTELLIGENT-ROUTING-VERIFICATION.md)

---

## Verify monitoring integration (MANDATORY if User Workload Monitoring is enabled)

The inference chart automatically creates ServiceMonitors. Verify they are scraping metrics:

```bash
# 1. Check ServiceMonitors were created
oc get servicemonitor -n <namespace> -l app.kubernetes.io/name=<serviceName>
# Expected for intelligent-inference: 2 ServiceMonitors (workload + EPP)
# Expected for P/D disaggregation: 1 ServiceMonitor (workload only)

# 2. Verify Prometheus targets are healthy
oc port-forward -n openshift-user-workload-monitoring prometheus-user-workload-0 9090:9090 &
# Open http://localhost:9090/targets and search for your namespace
# Expected: State: UP for all targets

# 3. Send test traffic to generate metrics
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

# 4. Wait for Prometheus to scrape (30s)
sleep 30

# 5. Query cache hit rate
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -- \
  curl -s 'http://localhost:9090/api/v1/query?query=vllm:prefix_cache_hits_total/vllm:prefix_cache_queries_total*100' | \
  jq -r '.data.result[] | select(.metric.namespace=="<namespace>") | "Cache Hit Rate: \(.value[1] | tonumber | floor)%"'
# Expected for intelligent-inference: 50-90% cache hit rate
```

**What this proves:**
- ServiceMonitors created automatically with model deployment
- Prometheus scraping vLLM metrics
- Prefix caching enabled and working (hit rate > 0%)
- Metrics pipeline functional

**Troubleshooting:**
- **0% cache hit rate:** Verify prefix caching is enabled in the pod:
  ```bash
  POD=$(oc get pods -n <namespace> -l llm-d.ai/role=both -o jsonpath='{.items[0].metadata.name}')
  oc exec -n <namespace> $POD -c main -- ps aux | grep "enable-prefix-caching"
  # Expected: --enable-prefix-caching in the command line
  ```
  If missing, the pod was deployed with an old chart version. Re-deploy with the current chart (prefix caching is auto-enabled for intelligent-inference).

- **No metrics in Prometheus:** Check User Workload Monitoring is enabled (see pre-flight checks above).

For complete monitoring setup and troubleshooting, see: [LLM-D-MONITORING-INTEGRATION.md](../../gitops/instance/llm-d-observability/LLM-D-MONITORING-INTEGRATION.md)

---

**End of Phase 5:** Stop here and report the llm-d Quick Start test results to the user. Show:
1. Chat completion response (model is responding)
2. Intelligent routing verification (EPP + prefix cache working)
3. Monitoring verification (ServiceMonitors + metrics flowing)

Wait for confirmation before proceeding to [Phase 6](06-maas.md).
