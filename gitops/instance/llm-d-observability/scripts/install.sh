#!/bin/bash
set -e

# Cluster Observability Operator Installation Script
# Installs COO with Perses dashboards for llm-d metrics monitoring

# Configuration
LLM_NAMESPACE="${LLM_NAMESPACE:-llm-d-demo}"
DASHBOARD_NAMESPACE="${DASHBOARD_NAMESPACE:-redhat-ods-monitoring}"

echo "╔════════════════════════════════════════════════════════════════════════╗"
echo "║  Cluster Observability Operator Installation for llm-d Metrics        ║"
echo "╚════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Configuration:"
echo "  llm-d namespace:       ${LLM_NAMESPACE}"
echo "  Dashboard namespace:   ${DASHBOARD_NAMESPACE}"
echo ""

# Check prerequisites
echo "📋 Checking prerequisites..."

if ! command -v oc &> /dev/null; then
    echo "❌ ERROR: oc CLI not found. Please install OpenShift CLI."
    exit 1
fi

if ! oc whoami &> /dev/null; then
    echo "❌ ERROR: Not logged in to OpenShift. Run 'oc login' first."
    exit 1
fi

if ! oc auth can-i '*' '*' --all-namespaces &> /dev/null; then
    echo "❌ ERROR: Cluster admin access required."
    exit 1
fi

if ! oc get namespace ${LLM_NAMESPACE} &> /dev/null; then
    echo "❌ ERROR: Namespace ${LLM_NAMESPACE} does not exist."
    echo "   Create it first or set LLM_NAMESPACE environment variable."
    exit 1
fi

echo "✅ Prerequisites check passed"
echo ""

# Step 1: Install Cluster Observability Operator
echo "════════════════════════════════════════════════════════════════════════"
echo "Step 1/6: Installing Cluster Observability Operator"
echo "════════════════════════════════════════════════════════════════════════"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPERATOR_DIR="${SCRIPT_DIR}/../../operators/cluster-observability-operator"

if [ ! -d "${OPERATOR_DIR}" ]; then
    echo "❌ ERROR: Operator directory not found at ${OPERATOR_DIR}"
    exit 1
fi

oc apply -k "${OPERATOR_DIR}"

echo "⏳ Waiting for operator to be ready (this may take 2-3 minutes)..."
sleep 30

# Wait for CSV to exist first
for i in {1..60}; do
    if oc get csv -n openshift-cluster-observability-operator cluster-observability-operator.v1.4.0 &> /dev/null; then
        break
    fi
    echo -n "."
    sleep 5
done
echo ""

# Now wait for it to succeed
oc wait --for=jsonpath='{.status.phase}'=Succeeded \
  csv cluster-observability-operator.v1.4.0 \
  -n openshift-cluster-observability-operator \
  --timeout=300s

echo "✅ Cluster Observability Operator installed successfully"
echo ""

# Step 2: Create UIPlugin
echo "════════════════════════════════════════════════════════════════════════"
echo "Step 2/6: Creating UIPlugin for Perses"
echo "════════════════════════════════════════════════════════════════════════"

cat <<'EOF' | oc apply -f -
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: monitoring
spec:
  type: Monitoring
  monitoring:
    perses:
      enabled: true
EOF

sleep 5

oc get uiplugin monitoring -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' | grep -q "True"
if [ $? -eq 0 ]; then
    echo "✅ UIPlugin created successfully"
else
    echo "⚠️  UIPlugin created but may not be ready yet. Check status with: oc get uiplugin monitoring"
fi
echo ""
echo "ℹ️  NOTE: You may need to refresh your browser (Ctrl+F5) to see 'Dashboards (Perses)'"
echo ""

# Step 3: Enable User Workload Monitoring
echo "════════════════════════════════════════════════════════════════════════"
echo "Step 3/6: Enabling User Workload Monitoring"
echo "════════════════════════════════════════════════════════════════════════"

if oc get configmap cluster-monitoring-config -n openshift-monitoring &> /dev/null; then
    CURRENT_CONFIG=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}')
    if echo "${CURRENT_CONFIG}" | grep -q "enableUserWorkload: true"; then
        echo "✅ User Workload Monitoring already enabled"
    else
        echo "⚠️  ConfigMap exists but enableUserWorkload not set. Updating..."
        cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
        echo "✅ User Workload Monitoring enabled"
    fi
else
    cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
    echo "✅ User Workload Monitoring enabled"
fi

echo "⏳ Waiting for prometheus-user-workload pods to start (this may take 1-2 minutes)..."
sleep 60

# Wait for pods to be ready
oc wait --for=condition=ready pod \
  -l app.kubernetes.io/name=prometheus \
  -n openshift-user-workload-monitoring \
  --timeout=180s

echo "✅ User Workload Monitoring pods are ready"
echo ""

# Step 4: Create ServiceMonitors
echo "════════════════════════════════════════════════════════════════════════"
echo "Step 4/6: Creating ServiceMonitors for llm-d metrics"
echo "════════════════════════════════════════════════════════════════════════"

cat <<EOF | oc apply -f -
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: llm-d-workload-metrics
  namespace: ${LLM_NAMESPACE}
  labels:
    app: llm-d
spec:
  selector:
    matchLabels:
      app.kubernetes.io/part-of: llminferenceservice
      kserve.io/component: workload
  endpoints:
  - port: https
    interval: 30s
    path: /metrics
    scheme: https
    tlsConfig:
      insecureSkipVerify: true
  namespaceSelector:
    matchNames:
    - ${LLM_NAMESPACE}
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: llm-d-epp-metrics
  namespace: ${LLM_NAMESPACE}
  labels:
    app: llm-d
spec:
  selector:
    matchLabels:
      app.kubernetes.io/part-of: llminferenceservice
      app.kubernetes.io/component: llminferenceservice-router-scheduler
  endpoints:
  - port: metrics
    interval: 30s
    path: /metrics
    scheme: http
  namespaceSelector:
    matchNames:
    - ${LLM_NAMESPACE}
EOF

echo "✅ ServiceMonitors created in namespace ${LLM_NAMESPACE}"
echo ""

# Step 5: Create Perses Datasource
echo "════════════════════════════════════════════════════════════════════════"
echo "Step 5/6: Creating Perses Datasource"
echo "════════════════════════════════════════════════════════════════════════"

# Create ServiceAccount and RBAC
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: perses-prometheus-reader
  namespace: ${DASHBOARD_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: perses-prometheus-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-monitoring-view
subjects:
- kind: ServiceAccount
  name: perses-prometheus-reader
  namespace: ${DASHBOARD_NAMESPACE}
EOF

sleep 3

# Generate token
echo "🔑 Generating ServiceAccount token..."
TOKEN=$(oc create token perses-prometheus-reader -n ${DASHBOARD_NAMESPACE} --duration=8760h)

# Create secret with token
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: prometheus-datasource-secret
  namespace: ${DASHBOARD_NAMESPACE}
type: Opaque
stringData:
  BearerToken: "${TOKEN}"
EOF

# Create datasource
cat <<EOF | oc apply -f -
apiVersion: perses.dev/v1alpha2
kind: PersesDatasource
metadata:
  name: prometheus-datasource
  namespace: ${DASHBOARD_NAMESPACE}
spec:
  config:
    display:
      name: "Thanos Querier Datasource"
    default: true
    plugin:
      kind: "PrometheusDatasource"
      spec:
        proxy:
          kind: HTTPProxy
          spec:
            url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
            secret: prometheus-datasource-secret
  client:
    tls:
      enable: true
      caCert:
        type: file
        certPath: /ca/service-ca.crt
EOF

sleep 5

oc get persesdatasource prometheus-datasource -n ${DASHBOARD_NAMESPACE} \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' | grep -q "True"
if [ $? -eq 0 ]; then
    echo "✅ PersesDatasource created successfully"
else
    echo "⚠️  PersesDatasource created but may not be ready yet. Check status with:"
    echo "   oc get persesdatasource prometheus-datasource -n ${DASHBOARD_NAMESPACE}"
fi
echo ""

# Step 6: Create Perses Dashboard
echo "════════════════════════════════════════════════════════════════════════"
echo "Step 6/6: Creating Perses Dashboard for llm-d (Intelligent Inference)"
echo "════════════════════════════════════════════════════════════════════════"

echo "📊 Applying Intelligent Inference dashboard (well-lit path specific)..."
oc apply -f "${SCRIPT_DIR}/perses-dashboard-intelligent-inference.yaml"

sleep 5

oc get persesdashboard llm-d-intelligent-inference -n ${DASHBOARD_NAMESPACE} \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' | grep -q "True"
if [ $? -eq 0 ]; then
    echo "✅ PersesDashboard created successfully"
else
    echo "⚠️  PersesDashboard created but may not be ready yet. Check status with:"
    echo "   oc get persesdashboard llm-d-intelligent-inference -n ${DASHBOARD_NAMESPACE}"
fi
echo ""

# Summary
echo "╔════════════════════════════════════════════════════════════════════════╗"
echo "║                    ✅ Installation Complete!                           ║"
echo "╚════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "📊 Dashboard Access:"
echo "   1. Open OpenShift Console in your browser"
echo "   2. Navigate to: Observe → Dashboards (Perses)"
echo "   3. Select: 'llm-d Intelligent Inference (Prefix Caching + EPP)'"
echo ""
echo "💡 Well-Lit Path: Intelligent Inference"
echo "   Your deployment uses EPP (Endpoint Picker) for cache-aware routing."
echo "   Key metrics: Cache hit rate > 80%, TTFT reduction 50-80%, EPP routing."
echo ""
echo "ℹ️  NOTE: The dashboard will be empty until traffic is sent to the model."
echo ""
echo "🧪 To generate test metrics, run:"
echo "   ${SCRIPT_DIR}/generate-metrics.sh"
echo ""
echo "📝 For detailed documentation, see:"
echo "   ${SCRIPT_DIR}/INSTALL.md"
echo "   ${SCRIPT_DIR}/../../../WELL-LIT-PATH-MONITORING.md"
echo ""

# Verification
echo "🔍 Quick Verification:"
echo ""
echo "Operator Status:"
oc get csv cluster-observability-operator.v1.4.0 -n openshift-cluster-observability-operator \
  -o jsonpath='  CSV: {.metadata.name} - {.status.phase}{"\n"}'

echo "UIPlugin Status:"
oc get uiplugin monitoring -o jsonpath='  UIPlugin: {.metadata.name} - Available: {.status.conditions[?(@.type=="Available")].status}{"\n"}'

echo "User Workload Monitoring:"
POD_COUNT=$(oc get pods -n openshift-user-workload-monitoring --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "  Pods running: ${POD_COUNT}/5"

echo "ServiceMonitors:"
SM_COUNT=$(oc get servicemonitor -n ${LLM_NAMESPACE} -l app=llm-d --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "  Created: ${SM_COUNT}/2 in namespace ${LLM_NAMESPACE}"

echo "Datasource:"
oc get persesdatasource prometheus-datasource -n ${DASHBOARD_NAMESPACE} \
  -o jsonpath='  {.metadata.name} - Available: {.status.conditions[?(@.type=="Available")].status}{"\n"}' 2>/dev/null

echo "Dashboard:"
oc get persesdashboard llm-d-intelligent-inference -n ${DASHBOARD_NAMESPACE} \
  -o jsonpath='  {.spec.display.name} - Available: {.status.conditions[?(@.type=="Available")].status}{"\n"}' 2>/dev/null

echo ""
