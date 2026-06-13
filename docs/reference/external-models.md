# ExternalModel — Credential Injection

> Part of the [llm-d-demo Co-pilot Runbook](../../AGENTS.md). Reference material for
> [Phase 6 — MaaS](../phases/06-maas.md).

An `ExternalModel` CR points the MaaS gateway at any OpenAI-compatible endpoint. The
`payload-processing` ext_proc service (pod in `openshift-ingress`) has two controllers: one for
`ExternalModel` CRs (routing/model-store) and one for `Secret` CRs (credential-store).

## Critical Requirements

**1. MaaSModelRef name MUST match ExternalModel name exactly.**

This is a mandatory constraint. Unlike `LLMInferenceService` where the MaaSModelRef can have a
different name, for ExternalModel the names must be identical:

```yaml
# ExternalModel
apiVersion: maas.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: qwen3-14b              # ← This name
  namespace: maas-demo
spec:
  credentialRef:
    name: litellm-credentials
  endpoint: litellm-prod.apps.maas.redhatworkshops.io
  provider: openai
  targetModel: qwen3-14b

---
# MaaSModelRef MUST have the same name
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

**2. Credential secret requires the label `inference.networking.k8s.io/bbr-managed: "true"`.**

Secrets without this label are silently ignored — the credential store is never populated and every
request fails with `"provider 'openai' credentials not found"`.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: litellm-credentials
  namespace: maas-demo
  labels:
    inference.networking.k8s.io/bbr-managed: "true"  # ← REQUIRED
type: Opaque
data:
  OPENAI_API_KEY: <base64-encoded-api-key>
```

**3. MaaSModelRef must be created manually.**

Unlike `LLMInferenceService` which auto-creates the MaaSModelRef when `maas.enabled=true`,
ExternalModel requires manual creation of the MaaSModelRef.

**Path format:** The MaaS gateway path for an ExternalModel is `/{namespace}/{ExternalModel.metadata.name}/v1/...`.
Example: `https://maas.<domain>/maas-demo/qwen3-14b/v1/chat/completions`.

**Only llm-d runtime supports MaaS:** The "Publish as MaaS endpoint" toggle in Advanced settings
is only available when **Distributed inference with llm-d** is selected as the serving runtime.

## Monitoring ExternalModels

ExternalModels expose metrics via Limitador, not vLLM. Deploy monitoring:

```bash
oc label namespace kuadrant-system openshift.io/cluster-monitoring=true --overwrite
oc apply -f gitops/instance/llm-d-observability/limitador-servicemonitor.yaml
oc apply -f gitops/instance/llm-d-observability/perses-dashboard-external-models.yaml
```

Dashboard: Console → Observe → Dashboards → "MaaS External Models"

Technical details: `gitops/instance/llm-d-observability/EXTERNAL-MONITORING-INTEGRATION.md`
