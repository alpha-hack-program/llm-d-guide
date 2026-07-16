# MaaS Demo — Token Rate Limiting

> **Prerequisites:** [Phase 6 (MaaS)](../../README.md#9-model-as-a-service-maas) must be complete and `qwen3-8b` must be `Ready` via MaaS.
>
> See also: [ExternalModel MaaS Demo](external-model-demo.md) | [Full MaaS Reset](maas-reset.md)

A self-contained walkthrough showing token rate-limit enforcement across three tiers, and live tier migration.

**Tier layout:**

| Tier | Group | User | Limit | Window | Effect |
|---|---|---|---|---|---|
| freemium | `freemium-users` | charlie | 300 tokens | 5 min | Exhausted after ~3 short requests |
| pro | `pro-users` | bob | 3 000 tokens | 5 min | ~30 requests — not exhausted in demo |
| premium | `premium-users` | alice | 30 000 tokens | 5 min | Effectively unlimited |

5-minute windows make the demo repeatable — limits reset without any manual cleanup.

## Setup (one-time)

```bash
OCP_API=$(oc whoami --show-server)
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
MAAS_GW="maas.${CLUSTER_DOMAIN}"
SECRET_NAME=$(oc get oauth cluster \
  -o jsonpath='{.spec.identityProviders[?(@.type=="HTPasswd")].htpasswd.fileData.name}')
```

**Add users to htpasswd** — `scripts/add-htpasswd-user.sh` outputs a single bcrypt htpasswd line, ready for scripting:

```bash
# Download the current htpasswd file
oc get secret "${SECRET_NAME}" -n openshift-config \
  -o jsonpath='{.data.htpasswd}' | base64 -d > /tmp/htpasswd.current

# Disable bash history expansion — required when passwords contain '!'
set +H

# Generate and append entries for each user
for SPEC in "alice:Alice1234!" "bob:Bob1234!" "charlie:Charlie1234!"; do
  USER="${SPEC%%:*}" PASS="${SPEC##*:}"
  grep -v "^${USER}:" /tmp/htpasswd.current > /tmp/htpasswd.new 2>/dev/null || true
  ./scripts/add-htpasswd-user.sh "${USER}" "${PASS}" >> /tmp/htpasswd.new
  mv /tmp/htpasswd.new /tmp/htpasswd.current
done

set -H

# Update the secret and restart OAuth (~30 s)
echo "Update secret: ${SECRET_NAME} in namespace: openshift-config with file: /tmp/htpasswd.current"
cat /tmp/htpasswd.current
```

**Create OCP groups and assign users:**

```bash
oc adm groups new freemium-users 2>/dev/null || true
oc adm groups new pro-users      2>/dev/null || true
oc adm groups new premium-users  2>/dev/null || true
oc adm groups add-users freemium-users charlie
oc adm groups add-users pro-users      bob
oc adm groups add-users premium-users  alice
```

**Ensure the `MaaSModelRef` for `qwen3-8b` exists:**

The `MaaSSubscription` controller resolves model references at creation time — if the
`MaaSModelRef` is missing the subscriptions enter `Failed` phase immediately.

The inference chart creates it automatically when `maas.enabled=true`. Re-apply the chart if
starting from a clean slate (e.g. after the [full MaaS reset](maas-reset.md)):

```bash
helm template inference gitops/instance/llm-d/inference \
  -n llm-d-demo \
  -f gitops/instance/llm-d/inference/qwen3-8b-values.yaml \
  --set maas.enabled=true \
  | oc apply -n llm-d-demo -f -
oc wait maasmodelref/qwen3-8b -n llm-d-demo --for=jsonpath='{.status.phase}'=Ready --timeout=60s
```

**Create MaaSSubscriptions (one per tier):**

```bash
cat <<'EOF' | oc apply -f -
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: freemium-subscription
  namespace: models-as-a-service
spec:
  priority: 1
  owner:
    groups:
      - name: freemium-users
  modelRefs:
    - name: qwen3-8b
      namespace: llm-d-demo
      tokenRateLimits:
        - limit: 300
          window: 5m
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: pro-subscription
  namespace: models-as-a-service
spec:
  priority: 2
  owner:
    groups:
      - name: pro-users
  modelRefs:
    - name: qwen3-8b
      namespace: llm-d-demo
      tokenRateLimits:
        - limit: 3000
          window: 5m
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: premium-subscription
  namespace: models-as-a-service
spec:
  priority: 3
  owner:
    groups:
      - name: premium-users
  modelRefs:
    - name: qwen3-8b
      namespace: llm-d-demo
      tokenRateLimits:
        - limit: 30000
          window: 5m
EOF
```

**Create MaaSAuthPolicies (one per tier):**

```bash
cat <<'EOF' | oc apply -f -
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: freemium-auth-policy
  namespace: models-as-a-service
spec:
  subjects:
    groups:
      - name: freemium-users
  modelRefs:
    - name: qwen3-8b
      namespace: llm-d-demo
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: pro-auth-policy
  namespace: models-as-a-service
spec:
  subjects:
    groups:
      - name: pro-users
  modelRefs:
    - name: qwen3-8b
      namespace: llm-d-demo
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: premium-auth-policy
  namespace: models-as-a-service
spec:
  subjects:
    groups:
      - name: premium-users
  modelRefs:
    - name: qwen3-8b
      namespace: llm-d-demo
EOF
```

**Verify Kuadrant translated the subscriptions into TokenRateLimitPolicies:**

```bash
oc get tokenratelimitpolicy -n llm-d-demo
# Expected: maas-trlp-qwen3-8b
```

```bash
$ oc get tokenratelimitpolicy maas-trlp-qwen3-8b -n llm-d-demo -o yaml
apiVersion: kuadrant.io/v1alpha1
kind: TokenRateLimitPolicy
metadata:
  annotations:
    maas.opendatahub.io/subscriptions: admin-subscription,freemium-subscription,premium-subscription,pro-subscription
  labels:
    app.kubernetes.io/component: token-rate-limit-policy
    app.kubernetes.io/managed-by: maas-controller
    app.kubernetes.io/part-of: maas-subscription
    maas.opendatahub.io/model: qwen3-8b
    maas.opendatahub.io/model-namespace: llm-d-demo
  name: maas-trlp-qwen3-8b
  namespace: llm-d-demo
  ...
spec:
  limits:
    models-as-a-service-admin-subscription-qwen3-8b-tokens:
      counters:
      - expression: auth.identity.userid
      rates:
      - limit: 100000
        window: 1h
      when:
      - predicate: auth.identity.selected_subscription_key == "models-as-a-service/admin-subscription@llm-d-demo/qwen3-8b"
          && !request.path.endsWith("/v1/models")
    models-as-a-service-freemium-subscription-qwen3-8b-tokens:
      counters:
      - expression: auth.identity.userid
      rates:
      - limit: 300
        window: 5m
      when:
      - predicate: auth.identity.selected_subscription_key == "models-as-a-service/freemium-subscription@llm-d-demo/qwen3-8b"
          && !request.path.endsWith("/v1/models")
    models-as-a-service-premium-subscription-qwen3-8b-tokens:
      counters:
      - expression: auth.identity.userid
      rates:
      - limit: 30000
        window: 5m
      when:
      - predicate: auth.identity.selected_subscription_key == "models-as-a-service/premium-subscription@llm-d-demo/qwen3-8b"
          && !request.path.endsWith("/v1/models")
    models-as-a-service-pro-subscription-qwen3-8b-tokens:
      counters:
      - expression: auth.identity.userid
      rates:
      - limit: 3000
        window: 5m
      when:
      - predicate: auth.identity.selected_subscription_key == "models-as-a-service/pro-subscription@llm-d-demo/qwen3-8b"
          && !request.path.endsWith("/v1/models")
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: qwen3-8b-kserve-route
status:
  conditions:
  - lastTransitionTime: "2026-05-20T10:37:26Z"
    message: TokenRateLimitPolicy has been accepted
    reason: Accepted
    status: "True"
    type: Accepted
  - lastTransitionTime: "2026-05-20T17:58:55Z"
    message: TokenRateLimitPolicy has been successfully enforced
    reason: Enforced
    status: "True"
    type: Enforced
  observedGeneration: 4
```

**Obtain OCP tokens and create API keys — one terminal per user:**

Each user gets their own kubeconfig so the admin session is never interrupted.

**Admin terminal — resolve cluster coordinates first:**
```bash
OCP_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
OCP_API="https://api.${OCP_DOMAIN#apps.}:6443"
MAAS_GW="maas.${OCP_DOMAIN}"
printf 'OCP_API="%s"\nMAAS_GW="%s"\n' "${OCP_API}" "${MAAS_GW}"
```

Copy the two printed lines and paste them at the top of each user terminal below.

**Terminal — alice:**
```bash
OCP_API="<paste value>"
MAAS_GW="<paste value>"
export KUBECONFIG=~/.kube/config-34GA-alice
oc login --username=alice --password='Alice1234!' "${OCP_API}"
ALICE_TOKEN=$(oc whoami -t)
ALICE_KEY=$(curl -sk -X POST "https://${MAAS_GW}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"alice-demo-key","expiresInDays":1}' \
  | jq -re '.key')
echo "export ALICE_KEY=${ALICE_KEY}"
```

**Terminal — bob:**
```bash
OCP_API="<paste value>"
MAAS_GW="<paste value>"
export KUBECONFIG=~/.kube/config-34GA-bob
oc login --username=bob --password='Bob1234!' "${OCP_API}"
BOB_TOKEN=$(oc whoami -t)
BOB_KEY=$(curl -sk -X POST "https://${MAAS_GW}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer ${BOB_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"bob-demo-key","expiresInDays":1}' \
  | jq -re '.key')
echo "export BOB_KEY=${BOB_KEY}"
```

**Terminal — charlie:**
```bash
OCP_API="<paste value>"
MAAS_GW="<paste value>"
export KUBECONFIG=~/.kube/config-34GA-charlie
oc login --username=charlie --password='Charlie1234!' "${OCP_API}"
CHARLIE_TOKEN=$(oc whoami -t)
CHARLIE_KEY=$(curl -sk -X POST "https://${MAAS_GW}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer ${CHARLIE_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"charlie-demo-key","expiresInDays":1}' \
  | jq -re '.key')
echo "export CHARLIE_KEY=${CHARLIE_KEY}"
```

**Admin terminal — paste the three export lines printed above, then set demo variables:**
```bash
OCP_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
MAAS_GW="maas.${OCP_DOMAIN}"
# paste export ALICE_KEY=... BOB_KEY=... CHARLIE_KEY=... here
```

## Demo Run

Run everything below in the **admin terminal** (the one where you pasted the `export *_KEY=` lines).

**Set demo variables (admin terminal):**
```bash
OCP_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
MAAS_GW="maas.${OCP_DOMAIN}"
# paste the export lines printed by each user terminal:
export ALICE_KEY="sk-oai-..."
export BOB_KEY="sk-oai-..."
export CHARLIE_KEY="sk-oai-..."
```

Define the helper in **each** user terminal before running the acts (MAAS_GW is already set there from setup):

```bash
call_model() {
  local KEY="$1" LABEL="$2"
  local HTTP
  HTTP=$(curl -sk -o /tmp/maas_resp.json -w "%{http_code}" \
    "https://${MAAS_GW}/llm-d-demo/qwen3-8b/v1/chat/completions" \
    -H "Authorization: Bearer ${KEY}" \
    -H "Content-Type: application/json" \
    -d '{"model":"alibaba/qwen3-8b","messages":[{"role":"user","content":"Say hi in exactly one sentence."}],"max_tokens":30}')
  if [[ "${HTTP}" == "429" ]]; then
    echo "  [${LABEL}] 429 — rate limit hit, quota exhausted"
    return 1
  fi
  TOKENS=$(jq -r '.usage.total_tokens // "?"' /tmp/maas_resp.json 2>/dev/null || echo "?")
  echo "  [${LABEL}] ${HTTP} OK — ${TOKENS} tokens"
}
```

**Act 1 — Charlie (freemium) exhausts quota:**

*Terminal — charlie:*
```bash
echo "=== Act 1: Charlie (freemium, 300 tokens / 5 min) ==="
COUNT=0
while call_model "${CHARLIE_KEY}" "charlie/freemium req $((++COUNT))"; do
  sleep 1
done
echo "Charlie is locked out."
```

Expected: fails after 3-4 calls as the 300-token window fills.

**Act 2 — Bob (pro) and Alice (premium) for contrast:**

*Terminal — bob:*
```bash
echo "=== Act 2: Bob (pro) ==="
for i in 1 2 3 4 5; do
  call_model "${BOB_KEY}" "bob/pro req ${i}"
  sleep 1
done
```

*Terminal — alice:*
```bash
echo "=== Act 2: Alice (premium) ==="
for i in 1 2 3 4 5; do
  call_model "${ALICE_KEY}" "alice/premium req ${i}"
  sleep 1
done
```

**Act 3 — Migrate Charlie: freemium -> pro:**

*Admin terminal — move charlie to the pro group:*
```bash
echo "=== Act 3: Migrating charlie from freemium to pro ==="
oc adm groups remove-users freemium charlie
oc adm groups add-users pro charlie
```

*Terminal — charlie — revoke the old freemium key, then create a new one bound to pro-subscription:*
```bash
# Keys are bound to a subscription at creation time — the old freemium key would still
# enforce freemium limits even after the group change. Revoke it first.
CHARLIE_KEY_ID=$(curl -sk -X POST "https://${MAAS_GW}/maas-api/v1/api-keys/search" \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{"data":{"filters":{},"sort":{"by":"created_at","order":"desc"},"pagination":{"limit":50,"offset":0}}}' \
  | jq -re '[.data[] | select(.name == "charlie-demo-key")][0].id')
curl -sk -X DELETE "https://${MAAS_GW}/maas-api/v1/api-keys/${CHARLIE_KEY_ID}" \
  -H "Authorization: Bearer $(oc whoami -t)"

CHARLIE_PRO_KEY=$(curl -sk -X POST "https://${MAAS_GW}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{"name":"charlie-pro-key","expiresInDays":1}' \
  | jq -re '.key')
echo "export CHARLIE_PRO_KEY=${CHARLIE_PRO_KEY}"
```

*Admin terminal — paste the export line printed above:*
```bash
export CHARLIE_PRO_KEY="sk-oai-..."
```

**Act 4 — Charlie (pro) succeeds:**

*Terminal — charlie:*
```bash
echo "=== Act 4: Charlie (now pro, 3000 tokens / 5 min) ==="
for i in 1 2 3 4 5; do
  call_model "${CHARLIE_PRO_KEY}" "charlie/pro req ${i}"
  sleep 1
done
echo "Charlie is no longer rate-limited."
```

> **Key lifecycle note:** API keys are bound to a subscription **at creation time**. Moving a user
> to a different group does not invalidate existing keys or change their rate limits — the old key
> keeps working under its original subscription until it expires or is explicitly revoked.
> This means a tier downgrade requires two steps: remove the user from the higher-tier group
> **and** revoke their existing keys. Only then will new keys bind to the lower-tier subscription.
>
> To revoke a key by ID (admin terminal):
> ```bash
> curl -sk -X DELETE "https://${MAAS_GW}/maas-api/v1/api-keys/<key-id>" \
>   -H "Authorization: Bearer $(oc whoami -t)"
> # Returns the key object with "status": "revoked"; subsequent requests with it get 403.
> ```

## Reset / Cleanup

**Repeat the demo** — wait 5 minutes for the token windows to expire, re-export the API keys, and run from Act 1.

**Full cleanup:**

```bash
# Delete API keys (use IDs from key creation responses)
for KEY in "${ALICE_KEY}" "${BOB_KEY}" "${CHARLIE_KEY}" "${CHARLIE_PRO_KEY}"; do
  KEY_ID=$(curl -sk -X POST "https://${MAAS_GW}/maas-api/v1/api-keys/search" \
    -H "Authorization: Bearer $(oc whoami -t)" \
    -H "Content-Type: application/json" \
    -d '{"data":{"filters":{},"sort":{"by":"created_at","order":"desc"},"pagination":{"limit":50,"offset":0}}}' \
    | python3 -c "
import json,sys
keys=[k for k in json.load(sys.stdin).get('data',[]) if k.get('keyPrefix','') in '${KEY}']
print(keys[0]['id'] if keys else '')" 2>/dev/null || true)
  [[ -n "${KEY_ID}" ]] && curl -sk -X DELETE \
    "https://${MAAS_GW}/maas-api/v1/api-keys/${KEY_ID}" \
    -H "Authorization: Bearer $(oc whoami -t)"
done

# Remove MaaS CRs
oc delete maasauthpolicy freemium-auth-policy pro-auth-policy premium-auth-policy \
  -n models-as-a-service 2>/dev/null || true
oc delete maassubscription freemium-subscription pro-subscription premium-subscription \
  -n models-as-a-service 2>/dev/null || true

# Remove groups and users
oc delete group freemium-users pro-users premium-users 2>/dev/null || true
# oc delete user alice bob charlie 2>/dev/null || true
# oc delete identity --all 2>/dev/null || true   # clears IdP-linked identity objects
```

For a complete wipe of all demo state, see [Full MaaS Reset](maas-reset.md).
