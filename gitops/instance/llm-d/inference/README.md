# llm-d inference chart

Deploys a `LLMInferenceService` (llm-d / RHOAI 3.4) via Helm. Supports CPU and GPU nodes, optional MaaS tier registration, HuggingFace and OCI storage, and PD-disaggregation.

## Deployment types

| `deploymentType` | Description |
|---|---|
| `intelligent-inference` | Single pool with full EPP scheduler (prefix-cache, queue, KV-cache scoring). Default. |
| `pd-disaggregation` | Split prefill + decode pools with NixlConnector KV transfer. |

---

## Quick-start examples

### facebook/opt-125m — CPU node, registered in MaaS (RHOAI 3.4)

```bash
helm template opt-125m . --namespace llm-d-demo \
  --set deploymentType=intelligent-inference \
  --set serviceName=opt-125m \
  --set storage.type=hf \
  --set storage.uri=hf://facebook/opt-125m \
  --set model.name=facebook/opt-125m \
  --set replicas=1 \
  --set useStartupProbe=true \
  --set resources.limits.cpu=4 \
  --set resources.limits.memory=8Gi \
  --set resources.requests.cpu=2 \
  --set resources.requests.memory=4Gi \
  --set maas.enabled=true \
  | oc apply -n llm-d-demo -f -
```

What this does:
- Auto-selects `vllm-cpu-rhel9` image (no `gpuCount` set)
- Sets `hardwareProfile: default-cpu`
- Injects `VLLM_SKIP_WARMUP=true` and `VLLM_CPU_KVCACHE_SPACE=4` automatically
- Routes through the MaaS gateway and enables auth

> After applying, create a `MaaSModelRef` in `llm-d-demo` and add the model to a
> `MaaSSubscription` + `MaaSAuthPolicy` in `models-as-a-service` to control who can access it.

Or via a values file (`opt-125m.yaml`):

```yaml
deploymentType: intelligent-inference
serviceName: opt-125m
replicas: 1
useStartupProbe: true

model:
  name: facebook/opt-125m

storage:
  type: hf
  uri: hf://facebook/opt-125m

resources:
  limits:
    cpu: "4"
    memory: 8Gi
  requests:
    cpu: "2"
    memory: 4Gi

maas:
  enabled: true
```

```bash
helm template opt-125m . -f opt-125m.yaml | oc apply -n llm-d-demo -f -
```

> After applying, create a `MaaSModelRef` in `llm-d-demo` and add the model to a
> `MaaSSubscription` + `MaaSAuthPolicy` in `models-as-a-service` to control who can access it.

---

### Qwen3-8B — GPU node, OCI image, registered in MaaS (free tier)

The live instance values are in [`qwen3-8b-values.yaml`](qwen3-8b-values.yaml). Apply with:

```bash
helm template inference . -n llm-d-demo \
  -f qwen3-8b-values.yaml \
  | oc apply -n llm-d-demo -f -
```

What this does:
- Auto-selects `vllm-cuda-rhel9` image (`gpuCount=1` set)
- Sets `hardwareProfile: nvidia`
- Adds GPU toleration (`nvidia.com/gpu: NoSchedule`)
- Injects `VLLM_ADDITIONAL_ARGS` (tool-call parser, log suppression)
- Enables MaaS gateway routing and auth

> **Always use the values file** when re-applying. `oc apply` with strategic merge patch will
> drop env vars that are not present in the rendered YAML, including `VLLM_ADDITIONAL_ARGS`.

---

## Key values reference

### Core

| Value | Default | Description |
|---|---|---|
| `deploymentType` | — | **Required.** `intelligent-inference` or `pd-disaggregation` |
| `serviceName` | `my-model` | Name of the `LLMInferenceService` |
| `replicas` | `1` | Number of decode/main replicas |
| `model.name` | — | Model ID as served (e.g. `facebook/opt-125m`) |
| `storage.type` | — | `hf` or `oci` |
| `storage.uri` | — | `hf://org/model` or `oci://registry/repo:tag` |

### Resources & image

| Value | Default | Description |
|---|---|---|
| `resources.limits.cpu` | `"1"` | CPU limit |
| `resources.limits.memory` | `8Gi` | Memory limit |
| `resources.limits.gpuCount` | _(unset)_ | NVIDIA GPU count; triggers GPU image + toleration |
| `resources.requests.*` | mirrors limits | Resource requests |
| `images.gpu` | `vllm-cuda-rhel9@sha256:…` | Image used when `gpuCount` is set |
| `images.cpu` | `vllm-cpu-rhel9@sha256:…` | Image used when no `gpuCount` |
| `images.override` | `""` | Force a specific image regardless of `gpuCount` |

### CPU settings (auto-injected as env vars when no gpuCount)

| Value | Default | Env var injected |
|---|---|---|
| `cpu.kvCacheSpaceGiB` | `4` | `VLLM_CPU_KVCACHE_SPACE` |
| `cpu.skipWarmup` | `true` | `VLLM_SKIP_WARMUP` |

### vLLM additional arguments

| Value | Default | Description |
|---|---|---|
| `vllmAdditionalArgs` | `""` | Injected as `VLLM_ADDITIONAL_ARGS` env var when non-empty |

Use this for flags like `--tool-call-parser`, `--disable-uvicorn-access-log`, etc. It is appended
after CPU auto-vars and before `env[]`, making it easier to track in per-model values files
without burying it in a generic list.

```yaml
vllmAdditionalArgs: "--disable-uvicorn-access-log --enable-auto-tool-choice --tool-call-parser hermes"
```

### Update strategy

The `LLMInferenceService` CRD does not expose a deployment strategy field — confirmed via
`oc explain llminferenceservice.spec.template.containers.strategy` (field does not exist).
The operator controls the underlying Deployments directly with hardcoded values:

- Scheduler Deployment — always `Recreate`
- Main workload Deployment — always `RollingUpdate`

There is no supported way to override this through the CR spec. The chart previously exposed
an `updateStrategy` value and emitted a `strategy` block inside the container spec, but this
was silently ignored by the API server and has been removed.

**Practical consequence with RollingUpdate on GPU clusters:** if all GPU nodes are fully
utilised, the rolling update will stall — the new pod cannot schedule until an old one is
terminated, but the controller waits for the new pod to be Ready before terminating the old
one. Unblock it by deleting the old pods manually so the controller scales down the old
ReplicaSet.

### Extra env vars

Any env vars in `env[]` are appended after `vllmAdditionalArgs` and auto-injected CPU vars:

```yaml
env:
  - name: HF_TOKEN
    valueFrom:
      secretKeyRef:
        name: hf-token
        key: token
```

### MaaS integration

| Value | Default | Description |
|---|---|---|
| `maas.enabled` | `false` | Route traffic through the MaaS gateway and enable auth |
| `maas.gateway.name` | `maas-default-gateway` | MaaS gateway name |
| `maas.gateway.namespace` | `openshift-ingress` | MaaS gateway namespace |

When `maas.enabled=true`:
- `security.opendatahub.io/enable-auth` is forced to `true`
- `router.gateway.refs` points to the MaaS gateway

Access control is managed separately via `MaaSModelRef`, `MaaSSubscription`, and `MaaSAuthPolicy` CRs in the `models-as-a-service` namespace — create those after deploying the model.

### Hardware profile

Auto-selected based on `gpuCount`:

| gpuCount set? | Profile | Image |
|---|---|---|
| No | `default-cpu` | `vllm-cpu-rhel9` |
| Yes | `gpu-profile` | `vllm-cuda-rhel9` |

Override with `hardwareProfile.name` if needed (e.g. `nvidia`, `nvidiaa10g-profile`).

### Storage caching (PVC)

To cache the model locally and avoid re-downloading on pod restarts:

```yaml
storage:
  type: hf
  uri: hf://facebook/opt-125m
  pvc:
    size: 10Gi
    accessMode: ReadWriteOnce
```

### Scheduler TLS (EPP)

To use custom TLS for the EPP scheduler instead of the auto-generated self-signed cert:

```yaml
schedulerTLS:
  enabled: true
  secretName: epp-serving-tls   # Secret with tls.crt and tls.key
  mountPath: /etc/epp/tls
```

### Private HuggingFace models

Pass the token as an env var from a secret:

```yaml
env:
  - name: HF_TOKEN
    valueFrom:
      secretKeyRef:
        name: hf-token
        key: token
```

Create the secret first:

```bash
oc create secret generic hf-token --from-literal=token=hf_xxxx -n llm-d-demo
```

---

## Technical Documentation

For deep-dive technical references, see [docs/](docs/):

- [VLLM-ARGS-STRUCTURED.md](docs/VLLM-ARGS-STRUCTURED.md) — Structured vLLM arguments configuration
- [WELL-LIT-PATH-LABELS.md](docs/WELL-LIT-PATH-LABELS.md) — Automatic well-lit path labeling
- [MONITORING.md](docs/MONITORING.md) — ServiceMonitor integration (auto-created)
- [PREFIX-CACHING-CONFIG.md](docs/PREFIX-CACHING-CONFIG.md) — Prefix caching configuration reference
- [ENABLE-PREFIX-CACHING.md](docs/ENABLE-PREFIX-CACHING.md) — Prefix caching troubleshooting guide

---

## Related Documentation

- [README.md Step 3](../../../README.md#step-3-deploy-a-model) — Deployment walkthrough
- [AGENTS.md Phase 5](../../../AGENTS.md#phase-5--llm-d-quick-start) — Deployment with assistant
- [LLM-D-MONITORING-INTEGRATION.md](../../llm-d-observability/LLM-D-MONITORING-INTEGRATION.md) — Monitoring setup
