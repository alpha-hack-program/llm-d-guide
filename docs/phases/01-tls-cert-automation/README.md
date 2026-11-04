# Phase 1 — TLS Certificate Automation

> Part of the [llm-d-guide Co-pilot Runbook](../../../AGENTS.md). See the
> [Phase Map](../../../AGENTS.md#phase-map) for the full sequence.

**Goal:** Install the cert-manager operator and automate TLS certificate lifecycle.

**Before starting Phase 1 — confirm with the user:**

> 1. **Cloud provider** (if not already confirmed in Phase 0): "Is this cluster running on AWS,
>    GCP, or neither (bare metal / other)?" → `CLOUD=aws`, `CLOUD=gcp`, or `CLOUD=none`.
>
> 2. **Managed vs. self-managed:** check `ocm describe cluster <id> 2>/dev/null | grep -E
>    'Product|HCP'` (or ask) — OpenShift Dedicated (`osd`) and ROSA clusters are **managed**, and
>    behave very differently in this phase (see below). If `ocm` is unavailable or the check is
>    inconclusive, ask directly: "Is this a managed cluster (OpenShift Dedicated / ROSA), or
>    self-managed (IPI/UPI)?"
>
> 3. **TLS issuer** — only needs asking for self-managed clusters; see the cloud-specific guide:
>    - **AWS** → [aws.md](aws.md)
>    - **GCP** → [gcp.md](gcp.md)
>    - **Bare metal / other** → [baremetal.md](baremetal.md)

> **Managed clusters (OpenShift Dedicated / ROSA) — read this first:** confirmed live against an
> OpenShift Dedicated on GCP cluster: these clusters already ship a **publicly-trusted Let's
> Encrypt wildcard certificate** for `*.apps.<cluster-domain>` and `api.<cluster-domain>`,
> referenced by `ingresscontroller/default .spec.defaultCertificate.name`. This is unrelated to
> `TLS_ISSUER`/cert-manager entirely — it exists before Phase 1 even starts. You do **not** need
> local-ca, Let's Encrypt DIY, or any cert-manager `Issuer`/`Certificate` for TLS on a managed
> cluster — skip straight to [Step 0 below](#step-0--managed-clusters-use-the-existing-public-certificate).
> Also be aware that OSD/ROSA's `sre-regular-user-validation` admission webhook blocks customer
> writes to `configmaps` in `openshift-config`, `proxy/cluster`, `ingresscontroller/default`, and
> `machine.openshift.io` resources — even for users with `cluster-admin`-equivalent RBAC. This
> makes the local-ca "inject into cluster trust bundle" step (below) **impossible** on managed
> clusters; see [gcp.md](gcp.md) for the full writeup and the tested workaround.
>
> **But still install the bare cert-manager *operator*, even on managed clusters.** This is
> unrelated to TLS/ingress certs — confirmed live (RHOAI 3.5, OSD/GCP): `LeaderWorkerSetOperator`
> hard-requires the cert-manager operator's CRDs/controller to be present (for its own internal
> webhook certs) before it reaches `Available`, and KServe's `LLMInferenceServiceWideEPDependencies`
> condition stays blocked on `LeaderWorkerSetOperator` until it does — this surfaces in Phase 3
> Step 2, not here, which is why it's easy to miss. Managed clusters still need Phase 1 Step 1
> below, run with `--set cloud=${CLOUD} --set issueCerts=false` (`cloud` stays truthful to the
> actual platform; `issueCerts=false` is what actually suppresses `CredentialsRequest`/CCO
> involvement, `Issuer`, and `Certificate` — just the bare operator gets installed): do not skip
> Step 1 even when skipping everything else in this phase.

Do NOT pass `--set cloud=...` without an explicit answer from the user. Let's Encrypt requires
`CLOUD=aws` or `CLOUD=gcp` (with extra caveats — see the cloud-specific guide); it is not available
for `CLOUD=none`.

---

### Step 0 — Managed clusters: use the existing public certificate

**Skip this step entirely for self-managed (IPI/UPI) clusters** — go to Step 1.

On OpenShift Dedicated / ROSA, confirm the existing certificate and derive its secret name once —
every later phase's `tls.secretName` (llm-d gateway, MaaS gateway, MCP Gateway) should point here:

```bash
# Confirm a cluster-managed default certificate exists:
oc get ingresscontroller/default -n openshift-ingress-operator \
  -o jsonpath='{.spec.defaultCertificate.name}'
# Non-empty on OSD/ROSA, e.g. "<cluster-name>-primary-cert-bundle-secret"

REAL_CERT_SECRET=$(oc get ingresscontroller/default -n openshift-ingress-operator \
  -o jsonpath='{.spec.defaultCertificate.name}')
echo "REAL_CERT_SECRET=${REAL_CERT_SECRET}"

# Verify it is a real, publicly-trusted cert (not self-signed):
oc get secret "${REAL_CERT_SECRET}" -n openshift-ingress \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer -subject -ext subjectAltName
# Expected issuer: Let's Encrypt (or another public CA) — NOT "openshift-service-serving-signer"
# Expected SAN: *.apps.<cluster-domain> and api.<cluster-domain>
```

If `defaultCertificate.name` is empty, the cluster does not have a pre-provisioned public
certificate — fall through to Step 1 (self-managed flow) instead.

**Human gate:** The certificate's issuer must be a real public CA. If it is, the TLS-automation
part of Phase 1 is **done** — do not install an `Issuer`/`Certificate` or do local-ca trust-bundle
injection. **Still run Step 1 below with `--set cloud=${CLOUD} --set issueCerts=false`** (`cloud`
stays truthful to the actual platform; `issueCerts=false` is what skips `Issuer`, `Certificate`,
and CCO involvement) to install the bare cert-manager operator — `LeaderWorkerSetOperator`
(Phase 3 Step 2) requires it regardless of managed/self-managed status; skipping it blocks
KServe's Wide-EP dependency condition and the `LeaderWorkerSetOperator` CR shows
`Degraded: True (MissingDependency)`. Record `REAL_CERT_SECRET` for Phases 5, 6, and 8
(`tls.secretName=${REAL_CERT_SECRET}` on every Gateway chart, all in the `openshift-ingress`
namespace already, so no `ReferenceGrant` is needed). Proceed to Step 1 (cert-manager operator
only), then [Phase 2](../02-gpu-nodes/README.md).

> **Gotcha — do not set `tls.secretName` to a name that doesn't already exist as a real secret**
> (e.g. `router-certs-default`) expecting it to "reuse" an existing cert. Confirmed live: the
> llm-d/MaaS gateway charts' Service template always carries a
> `service.beta.openshift.io/serving-cert-secret-name` annotation set to `tls.secretName`. If no
> secret exists at that name, `service-ca-operator` happily creates a **brand new, Service-scoped,
> cluster-internal self-signed cert** there (CN matching the Service's own `.svc` FQDN, not your
> public hostname) — silently replacing what you intended to reuse, with no error. If a secret
> already exists there under a different owner (e.g. the real `REAL_CERT_SECRET` from Step 0),
> `service-ca-operator` correctly refuses to touch it (logs a
> `service.beta.openshift.io/serving-cert-generation-error` annotation on the Service and leaves
> the secret alone) — this error annotation is cosmetic and expected in that case; the Gateway
> still serves the real certificate correctly because its `certificateRefs` reads from the secret
> directly, independent of the Service annotation.

---

### Step 1 — cert-manager Operator (ALL clusters, including managed)

The chart takes two independent values: `cloud` (the actual platform — `aws`/`gcp`/`none`, kept
truthful) and `issueCerts` (`true`/`false` — whether this install should actually be wired up to
request publicly-trusted certs via ACME DNS-01 against that cloud's DNS service, or just install
the bare operator). Only set `issueCerts=true` for the self-managed Let's Encrypt flow below.

> **Managed clusters (OSD/ROSA):** run this step too, with `issueCerts=false` and `cloud` set to
> the cluster's real platform — you're installing only the bare operator (its CRDs/controller),
> not configuring an `Issuer` or `Certificate` for ingress TLS (that part is correctly skipped per
> Step 0 above). `issueCerts=false` creates zero `CredentialsRequest`/CCO involvement regardless of
> `cloud`. This is required because `LeaderWorkerSetOperator` (Phase 3 Step 2) depends on the
> cert-manager operator being present, independent of TLS_ISSUER or managed/self-managed status —
> confirmed live.

Set `CLOUD` to **aws**, **gcp**, or **none**, and `ISSUE_CERTS` to **true** only if doing the
self-managed Let's Encrypt flow via Issuer/Certificate (Step 2 below) — otherwise **false**:

```bash
CLOUD=aws         # or "gcp", or "none" for bare metal / other
ISSUE_CERTS=true  # "false" for managed clusters, local-ca, or bare-operator-only installs
```

Install the operator (retry loop handles the two-pass CRD race):

```bash
for i in $(seq 1 60); do
  if helm template gitops/operators/cert-manager-operator \
       --set cloud=${CLOUD} --set issueCerts=${ISSUE_CERTS} --name-template cert-manager | oc apply -f -; then
    break
  fi
  [[ $i -eq 60 ]] && { echo "Gave up after 60 attempts"; exit 1; }
  sleep 5
done

# Wait for CSV
echo "Waiting for cert-manager CSV..."
for i in $(seq 1 60); do
  CSV=$(oc get csv -n cert-manager-operator -o name 2>/dev/null | grep cert-manager || true)
  if [[ -n "$CSV" ]]; then
    echo "Found: $CSV"
    oc wait --for=jsonpath='{.status.phase}'=Succeeded $CSV -n cert-manager-operator --timeout=300s
    break
  fi
  sleep 5
done
```

> **Note (two-pass apply):** The first `helm template | oc apply` will fail on the `CertManager` CR
> with `no matches for kind "CertManager"` because the operator CRD is not registered until the CSV
> reports success. This is expected — confirmed live. Wait for the operator to be ready, then run
> the same command a second time — it applies cleanly.

Wait for the 3 cert-manager pods to be `Ready`:

```bash
echo -n "Waiting for cert-manager pods to be ready..."
while [[ $(oc get pods -l app.kubernetes.io/instance=cert-manager -n cert-manager \
  -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True True True" ]]; do
  echo -n "." && sleep 1
done
echo -e "  [OK]"
```

### Step 2 — Local CA or Let's Encrypt

> **Local CA works identically on every platform** — AWS, GCP, bare metal — and is documented once
> here. Let's Encrypt is cloud-specific (different DNS-01 solver per provider) — see
> [aws.md](aws.md) or [gcp.md](gcp.md) for that path. Bare metal has no Let's Encrypt path; see
> [baremetal.md](baremetal.md).

**Extract the cluster base domain:**

```bash
CLUSTER_DOMAIN=$(oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}')
[[ -z "${CLUSTER_DOMAIN}" ]] && { echo "Error: CLUSTER_DOMAIN could not be detected."; exit 1; }
echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"
```

**Apply the local CA chart:**

```bash
helm template gitops/operators/cert-manager-local-ca \
  --name-template cert-manager-local-ca \
  --set clusterDomain="${CLUSTER_DOMAIN}" | oc apply -f -
```

This creates:
1. `selfsigned-issuer` (ClusterIssuer) — bootstraps the CA key material
2. `selfsigned-ca` (Certificate in `cert-manager` namespace) — the CA cert (ECDSA P-256)
3. `local-ca` (ClusterIssuer) — issues certs signed by the local CA
4. `ocp-ingress` (Certificate) — `*.apps.<cluster>`, secret `ingress-certs`
5. `ocp-api` (Certificate) — `api.<cluster>`, secret `api-certs`

Wait for both certificates:

```bash
oc wait --for=condition=Ready certificate/selfsigned-ca -n cert-manager --timeout=120s
oc wait --for=condition=Ready certificate/ocp-api -n openshift-config --timeout=300s
oc wait --for=condition=Ready certificate/ocp-ingress -n openshift-ingress --timeout=300s
oc get certificates.cert-manager.io --all-namespaces \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status'
```

**Inject the CA into the cluster trust bundle — self-managed clusters only, mandatory there:**

> **Managed clusters (OSD/ROSA): this step is BLOCKED and will fail — do not attempt it.**
> Confirmed live: `oc create configmap user-ca-bundle -n openshift-config` and
> `oc patch proxy/cluster` are both rejected by the `sre-regular-user-validation` admission webhook
> with `Prevented from accessing Red Hat managed resources`, regardless of RBAC. On managed
> clusters, use [Step 0](#step-0--managed-clusters-use-the-existing-public-certificate) instead —
> it needs no trust bundle at all because the certificate is already publicly trusted. If you
> specifically need a *custom* self-signed CA trusted cluster-wide on a managed cluster (rare),
> open a Red Hat support case — this is an SRE-only action.

```bash
# Self-managed clusters only:
oc get secret cert-manager-ca -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/local-ca.crt

oc create configmap user-ca-bundle -n openshift-config \
  --from-file=ca-bundle.crt=/tmp/local-ca.crt \
  --dry-run=client -o yaml | oc apply -f -

oc patch proxy/cluster --type=merge \
  -p '{"spec":{"trustedCA":{"name":"user-ca-bundle"}}}'
```

> **What this does:** The `user-ca-bundle` ConfigMap is the standard OpenShift mechanism for
> adding private/corporate CAs to the cluster-wide trust store. RHOAI automatically merges it
> into the `odh-trusted-ca-bundle`/`odh-ca-bundle` ConfigMaps mounted by its components —
> including `maas-ui`, which validates TLS when calling the MaaS API.

### Verify

```bash
# All 3 cert-manager pods must be Ready before proceeding
oc get pods -n cert-manager
# controller, cainjector, webhook — all must show 1/1 Running

oc wait --for=condition=Ready certificate/ocp-api -n openshift-config --timeout=300s
oc wait --for=condition=Ready certificate/ocp-ingress -n openshift-ingress --timeout=300s

# WARNING: conditions[0] is NOT always the Ready condition; using it gives misleading output
# (e.g. "READY: True" when Issuing is active but cert is NOT done). Use the filter below.
oc get certificates.cert-manager.io --all-namespaces \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status'

# If a cert is stuck, check the ACME order and challenge status:
oc get orders,challenges -n openshift-config
oc get orders,challenges -n openshift-ingress
```

**Human gate:** Every certificate must show `READY=True`. `Issuing` is not done — wait until
`Ready=True` for all certs before proceeding. Do not proceed with any cert showing `False` or
blank.

**Known gotchas:**
- The first `helm template | oc apply` will fail on the `CertManager` CR because the operator CRD
  isn't registered until the CSV reports success. Wait for the operator to be ready, then re-run
  the same command — it applies cleanly on the second pass.
- `oc get orders, challenges` (with a space) is invalid syntax — always use
  `oc get orders,challenges` (no space).
- See [aws.md](aws.md) / [gcp.md](gcp.md) / [baremetal.md](baremetal.md) for cloud-specific
  gotchas (Route53 zone access, GCP Workload Identity, etc.).

**End of Phase 1:** Stop here and report certificate status to the user — either "using the
existing managed-cluster certificate" (Step 0) or "all certificates READY=True" (Step 1-2). Wait
for confirmation before proceeding to [Phase 2](../02-gpu-nodes/README.md).
