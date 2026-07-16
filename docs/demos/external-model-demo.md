# ExternalModel MaaS Demo

> **Prerequisites:** [Phase 6 (MaaS)](../../README.md#9-model-as-a-service-maas) must be complete. The `premium-users` group and `alice` user from the [MaaS Demo](maas-demo.md) are reused here; if you skipped that demo, the setup steps below create them.
>
> See also: [MaaS Demo](maas-demo.md) | [Full MaaS Reset](maas-reset.md)

An `ExternalModel` lets you publish any OpenAI-compatible API endpoint, through the same MaaS gateway, giving it identical API key auth, token rate limiting, and subscription controls as a native llm-d model. No GPU workload is deployed: the `ExternalModel` CR is just a pointer to an existing endpoint with an attached credential.

**Demo layout:**

| Tier | Group | User | Model | Limit | Window |
|---|---|---|---|---|---|
| premium | `premium-users` | alice | `qwen3-14b` (external) | 1 000 tokens | 1 h |

## 1. Prepare the model namespace

The `ExternalModel` and its credential Secret live in the same namespace used for llm-d inference services. This demo uses `llm-d-demo`, which is already in the MaaS gateway's allowed namespace list from Phase 6.

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
MODEL_NAMESPACE=llm-d-demo
```

> **Using a different namespace?** If you want to isolate the ExternalModel in its own namespace, create it first and then re-apply the gateway chart with the new namespace added to `gateway.modelNamespaces`:
>
> ```bash
> helm template gitops/instance/maas/gateway --name-template maas-gateway \
>   --set clusterDomain="${CLUSTER_DOMAIN}" \
>   --set useOpenShiftRoute=true \
>   --set tls.secretName=ingress-certs \
>   --set limitador.exhaustiveTelemetry=false \
>   --set telemetry.enabled=false \
>   --set "gateway.modelNamespaces={llm-d-demo,<YOUR_NAMESPACE>}" | oc apply -f -
> ```

Verify the Gateway listener has `llm-d-demo` (or your namespace) in its allowed routes:

```bash
oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.listeners[0].allowedRoutes}' | jq .
```

## Critical Requirements for ExternalModel

Before creating an ExternalModel, understand these **mandatory** constraints:

1. **MaaSModelRef name MUST match ExternalModel name exactly.**

   Unlike `LLMInferenceService` where the MaaSModelRef can have a different name, for ExternalModel the names must be identical. This is either intentional design or a known constraint - either way, it's mandatory for the system to work correctly.

   ```yaml
   # ExternalModel name
   metadata:
     name: qwen3-14b              # <- This name
   
   # MaaSModelRef MUST have the exact same name
   metadata:
     name: qwen3-14b              # <- MUST match
   ```

2. **Credential secret requires the label `inference.networking.k8s.io/bbr-managed: "true"`.**

   The `payload-processing` ext_proc service uses this label as a predicate — secrets without it are silently ignored and the credential store is never populated, causing every call to fail with `"provider 'openai' credentials not found"`.

3. **MaaSModelRef must be created manually.**

   Unlike `LLMInferenceService` which auto-creates the MaaSModelRef when `maas.enabled=true`, ExternalModel requires manual creation of the MaaSModelRef with the matching name.

## 2. Create the ExternalModel and credentials

Replace `<LITELLM_ENDPOINT>` with the hostname (no `https://`) of your OpenAI-compatible endpoint, and `<LITELLM_API_KEY>` with the API key that endpoint expects.

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: litellm-credentials
  namespace: ${MODEL_NAMESPACE}
  labels:
    inference.networking.k8s.io/bbr-managed: "true"
type: Opaque
stringData:
  api-key: "<LITELLM_API_KEY>"
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: qwen3-14b
  namespace: ${MODEL_NAMESPACE}
spec:
  provider: openai
  endpoint: <LITELLM_ENDPOINT>
  targetModel: qwen3-14b
  credentialRef:
    name: litellm-credentials
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: qwen3-14b
  namespace: ${MODEL_NAMESPACE}
spec:
  modelRef:
    kind: ExternalModel
    name: qwen3-14b
EOF
```

Wait for the `MaaSModelRef` to become Ready:

```bash
oc get maasmodelref qwen3-14b -n ${MODEL_NAMESPACE} -w
# Expected: Ready: True (the maas-controller creates an HTTPRoute and wires the gateway)
```

Check the HTTPRoute the maas-controller created:

```bash
oc get httproute -n ${MODEL_NAMESPACE}
# Expected: a route with parentRef maas-default-gateway and path /${MODEL_NAMESPACE}/qwen3-14b/*
```

## 3. Subscription and auth policy

```bash
cat <<EOF | oc apply -f -
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: external-premium-subscription
  namespace: models-as-a-service
spec:
  owner:
    groups:
      - name: premium-users
  modelRefs:
    - name: qwen3-14b
      namespace: ${MODEL_NAMESPACE}
      tokenRateLimits:
        - limit: 1000
          window: 1h
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: external-premium-auth-policy
  namespace: models-as-a-service
spec:
  subjects:
    groups:
      - name: premium-users
  modelRefs:
    - name: qwen3-14b
      namespace: ${MODEL_NAMESPACE}
EOF
```

Verify the `maas-controller` translated the subscription into a Kuadrant policy:

```bash
oc get tokenratelimitpolicy -n ${MODEL_NAMESPACE}
# Expected: maas-trlp-qwen3-14b   Accepted=True  Enforced=True
```

## 4. Ensure the `premium-users` group and `alice` exist

Skip this block if alice is already set up from the [MaaS Demo](maas-demo.md).

```bash
SECRET_NAME=$(oc get oauth cluster \
  -o jsonpath='{.spec.identityProviders[?(@.type=="HTPasswd")].htpasswd.fileData.name}')

oc get secret "${SECRET_NAME}" -n openshift-config \
  -o jsonpath='{.data.htpasswd}' | base64 -d > /tmp/htpasswd.current

grep -v "^alice:" /tmp/htpasswd.current > /tmp/htpasswd.new 2>/dev/null || true
htpasswd -Bnb alice 'Alice1234!' >> /tmp/htpasswd.new

oc create secret generic "${SECRET_NAME}" -n openshift-config \
  --from-file=htpasswd=/tmp/htpasswd.new \
  --dry-run=client -o yaml | oc apply -f -

oc adm groups new premium-users 2>/dev/null || true
oc adm groups add-users premium-users alice
```

## 5. Test — create an API key and call the model

**Resolve cluster coordinates:**

```bash
OCP_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
OCP_API="https://api.${OCP_DOMAIN#apps.}:6443"
MAAS_GW="maas.${OCP_DOMAIN}"
```

**Log in as alice and create an API key:**

```bash
export KUBECONFIG=~/.kube/config-ext-alice
oc login --username=alice --password='Alice1234!' "${OCP_API}"
ALICE_TOKEN=$(oc whoami -t)

ALICE_KEY=$(curl -sk -X POST "https://${MAAS_GW}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"alice-ext-key","subscription":"external-premium-subscription","expiresInDays":90}' \
  | jq -re '.key')
echo "ALICE_KEY=${ALICE_KEY}"
```

**Call the external model:**

The MaaS gateway path for an ExternalModel is `/{namespace}/{ExternalModel-name}/v1/...` (not the MaaSModelRef name):

```bash
curl -sk "https://${MAAS_GW}/${MODEL_NAMESPACE}/qwen3-14b/v1/chat/completions" \
  -H "Authorization: Bearer ${ALICE_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-14b",
    "messages": [{"role": "user", "content": "What is the capital of France?"}],
    "max_tokens": 50
  }' | jq '{status: .choices[0].finish_reason, tokens: .usage.total_tokens, reply: .choices[0].message.content}'
```

Expected response:

```json
{
  "status": "stop",
  "tokens": 42,
  "reply": "The capital of France is Paris."
}
```

**Verify rate limiting is active** — fire enough calls to approach the 1 000-token/h window:

```bash
for i in $(seq 1 20); do
  HTTP=$(curl -sk -o /tmp/ext_resp.json -w "%{http_code}" \
    "https://${MAAS_GW}/${MODEL_NAMESPACE}/qwen3-14b/v1/chat/completions" \
    -H "Authorization: Bearer ${ALICE_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen3-14b","messages":[{"role":"user","content":"Say hi in one sentence."}],"max_tokens":30}')
  TOKENS=$(jq -r '.usage.total_tokens // "—"' /tmp/ext_resp.json 2>/dev/null)
  echo "  req ${i}: HTTP ${HTTP} — ${TOKENS} tokens"
  [[ "${HTTP}" == "429" ]] && echo "Rate limit hit." && break
  sleep 1
done
```

## 6. Monitoring (Optional)

ExternalModels expose rate limiting metrics via Limitador (not vLLM). A Perses dashboard shows request rate, token usage, and rate limiting.

**Deploy:**

```bash
# Enable Prometheus scraping + deploy dashboard
oc label namespace kuadrant-system openshift.io/cluster-monitoring=true --overwrite
oc apply -f gitops/instance/llm-d-observability/limitador-servicemonitor.yaml
oc apply -f gitops/instance/llm-d-observability/perses-dashboard-external-models.yaml
```

**Access:** Console -> **Observe** -> **Dashboards** -> **"MaaS External Models"**

See [`EXTERNAL-MONITORING-INTEGRATION.md`](../../gitops/instance/llm-d-observability/EXTERNAL-MONITORING-INTEGRATION.md) for technical details.

## 7. Cleanup

```bash
# Delete MaaS CRs
oc delete maasauthpolicy external-premium-auth-policy -n models-as-a-service 2>/dev/null || true
oc delete maassubscription external-premium-subscription -n models-as-a-service 2>/dev/null || true
oc delete maasmodelref qwen3-14b -n ${MODEL_NAMESPACE} 2>/dev/null || true
oc delete externalmodel qwen3-14b -n ${MODEL_NAMESPACE} 2>/dev/null || true
oc delete secret litellm-credentials -n ${MODEL_NAMESPACE} 2>/dev/null || true
# Also removes the HTTPRoute created by the maas-controller:
oc delete httproute qwen3-14b -n ${MODEL_NAMESPACE} 2>/dev/null || true
```

For a complete wipe of all demo state, see [Full MaaS Reset](maas-reset.md).
