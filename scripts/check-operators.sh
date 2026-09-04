#!/bin/bash

OCP_MINOR=$(oc version -o json 2>/dev/null | jq -r '.openshiftVersion' | cut -d. -f2)

FAILURES=0

check_operator() {
  local label="$1"
  local csv_pattern="$2"
  local csv_namespace="$3"
  local ce_name="$4"
  local required="${5:-true}"

  echo -n "${label}: "

  if oc get csv -n "${csv_namespace}" 2>/dev/null | grep -q "${csv_pattern}"; then
    echo "OK (OLMv0)"
    return 0
  fi

  if [[ -n "${ce_name}" ]] && oc get clusterextension "${ce_name}" &>/dev/null; then
    local installed
    installed=$(oc get clusterextension "${ce_name}" -o jsonpath='{.status.conditions[?(@.type=="Installed")].status}' 2>/dev/null)
    if [[ "${installed}" == "True" ]]; then
      echo "OK (OLMv1)"
      return 0
    else
      echo "INSTALLING (OLMv1 — Installed=${installed})"
      FAILURES=$((FAILURES + 1))
      return 1
    fi
  fi

  if [[ "${required}" == "true" ]]; then
    echo "MISSING"
    FAILURES=$((FAILURES + 1))
  else
    echo "MISSING (optional)"
  fi
  return 0
}

echo "=== Checking Required Operators (OCP 4.${OCP_MINOR}) ==="

check_operator "Cert Manager" "cert-manager" "cert-manager-operator" "cert-manager-operator"

echo -n "Connectivity Link: "
if oc get csv -n openshift-operators 2>/dev/null | grep -q "rhcl-operator"; then
  rhcl_ver=$(oc get csv -n openshift-operators -o jsonpath='{.items[?(@.spec.displayName=="Red Hat Connectivity Link")].spec.version}' 2>/dev/null)
  if [[ "$rhcl_ver" =~ ^1\.3\.([0-9]+)$ ]]; then
    patch="${BASH_REMATCH[1]}"
    if (( patch >= 5 )); then
      echo "OK (OLMv0, ${rhcl_ver})"
    else
      echo "WARN: ${rhcl_ver} installed (RHOAI 3.5 requires >= 1.3.5 — see docs/reference/rhcl-version-pin.md)"
      FAILURES=$((FAILURES + 1))
    fi
  elif [[ -n "$rhcl_ver" ]]; then
    echo "WARN: ${rhcl_ver} installed (pin is 1.3.x >= 1.3.5 — see docs/reference/rhcl-version-pin.md)"
    FAILURES=$((FAILURES + 1))
  else
    echo "OK (OLMv0)"
  fi
elif oc get clusterextension rhcl-operator &>/dev/null; then
  installed=$(oc get clusterextension rhcl-operator -o jsonpath='{.status.conditions[?(@.type=="Installed")].status}' 2>/dev/null)
  if [[ "${installed}" == "True" ]]; then
    echo "OK (OLMv1 — verify RHCL CSV >= 1.3.5 with oc get csv -n openshift-operators | grep rhcl)"
  else
    echo "INSTALLING (OLMv1 — Installed=${installed})"
    FAILURES=$((FAILURES + 1))
  fi
else
  echo "MISSING"
  FAILURES=$((FAILURES + 1))
fi

check_operator "OpenShift AI" "rhods" "redhat-ods-operator" "rhods-operator"
# LeaderWorkerSet, NFD, NVIDIA: OLMv0 only (bundles don't support AllNamespaces)
check_operator "Leader Worker Set" "leader-worker-set" "openshift-lws-operator" ""
check_operator "Node Feature Discovery" "nfd" "openshift-nfd" ""
check_operator "NVIDIA GPU Operator" "gpu-operator" "nvidia-gpu-operator" ""

echo ""
echo "=== Monitoring Operators ==="

check_operator "Cluster Observability Operator" "cluster-observability" "openshift-cluster-observability-operator" "cluster-observability-operator"
# Tempo, OpenTelemetry: OLMv0 only (RHOAI detects via CSV, not ClusterExtension)
check_operator "Tempo Operator" "tempo" "openshift-tempo-operator" ""
check_operator "OpenTelemetry Operator" "opentelemetry" "openshift-opentelemetry-operator" ""
check_operator "Grafana Operator" "grafana" "grafana-operator" "" "false"

exit ${FAILURES}
