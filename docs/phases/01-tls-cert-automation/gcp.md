# Phase 1 — GCP: TLS

> Part of [Phase 1 — TLS Certificate Automation](README.md). Read the shared README first.

**Live-validated** against an OpenShift Dedicated (OSD) 4.22 cluster on GCP (CCO in Manual mode
with Workload Identity Federation). The findings below are specific to GCP and to managed
(OSD/ROSA-style) clusters more broadly.

## Recommended path: use the existing public certificate (managed clusters)

**This is the primary, tested, zero-setup path for GCP OpenShift Dedicated.** Follow
[README.md Step 0](README.md#step-0--managed-clusters-use-the-existing-public-certificate) — do
not install cert-manager at all unless you have a specific need for automated issuance of
*other* certificates.

Confirmed live: the cluster already had a Let's Encrypt wildcard certificate
(`*.apps.<cluster-domain>` + `api.<cluster-domain>`) referenced by
`ingresscontroller/default .spec.defaultCertificate.name`, issued and rotated by Red Hat — this
exists before Phase 1 starts and requires no action. `curl` against a Gateway using this secret
validates with zero flags (no `-k`, no custom CA trust) — a real end-to-end tested result, not a
theoretical claim.

This also sidesteps a hard blocker described below: on managed clusters you *cannot* complete the
local-ca trust-bundle injection step even if you wanted to.

## Why local-ca's trust-bundle step fails on managed GCP clusters (and any OSD/ROSA cluster)

Confirmed live: OSD ships a set of `sre-*-validation` admission webhooks
(`sre-regular-user-validation` is the relevant one) that reject, **regardless of RBAC**:
- `configmaps` CREATE/UPDATE/DELETE in protected namespaces (including `openshift-config`)
- `proxies.config.openshift.io` (i.e. `proxy/cluster`) of any kind
- `apiservers.config.openshift.io`, `machine.openshift.io/*`, and several other cluster-scoped
  resource types

The error is explicit and easy to recognize:
```
Error from server (Forbidden): error when creating "STDIN": admission webhook
"regular-user-validation.managed.openshift.io" denied the request: Prevented from accessing Red
Hat managed resources.
```

This means the README's local-ca "inject CA into cluster trust bundle" step
(`oc create configmap user-ca-bundle -n openshift-config` + `oc patch proxy/cluster`) **cannot
succeed** on a managed cluster, even logged in as a user for whom
`oc auth can-i '*' '*' --all-namespaces` returns `yes` — the webhook checks identity/group
membership independently of RBAC. There is no customer-facing workaround; it would require a Red
Hat support case for SRE to apply it on your behalf. **Use the existing public certificate (above)
instead** — it needs no trust bundle changes at all.

The local-ca `Certificate` CRs themselves (`ocp-ingress`, `ocp-api`) still apply and reach
`Ready: True` fine on a managed cluster — only the trust-bundle injection step is blocked. If you
apply local-ca anyway (e.g. to get a cert-manager-issued secret for a specific Gateway), downstream
components that validate TLS (like `maas-ui`) will see an untrusted cert unless you fall back to
the public certificate from Step 0 for the Gateway listeners specifically.

## Self-managed (IPI) GCP: Let's Encrypt via Google Cloud DNS — documented, not live-validated

**Not exercised in this session** — the test cluster was managed (OSD), where this path is
unnecessary (see above). This section documents the path for a **self-managed GCP IPI** cluster
with CCO in Mint mode.

Chart: [`gitops/operators/cert-manager-clouddns`](../../../gitops/operators/cert-manager-clouddns)
(mirrors `cert-manager-route53`, using cert-manager's native Google CloudDNS ACME solver).

Set `cloud=gcp` and `issueCerts=true` when installing the cert-manager operator (README Step 1):

```bash
CLOUD=gcp
ISSUE_CERTS=true
```

This adds `CLOUD_CREDENTIALS_SECRET_NAME=gcp-creds` to the operator Subscription and deploys a
`GCPProviderSpec` `CredentialsRequest` (`predefinedRoles: [roles/dns.admin]`) targeting a
`gcp-creds` secret in the `cert-manager` namespace.

> **Manual-mode CCO / Workload Identity Federation (the default on GCP OpenShift Dedicated, and
> possibly on some self-managed clusters too) — check first:**
> ```bash
> oc get cloudcredential cluster -o jsonpath='{.spec.credentialsMode}'
> # "Mint" → the CredentialsRequest above is auto-fulfilled, continue below.
> # "Manual" → NOT auto-fulfilled. Run `ccoctl gcp create-service-accounts` (or equivalent manual
> #            GCP IAM + Workload Identity Pool binding) yourself to populate `gcp-creds` first.
> #            This is an advanced, out-of-band step not covered by this guide.
> ```

Once `gcp-creds` exists:

```bash
./scripts/validate-cluster-domain.sh

CLUSTER_DOMAIN=$(oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}')
GCP_PROJECT=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.gcp.projectID}')
echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"
echo "GCP_PROJECT=${GCP_PROJECT}"

helm template gitops/operators/cert-manager-clouddns \
  --name-template cert-manager-clouddns \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --set clouddns.project="${GCP_PROJECT}" | oc apply -f -
```

**Prerequisite:** a Google Cloud DNS managed zone covering `${CLUSTER_DOMAIN}` must exist in
`GCP_PROJECT` and be reachable by the service account behind `gcp-creds`.

> **Interesting live finding (not the self-managed case, but useful context):** on the OSD/GCP
> cluster tested, the cluster's *public* DNS zone for its own subdomain (`dnses.config/cluster
> .spec.publicZone.id`) **was** present in the customer's own GCP project — Red Hat's installer
> delegates a per-cluster Cloud DNS zone into the customer's project even though the parent domain
> (`*.openshiftapps.com`) is Red Hat-owned. This means Cloud DNS DNS-01 is *technically* reachable
> on an OSD cluster too, if you went through the `ccoctl`/WIF bootstrap — but since the existing
> public certificate (Step 0, above) already solves the problem with zero setup, there was no
> reason to pursue it further.

Then follow [README.md's Verify section](README.md#verify).

## GPU hardware profile naming

`gitops/instance/rhoai/templates/hardware-profiles.yaml` (applied in Phase 3) ships an
AWS-specific example profile, `nvidia-a10g-profile` (pinned to AWS's `NVIDIA-A10G` GPU product
label, used by `g5.*` instances). This is not cloud-specific to Phase 1, but if you're following
the GCP path end-to-end: when you reach Phase 2/5, create an equivalent `HardwareProfile` for
your actual GCP GPU product label instead (e.g. `nodeSelector: nvidia.com/gpu.product:
NVIDIA-L4` or `NVIDIA-A100-SXM4-40GB`, depending on your chosen machine type — see
[02-gpu-nodes/gcp.md](../02-gpu-nodes/gcp.md)).
