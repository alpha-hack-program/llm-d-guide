# Phase 2 — GPU Nodes + NFD + NVIDIA GPU Operator

> Part of the [llm-d-guide Co-pilot Runbook](../../../AGENTS.md). See the
> [Phase Map](../../../AGENTS.md#phase-map) for the full sequence.

**Goal:** Add GPU worker nodes and install the hardware detection and driver stack.

**Before starting Phase 2 — ask the user:**
> "How many availability zones do you want GPU nodes in?
> - **All 3 AZs** (a, b, c) — recommended for production; 3 GPU nodes total (1 per AZ).
> - **Single AZ** — sufficient for a single-model test; cheaper, faster to provision.
> Which would you like?"

Do NOT decide this yourself — the number of GPU nodes affects cost and scheduling decisions that
belong to the user.

**Install order:**
1. **GPU node provisioning (cloud-specific — start first** so nodes are ready by the time operators
   finish installing):
   - **AWS** → [aws.md](aws.md)
   - **GCP** → [gcp.md](gcp.md)
   - **Bare metal / other** → [baremetal.md](baremetal.md)
2. NFD + NVIDIA GPU operators (below, identical on every platform)
3. Apply the instance CRs (below, identical on every platform)

### Step 2 — NFD + NVIDIA GPU operators

> **OLMv0 only:** NFD and NVIDIA GPU Operator bundles do not support `AllNamespaces` install mode,
> so OLMv1 (`ClusterExtension`) cannot be used. The `install.sh` scripts always use OLMv0
> (`Subscription`) regardless of OCP version. Wait for CSV `Succeeded` on both 4.20 and 4.21+.
>
> **Worth installing even with zero GPU nodes provisioned yet** (e.g. while cost/quota approval
> for GPU nodes is pending) — confirmed live: both operators install and reach `Succeeded` cleanly
> with no GPU hardware present. The `ClusterPolicy` CR (Step 3) also reports `state: ready`
> trivially in that case, since its GPU-targeted DaemonSets simply have zero desired replicas with
> no matching nodes.

```bash
# Install NFD operator (always OLMv0)
bash gitops/operators/nfd/install.sh

# Wait for NFD CSV to reach Succeeded (poll by name — label selector is not
# applied immediately and causes "no matching resources" on fresh installs):
echo "Waiting for NFD CSV..."
for i in $(seq 1 60); do
  CSV=$(oc get csv -n openshift-nfd -o name 2>/dev/null | grep nfd || true)
  if [[ -n "$CSV" ]]; then
    echo "Found: $CSV"
    oc wait --for=jsonpath='{.status.phase}'=Succeeded $CSV -n openshift-nfd --timeout=300s
    break
  fi
  sleep 5
done

# Install NVIDIA GPU operator (always OLMv0)
bash gitops/operators/nvidia/install.sh

# Wait for NVIDIA GPU operator CSV to reach Succeeded:
echo "Waiting for NVIDIA GPU operator CSV..."
for i in $(seq 1 60); do
  CSV=$(oc get csv -n nvidia-gpu-operator -o name 2>/dev/null | grep gpu-operator || true)
  if [[ -n "$CSV" ]]; then
    echo "Found: $CSV"
    oc wait --for=jsonpath='{.status.phase}'=Succeeded $CSV -n nvidia-gpu-operator --timeout=300s
    break
  fi
  sleep 5
done
```

### Step 3 — Apply the instance CRs (after both operator CSVs reach `Succeeded`)

```bash
# Apply NFD instance (NodeFeatureDiscovery CR)
oc apply -k gitops/instance/nfd

# Wait for NFD labels to appear on nodes before applying ClusterPolicy
oc wait --for=condition=Established crd/nodefeaturediscoveries.nfd.openshift.io --timeout=120s

# Apply NVIDIA instance (ClusterPolicy CR)
oc apply -k gitops/instance/nvidia

# Wait for the ClusterPolicy to reach ready state (all GPU daemonsets deployed —
# trivially "ready" with zero replicas if no GPU nodes exist yet)
oc wait --for=jsonpath='{.status.state}'=ready clusterpolicy/gpu-cluster-policy --timeout=600s
```

**Key wait conditions:**
```bash
# NFD labels applied to GPU nodes
oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true

# NVIDIA device plugin running on GPU nodes
oc get pods -n nvidia-gpu-operator -w

# GPU capacity visible on nodes
oc get nodes -o json | jq '.items[].status.capacity | select(."nvidia.com/gpu")'
```

**Human gate:** Confirm that at least one GPU node/machine is `Provisioned` (or, if deferring GPU
provisioning, that both operators are installed and ready to detect GPUs once nodes join) and both
operator CSVs are `Succeeded` (NFD and NVIDIA always use OLMv0, even on OCP 4.21+). You do **not**
need to wait for all GPU nodes to be `Ready` or for `nvidia.com/gpu` capacity to appear — Phases 3
and 4 install operators that have no GPU dependency. GPU capacity is only required at Phase 5
(llm-d deployment).

> **Tip:** GPU node provisioning (10–15 min on cloud platforms) and NVIDIA driver installation run
> in the background while you work through Phases 3–4. By the time you reach Phase 5, nodes will
> typically be ready. If not, Phase 5 will prompt you to wait.

**Known gotcha:** The ClusterPolicy webhook may reject the CR if the NFD labels aren't present yet.
Apply NFD first, wait for labels, then apply nvidia.

**End of Phase 2:** Report GPU node status and operator CSV state to the user. Wait for
confirmation before proceeding to [Phase 3](../03-operators-rhoai.md).
