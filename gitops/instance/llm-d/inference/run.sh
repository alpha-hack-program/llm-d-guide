#!/bin/sh
# Render the chart locally (env vars → temp values → helm template).
#
# Required env vars:
#   DEPLOYMENT_TYPE  intelligent-inference | intelligent-inference-simple | pd-disaggregation  (default: intelligent-inference)
#   STORAGE_TYPE     hf | oci                                    (default: hf)
#   MODEL_URI        e.g. hf://facebook/opt-125m  or  oci://quay.io/…
#   MODEL_NAME       e.g. facebook/opt-125m
#   SERVICE_NAME     name of the LLMInferenceService (and PVC when storage.pvc is set)
#   NAMESPACE        target namespace                            (default: demo-llm)
#
# Example (intelligent-inference, HuggingFace):
#   DEPLOYMENT_TYPE=intelligent-inference \
#   STORAGE_TYPE=hf \
#   MODEL_URI="hf://facebook/opt-125m" \
#   MODEL_NAME="facebook/opt-125m" \
#   SERVICE_NAME=opt-125m \
#   sh run.sh | oc apply -f -
#
# Direct helm template (from this directory):
#   helm template . --name-template inference -n demo-llm -f values.yaml
#   helm template . --name-template inference -n demo-llm -f values.yaml -f my-override.yaml
#   helm template . --name-template inference -n demo-llm --set serviceName=my-model --set-string storage.uri="oci://registry.redhat.io/..."

APP_NAME=inference

# Write runtime values to a temp file to avoid shell-quoting issues with URIs
TMPFILE=$(mktemp /tmp/helm-values-XXXXXX.yaml)
trap "rm -f ${TMPFILE}" EXIT

cat > "${TMPFILE}" <<EOF
deploymentType: "${DEPLOYMENT_TYPE:-intelligent-inference}"
serviceName: "${SERVICE_NAME:-my-model}"
storage:
  type: "${STORAGE_TYPE:-hf}"
  uri: "${MODEL_URI:-hf://facebook/opt-125m}"
model:
  name: "${MODEL_NAME:-facebook/opt-125m}"
EOF

helm template . --name-template ${APP_NAME} \
  -n "${NAMESPACE:-demo-llm}" \
  -f "${TMPFILE}" \
  --include-crds
