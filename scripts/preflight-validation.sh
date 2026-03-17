#!/bin/bash

echo "=========================================="
echo "LLM-D Pre-flight Validation"
echo "=========================================="

PASS=0
FAIL=0

check() {
  if eval "$2" > /dev/null 2>&1; then
    echo "[PASS] $1"
    ((PASS++))
  else
    echo "[FAIL] $1"
    ((FAIL++))
  fi
}

# Core checks
check "OpenShift 4.19+" "oc version | grep -E 'Server Version: 4\.(19|[2-9][0-9])'"
check "Cluster admin access" "oc auth can-i '*' '*' --all-namespaces"
check "GPU nodes available" "oc get nodes -l nvidia.com/gpu.present=true | grep -v NAME"

# Operator checks
check "Cert Manager installed" "oc get csv -A | grep -i cert-manager | grep -i succeeded"
check "Service Mesh 3 installed" "oc get csv -n openshift-operators | grep -i servicemesh | grep -i succeeded"
check "Connectivity Link installed" "oc get csv -n openshift-operators | grep rhcl-operator | grep -i succeeded"
check "OpenShift AI installed" "oc get csv -A | grep -E 'rhods|openshift-ai' | grep -i succeeded"
check "NVIDIA GPU Operator installed" "oc get csv -n nvidia-gpu-operator | grep gpu-operator | grep -i succeeded"

# Gateway checks
check "GatewayClass exists" "oc get gatewayclass openshift-default"
check "AI Inference Gateway exists" "oc get gateway openshift-ai-inference -n openshift-ingress"

# Configuration checks
check "KServe in RawDeployment mode" "oc get datasciencecluster -o yaml | grep -A5 kserve | grep RawDeployment"

echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="

if [ $FAIL -gt 0 ]; then
  echo "Please resolve failed checks before proceeding."
  exit 1
fi
