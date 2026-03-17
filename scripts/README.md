# Compare inference manifests (playbook vs Helm)

`compare-inference-manifests.sh` generates LLMInferenceService manifests from:

1. **Playbook** – `llm-d-playbook/gitops/instance/llm-d` (kustomize) for each model/overlay.
2. **Helm** – `gitops/instance/llm-d/inference` chart with equivalent values.

It then extracts the LLMInferenceService object from each, normalizes (drops ephemeral metadata), and diffs them.

## Run

From repo root:

```bash
./scripts/compare-inference-manifests.sh
```

Requires: `kustomize` (or `kubectl kustomize`), `helm`, and optionally `yq` for normalization.

Comparison uses **dyff** (https://github.com/homeport/dyff) when available for structural YAML diff; otherwise falls back to `diff -u`.

Optional: `NAMESPACE=demo-llm` (default).

## Cases

| Case | Playbook path | Helm deploymentType / storage |
|------|----------------|-------------------------------|
| intelligent-inference/opt-125m | intelligent-inference/opt-125m | intelligent-inference, hf |
| intelligent-inference/qwen3-0.6b | intelligent-inference/qwen3-0.6b | intelligent-inference, hf |
| intelligent-inference/gpt-oss-20b-huggingface | gpt-oss-20b/overlays/huggingface (base+patch only) | intelligent-inference-simple, hf |
| intelligent-inference/gpt-oss-20b-modelcar | gpt-oss-20b/overlays/modelcar | intelligent-inference-simple, oci |
| intelligent-inference/gpt-oss-20b-huggingface-with-pvc | gpt-oss-20b/overlays/huggingface-with-pvc | intelligent-inference-simple, hf + pvc |
| pd-disaggregation/qwen3-0.6b | pd-disaggregation/qwen3-0.6b | pd-disaggregation, hf |
| pd-disaggregation/gpt-oss-20b-huggingface | pd-disaggregation/gpt-oss-20b/overlays/huggingface | pd-disaggregation, hf |
| pd-disaggregation/gpt-oss-20b-modelcar | pd-disaggregation/gpt-oss-20b/overlays/modelcar | pd-disaggregation, oci |

## Output

- `.compare-inference/playbook/<case>.yaml` – LLMInferenceService from kustomize.
- `.compare-inference/helm/<case>.yaml` – LLMInferenceService from helm template.
- `.compare-inference/<case>.diff` – unified diff of normalized YAML (only present if there are deviations).

Expected deviations (chart vs playbook) can include:

- Field ordering and YAML style (`route: { }` vs `route: {}`).
- Comments in configText (e.g. `# block size...`) stripped or different.
- Chart does not model `startupProbe` (gpt-oss-20b base uses it).
- Slight differences in env ordering or default values.

Use the diffs to decide whether to extend the chart or accept the differences.
