# ExternalModel Monitoring Integration

Technical reference for monitoring ExternalModel endpoints via Limitador metrics.

## Overview

ExternalModels do not run local workloads, so they have no vLLM/GPU metrics. Instead, they expose **rate limiting and authorization metrics** via Kuadrant's Limitador service.

## Architecture

```
ExternalModel API calls
    ↓
MaaS Gateway (maas-default-gateway)
    ↓
Authorino (auth) + Limitador (rate limiting)
    ↓
Limitador exports metrics at :8080/metrics
    ↓
Prometheus scrapes via ServiceMonitor
    ↓
Perses dashboard queries Prometheus
```

## Metrics Available

| Metric | Type | Description | Labels |
|--------|------|-------------|--------|
| `authorized_calls` | counter | Total authorized API calls | `user`, `limitador_namespace` |
| `authorized_hits` | counter | Total tokens consumed | `user`, `model`, `limitador_namespace` |
| `limited_calls` | counter | Requests rejected (HTTP 429) | `user`, `limitador_namespace`, `limit_name` |
| `limitador_up` | gauge | Service health (1=up, 0=down) | - |
| `datastore_partitioned` | gauge | Datastore status (0=ok, 1=partitioned) | - |

**Metrics endpoint:** `http://limitador-limitador.kuadrant-system.svc:8080/metrics`

## Filtering ExternalModels vs LLMInferenceService

Both ExternalModels and MaaS-enabled LLMInferenceServices appear in Limitador metrics with the same label structure.

**HTTPRoute naming pattern:**
- ExternalModel: `limitador_namespace="maas-demo/qwen3-14b"` (HTTPRoute name = ExternalModel name)
- LLMInferenceService: `limitador_namespace="maas-demo/qwen3-8b-maas-kserve-route"` (has `-kserve-route` suffix)

**Filter for ExternalModels only:**
```promql
authorized_calls{limitador_namespace=~"maas-demo/.*",limitador_namespace!~".*-kserve-route"}
```

## Prometheus Integration

### Requirements

1. **Namespace label** - Prometheus only scrapes namespaces with `openshift.io/cluster-monitoring=true`:
   ```bash
   oc label namespace kuadrant-system openshift.io/cluster-monitoring=true
   ```

2. **ServiceMonitor** - Tells Prometheus where to scrape Limitador:
   ```yaml
   apiVersion: monitoring.coreos.com/v1
   kind: ServiceMonitor
   metadata:
     name: limitador-metrics
     namespace: kuadrant-system
   spec:
     selector:
       matchLabels:
         app: limitador
     endpoints:
     - port: http
       path: /metrics
       interval: 30s
   ```

### Dashboard Queries

All queries use `rate()` over 5-minute windows for trend analysis:

**Request Rate (req/s):**
```promql
sum(rate(authorized_calls{limitador_namespace=~"maas-demo/.*",limitador_namespace!~".*-kserve-route"}[5m])) by (limitador_namespace)
```

**Token Rate (tok/s):**
```promql
sum(rate(authorized_hits{limitador_namespace=~"maas-demo/.*",limitador_namespace!~".*-kserve-route"}[5m])) by (limitador_namespace, model)
```

**Rate Limited Rate (429/s):**
```promql
sum(rate(limited_calls{limitador_namespace=~"maas-demo/.*",limitador_namespace!~".*-kserve-route"}[5m])) by (limitador_namespace, user)
```

## Known Behaviors

### Prometheus Naming Convention Warning

Limitador exports counters without the `_total` suffix (e.g., `authorized_calls` instead of `authorized_calls_total`). Prometheus shows warnings like:

```
PromQL info: metric might not be a counter, name does not end in _total
```

**This is expected and harmless.** The metrics are correctly typed as counters in Limitador's `/metrics` endpoint. Queries work correctly despite the warning.

### Metric Label Structure

The `limitador_namespace` label format is `{namespace}/{httproute-name}`, not `{namespace}/{maasmodelref-name}`. For ExternalModels, the HTTPRoute name matches the ExternalModel name (not the MaaSModelRef name, which can differ).

### Streaming Request Limitation

`TokenRateLimitPolicy` only counts tokens from non-streaming responses. Streaming requests (`stream: true`) bypass token counting - the quota is not decremented and limits are not enforced per-token. See [Kuadrant docs](https://docs.kuadrant.io/1.3.x/kuadrant-operator/doc/overviews/token-rate-limiting/) for details.

## Dashboard Panels

The Perses dashboard (`perses-dashboard-external-models.yaml`) provides:

1. **Request Rate (req/s)** - API call rate per external model
2. **Token Rate (tok/s)** - Token consumption rate (for cost tracking)
3. **Rate Limited Rate (429/s)** - HTTP 429 error rate (should be near zero)
4. **Limitador Status** - Service health gauge

## Comparison: ExternalModel vs LLMInferenceService Metrics

| Metric Source | ExternalModel | LLMInferenceService |
|---------------|---------------|---------------------|
| **vLLM metrics** (TTFT, latency, GPU) | ❌ No | ✅ Yes |
| **EPP scheduler metrics** | ❌ No | ✅ Yes |
| **Limitador metrics** (auth, rate limits) | ✅ Yes | ✅ Yes (if MaaS enabled) |
| **Prometheus scraping** | Via ServiceMonitor in kuadrant-system | Via ServiceMonitor in model namespace |
| **Dashboard** | MaaS External Models | llm-d Performance / Intelligent Inference |

## Troubleshooting

**No data in dashboard:**
1. Check namespace label: `oc get namespace kuadrant-system -o jsonpath='{.metadata.labels.openshift\.io/cluster-monitoring}'`
2. Verify ServiceMonitor exists: `oc get servicemonitor limitador-metrics -n kuadrant-system`
3. Check Prometheus targets: Console → Observe → Targets → search "limitador"
4. Verify metrics endpoint: `oc exec -n kuadrant-system deployment/limitador-limitador -- curl -s localhost:8080/metrics | grep authorized_calls`

**Dashboard shows LLMInferenceService data:**
- Verify queries include the filter: `limitador_namespace!~".*-kserve-route"`

**Prometheus warnings about metric names:**
- Expected behavior - Limitador uses non-standard naming but metrics work correctly
