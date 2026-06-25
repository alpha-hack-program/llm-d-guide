# Validation Commands

> Part of the [llm-d-guide Co-pilot Runbook]](../../AGENTS.md). Use these commands anytime to check
> cluster health.

## Core infrastructure

```bash
# All operator CSVs — any non-Succeeded is a problem
oc get csv -A | grep -v Succeeded

# RHOAI pods
oc get pods -n redhat-ods-applications

# llm-d CRDs
oc get crd | grep llminference

# LeaderWorkerSet CRD
oc get crd | grep leaderworkerset

# Gateway status
oc get gateway,httproute -n openshift-ingress

# Active inference services and external models
oc get llminferenceservice -A
oc get externalmodel -A

# GPU node capacity
oc get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.capacity.nvidia\.com/gpu'

# Hardware profiles visibility check
kubectl get hardwareprofile -n redhat-ods-applications \
  -o custom-columns="NAME:.metadata.name,TYPE:.spec.scheduling.type,VISIBILITY:.metadata.annotations.opendatahub\.io/dashboard-feature-visibility"
```

## MaaS core

```bash
oc get kuadrant -n kuadrant-system
oc get pods -n kuadrant-system
oc get pods -n redhat-ods-applications -l app.kubernetes.io/name=maas-api
oc get gateway maas-default-gateway -n openshift-ingress
oc get authconfig -A | grep -v "^NAMESPACE"
```

## MaaS subscription stack

```bash
oc get tenant,maasmodelref,maassubscription,maasauthpolicy -A
oc get envoyfilter maas-default-gateway-authn-ssl -n openshift-ingress  # TLS EnvoyFilter
oc get authpolicy,tokenratelimitpolicy -n llm-d-demo                    # Kuadrant policies
```

## Authorino TLS

```bash
oc get authorino authorino -n kuadrant-system -o jsonpath='{.spec.listener.tls.enabled}'
oc get secret authorino-server-cert -n kuadrant-system
```

## ExternalModel credential secrets

```bash
# Must have bbr-managed label
oc get secrets -A -l inference.networking.k8s.io/bbr-managed=true
```

## Optional — Kueue status

Only if Kueue was installed for GPUaaS/distributed workloads:

```bash
oc get clusterqueue
oc get localqueue -A
oc get resourceflavor
```
