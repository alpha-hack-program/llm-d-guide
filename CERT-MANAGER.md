# cert-manager TLS Automation

This document explains how TLS certificate automation is implemented in this repo using the cert-manager Operator and AWS Route53, with a focus on how AWS credentials are provisioned and consumed.

---

## Overview

cert-manager automates the full TLS lifecycle: requesting, signing, renewing, and distributing certificates. This repo uses Let's Encrypt DNS-01 challenges via AWS Route53 to issue certificates for the OpenShift Ingress and API endpoints.

All cert-manager configuration lives under `gitops/operators/cert-manager-operator/` and `gitops/operators/cert-manager-route53/`.

---

## `aws-creds` — how it is provisioned and used

`aws-creds` is a Kubernetes Secret in the `cert-manager` namespace that holds AWS IAM credentials (`aws_access_key_id`, `aws_secret_access_key`). It is only created on AWS deployments (`cloud=aws`) and is used exclusively by the cert-manager TLS automation flow.

### Data flow

```
CredentialsRequest CR
    → OpenShift Cloud Credential Operator (CCO) mints a scoped IAM keypair
        → aws-creds Secret  (cert-manager namespace)
            ├── cert-manager operator  (via CLOUD_CREDENTIALS_SECRET_NAME env var)
            └── ClusterIssuer letsencrypt / letsencrypt-staging
                    → DNS-01 ACME challenge via Route53
                            → TLS certificates for cluster Ingress and API
```

### Step 1 — Provisioned by OpenShift Cloud Credential Operator

`gitops/operators/cert-manager-operator/templates/credentialsrequest.yaml` creates a `CredentialsRequest` CR (only when `cloud=aws`). The CCO reads it and mints a scoped IAM keypair with the minimum Route53 permissions required for DNS-01 challenge solving:

| IAM Permission | Purpose |
|---|---|
| `route53:GetChange` | Poll propagation status of a DNS change |
| `route53:ChangeResourceRecordSets` | Create/delete the ACME `_acme-challenge` TXT record |
| `route53:ListResourceRecordSets` | Read existing records before modifying |
| `route53:ListHostedZonesByName` | Look up the hosted zone ID from the domain name |

The resulting credentials are written into the `aws-creds` Secret in the `cert-manager` namespace.

### Step 2 — Referenced by the cert-manager operator Subscription

`gitops/operators/cert-manager-operator/templates/subscription.yaml` (when `cloud=aws`) injects:

```yaml
env:
  - name: CLOUD_CREDENTIALS_SECRET_NAME
    value: aws-creds
```

This env var tells the cert-manager operator where to find the cloud credentials to mount into the DNS-01 solver.

### Step 3 — Consumed by both ClusterIssuers

`gitops/operators/cert-manager-route53/templates/clusterissuer-letsencrypt.yaml` and `clusterissuer-letsencrypt-staging.yaml` reference `aws-creds` directly in the Route53 DNS-01 solver:

```yaml
solvers:
  - dns01:
      route53:
        accessKeyIDSecretRef:
          name: aws-creds
          key: aws_access_key_id
        region: "{{ .Values.route53.region }}"
        secretAccessKeySecretRef:
          name: aws-creds
          key: aws_secret_access_key
```

The two issuers are identical except for the ACME server URL:
- `letsencrypt` → `https://acme-v02.api.letsencrypt.org/directory` (production)
- `letsencrypt-staging` → `https://acme-staging-v02.api.letsencrypt.org/directory` (testing)

---

## Non-AWS deployments

When `cloud=none` (bare metal, vSphere, etc.):
- The `CredentialsRequest` CR is not rendered.
- `CLOUD_CREDENTIALS_SECRET_NAME` is not set on the Subscription.
- `aws-creds` does not exist.
- You must supply certificates via a different mechanism (HTTP-01 challenge, a different DNS provider, or manually).

---

## Verifying certificate issuance

```bash
# Check ClusterIssuers are Ready
oc get clusterissuer

# Check issued certificates across all namespaces
oc get certificates.cert-manager.io --all-namespaces \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[0].type,READY:.status.conditions[0].status'

# Inspect a certificate's events if it is stuck
oc describe certificate <name> -n <namespace>

# Check DNS-01 challenge status
oc get challenges.acme.cert-manager.io -A
```

---

## Troubleshooting

| Symptom | Likely cause | Resolution |
|---|---|---|
| `CertificateRequest` stuck in `Pending` | DNS-01 TXT record not propagating | Check `oc get challenges -A` and verify Route53 hosted zone ID is correct |
| `ClusterIssuer` not `Ready` | `aws-creds` Secret missing or CCO not provisioned it yet | Check `oc get credentialsrequest -n openshift-cloud-credential-operator` and `oc get secret aws-creds -n cert-manager` |
| cert-manager pods not starting | Operator CSV not `Succeeded` | Wait for `oc get csv -n cert-manager-operator` to show `Succeeded`, then re-run the helm apply |
| First `helm template | oc apply` fails on `CertManager` CR | CRD not registered until CSV is `Succeeded` | Re-run the command after CSV reaches `Succeeded` — it applies cleanly on the second pass |
