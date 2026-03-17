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
