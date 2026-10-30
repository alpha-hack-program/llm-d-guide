# Phase 2 — GCP: GPU Nodes

> Part of [Phase 2 — GPU Nodes](README.md). Read the shared README first — this file covers only
> GPU node provisioning (Step 1); NFD/NVIDIA operator install and instance CRs are identical on
> every platform and documented there.

**Partially live-validated** against an OpenShift Dedicated 4.22 cluster on GCP: the read-only
`ocm` lookups below were run live; the actual `ocm create machinepool` provisioning step was
**not** executed (no GPU quota approved for the test cluster, and provisioning real GPU nodes
incurs cost) — treat that one command as documented-but-unexecuted and verify the instance type
and quota before running it for real.

## `ocm create machinepool` (recommended for OSD/ROSA)

OpenShift Dedicated is a managed service — the supported customer path for adding a GPU worker
pool is `ocm create machinepool` (OCM API), not hand-editing `MachineSet` objects directly (that
is the self-managed/IPI pattern; see [aws.md](aws.md) for the AWS IPI equivalent chart). This
mirrors how ROSA is operated too.

**Derive the OCM cluster ID from the live cluster** (do not ask the user for it):

```bash
INTERNAL_CLUSTER_ID=$(oc get clusterversion version -o jsonpath='{.spec.clusterID}')
OCM_CLUSTER_ID=$(ocm list clusters --parameter search="external_id = '${INTERNAL_CLUSTER_ID}'" \
  --columns id --no-headers | xargs)
echo "OCM_CLUSTER_ID=${OCM_CLUSTER_ID}"
```

**Confirm you're looking at the right cluster and provider:**

```bash
ocm describe cluster "${OCM_CLUSTER_ID}"
# Confirm: Provider: gcp, Product: osd (or rosa), Region matches your expectation
```

**List existing machine pools (read-only, safe to run anytime):**

```bash
ocm get "/api/clusters_mgmt/v1/clusters/${OCM_CLUSTER_ID}/machine_pools" | \
  jq '.items[] | {id, instance_type, replicas, autoscaling}'
```

**Create the GPU machine pool.** Ask the user for the GCP GPU instance type if not already
confirmed — common choices:
- `a2-highgpu-1g` — 1x NVIDIA A100 40GB (built-in, no separate accelerator attachment)
- `g2-standard-4` — 1x NVIDIA L4 (cheaper, good for inference-sized models)

```bash
GCP_GPU_INSTANCE_TYPE="g2-standard-4"  # ask the user to confirm, or override
GPU_REPLICAS=1   # per the AZ choice confirmed in the README — ocm machinepool autoscaling spans AZs within a region automatically

ocm create machinepool --cluster "${OCM_CLUSTER_ID}" \
  gpu-worker \
  --instance-type "${GCP_GPU_INSTANCE_TYPE}" \
  --replicas "${GPU_REPLICAS}" \
  --labels "node-role.kubernetes.io/gpu=" \
  --taints "nvidia.com/gpu=:NoSchedule"
```

> **Multi-AZ:** unlike the AWS chart in this repo (which creates one `MachineSet` per AZ
> explicitly), `ocm create machinepool` on a multi-AZ OSD/ROSA cluster spreads replicas across the
> cluster's existing AZs automatically when `--replicas` is a multiple of the AZ count, or you can
> pass `--availability-zone <zone>` per pool to pin one pool per zone, mirroring the AWS
> one-MachineSet-per-AZ pattern if the user wants that level of control.

**Wait for the machine pool and nodes:**

```bash
oc get machineset -n openshift-machine-api | grep gpu-worker
oc get nodes -l node-role.kubernetes.io/gpu
```

**GPU quota:** GCP projects have per-region GPU quota that is 0 by default. If `ocm create
machinepool` reports instances but no nodes ever join, check GCP quota for the GPU type in the
cluster's region first:

```bash
gcloud compute regions describe "${REGION}" --project "${GCP_PROJECT}" \
  --format="value(quotas)" | tr ';' '\n' | grep -i gpu
```

## Self-managed IPI GCP: raw `MachineSet` + `GCPMachineProviderSpec`

Not covered by a chart in this repo (the only MachineSet chart shipped is AWS-specific, see
[aws.md](aws.md)). If you are on a self-managed GCP IPI cluster (not OSD), the pattern mirrors the
AWS chart but with `GCPMachineProviderSpec`:

```yaml
providerSpec:
  value:
    kind: GCPMachineProviderSpec
    apiVersion: machine.openshift.io/v1beta1
    machineType: a2-highgpu-1g      # or g2-standard-4 for L4
    zone: <region>-<az>             # e.g. europe-west4-a — confirmed live field shape
    disks:
    - autoDelete: true
      boot: true
      image: <same RHCOS image as an existing worker MachineSet's .spec.template.spec.providerSpec.value.disks[0].image>
      sizeGb: 300
      type: pd-ssd
    onHostMaintenance: Terminate     # mandatory for GPU-attached instance types — GCP live migration is not supported with GPUs
    restartPolicy: Always
```

Read the RHCOS image reference from an existing worker MachineSet the same way the AWS chart reads
`AMI_ID` — never guess a GCP image path:

```bash
oc get machineset -n openshift-machine-api -o \
  jsonpath='{.items[0].spec.template.spec.providerSpec.value.disks[0].image}'
```

## GPU hardware profile naming

Once nodes join (either path above), remember that
[`gitops/instance/rhoai/templates/hardware-profiles.yaml`](../../../gitops/instance/rhoai/templates/hardware-profiles.yaml)
(Phase 3) ships an AWS-specific `nvidia-a10g-profile` example. Create an equivalent profile with
`nodeSelector: nvidia.com/gpu.product: NVIDIA-L4` (or `NVIDIA-A100-SXM4-40GB`, etc., matching
`oc get nodes -o json | jq '.items[].metadata.labels."nvidia.com/gpu.product"'` on your actual GPU
nodes) before Phase 5.
