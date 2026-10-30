# Phase 0 — Cluster Validation

> Part of the [llm-d-guide Co-pilot Runbook](../../AGENTS.md). See the
> [Phase Map](../../AGENTS.md#phase-map) for the full sequence.

**Goal:** Confirm the cluster is ready before installing anything.

**Run the preflight script first — it covers all required checks:**

```bash
./scripts/preflight-validation.sh
```

If any check fails, use these individual commands to diagnose:

```bash
# OCP version — RHOAI 3.5 supports 4.20–4.21 (llm-d requires 4.20+)
oc version

# OCP minor version — determines OLMv0 (4.20) vs OLMv1 (4.21+) install path
OCP_MINOR=$(oc version -o json | jq -r '.openshiftVersion' | cut -d. -f2)
echo "OCP 4.${OCP_MINOR} detected — operator install method: $([ "${OCP_MINOR}" -ge 21 ] && echo 'OLMv1 (ClusterExtension)' || echo 'OLMv0 (Subscription)')"

# Cluster admin access
oc whoami
oc auth can-i '*' '*' --all-namespaces

# Default StorageClass exists
oc get storageclass | grep '(default)'

# No ODH installed (must be absent)
oc get csv -A | grep -i opendatahub

# No Service Mesh 2.x installed (must be absent). SM 3.x is only for Llama Stack, not llm-d.
oc get csv -A | grep -i servicemeshoperator | grep -v servicemeshoperator3

# Connected clusters: plan outbound access to registry.redhat.io and quay.io (or mirrors)

# DNS base domain
oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}'

# Registry pull access (expect login succeeded)
oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' \
  | base64 -d | jq '.auths | keys'
```

**Human gate:** Confirm env vars, region, and that all checks pass before proceeding.

**End of Phase 0:** Stop here and report validation results to the user. Wait for confirmation before proceeding to [Phase 1](01-tls-cert-automation/README.md).
