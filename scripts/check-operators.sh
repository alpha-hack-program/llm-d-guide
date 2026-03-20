#!/bin/bash

echo "=== Checking Required Operators ==="

# Check Cert Manager
echo -n "Cert Manager: "
oc get csv -A | grep -q "cert-manager" && echo "OK" || echo "MISSING"

# Check Service Mesh 3
echo -n "Service Mesh 3: "
oc get csv -n openshift-operators | grep -q "servicemesh" && echo "OK" || echo "MISSING"

# Check Connectivity Link (RHOAI 3.0+)
echo -n "Connectivity Link: "
oc get csv -n openshift-operators | grep -q "rhcl-operator" && echo "OK" || echo "NOT FOUND (required for RHOAI 3.0+)"

# Check OpenShift AI
echo -n "OpenShift AI: "
oc get csv -n redhat-ods-operator | grep -q "rhods\|openshift-ai" && echo "OK" || echo "MISSING"

# Check NFD
echo -n "Node Feature Discovery: "
oc get csv -A | grep -q "nfd" && echo "OK" || echo "MISSING"

# Check NVIDIA GPU Operator
echo -n "NVIDIA GPU Operator: "
oc get csv -n nvidia-gpu-operator | grep -q "gpu-operator" && echo "OK" || echo "MISSING"

echo ""
echo "=== Monitoring operators (RHOAI 3.3) ==="

# Check Cluster Observability Operator
echo -n "Cluster Observability Operator: "
if oc get subscription openshift-cluster-observability-operator -n openshift-cluster-observability-operator &>/dev/null; then
  phase=$(oc get csv -n openshift-cluster-observability-operator -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
  case "$phase" in *Succeeded*) echo "OK";; *) echo "INSTALLING or FAILED (phase: $phase)";; esac
else
  echo "MISSING (Subscription not found)"
fi

# Check Tempo Operator
echo -n "Tempo Operator: "
if oc get subscription tempo-product -n openshift-tempo-operator &>/dev/null; then
  phase=$(oc get csv -n openshift-tempo-operator -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
  case "$phase" in *Succeeded*) echo "OK";; *) echo "INSTALLING or FAILED (phase: $phase)";; esac
else
  echo "MISSING (Subscription not found)"
fi

# Check OpenTelemetry Operator
echo -n "OpenTelemetry Operator: "
if oc get subscription opentelemetry-product -n openshift-opentelemetry-operator &>/dev/null; then
  phase=$(oc get csv -n openshift-opentelemetry-operator -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
  case "$phase" in *Succeeded*) echo "OK";; *) echo "INSTALLING or FAILED (phase: $phase)";; esac
else
  echo "MISSING (Subscription not found)"
fi

# Check Grafana Operator (optional)
echo -n "Grafana Operator: "
if oc get subscription grafana-operator -n grafana-operator &>/dev/null; then
  phase=$(oc get csv -n grafana-operator -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
  case "$phase" in *Succeeded*) echo "OK";; *) echo "INSTALLING or FAILED (phase: $phase)";; esac
else
  echo "MISSING (optional)"
fi
