# Phase 1 — Bare Metal / Other: TLS

> Part of [Phase 1 — TLS Certificate Automation](README.md). Read the shared README first.

Bare metal and other non-cloud platforms have no DNS-01 provider available in this repo's charts
(no Route53, no Google Cloud DNS equivalent), so **Let's Encrypt is not an option** —
`TLS_ISSUER=local-ca` is the only path.

Set `cloud=none` and `issueCerts=false` when installing the cert-manager operator (README Step 1):

```bash
CLOUD=none
ISSUE_CERTS=false
```

This installs the operator with no `CredentialsRequest` and no cloud credentials at all.

Then follow [README.md Step 2 — Local CA](README.md#step-2--local-ca-or-lets-encrypt) exactly as
written — it is fully platform-agnostic. The trust-bundle injection step (`user-ca-bundle` +
`proxy/cluster` patch) is **mandatory and expected to succeed** on a self-managed bare-metal
cluster (unlike on OpenShift Dedicated/ROSA — see [gcp.md](gcp.md) if you're unsure whether your
cluster is managed).

If your bare-metal cluster is actually a managed offering (uncommon, but possible via some
on-prem-as-a-service arrangements), check for the same `sre-*-validation` webhooks described in
[gcp.md](gcp.md) before assuming the trust-bundle step will succeed:

```bash
oc get validatingwebhookconfigurations | grep sre-
```

If present, treat your cluster as "managed" for the purposes of this phase and follow the
managed-cluster guidance in [README.md Step 0](README.md#step-0--managed-clusters-use-the-existing-public-certificate)
instead — though on true bare metal there is usually no pre-provisioned public certificate
either, in which case local-ca remains the only option and the trust-bundle step would need a
support-channel workaround specific to that managed offering.
