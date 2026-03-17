#!/usr/bin/env bash
# Compare LLMInferenceService objects: playbook (kustomize) vs helm chart.
#
# For each playbook case (intelligent-inference and pd-disaggregation with their
# overlays), builds the same result via kustomize and via helm template, then
# extracts LLMInferenceService and diffs them to report deviations.
#
# Requirements: kustomize (or kubectl kustomize), helm, yq (https://github.com/mikefarah/yq)
# Comparison: dyff (https://github.com/homeport/dyff) when available, else diff -u
# Optional: set NAMESPACE (default demo-llm)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAYBOOK_ROOT="${REPO_ROOT}/llm-d-playbook/gitops/instance/llm-d"
CHART_PATH="${REPO_ROOT}/gitops/instance/llm-d/inference"
OUT_ROOT="${REPO_ROOT}/.compare-inference"
PLAYBOOK_OUT="${OUT_ROOT}/playbook"
HELM_OUT="${OUT_ROOT}/helm"
NAMESPACE="${NAMESPACE:-demo-llm}"

# -----------------------------------------------------------------------------
# Extract LLMInferenceService document(s) from multi-doc YAML stdin.
# Outputs only the first LLMInferenceService doc (one per case in our flows).
# -----------------------------------------------------------------------------
extract_llm() {
  if command -v yq >/dev/null 2>&1; then
    yq ea 'select(.kind == "LLMInferenceService")' -
  else
    awk '
      /^---$/ {
        if (buf ~ /kind: LLMInferenceService/) { print buf; exit }
        buf = ""
        next
      }
      { buf = buf $0 "\n" }
      END { if (buf ~ /kind: LLMInferenceService/) print buf }
    ' -
  fi
}

# Normalize for comparison: pretty-print, drop ephemeral metadata/status, set namespace.
normalize_llm() {
  local f="$1"
  if command -v yq >/dev/null 2>&1; then
    # yq v4: use 'ea' and single doc; drop ephemeral fields, force namespace for comparison
    yq e '
      del(.metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid, .metadata.managedFields, .metadata.generation, .status) |
      .metadata.namespace = "'"${NAMESPACE}"'"
    ' -P "$f" 2>/dev/null || cat "$f"
  else
    cat "$f"
  fi
}

run_kustomize() {
  local dir="$1"
  (cd "$dir" && kustomize build . 2>/dev/null) || (cd "$dir" && kubectl kustomize . 2>/dev/null)
}

# Base values without default PVC (so only cases that set storage.pvc get a PVC).
VALUES_BASE="${REPO_ROOT}/scripts/compare-values-base.yaml"

run_helm() {
  local name="$1"
  local extra_args=("${@:2}")
  helm template "${CHART_PATH}" \
    --name-template "$name" \
    -n "${NAMESPACE}" \
    -f "${VALUES_BASE}" \
    "${extra_args[@]}" \
    --include-crds
}

# -----------------------------------------------------------------------------
# Case definitions: id | kustomize_dir | helm override yaml
# Override yaml is merged on top of chart values (only set what differs).
# -----------------------------------------------------------------------------
declare -a CASES=(
  "intelligent-inference/opt-125m"
  "intelligent-inference/qwen3-0.6b"
  "intelligent-inference/gpt-oss-20b-huggingface"
  "intelligent-inference/gpt-oss-20b-modelcar"
  "intelligent-inference/gpt-oss-20b-huggingface-with-pvc"
  "pd-disaggregation/qwen3-0.6b"
  "pd-disaggregation/gpt-oss-20b-huggingface"
  "pd-disaggregation/gpt-oss-20b-modelcar"
)

get_kustomize_dir() {
  case "$1" in
    intelligent-inference/opt-125m)
      echo "${PLAYBOOK_ROOT}/intelligent-inference/opt-125m"
      ;;
    intelligent-inference/qwen3-0.6b)
      echo "${PLAYBOOK_ROOT}/intelligent-inference/qwen3-0.6b"
      ;;
    intelligent-inference/gpt-oss-20b-huggingface)
      echo "${PLAYBOOK_ROOT}/intelligent-inference/gpt-oss-20b/overlays/huggingface"
      ;;
    intelligent-inference/gpt-oss-20b-modelcar)
      echo "${PLAYBOOK_ROOT}/intelligent-inference/gpt-oss-20b/overlays/modelcar"
      ;;
    intelligent-inference/gpt-oss-20b-huggingface-with-pvc)
      echo "${PLAYBOOK_ROOT}/intelligent-inference/gpt-oss-20b/overlays/huggingface-with-pvc"
      ;;
    pd-disaggregation/qwen3-0.6b)
      echo "${PLAYBOOK_ROOT}/pd-disaggregation/qwen3-0.6b"
      ;;
    pd-disaggregation/gpt-oss-20b-huggingface)
      echo "${PLAYBOOK_ROOT}/pd-disaggregation/gpt-oss-20b/overlays/huggingface"
      ;;
    pd-disaggregation/gpt-oss-20b-modelcar)
      echo "${PLAYBOOK_ROOT}/pd-disaggregation/gpt-oss-20b/overlays/modelcar"
      ;;
    *) echo "UNKNOWN:$1" ;;
  esac
}

# Helm override YAML per case (merged over chart values).
get_helm_override() {
  local case_id="$1"
  case "$case_id" in
    intelligent-inference/opt-125m)
      cat <<EOF
deploymentType: intelligent-inference
serviceName: opt-125m
replicas: 1
storage:
  type: hf
  uri: hf://facebook/opt-125m
model:
  name: facebook/opt-125m
resources:
  limits: { cpu: "1", memory: 8Gi, gpuCount: "1" }
  requests: { cpu: "1", memory: 8Gi, gpuCount: "1" }
EOF
      ;;
    intelligent-inference/qwen3-0.6b)
      cat <<EOF
deploymentType: intelligent-inference
serviceName: qwen
replicas: 4
storage:
  type: hf
  uri: hf://Qwen/Qwen3-4B
model:
  name: Qwen/Qwen3-4B
env:
  - name: VLLM_ADDITIONAL_ARGS
    value: "--disable-uvicorn-access-log"
resources:
  limits: { cpu: "1", memory: 8Gi, gpuCount: "1" }
  requests: { cpu: "1", memory: 8Gi, gpuCount: "1" }
EOF
      ;;
    intelligent-inference/gpt-oss-20b-huggingface)
      cat <<EOF
deploymentType: intelligent-inference
intelligentInferenceSimple: true
serviceName: gpt-oss-20b
replicas: 1
useStartupProbe: true
storage:
  type: hf
  uri: hf://openai/gpt-oss-20b
model:
  name: openai/gpt-oss-20b
resources:
  limits: { cpu: "4", memory: 16Gi, gpuCount: "1" }
  requests: { cpu: "1", memory: 8Gi, gpuCount: "1" }
env:
  - name: VLLM_ADDITIONAL_ARGS
    value: "--disable-uvicorn-access-log"
EOF
      ;;
    intelligent-inference/gpt-oss-20b-modelcar)
      cat <<EOF
deploymentType: intelligent-inference
intelligentInferenceSimple: true
serviceName: gpt-oss-20b
replicas: 1
useStartupProbe: true
storage:
  type: oci
  uri: oci://quay.io/redhat-ai-services/modelcar-catalog:gpt-oss-20b
model:
  name: openai/gpt-oss-20b
resources:
  limits: { cpu: "4", memory: 16Gi, gpuCount: "1" }
  requests: { cpu: "1", memory: 8Gi, gpuCount: "1" }
env:
  - name: VLLM_ADDITIONAL_ARGS
    value: "--disable-uvicorn-access-log"
EOF
      ;;
    intelligent-inference/gpt-oss-20b-huggingface-with-pvc)
      cat <<EOF
deploymentType: intelligent-inference
intelligentInferenceSimple: true
serviceName: gpt-oss-20b
replicas: 1
useStartupProbe: true
storage:
  type: hf
  uri: hf://openai/gpt-oss-20b
  pvc:
    size: 40Gi
    accessMode: ReadWriteOnce
model:
  name: openai/gpt-oss-20b
resources:
  limits: { cpu: "4", memory: 16Gi, gpuCount: "1" }
  requests: { cpu: "1", memory: 8Gi, gpuCount: "1" }
env:
  - name: VLLM_ADDITIONAL_ARGS
    value: "--disable-uvicorn-access-log"
EOF
      ;;
    pd-disaggregation/qwen3-0.6b)
      cat <<EOF
deploymentType: pd-disaggregation
serviceName: qwen-pd
replicas: 1
storage:
  type: hf
  uri: hf://Qwen/Qwen3-0.6B
model:
  name: Qwen/Qwen3-0.6B
resources:
  limits: { cpu: "4", memory: 8Gi, gpuCount: "1" }
  requests: { cpu: "4", memory: 8Gi, gpuCount: "1" }
prefill:
  replicas: 1
  resources:
    limits: { cpu: "4", memory: 8Gi, gpuCount: "1" }
    requests: { cpu: "4", memory: 8Gi, gpuCount: "1" }
kvTransfer:
  loggingLevel: ""
  vllmArgsOrder: "kv_first"
  envOrder: "nixl_first"
EOF
      ;;
    pd-disaggregation/gpt-oss-20b-huggingface)
      cat <<EOF
deploymentType: pd-disaggregation
serviceName: gpt-oss-20b-pfd
replicas: 1
useStartupProbe: true
storage:
  type: hf
  uri: hf://openai/gpt-oss-20b
model:
  name: openai/gpt-oss-20b
resources:
  limits: { cpu: "4", memory: 16Gi, gpuCount: "1" }
  requests: { cpu: "1", memory: 8Gi, gpuCount: "1" }
prefill:
  replicas: 1
  resources:
    limits: { cpu: "4", memory: 16Gi, gpuCount: "1" }
    requests: { cpu: "1", memory: 8Gi, gpuCount: "1" }
EOF
      ;;
    pd-disaggregation/gpt-oss-20b-modelcar)
      cat <<EOF
deploymentType: pd-disaggregation
serviceName: gpt-oss-20b-pfd
replicas: 1
useStartupProbe: true
storage:
  type: oci
  uri: oci://quay.io/redhat-ai-services/modelcar-catalog:gpt-oss-20b
model:
  name: openai/gpt-oss-20b
resources:
  limits: { cpu: "4", memory: 16Gi, gpuCount: "1" }
  requests: { cpu: "1", memory: 8Gi, gpuCount: "1" }
prefill:
  replicas: 1
  resources:
    limits: { cpu: "4", memory: 16Gi, gpuCount: "1" }
    requests: { cpu: "1", memory: 8Gi, gpuCount: "1" }
EOF
      ;;
    *) echo "" ;;
  esac
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
mkdir -p "${PLAYBOOK_OUT}" "${HELM_OUT}"
FAILED=0
DEVIATIONS=()

for case_id in "${CASES[@]}"; do
  safe_name="${case_id//\//_}"
  playbook_dir="$(get_kustomize_dir "$case_id")"
  playbook_llm="${PLAYBOOK_OUT}/${safe_name}.yaml"
  helm_llm="${HELM_OUT}/${safe_name}.yaml"
  playbook_norm="${PLAYBOOK_OUT}/${safe_name}.norm.yaml"
  helm_norm="${HELM_OUT}/${safe_name}.norm.yaml"

  echo "=== $case_id ==="

  # Build playbook (kustomize)
  if [[ ! -d "$playbook_dir" ]]; then
    echo "  SKIP playbook: directory not found: $playbook_dir"
    continue
  fi
  # Playbook huggingface overlay references pvc.yaml which does not exist in that overlay; use base+patch only.
  if [[ "$case_id" == "intelligent-inference/gpt-oss-20b-huggingface" ]]; then
    tmp_kustom="${PLAYBOOK_ROOT}/intelligent-inference/gpt-oss-20b/overlays/huggingface-no-pvc-tmp"
    mkdir -p "$tmp_kustom"
    cat > "$tmp_kustom/kustomization.yaml" <<'KUST'
resources:
  - ../../base
patches:
  - path: llm-infra-patch.yaml
    target:
      kind: LLMInferenceService
      name: gpt-oss-20b
KUST
    cp "${PLAYBOOK_ROOT}/intelligent-inference/gpt-oss-20b/overlays/huggingface/llm-infra-patch.yaml" "$tmp_kustom/"
    playbook_dir="$tmp_kustom"
  fi
  if ! run_kustomize "$playbook_dir" | extract_llm > "${playbook_llm}" 2>/dev/null; then
    echo "  FAIL playbook: kustomize build failed"
    ((FAILED++)) || true
    continue
  fi
  if [[ ! -s "${playbook_llm}" ]]; then
    echo "  FAIL playbook: no LLMInferenceService in output"
    ((FAILED++)) || true
    continue
  fi

  # Build helm (capture exit code and stderr so we can show warnings when template fails)
  override_file="${HELM_OUT}/${safe_name}.values.yaml"
  get_helm_override "$case_id" > "${override_file}"
  helm_stdout="$(mktemp)"
  helm_stderr="$(mktemp)"
  helm_ret=0
  run_helm "inference" -f "${override_file}" > "${helm_stdout}" 2>"${helm_stderr}" || helm_ret=$?
  if [[ $helm_ret -ne 0 ]]; then
    echo "  WARNING: helm template failed (treat as warning — fix kustomize base descriptors if needed)"
    echo "  --- helm stderr ---"
    sed 's/^/    /' < "${helm_stderr}"
    echo "  ------------------"
    warning_file="${OUT_ROOT}/${safe_name}.helm-warning.txt"
    {
      echo "Helm template failed for case: $case_id"
      echo "Treat this as a warning. You may need to fix the original kustomize base descriptors"
      echo "(e.g. add a space after 'value:' so YAML is valid and matches)."
      echo ""
      echo "--- helm stderr ---"
      cat "${helm_stderr}"
    } > "${warning_file}"
    echo "  Highlight: ${warning_file}"
    rm -f "${helm_stdout}" "${helm_stderr}"
    continue
  fi
  extract_llm < "${helm_stdout}" > "${helm_llm}"
  rm -f "${helm_stdout}" "${helm_stderr}"
  if [[ ! -s "${helm_llm}" ]]; then
    echo "  FAIL helm: no LLMInferenceService in output"
    ((FAILED++)) || true
    continue
  fi

  # Normalize and compare
  normalize_llm "${playbook_llm}" > "${playbook_norm}" 2>/dev/null || cp "${playbook_llm}" "${playbook_norm}"
  normalize_llm "${helm_llm}"    > "${helm_norm}" 2>/dev/null || cp "${helm_llm}" "${helm_norm}"

  if command -v dyff >/dev/null 2>&1; then
    # dyff: structural YAML diff (playbook -> helm)
    if dyff between --set-exit-code "${playbook_norm}" "${helm_norm}" > "${OUT_ROOT}/${safe_name}.diff" 2>&1; then
      echo "  OK: no deviations"
      rm -f "${OUT_ROOT}/${safe_name}.diff"
    else
      echo "  DEVIATION: see ${OUT_ROOT}/${safe_name}.diff"
      DEVIATIONS+=("$case_id")
      ((FAILED++)) || true
    fi
  else
    if diff -u "${playbook_norm}" "${helm_norm}" > "${OUT_ROOT}/${safe_name}.diff" 2>/dev/null; then
      echo "  OK: no deviations"
      rm -f "${OUT_ROOT}/${safe_name}.diff"
    else
      echo "  DEVIATION: see ${OUT_ROOT}/${safe_name}.diff (diff -u)"
      DEVIATIONS+=("$case_id")
      ((FAILED++)) || true
    fi
  fi
done

echo ""
echo "--- Summary ---"
if [[ ${#DEVIATIONS[@]} -eq 0 ]]; then
  echo "All cases match (no deviations)."
  exit 0
fi
echo "Deviations in: ${DEVIATIONS[*]}"
echo "Diffs: ${OUT_ROOT}/*.diff"
exit 1
