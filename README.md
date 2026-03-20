# Red Hat OpenShift AI 3.3 — Installation Manual

**Version:** 3.3 Self-Managed  
**Target Platform:** OpenShift Container Platform 4.20  
**Date:** March 2026  
**Classification:** Internal / Operations

---

## Table of Contents

1. [Overview](#1-overview)
2. [Global Prerequisites](#2-global-prerequisites)
3. [Prerequisite Operators](#3-prerequisite-operators)
4. [Installing the Red Hat OpenShift AI Operator](#4-installing-the-red-hat-openshift-ai-operator)
5. [Configuring the DataScienceCluster](#5-configuring-the-datasciencecluster)
6. [TLS Certificate Management](#6-tls-certificate-management)
7. [OpenTelemetry Observability for RHOAI](#7-opentelemetry-observability-for-rhoai)
8. [Distributed Inference with llm-d](#8-distributed-inference-with-llm-d)
9. [Model as a Service (MaaS)](#9-model-as-a-service-maas)
10. [Validation and Testing](#10-validation-and-testing)
11. [Appendix A — Quick-Reference Commands](#appendix-a--quick-reference-commands)
12. [Appendix B — Troubleshooting](#appendix-b--troubleshooting)
13. [Appendix C — Reference Links](#appendix-c--reference-links)

---

## 1. Overview

Red Hat OpenShift AI (RHOAI) 3.3 is a self-managed AI/ML platform that provides an integrated environment for developing, training, serving, and monitoring models across hybrid cloud environments. This manual covers a full installation plan organized into two tiers.

**RHOAI Basic Features:**

- Dashboard
- Data Science Pipelines
- Model Serving (KServe single-model + ModelMesh multi-model)
- Model Registry
- Ray (distributed workloads) <=== TODO
- Workbenches
- TrustyAI (model monitoring and bias detection)

**Additional Features:**

- Distributed Inference with llm-d (disaggregated prefill/decode, Inference Gateway, KV-cache-aware routing)
- Model as a Service — MaaS (governed, rate-limited LLM access via Gateway API and Connectivity Link)
- Llama Stack Operator (OpenAI-compatible RAG APIs and agentic AI) <=== TODO quizá quitar

**Cross-Cutting Concerns:**

- OpenTelemetry observability (traces, metrics, and logs for RHOAI and model serving components)
- TLS certificate management (via cert-manager Operator or manual certificate generation)

> **Important:** There is no upgrade path from OpenShift AI 2.x to 3.3. This version requires a fresh installation. For distributed inference with llm-d, OCP 4.20 is required.

**Official Documentation:**  
- [RHOAI 3.3 Product Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3)
- [Supported Configurations for 3.x](https://access.redhat.com/articles/rhoai-supported-configs-3.x)
- [Supported Product and Hardware Configurations](https://docs.redhat.com/en/documentation/red_hat_ai/3/html/supported_product_and_hardware_configurations/index)

---

## 2. Global Prerequisites

### 2.1 Cluster Requirements

| Requirement | Specification |
|---|---|
| OpenShift Container Platform | **4.20** |
| Worker nodes (base) | Minimum 2 nodes, 8 vCPU / 32 GiB RAM each |
| Single-node OpenShift | 32 vCPU / 128 GiB RAM |
| GPU nodes (model serving, llm-d) | NVIDIA A100 / H100 / H200 / A10G / L40S or AMD MI250+ |
| Architecture | x86_64 (primary); aarch64, ppc64le, s390x also supported |
| Cluster admin access | Required for operator installation |
| OpenShift CLI (`oc`) | Installed and authenticated |
| Open Data Hub | Must **not** be installed on the cluster |

### 2.2 Storage Requirements

A default StorageClass with dynamic provisioning must be configured. Verify with:

```bash
oc get storageclass | grep '(default)'
```

S3-compatible object storage is needed for Pipelines, Model Registry, and model artifact storage (OpenShift Data Foundation, MinIO, or AWS S3).

### 2.3 Network Requirements

- Outbound access to `registry.redhat.io` and `quay.io` (or a disconnected mirror).
- For llm-d with ROCE: RDMA-capable NICs (see [Section 8.3](#83-roce-networking-optional-but-recommended-for-production)).
- DNS must be properly configured. In private cloud environments, manually configure DNS A/CNAME records after LoadBalancer IPs become available. See [Configuring External DNS for RHOAI 3.x on OpenStack and Private Clouds](https://access.redhat.com/).

### 2.4 Credentials

- Hugging Face token (`HF_TOKEN`) for downloading gated model weights used with llm-d and MaaS.
- Red Hat pull secret (from [console.redhat.com](https://console.redhat.com)).

---

## 3. Prerequisite Operators

RHOAI 3.3 requires several operators installed **before** creating the DataScienceCluster. Install them via **Operators → OperatorHub** in the web console or via CLI Subscription objects.

> **Note on cert-manager:** The cert-manager Operator for Red Hat OpenShift is useful and recommended for automating TLS certificate lifecycle across RHOAI, llm-d, OpenTelemetry, and Llama Stack. However, it is not a hard requirement — you can provide manually generated certificates instead wherever TLS is needed. That said, several components (Kueue-based workloads, llm-d, Llama Stack, OpenTelemetry admission webhooks) document cert-manager as a dependency in their official guides, making it the path of least resistance for most deployments.

### 3.0 ArgoCD

ArgoCD is needed ... 

Installation process:


Screen shots <== TODO

Approve in the next screen.

### 3.0 Certificates using Let's Encrypt

Install Cert Manager Operator:

```sh
cat <<EOF | oc apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  labels:
    app: cert-manager-operator
  name: cert-manager-operator
  namespace: openshift-gitops
spec:
  destination:
    server: 'https://kubernetes.default.svc'
  project: default
  source:
    path: 02-cert-manager-operator
    repoURL: https://github.com/alvarolop/ocp-secured-integration.git
    targetRevision: main
  syncPolicy:
    automated:
      prune: false
      selfHeal: false
EOF
```

# RBAC Permissions for cert-manager and supporting components:

- Allow cert-manager to create and manage Certificates, Certificaterequests, Orders, Challenges, ClusterIssuers, and Issuers (apiGroup: cert-manager.io)
- Allow access to cloudcredential.openshift.io CredentialsRequests for integration with OpenShift cloud-credential-operator (required for some managed certificate use cases)
- Allow access to ServiceMonitors from monitoring.coreos.com to enable monitoring integration

These permissions should be granted at ClusterRole scope if cert-manager manages resources cluster-wide, or in a Role if it is restricted to a namespace.

```sh
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: credentialsrequest-manager
rules:
- apiGroups:
  - cloudcredential.openshift.io
  resources:
  - credentialsrequests
  verbs:
  - get
  - list
  - watch
  - create
  - update
  - patch
  - delete
- apiGroups:
  - monitoring.coreos.com
  resources:
  - servicemonitors
  verbs:
  - get
  - list
  - watch
  - create
  - update
  - patch
  - delete
- apiGroups:
  - cert-manager.io
  resources:
  - clusterissuers
  - issuers
  - certificates
  - certificaterequests
  - orders
  - challenges
  verbs:
  - get
  - list
  - watch
  - create
  - update
  - patch
  - delete
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-credentialsrequest-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: credentialsrequest-manager
subjects:
- kind: ServiceAccount
  name: openshift-gitops-argocd-application-controller
  namespace: openshift-gitops
EOF
```

Install 

```sh
# 0) Check if logged in with oc
if ! oc whoami &>/dev/null; then
  echo "Error: Not logged in to OpenShift (oc). Please run 'oc login ...' with the appropriate cluster credentials before proceeding."
  exit 1
fi

# 1) Wait for the operator to be ready
echo -n "Waiting for cert-manager pods to be ready..."
while [[ $(oc get pods -l app.kubernetes.io/instance=cert-manager -n cert-manager -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True True True" ]]; do echo -n "." && sleep 1; done; echo -n -e "  [OK]\n"

# Configuration
CLUSTER_DOMAIN=$(oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}')
AWS_DEFAULT_REGION="eu-west-1"
echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"
echo "AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}"

if [[ -z "${CLUSTER_DOMAIN}" ]]; then
  echo "Error: CLUSTER_DOMAIN could not be detected. Please ensure the OpenShift DNS operator is running and DNS is configured."
  exit 1
fi

# 2) Ask user to confirm/change AWS region
read -p "AWS region for Route53 DNS (default: ${AWS_DEFAULT_REGION}): " INPUT_AWS_REGION
if [[ -n "${INPUT_AWS_REGION}" ]]; then
  AWS_DEFAULT_REGION="${INPUT_AWS_REGION}"
fi
echo "Using AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}"


# 3) Configure the OpenShift certificates for Ingress and API
cat <<EOF | oc apply -f -
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  labels:
    app: cert-manager-route53
  name: cert-manager-route53
  namespace: openshift-gitops
spec:
  destination:
    server: 'https://kubernetes.default.svc'
  project: default
  source:
    path: 02-cert-manager-route53
    repoURL: https://github.com/alvarolop/ocp-secured-integration.git
    targetRevision: main
    helm:
      parameters:
        - name: clusterDomain
          value: ${CLUSTER_DOMAIN}
        - name: route53.region
          value: ${AWS_DEFAULT_REGION}
        # - name: etcdEncryption.enabled
        #   value: "true"
  syncPolicy:
    automated:
      prune: false
      selfHeal: false
EOF
```

Check the status of the certs:

```sh
oc get certificates.cert-manager.io --all-namespaces -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[0].type,READY:.status.conditions[0].status'
```


### 3.1 Core Dependencies (All Installations)

| Operator | Channel | Purpose | Required For |
|---|---|---|---|
| Red Hat OpenShift Serverless | `stable` | Knative Serving for KServe advanced deployment | KServe |
| Red Hat — Authorino Operator | `managed-services` | Token auth for single-model serving endpoints | KServe |
| cert-manager Operator for Red Hat OpenShift | `stable-v1` | Automated TLS certificate lifecycle | Recommended (see above) |

> **Note on Service Mesh:** Do **not** install OpenShift Service Mesh v2 if you plan to use llm-d, as the included CRDs conflict with the llm-d gateway component. Service Mesh 3.x is required for Llama Stack but is not supported for model serving. RHOAI will configure Service Mesh automatically when needed via the DSC.


```sh
# 1. Cert Manager <== TODO this is done with Alvaro's repo
# oc apply -k llm-d-playbook/gitops/operators/cert-manager
# oc wait --for=condition=ready pod -l app.kubernetes.io/name=cert-manager -n cert-manager --timeout=300s

# 2. MetalLB (bare metal only - skip for cloud)
# oc apply -k llm-d-playbook/gitops/operators/metallb-operator
# oc wait --for=condition=ready pod -l control-plane=controller-manager -n metallb-system --timeout=300s

# 3. Service Mesh 3
oc apply -k ./gitops/operators/servicemeshoperator3/operator/overlays/stable
# Wait for operator to install (check CSV status)
oc get csv -n openshift-operators -w

# 4. Connectivity Link (required for RHOAI 3.0+)
oc apply -k ./gitops/operators/connectivity-link
# Note: InstallPlan may require manual approval due to dependencies
# Check and approve if needed:
oc get installplan -n openshift-operators | grep -i "requiresapproval"
# If an InstallPlan is pending, approve it:
# oc patch installplan <name> -n openshift-operators --type merge -p '{"spec":{"approved":true}}'
# Wait for operators to install
oc get csv -n openshift-operators -w | grep -E "rhcl|authorino|limitador"
# Wait for AuthPolicy CRD to be available
oc wait --for=condition=Established crd/authpolicies.kuadrant.io --timeout=300s

# 5. Red Hat Build of Kueue (needed for workbenches...)
oc apply -k gitops/operators/kueue-operator

# 5. Red Hat OpenShift AI
oc apply -k gitops/operators/rhoai
oc get csv -n redhat-ods-operator -w

# 6. Monitoring operators
# 1) Cluster Observability Operator (optional; metrics / MonitoringStack)
# oc apply -k gitops/operators/cluster-observability-operator
# oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -n openshift-cluster-observability-operator -l operators.coreos.com/openshift-cluster-observability-operator.openshift-cluster-observability-operator= --timeout=300s

# 2) Tempo Operator (distributed tracing)
oc apply -k gitops/operators/tempo-operator
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -n openshift-tempo-operator -l operators.coreos.com/tempo-product.openshift-tempo-operator= --timeout=300s

# 3) OpenTelemetry Operator (collector for traces/metrics/logs)
oc apply -k gitops/operators/opentelemetry-operator
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -n openshift-opentelemetry-operator -l operators.coreos.com/opentelemetry-product.openshift-opentelemetry-operator= --timeout=300s
# If you install Helm charts that use Instrumentation (e.g. llama-stack-demo), wait for the CRD:
# oc wait --for=condition=Established crd/instrumentations.opentelemetry.io --timeout=120s

# 4) Grafana Operator (optional; custom Grafana/dashboards)
oc apply -k gitops/operators/grafana-operator
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -n grafana-operator -l operators.coreos.com/grafana-operator.grafana-operator= --timeout=300s

# Optional: wait for all monitoring operators in one go (if you already applied them)
# oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -n openshift-cluster-observability-operator -l operators.coreos.com/openshift-cluster-observability-operator.openshift-cluster-observability-operator= --timeout=300s
# oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -n openshift-tempo-operator -l operators.coreos.com/tempo-product.openshift-tempo-operator= --timeout=300s
# oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -n openshift-opentelemetry-operator -l operators.coreos.com/opentelemetry-product.openshift-opentelemetry-operator= --timeout=300s
# oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -n grafana-operator -l operators.coreos.com/grafana-operator.grafana-operator= --timeout=300s


# 7. Configure OpenShift AI (DSCInitialization and DataScienceCluster)
# Use helm template (not install): the chart emits resources in multiple namespaces
helm template rhoai ./gitops/instance/rhoai | oc apply -f -

# Wait for LLMInferenceService CRD to be created
oc wait --for=condition=Established crd/llminferenceservices.serving.kserve.io --timeout=300s
# Wait for controller pods to be ready (required for webhook validation)
oc wait --for=condition=ready pod -l control-plane=odh-model-controller -n redhat-ods-applications --timeout=300s
oc wait --for=condition=ready pod -l control-plane=kserve-controller-manager -n redhat-ods-applications --timeout=300s
```

### 3.2 Pipeline Dependencies

| Operator | Channel | Purpose |
|---|---|---|
| Red Hat OpenShift Pipelines | `latest` | Tekton pipelines for data science workflows |


```sh
# Install pipelines
oc apply -k gitops/operators/pipelines
```

### 3.3 GPU and Hardware Dependencies

| Operator | Channel | Purpose |
|---|---|---|
| Node Feature Discovery (NFD) Operator | `stable` | Detects GPU hardware capabilities |
| NVIDIA GPU Operator | `v24.9` or latest | GPU device plugin, drivers, DCGM |

Install NFD first, then the GPU Operator. Create the required custom resources:

```yaml
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec:
  operand:
    image: registry.redhat.io/openshift4/ose-node-feature-discovery-rhel9:v4.20
```

```yaml
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: gpu-cluster-policy
spec:
  operator:
    defaultRuntime: crio
  driver:
    enabled: true
  toolkit:
    enabled: true
  devicePlugin:
    enabled: true
  dcgm:
    enabled: true
  dcgmExporter:
    enabled: true
  validator:
    enabled: true
  mig:
    strategy: single  # or 'mixed' if using MIG partitioning
```

```sh
oc apply -k gitops/instance/nfd
oc apply -k gitops/instance/nvidia
```

See: [NVIDIA GPU Operator on Red Hat OpenShift Container Platform](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/index.html)

### 3.4 Leader Worker Set Operator

```sh
# 9. Leader Worker Set
oc apply -k ./gitops/operators/leader-worker-set
```

#### 3.5 Check Operators

```sh
llm-d-playbook/scripts/check-operators.sh
```

# Adding GPUs in AWS

```sh
export INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
export AWS_REGION="eu-west-1"
export AMI_ID="ami-0b8c325b7499597c6"
export AWS_INSTANCE_TYPE="g5.2xlarge"

for AZ in a b c; do
  helm template gpu-worker ./gitops/instance/machine-sets/gpu-worker \
    --set infrastructureId="${INFRA_ID}" \
    --set region=${AWS_REGION} \
    --set instanceType=${AWS_INSTANCE_TYPE} \
    --set amiId="${AMI_ID}" \
    --set devicePluginConfig="" \
    --set az=${AZ} | oc apply -f -
done

```

# Quick Start Guide to Deploy llm-d

Deploy LLM-D on a connected OpenShift cluster.

## Step 1: Configure the Gateway

Create the GatewayClass and Gateway for LLM-D:

```bash
# oc apply -k gitops/instance/llm-d/gateway

APP_NAME="gateway"
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"
helm template gitops/instance/llm-d/gateway \
  --name-template ${APP_NAME} \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --include-crds | oc apply -f -
```

Verify the Gateway is ready:

```bash
oc get gateway -n openshift-ingress

# Expected output:
# NAME                     CLASS              ADDRESS   PROGRAMMED   AGE
# openshift-ai-inference   openshift-default  ...       True         ...
```

## Step 2: Create Namespace

Manually:

```bash
PROJECT="llm-d-demo"

oc new-project ${PROJECT}
oc label namespace ${PROJECT} modelmesh-enabled=false opendatahub.io/dashboard=true
```

## Step 3: Deploy an LLMInferenceService

### Simple Intelligent Inference: Qwen3-8B-FP8-dynamic Using ModelCar (OCI Container)

Deploy using the inference Helm chart with a values override, 2 instances of the model with 1 GPU each:

Example for a simple intelligent-inference deployment (OCI, qwen3-8b-fp8-dynamic):

Create a values override file:

```sh
cat <<EOF > qwen3-8b-fp8-dynamic-oci.tmp.yaml
deploymentType: intelligent-inference
serviceName: qwen3-8b
replicas: 2
useStartupProbe: true
storage:
  type: oci
  uri: oci://registry.redhat.io/rhelai1/modelcar-qwen3-8b-fp8-dynamic:1.5
model:
  name: alibaba/qwen3-8b
resources:
  limits: { cpu: "4", memory: 16Gi, gpuCount: "1" }
  requests: { cpu: "1", memory: 8Gi, gpuCount: "1" }
env:
  - name: VLLM_ADDITIONAL_ARGS
    value: "--disable-uvicorn-access-log --enable-auto-tool-choice --tool-call-parser hermes"
EOF
```

Render and apply:

```bash
helm template gitops/instance/llm-d/inference --name-template qwen3-8b -n ${PROJECT} \
  -f gitops/instance/llm-d/inference/values.yaml \
  -fqwen3-8b-fp8-dynamic-oci.tmp.yaml \
  --include-crds | oc apply -f -
```

Or

```bash
helm install gitops/instance/llm-d/inference --name-template qwen3-8b -n ${PROJECT} \
  -f gitops/instance/llm-d/inference/values.yaml \
  --set replicas=2 \
  -f qwen3-8b-fp8-dynamic-oci.tmp.yaml
```


Or use `run.sh` with environment variables (see `gitops/instance/llm-d/inference/run.sh`).

<!-- ```bash
oc apply -k gitops/instance/llm-d/intelligent-inference/gpt-oss-20b/overlays/modelcar
``` -->

###  Simple Intelligent Inference: Facebook Opt-125m Using ModelCar (HuggingFace)

```sh
cat <<EOF > facebook-opt-125m-hf.tmp.yaml
deploymentType: intelligent-inference
serviceName: opt-125m
replicas: 1
useStartupProbe: true
storage:
  type: hf
  uri: hf://facebook/opt-125m
model:
  name: facebook/opt-125m
resources:
  limits: { cpu: "2", memory: 8Gi, gpuCount: 1 }
  requests: { cpu: "1", memory: 4Gi, gpuCount: 1 }
# env:
#   - name: VLLM_ADDITIONAL_ARGS
#     value: "--disable-uvicorn-access-log --enable-auto-tool-choice --tool-call-parser hermes"
EOF
```

Render and apply:

```bash
helm template gitops/instance/llm-d/inference --name-template opt-125m -n ${PROJECT} \
  -f gitops/instance/llm-d/inference/values.yaml \
  -f facebook-opt-125m-hf.tmp.yaml \
  --include-crds | oc apply -f -
```

Or

```bash
helm install gitops/instance/llm-d/inference --name-template opt-125m -n ${PROJECT} \
  -f gitops/instance/llm-d/inference/values.yaml \
  --set replicas=2 \
  -f facebook-opt-125m-hf.tmp.yaml
```
If using HuggingFace, ensure you have configured access to the appropriate model hub and secrets as needed.


## Step 4: Verify Deployment

### Check LLMInferenceService Status

```bash
oc get llminferenceservice -w -n ${PROJECT}

# Expected output:
# NAME          URL                                              READY   AGE
# qwen3-8b   http://<gateway-url>/${PROJECT}/qwen3-8b       True    5m
```

### Check Pods

```bash
oc get pods -w -n ${PROJECT}

# Expected output:
# NAME                                            READY   STATUS    AGE
# qwen3-8b-kserve-xxxxx-xxxxx                 1/1     Running   3m
# qwen3-8b-kserve-xxxxx-xxxxx                 1/1     Running   3m
# qwen3-8b-kserve-router-scheduler-xxxxx      1/1     Running   3m
```

### Watch Pod Logs

```bash
# Watch vLLM server logs

oc logs -f -l app.kubernetes.io/name=qwen3-8b,app.kubernetes.io/component=llminferenceservice-workload -n ${PROJECT}

# Watch scheduler logs
oc logs -f -l app.kubernetes.io/name=qwen3-8b,app.kubernetes.io/component=llminferenceservice-router-scheduler -n ${PROJECT}
```

## Step 5: Test the Endpoint

### Get the Inference URL

```bash
INFERENCE_URL=$(oc get gateway openshift-ai-inference -n openshift-ingress -o json | jq -r '.spec.listeners[] | select(.name=="https").hostname')
echo "Inference URL: https://${INFERENCE_URL}"
```

### List Available Models

```bash
curl -s https://${INFERENCE_URL}/${PROJECT}/qwen3-8b/v1/models | jq
```

### Send a Completion Request

```bash
curl -s -X POST https://${INFERENCE_URL}/${PROJECT}/qwen3-8b/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "alibaba/qwen3-8b",
    "prompt": "Explain the difference between supervised and unsupervised learning.",
    "max_tokens": 50,
    "temperature": 0.7
  }' | jq '.choices[0].text'
```

### Send a Chat Completion Request

```bash
curl -s -X POST https://${INFERENCE_URL}/${PROJECT}/qwen3-8b/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "alibaba/qwen3-8b",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant. Be VERY concise"},
      {"role": "user", "content": "Answer to the Ultimate Question of Life, the Universe, and Everything."}
    ],
    "max_tokens": 200,
    "temperature": 0.7
  }' | jq '.choices[0].message.content'
```

## Step 6: Deploy Monitoring (Optional)

Deploy Prometheus and Grafana for performance monitoring:

```bash
until oc apply -k gitops/instance/llm-d-monitoring; do : ; done

# Get Grafana URL
oc get route grafana -n llm-d-monitoring -o jsonpath='{.spec.host}'
```

Access Grafana with default credentials: `admin` / `admin`

## Quick Start Summary

| Step | Command | Verification |
|------|---------|--------------|
| 1. Configure Gateway | `CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'); helm template gitops/instance/llm-d/gateway --name-template gateway --set clusterDomain="${CLUSTER_DOMAIN}" --include-crds \| oc apply -f -` | `oc get gateway -n openshift-ingress` |
| 2. Create namespace | `PROJECT=llm-d-demo; oc new-project ${PROJECT}; oc label namespace ${PROJECT} modelmesh-enabled=false opendatahub.io/dashboard=true` | `oc get ns ${PROJECT}` |
| 3. Deploy model | Create override file (see Step 3 above), then: `helm template gitops/instance/llm-d/inference --name-template qwen3-8b -n ${PROJECT} -f gitops/instance/llm-d/inference/values.yaml -f qwen3-8b-fp8-dynamic-oci.tmp.yaml --include-crds \| oc apply -f -` | `oc get llminferenceservice -n ${PROJECT}` |
| 4. Test endpoint | `INFERENCE_URL=$(oc get gateway openshift-ai-inference -n openshift-ingress -o json \| jq -r '.spec.listeners[] \| select(.name=="https").hostname'); curl -s https://${INFERENCE_URL}/${PROJECT}/qwen3-8b/v1/models \| jq` | JSON response |

## Cleanup

Resources were applied with `helm template ... | oc apply -f -` (no Helm release), so remove them with the same template piped to `oc delete -f -`:

```bash
# Remove inference deployment (same as Step 3, with oc delete)
helm template gitops/instance/llm-d/inference --name-template qwen3-8b -n ${PROJECT} \
  -f gitops/instance/llm-d/inference/values.yaml \
  -f qwen3-8b-fp8-dynamic-oci.tmp.yaml \
  --include-crds | oc delete -f -

# Remove gateway (same as Step 1, with oc delete)
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
helm template gitops/instance/llm-d/gateway --name-template gateway \
  --set clusterDomain="${CLUSTER_DOMAIN}" --include-crds | oc delete -f -

# Delete namespace
oc delete ns ${PROJECT}
```

Alternatively, delete only the LLMInferenceService and leave the gateway in place: `oc delete llminferenceservice qwen3-8b -n ${PROJECT}`.

