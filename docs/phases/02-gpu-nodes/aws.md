# Phase 2 — AWS: GPU MachineSets

> Part of [Phase 2 — GPU Nodes](README.md). Read the shared README first — this file covers only
> GPU node provisioning (Step 1); NFD/NVIDIA operator install and instance CRs are identical on
> every platform and documented there.

**Chart:** [`gitops/instance/machine-sets/gpu-worker`](../../../gitops/instance/machine-sets/gpu-worker)
(self-managed/IPI AWS only — creates raw `MachineSet` objects with `AWSMachineProviderConfig`).

> **Managed clusters (ROSA):** direct `MachineSet` edits are not the supported customer path —
> use `rosa create machinepool` instead, mirroring the GCP OSD guidance in
> [../gcp.md](gcp.md#ocm-create-machinepool-recommended-for-osdrosa). This file documents the
> self-managed IPI path only.

```bash
export INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
export AWS_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')
export AMI_ID=$(oc get machineset -n openshift-machine-api \
  -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.ami.id}')
export AWS_INSTANCE_TYPE="${AWS_INSTANCE_TYPE:=g5.2xlarge}"
export AWS_INSTANCES_PER_AZ=1

# All 3 AZs → 3 MachineSets, one per AZ (3 GPU nodes total)
# Single AZ → replace "a b c" with just "a" (or the user's chosen AZ)
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

Use the AZ choice the user confirmed in the [README](README.md). **Do not default to a single
AZ** without explicit user approval — 3 AZs means 3 separate MachineSets, 3 GPU nodes.

> **Never use `aws ec2 describe-images` to look up `AMI_ID`** — every AWS OCP cluster already has
> worker MachineSets whose `providerSpec` contains the exact RHCOS AMI the cluster was installed
> with (correct image, region, architecture). Read it from an existing MachineSet as shown above.

Continue to [README.md Step 2](README.md#step-2--nfd--nvidia-gpu-operators) once the MachineSets
are applied.
