# Phase 1 — AWS: Let's Encrypt via Route53

> Part of [Phase 1 — TLS Certificate Automation](README.md). Read the shared README first — it
> covers the cert-manager operator install (Step 1) and the local-ca path (Step 2), both of which
> work unchanged on AWS. This file covers only the AWS-specific Let's Encrypt path.

**When to use this:** `TLS_ISSUER=letsencrypt` on a **self-managed** (IPI/UPI) AWS cluster where
the Cloud Credential Operator runs in Mint mode (the default for self-managed AWS IPI). On a
managed cluster (ROSA), check
[the README's managed-cluster note](README.md#step-0--managed-clusters-use-the-existing-public-certificate)
first — you likely don't need this at all.

Set `cloud=aws` and `issueCerts=true` when installing the cert-manager operator (README Step 1):

```bash
CLOUD=aws
ISSUE_CERTS=true
```

This adds the `CLOUD_CREDENTIALS_SECRET_NAME=aws-creds` env var to the operator Subscription and
deploys a `CredentialsRequest` (`gitops/operators/cert-manager-operator/templates/credentialsrequest.yaml`)
scoped to `route53:ChangeResourceRecordSets` / `route53:ListResourceRecordSets` /
`route53:ListHostedZonesByName` / `route53:GetChange`. On Mint-mode CCO, this is auto-fulfilled —
the `aws-creds` secret appears in the `cert-manager` namespace automatically.

> **STS/Manual-mode CCO (e.g. some AWS IPI clusters with manually-managed credentials):** the
> `CredentialsRequest` above is **not** auto-fulfilled. You must run `ccoctl aws create-iam-roles`
> (or equivalent manual IAM + secret creation) yourself to populate `aws-creds` before this path
> works. Check with:
> ```bash
> oc get cloudcredential cluster -o jsonpath='{.spec.credentialsMode}'
> # "Mint" → auto-fulfilled. "Manual" → ccoctl step required first.
> ```

**MANDATORY: Run the domain validation script now:**

```bash
./scripts/validate-cluster-domain.sh
```

Do NOT re-implement this logic inline. Run the script and capture its output. It checks that the
extracted `baseDomain` matches the cluster's actual apps domain (`apps.<baseDomain>`), catching the
common mistake of extracting a parent domain instead of the full cluster base domain. If it fails,
stop and fix before proceeding.

**CRITICAL — After running the script, output this message verbatim and wait for the user's reply
before running any further commands:**

```
The domain validation script output:
<paste full script output here>

The cluster base domain is: <extracted-domain>
All certificates will be issued for api.<domain> and *.apps.<domain>.

Is this correct? I will not proceed until you confirm.
```

Do NOT proceed with applying the cert-manager-route53 chart until the user explicitly replies to
confirm.

**Route53 zone accessibility check:**

- The OpenShift installer creates a **private** hosted zone for the cluster base domain.
- The **public parent zone** must be accessible for DNS-01 challenges to work.
- For AWS IPI clusters, both zones are typically in the same AWS account.

If Route53 zones are not accessible (e.g., DNS hosted externally), **stop here** and ask the user
whether to:
1. Switch to `TLS_ISSUER=local-ca` (see [README.md](README.md)).
2. Use HTTP-01 challenges instead of DNS-01 (not currently supported by this repo's charts).
3. Skip TLS automation for this phase.

**Install the certificate issuers:**

```bash
# Wait for the operator to be ready (see README.md Step 1)
echo -n "Waiting for cert-manager pods to be ready..."
while [[ $(oc get pods -l app.kubernetes.io/instance=cert-manager -n cert-manager \
  -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True True True" ]]; do
  echo -n "." && sleep 1
done
echo -e "  [OK]"

./scripts/validate-cluster-domain.sh

CLUSTER_DOMAIN=$(oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}')
AWS_DEFAULT_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')

[[ -z "${CLUSTER_DOMAIN}" ]] && { echo "Error: CLUSTER_DOMAIN could not be detected."; exit 1; }
[[ -z "${AWS_DEFAULT_REGION}" ]] && { echo "Error: AWS_DEFAULT_REGION could not be detected."; exit 1; }

echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"
echo "AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}"

helm template gitops/operators/cert-manager-route53 \
  --name-template cert-manager-route53 \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --set route53.region="${AWS_DEFAULT_REGION}" | oc apply -f -
```

> **Alternative — ArgoCD Application:** If using ArgoCD instead of CLI, see the
> [ArgoCD option in README §3.1](../../../README.md#31-cert-manager-operator-and-lets-encrypt-certificate-issuer)
> for the ClusterRole, ClusterRoleBinding, and Application YAML.

Then follow [README.md's Verify section](README.md#verify) — it is identical regardless of issuer.

**AWS-specific gotchas:**
- `scripts/aws-creds-setup.sh` extracts the `aws-creds` secret into your shell's AWS CLI
  environment for manual Route53 debugging (e.g. `aws route53 list-hosted-zones`) — only useful
  after the `CredentialsRequest` has been fulfilled.
- If the ACME order is stuck on `pending`, check that the Route53 hosted zone's NS records
  actually resolve publicly (`dig NS <clusterDomain>`) — a private-only zone with no public
  delegation will never complete a DNS-01 challenge.
