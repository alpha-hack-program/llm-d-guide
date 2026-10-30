# Phase 2 — Bare Metal / Other: GPU Nodes

> Part of [Phase 2 — GPU Nodes](README.md). Read the shared README first — this file covers only
> GPU node provisioning (Step 1); NFD/NVIDIA operator install and instance CRs are identical on
> every platform and documented there.

Bare metal has no `MachineSet`/cloud-provider autoscaling story — GPU nodes are physical or
pre-provisioned machines that must already be joined to the cluster (via the standard bare-metal
or UPI node-addition process, out of scope for this guide) before this phase starts.

**Confirm the GPU-capable nodes are already `Ready`:**

```bash
oc get nodes
```

**Label and taint them to match the convention used by the AWS/GCP charts**, so the rest of this
guide (hardware profiles, scheduling) behaves identically regardless of platform:

```bash
NODE_NAME=<your-gpu-node-name>

oc label node "${NODE_NAME}" node-role.kubernetes.io/gpu=
oc adm taint node "${NODE_NAME}" nvidia.com/gpu=:NoSchedule
```

Repeat per GPU node, using the AZ/rack topology the user confirmed in the
[README](README.md) question as a guide for how many nodes to label.

Continue to [README.md Step 2](README.md#step-2--nfd--nvidia-gpu-operators) — NFD will detect the
GPU hardware via PCI device scanning regardless of how the node was provisioned, and the NVIDIA GPU
Operator's driver DaemonSet will target any node with the matching NFD labels, taint tolerance
aside.
