# Bug Report: gen-ai-ui crash loop on nil `spec.model.name` in LLMInferenceService

**Date:** 2026-05-25  
**Environment:** RHOAI 3.4 GA, OCP 4.21, llm-d, MaaS  
**Cluster:** `apps.ocp.sandbox1346.opentlc.com`  
**Severity:** High — Gen AI Studio completely unavailable

---

## Summary

The `gen-ai-ui` sidecar in the `rhods-dashboard` pod enters a crash loop whenever the
Gen AI Studio page is loaded and the namespace contains an `LLMInferenceService`
with no `spec.model.name` field. The crash is a nil pointer dereference (Go panic) in
`getAAModelsFromLLMInferenceService`. Every crash causes the dashboard BFF to return
`UND_ERR_SOCKET` (500) to the browser for all Gen AI Studio requests.

---

## Environment

| Component | Version / Details |
|---|---|
| RHOAI | 3.4.0 GA (self-managed) |
| OCP | 4.21 |
| llm-d | deployed in `llm-d-demo` |
| MaaS | enabled, gateway in `openshift-ingress` |
| Models deployed | `qwen3-8b` (Helm), `nemotron-nano-9b-v2-fp8` (dashboard UI) |

---

## Symptom

Opening the Gen AI Studio / AI Assets page in the RHOAI dashboard shows:

```
Some models may be unavailable
Locally deployed models could not be loaded. Only models from available sources are shown.
{
    "statusCode": 500,
    "code": "UND_ERR_SOCKET",
    "error": "Internal Server Error",
    "message": "Undici Socket Error"
}
```

---

## Root Cause 1 (Primary) — nil pointer dereference in gen-ai-ui

### What happened

The `nemotron-nano-9b-v2-fp8` `LLMInferenceService` was deployed through the RHOAI
dashboard UI. The UI deployment path does **not** set `spec.model.name`; only the Helm
chart (`gitops/instance/llm-d/inference`) populates that field. The resulting object had:

```yaml
spec:
  model:
    # name: <MISSING>
    uri: oci://registry.redhat.io/rhelai1/modelcar-nvidia-nemotron-nano-9b-v2-fp8-dynamic:1.5
```

When a user loads the Gen AI Studio page, the dashboard BFF calls
`/gen-ai/api/v1/aaa/models?namespace=llm-d-demo`, which is proxied to the `gen-ai-ui`
sidecar (ClusterIP `172.30.205.54`, port 8143). The `gen-ai-ui` calls
`getAAModelsFromLLMInferenceService`, iterates over all `LLMInferenceService` objects in
the namespace, and dereferences `spec.model.name` without a nil guard. This panics:

```
panic: runtime error: invalid memory address or nil pointer dereference
[signal SIGSEGV: segmentation violation code=0x1 addr=0x0 pc=0x22edd03]

goroutine 186 [running]:
github.com/opendatahub-io/gen-ai/internal/integrations/kubernetes.
  (*TokenKubernetesClient).getAAModelsFromLLMInferenceService(...)
    token_k8s_client.go:822 +0x6e3
```

The panic kills the `gen-ai-ui` container. Kubernetes restarts it (CrashLoopBackOff).
During each restart window the BFF gets `ECONNREFUSED` or `UND_ERR_SOCKET` on port 8143.

### Affected resource

```
Kind:       LLMInferenceService
Name:       nemotron-nano-9b-v2-fp8
Namespace:  llm-d-demo
Field:      spec.model.name  (absent)
```

### Fix applied

```bash
oc patch llminferenceservice nemotron-nano-9b-v2-fp8 -n llm-d-demo \
  --type=merge \
  -p '{"spec":{"model":{"name":"nvidia/Nemotron-Nano-9B-v2-Instruct"}}}'
```

After the patch the gen-ai-ui restart counter stopped incrementing and the crash logs
ceased.

### Upstream bug

The `gen-ai-ui` code at `token_k8s_client.go:822` must add a nil/empty check on
`spec.model.name` before dereferencing it. The field is optional in the CRD schema (the
dashboard UI does not require it) so the code must not assume it is set.

---

## Checklist for prevention

- [ ] Dashboard UI deployment path should write `spec.model.name` when creating an
  `LLMInferenceService` (or the field should be required in the CRD).
- [ ] `gen-ai-ui` upstream fix: nil-guard `spec.model.name` in
  `getAAModelsFromLLMInferenceService` (`token_k8s_client.go:822`).
- [ ] Add Phase 10 teardown cleanup commands to `README.md` covering all four external
  model resources.
- [ ] Document that `LLMInferenceService` created via dashboard UI omits `spec.model.name`
  and must be patched if the model is exposed to Gen AI Studio.
