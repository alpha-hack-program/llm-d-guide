# ExternalModel — Two-Resource Pattern (RHOAI 3.5+)

> Part of the [llm-d-guide Co-pilot Runbook](../../AGENTS.md). Reference material for
> [Phase 6 — MaaS](../phases/06-maas.md).

In RHOAI 3.5, `ExternalModel` and `ExternalProvider` moved from `maas.opendatahub.io/v1alpha1`
to **`inference.opendatahub.io/v1alpha1`** with a redesigned spec. The old single-resource pattern
(endpoint + credentials inline on ExternalModel) is replaced by a two-resource pattern:

- **`ExternalProvider`** — defines the provider endpoint, type, and credential reference
- **`ExternalModel`** — references one or more ExternalProviders via `externalProviderRefs`

Old `maas.opendatahub.io` ExternalModel CRs are auto-migrated by the `ipp-legacy-migration`
controller — they show `status.phase: Migrated` and stop functioning. Delete them and recreate
using the new API.

## Critical Requirements

**1. Create an ExternalProvider, then an ExternalModel that references it.**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-provider-credentials
  namespace: maas-demo
  labels:
    inference.llm-d.ai/ipp-managed: "true"  # ← REQUIRED (3.5 label)
type: Opaque
data:
  api-key: <base64-encoded-api-key>        # ← field must be "api-key"
---
apiVersion: inference.opendatahub.io/v1alpha1
kind: ExternalProvider
metadata:
  name: my-provider
  namespace: maas-demo
spec:
  provider: openai
  endpoint: api.example.com
  auth:
    type: apikey
    secretRef:
      name: my-provider-credentials
---
apiVersion: inference.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: qwen3-14b
  namespace: maas-demo
spec:
  externalProviderRefs:
  - ref:
      name: my-provider
    targetModel: qwen3-14b
    apiFormat: openai-chat
    path: /v1/chat/completions
    weight: 100
```

**2. MaaSModelRef name MUST match ExternalModel name exactly.**

This is a mandatory constraint. Unlike `LLMInferenceService` where the MaaSModelRef can have a
different name, for ExternalModel the names must be identical:

```yaml
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: qwen3-14b              # ← MUST match ExternalModel name exactly
  namespace: maas-demo
spec:
  modelRef:
    kind: ExternalModel
    name: qwen3-14b
```

**3. Credential secret requires the label `inference.llm-d.ai/ipp-managed: "true"`.**

Secrets without this label are silently ignored — the credential store is never populated and every
request fails with `"provider 'openai' credentials not found"`. The secret data field must be
named `api-key` (not `OPENAI_API_KEY`).

> **Migration note:** The 3.4 label was `inference.networking.k8s.io/bbr-managed: "true"` — update
> it when migrating to 3.5.

**4. MaaSModelRef must be created manually.**

Unlike `LLMInferenceService` which auto-creates the MaaSModelRef when `maas.enabled=true`,
ExternalModel requires manual creation of the MaaSModelRef.

**5. Supported `apiFormat` values:** `openai-chat`, `messages` (Anthropic), `openai-responses`,
`vertex-messages`. When any ExternalModel uses `apiFormat: messages`, the gateway enables
`x-api-key` header auth cluster-wide.

**Path format:** The MaaS gateway path for an ExternalModel is `/{namespace}/{ExternalModel.metadata.name}/v1/...`.
Example: `https://maas.<domain>/maas-demo/qwen3-14b/v1/chat/completions`.

**Only llm-d runtime supports MaaS:** The "Publish as MaaS endpoint" toggle in Advanced settings
is only available when **Distributed inference with llm-d** is selected as the serving runtime.

## Migration from 3.4 ExternalModel

Old `maas.opendatahub.io` ExternalModels are auto-migrated but non-functional. To clean up:

1. Delete the old ExternalModel: `oc delete externalmodel.maas.opendatahub.io <name> -n <ns>`
   (cascades to the auto-migrated ExternalProvider and ExternalModel via ownerReferences)
2. Update the secret label: `inference.networking.k8s.io/bbr-managed` → `inference.llm-d.ai/ipp-managed`
3. Update the secret data field: `OPENAI_API_KEY` → `api-key`
4. Create new ExternalProvider + ExternalModel with `inference.opendatahub.io/v1alpha1`

## Monitoring ExternalModels

ExternalModels expose metrics via Limitador, not vLLM. Deploy monitoring:

```bash
oc label namespace kuadrant-system openshift.io/cluster-monitoring=true --overwrite
oc apply -f gitops/instance/llm-d-observability/limitador-servicemonitor.yaml
oc apply -f gitops/instance/llm-d-observability/perses-dashboard-external-models.yaml
```

Dashboard: Console → Observe → Dashboards → "MaaS External Models"

Technical details: `gitops/instance/llm-d-observability/EXTERNAL-MONITORING-INTEGRATION.md`
