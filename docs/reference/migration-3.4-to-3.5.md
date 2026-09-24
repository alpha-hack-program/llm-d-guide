# Migration Notes — RHOAI 3.4 → 3.5

These notes document breaking changes, required actions, and gotchas discovered during the validated upgrade from RHOAI 3.4 to 3.5 on OCP 4.21.

---

## Breaking changes

### TrustyAI now required for Gen AI Studio playground (RHOAI 3.5.1+)

Starting in RHOAI 3.5.1, `gen-ai-ui` requires the `nemoguardrails.trustyai.opendatahub.io` CRD to exist. If TrustyAI is `Removed` in the DSC, the playground returns HTTP 500 on every chat request. Set `trustyai.managementState: Managed` in the DSC — the CRD is sufficient, no guardrails need to be configured. See [MaaS Troubleshooting](maas-troubleshooting.md#gen-ai-studio-playground-500--missing-trustyai--nemoguardrails-crds-rhoai-351) for details.

### DSC v2 API — MaaS field migration

The MaaS toggle moved from `kserve.modelsAsService` to `aigateway.modelsAsAService`. The old field is deprecated but respected through RHOAI 3.6.

```yaml
# 3.4 (deprecated)
kserve:
  modelsAsService:
    managementState: Managed

# 3.5 (new)
aigateway:
  managementState: Managed
  modelsAsAService:
    managementState: Managed
```

**Action:** Re-apply the RHOAI instance chart (`helm template rhoai ./gitops/instance/rhoai | oc apply -f -`). The updated chart uses `aigateway.modelsAsAService`. A dry-run warning confirms the old field is deprecated but still functional.

### DSC v2 API — new and renamed components

| 3.4 component | 3.5 replacement | Notes |
|---|---|---|
| `llamastackoperator` | `ogx` | OGX replaces LlamaStack |
| — | `trainer` | New (default: Removed) |
| — | `mcplifecycleoperator` | New (default: Removed) |
| — | `aigateway` | New — hosts `modelsAsAService` |
| — | `mlflowoperator` | New — MLflow operator + instance CR |

### ExternalModel API group and spec redesign

`ExternalModel` and `ExternalProvider` moved from `maas.opendatahub.io/v1alpha1` to `inference.opendatahub.io/v1alpha1`. The spec was restructured into a two-resource pattern:

```yaml
# 3.4 (single resource — auto-migrated, non-functional in 3.5)
apiVersion: maas.opendatahub.io/v1alpha1
kind: ExternalModel
spec:
  credentialRef:
    name: my-credentials
  endpoint: api.example.com
  provider: openai
  targetModel: my-model

# 3.5 (two resources)
apiVersion: inference.opendatahub.io/v1alpha1
kind: ExternalProvider
spec:
  provider: openai
  endpoint: api.example.com
  auth:
    type: apikey
    secretRef:
      name: my-credentials
---
apiVersion: inference.opendatahub.io/v1alpha1
kind: ExternalModel
spec:
  externalProviderRefs:
  - ref:
      name: my-provider
    targetModel: my-model
    apiFormat: openai-chat
    path: /v1/chat/completions
    weight: 100
```

Old `maas.opendatahub.io` ExternalModels are auto-migrated by the `ipp-legacy-migration` controller — they show `status.phase: Migrated`. The migrated resources have ownerReferences back to the old CR, so deleting the old one cascade-deletes the auto-migrated resources.

**Credential secret changes:**
- Label: `inference.networking.k8s.io/bbr-managed` → `inference.llm-d.ai/ipp-managed`
- Data field: the gateway reads `api-key` (not `OPENAI_API_KEY`)

**Action:** Delete old ExternalModels, update secret labels/fields, recreate with `inference.opendatahub.io/v1alpha1`. See [ExternalModel Guide](external-models.md) for the full migration procedure.

### EPP API group rename

The `EndpointPickerConfig` and `InferenceObjective` API group changed:

```
inference.networking.x-k8s.io/v1alpha1  →  llm-d.ai/v1alpha1
```

Both CRDs exist on the cluster during transition, but new deployments must use `llm-d.ai`. The inference chart template has been updated.

### EPP metrics prefix

The EPP metrics prefix changed from `inference_extension_` to `llm_d_epp_`. Update any custom Prometheus dashboards, alerts, or Grafana panels that reference the old prefix.

---

## MaaS infrastructure namespace change

The MaaS infrastructure namespace moved from `redhat-ods-applications` to `redhat-ai-gateway-infra`. The `maas-db-config` secret, `maas-api` deployment, and `maas-api-route` HTTPRoute all live in this new namespace.

**Impact on upgrades:** The MaaS gateway's `allowedRoutes` must include `redhat-ai-gateway-infra`. Gateways deployed from the 3.4 chart only allow `redhat-ods-applications`, causing the `maas-api-route` HTTPRoute to be rejected with `NotAllowedByListeners`. The MaaS API returns 404 for all paths (`/v1/api-keys`, `/v1/models`, etc.).

**Fix:** Re-apply the MaaS gateway chart — the 3.5 chart includes the new namespace:

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
helm template gitops/instance/maas/gateway --name-template maas-gateway \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --set useOpenShiftRoute=true \
  --set tls.secretName=ingress-certs \
  --set "gateway.modelNamespaces={llm-d-demo}" | oc apply -f -
```

Verify the HTTPRoute is accepted:

```bash
oc get httproute maas-api-route -n redhat-ai-gateway-infra \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'
# Expected: True
```

### Tenant CR deprecation

The `Tenant` CR is deprecated in 3.5 — it will be replaced by `AITenant` + `MaasTenantConfig` in a future release. The `Tenant` CR still works in 3.5; no action required yet.

---

## vLLM changes

### Access-log flag deprecation

`--disable-uvicorn-access-log` is deprecated in favor of `--disable-access-log-for-endpoints=/health,/metrics,/ping`. The old flag still works on vLLM 0.18.0 (generates a `Found duplicate keys` warning) but may be removed in a future release. All per-model values files in the chart have been updated.

### New EPP scheduler scorers

The default EPP scheduler adds two new scorers alongside the existing ones:

| Scorer | Weight | New in 3.5 |
|---|---|---|
| `prefix-cache-scorer` | 3.0 | No (weight changed from 2.0) |
| `queue-scorer` | 2.0 | No (weight changed from 1.0) |
| `kv-cache-utilization-scorer` | 1.0 | Yes |
| `no-hit-lru-scorer` | 1.0 | Yes |

No action required unless you use a custom scorer configuration.

---

## OLMv1 support (OCP 4.21+)

RHOAI 3.5 on OCP 4.21 supports both OLMv0 and OLMv1. Each operator directory ships both `operator.yaml` (OLMv0) and `cluster-extension.yaml` (OLMv1). Helm charts accept `--set olmVersion=v1`.

### AllNamespaces install mode constraint

OLMv1 `ClusterExtension` only works with bundles that support `AllNamespaces` install mode. Three operators in this guide do **not** — their bundles are limited to `OwnNamespace`:

| Operator | OLMv1 compatible | Install method on 4.21+ |
|---|---|---|
| NFD | No | `install.sh` (always OLMv0) |
| NVIDIA GPU Operator | No | `install.sh` (always OLMv0) |
| LeaderWorkerSet | No | `oc apply -k` (always OLMv0) |

The `install.sh` scripts for NFD and NVIDIA always use OLMv0 regardless of OCP version. The `cluster-extension.yaml` files are kept for forward compatibility.

### In-place OLMv0 → OLMv1 migration not supported

Operators installed via OLMv0 **cannot be migrated in-place to OLMv1**. OLMv1 uses Helm internally and refuses to adopt pre-existing resources (CRDs, ClusterRoles, Roles) it didn't create — each one fails individually with `"already exists and cannot be managed by operator-controller"`. Even after deleting all OLMv0 leftovers, the migration requires a full teardown including CRD deletion (which cascade-deletes all CR instances).

**If your cluster was installed with RHOAI 3.4 (OLMv0), keep all operators on OLMv0.** OLMv1 is only for fresh installs on OCP 4.21+. OLMv0 remains fully supported throughout the OCP 4 lifecycle.

### RHOAI 3.5 monitoring controller only detects operators via CSV

RHOAI 3.5's monitoring controller checks for Tempo and OpenTelemetry operators by looking for their CSV (OLMv0). Operators installed via OLMv1 (`ClusterExtension`) are invisible to this check — the monitoring precondition fails with `"Tempo operator must be installed for traces configuration"`, preventing TempoMonolithic creation. **Tempo and OpenTelemetry must use OLMv0** until RHOAI adds OLMv1 awareness.

### `crdUpgradeSafety` schema change

The `ClusterExtension` CRD schema changed the preflight safety field:

```yaml
# Old (fails with validation error on current OCP 4.21)
install:
  preflight:
    crdUpgradeSafety:
      disabled: false

# New (correct)
install:
  preflight:
    crdUpgradeSafety:
      enforcement: Strict    # or None to disable
```

All `cluster-extension.yaml` files in this guide have been updated. If you have custom ClusterExtension resources, update them to use `enforcement` instead of `disabled`.

See [OLMv1 Migration Reference](olmv1-migration.md) for full details.

**`check-operators.sh`** has been updated to detect operators installed via either OLMv0 (CSV) or OLMv1 (ClusterExtension).

---

## LLMInferenceService API version

Both `v1alpha1` (served) and `v1alpha2` (served + storage) are available on the CRD. The inference chart uses `v1alpha2` because it is the storage version. Resources at either version are accepted.

---

## Upgrade checklist

1. [ ] Update RHOAI operator to 3.5 (stable channel auto-upgrades)
2. [ ] Re-apply RHOAI instance chart (DSC v2 with `aigateway.modelsAsAService`, `trustyai: Managed`)
3. [ ] Re-apply MaaS gateway chart (adds `redhat-ai-gateway-infra` to allowedRoutes)
4. [ ] Update per-model values files (`--disable-uvicorn-access-log` → `--disable-access-log-for-endpoints=...`)
5. [ ] Re-deploy LLMInferenceServices (picks up new EPP scorers and API group)
6. [ ] Migrate ExternalModels: delete old `maas.opendatahub.io` CRs, update secret labels/fields, recreate with `inference.opendatahub.io`
7. [ ] Verify `check-operators.sh` passes
8. [ ] Clean up stale resources in `redhat-ods-applications` if MaaS was previously deployed there
