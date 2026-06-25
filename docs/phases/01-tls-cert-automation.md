# Phase 1 — TLS Certificate Automation

> Part of the [llm-d-guide Co-pilot Runbook]](../../AGENTS.md). See the
> [Phase Map](../../AGENTS.md#phase-map) for the full sequence.

**Goal:** Install the GitOps operator and automate TLS certificate lifecycle.

**Before starting Phase 1 — ask the user:**
> "Is this cluster running on AWS, or on bare metal / a non-AWS cloud?
> - **AWS** → cert-manager will use Route53 DNS-01 via CCO (`cloud=aws`).
> - **Bare metal / non-AWS** → no CredentialsRequest is created (`cloud=none`).
>
> Which is it?"

Do NOT pass `--set cloud=aws` (or `cloud=none`) without an explicit answer from the user.

---

### Step 1 — ArgoCD (Red Hat OpenShift GitOps) *(optional)*

> **Ask the user before skipping:** "Do you want to install ArgoCD (OpenShift GitOps), or will you apply manifests directly with `helm template | oc apply`?" Do NOT skip without confirmation.

```bash
helm template openshift-gitops ./gitops/operators/openshift-gitops | oc apply -f -
```

Wait for the CSV to reach `Succeeded`:

```bash
oc get csv -n openshift-gitops-operator --watch
```

---

### Step 2 — cert-manager Operator

Set `CLOUD` to **aws** when running on AWS, or **none** for bare metal / non-AWS:

```bash
CLOUD=aws   # or "none" for bare metal / non-AWS
```

Install the operator (retry loop handles the two-pass CRD race):

```bash
for i in $(seq 1 60); do
  if helm template gitops/operators/cert-manager-operator \
       --set cloud=${CLOUD} --name-template cert-manager | oc apply -f -; then
    break
  fi
  [[ $i -eq 60 ]] && { echo "Gave up after 60 attempts"; exit 1; }
  sleep 5
done

# Wait for CSV
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv \
  -n cert-manager-operator \
  -l operators.coreos.com/openshift-cert-manager-operator.cert-manager-operator= \
  --timeout=300s
```

> **Note (two-pass apply):** The first `helm template | oc apply` will fail on the `CertManager` CR with `no matches for kind "CertManager"` because the operator CRD is not registered until the CSV reaches `Succeeded`. This is expected. Wait for the CSV, then run the same command a second time — it applies cleanly:
> ```bash
> # Wait for CSV
> oc wait --for=jsonpath='{.status.phase}'=Succeeded csv \
>   -n cert-manager-operator \
>   -l operators.coreos.com/openshift-cert-manager-operator.cert-manager-operator= \
>   --timeout=300s
> # Second pass — applies the CertManager CR
> helm template gitops/operators/cert-manager-operator \
>   --set cloud=${CLOUD} --name-template cert-manager | oc apply -f -
> ```

---

### Step 3 — Let's Encrypt Cluster Issuers and Certificates

> **Note:** Only required if `CLOUD=aws`. For bare metal / non-AWS, skip to
> [Step 3 — Alternative: Local CA](#step-3--alternative-local-ca-non-aws--bare-metal) below.

**MANDATORY: Run the domain validation script now (AWS only):**

```bash
./scripts/validate-cluster-domain.sh
```

Do NOT re-implement this logic inline. Run the script and capture its output.

The script checks that the extracted `baseDomain` matches the cluster's actual apps domain
(`apps.<baseDomain>`), catching the common mistake of extracting a parent domain instead of the
full cluster base domain. If it fails, stop and fix before proceeding.

**CRITICAL — After running the script, output this message verbatim and wait for the user's reply before running any further commands:**

```
The domain validation script output:
<paste full script output here>

The cluster base domain is: <extracted-domain>
All certificates will be issued for api.<domain> and *.apps.<domain>.

Is this correct? I will not proceed until you confirm.
```

Do NOT proceed with applying the cert-manager-route53 chart until the user explicitly replies to confirm.

**Route53 zone accessibility check (AWS only):**

After validation, verify that Route53 zones are accessible via the cluster's AWS credentials:
- The OpenShift installer creates a **private** hosted zone for the cluster base domain
- The **public parent zone** must be accessible for DNS-01 challenges to work
- For AWS IPI clusters, both zones are typically in the same AWS account

If Route53 zones are not accessible (e.g., DNS hosted externally), **stop here** and ask the user whether to:
1. Switch to `cloud=none` and manual certificates
2. Use HTTP-01 challenges instead of DNS-01 (if applicable)
3. Skip TLS automation for this phase

**Install the certificate issuers:**

```bash
# Check if logged in with oc
if ! oc whoami &>/dev/null; then
  echo "Error: Not logged in to OpenShift. Please run 'oc login ...' before proceeding."
  exit 1
fi

# Wait for the operator to be ready
echo -n "Waiting for cert-manager pods to be ready..."
while [[ $(oc get pods -l app.kubernetes.io/instance=cert-manager -n cert-manager \
  -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True True True" ]]; do
  echo -n "." && sleep 1
done
echo -e "  [OK]"

# Validate and extract cluster domain
./scripts/validate-cluster-domain.sh

CLUSTER_DOMAIN=$(oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}')
AWS_DEFAULT_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')

[[ -z "${CLUSTER_DOMAIN}" ]] && { echo "Error: CLUSTER_DOMAIN could not be detected."; exit 1; }
[[ -z "${AWS_DEFAULT_REGION}" ]] && { echo "Error: AWS_DEFAULT_REGION could not be detected."; exit 1; }

echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"
echo "AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}"
```

Apply the Route53 ClusterIssuers and certificates:

```bash
helm template gitops/operators/cert-manager-route53 \
  --name-template cert-manager-route53 \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --set route53.region="${AWS_DEFAULT_REGION}" | oc apply -f -
```

> **Alternative — ArgoCD Application:** If using ArgoCD instead of CLI, see the
> [ArgoCD option in README §3.1](../../README.md#31-cert-manager-operator-and-lets-encrypt-certificate-issuer)
> for the ClusterRole, ClusterRoleBinding, and Application YAML.

---

### Step 3 — Alternative: Local CA (non-AWS / bare metal)

> **Note:** Use this step instead of Step 3 (Let's Encrypt) when `CLOUD=none` — i.e., bare metal,
> non-AWS clouds, or lab/demo environments without public DNS. This creates a local CA chain
> using cert-manager: a self-signed root bootstraps a CA certificate, which then issues
> properly signed certs for the cluster's API and ingress endpoints.

**Wait for cert-manager pods to be ready:**

```bash
echo -n "Waiting for cert-manager pods to be ready..."
while [[ $(oc get pods -l app.kubernetes.io/instance=cert-manager -n cert-manager \
  -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True True True" ]]; do
  echo -n "." && sleep 1
done
echo -e "  [OK]"
```

**Extract the cluster base domain:**

```bash
CLUSTER_DOMAIN=$(oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}')
[[ -z "${CLUSTER_DOMAIN}" ]] && { echo "Error: CLUSTER_DOMAIN could not be detected."; exit 1; }
echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"
echo "Certificates will be issued for api.${CLUSTER_DOMAIN} and *.apps.${CLUSTER_DOMAIN}"
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

**Inject the CA into the cluster trust bundle:**

This step is **mandatory** — without it, cluster components (including the MaaS `maas-ui` sidecar)
will reject the locally-signed certificates. See [Appendix D](../../README.md#appendix-d--maas-with-self-signed-tls-certificates) for details.

```bash
# Wait for the CA secret to be populated
oc wait --for=condition=Ready certificate/selfsigned-ca -n cert-manager --timeout=120s

# Extract the CA certificate
oc get secret cert-manager-ca -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/local-ca.crt

# Create (or update) the cluster trust bundle ConfigMap
oc create configmap user-ca-bundle -n openshift-config \
  --from-file=ca-bundle.crt=/tmp/local-ca.crt \
  --dry-run=client -o yaml | oc apply -f -

# Tell the cluster to trust this CA
oc patch proxy/cluster --type=merge \
  -p '{"spec":{"trustedCA":{"name":"user-ca-bundle"}}}'
```

> **What this does:** The `user-ca-bundle` ConfigMap is the standard OpenShift mechanism for
> adding private/corporate CAs to the cluster-wide trust store. RHOAI automatically merges it
> into the `odh-trusted-ca-bundle` and `odh-ca-bundle` ConfigMaps mounted by its components —
> including `maas-ui`, which validates TLS when calling the MaaS API.

---

### Verify

```bash
# All 3 cert-manager pods must be Ready before proceeding
oc get pods -n cert-manager
# controller, cainjector, webhook — all must show 1/1 Running

# Wait for both certificates to reach Ready state (do not use sleep — use oc wait)
oc wait --for=condition=Ready certificate/ocp-api -n openshift-config --timeout=300s
oc wait --for=condition=Ready certificate/ocp-ingress -n openshift-ingress --timeout=300s

# Confirm final status — filter by the Ready condition explicitly.
# WARNING: conditions[0] is NOT always the Ready condition; using it gives misleading output
# (e.g. "READY: True" when Issuing is active but cert is NOT done). Use the filter below.
oc get certificates.cert-manager.io --all-namespaces \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status'

# If a cert is stuck, check the ACME order and challenge status:
oc get orders,challenges -n openshift-config
oc get orders,challenges -n openshift-ingress
```

**Human gate:** Every certificate must show `READY=True` under the `READY` column above. `Issuing` is not done — wait until `Ready=True` for all certs before proceeding. Do not proceed with any cert showing `False` or blank.

**Known gotchas:**
- The first `helm template | oc apply` will fail on the `CertManager` CR because the operator CRD isn't registered until the CSV reaches `Succeeded`. Wait for `Succeeded`, then re-run the same command — it applies cleanly on the second pass.
- If using ArgoCD: if the cert-manager webhook is slow to start, the ArgoCD sync may fail on the first attempt. Re-sync after all 3 pods are Running.
- `oc get orders, challenges` (with a space) is invalid syntax — always use `oc get orders,challenges` (no space).

**End of Phase 1:** Stop here and report certificate status to the user. All certificates must show `READY=True`. Wait for confirmation before proceeding to [Phase 2](02-gpu-nodes.md).
