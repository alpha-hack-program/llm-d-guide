Phase 1 — MetalLB Configuration (Full Manifests)
Step 1.1 — Label the Baremetal Nodes
MetalLB speaker pods must only run on baremetal nodes. The cleanest approach is an explicit label. Run this for each baremetal GPU node:
bash# List your nodes first to identify baremetal ones
oc get nodes -o wide

# Apply label to each baremetal node
oc label node <baremetal-node-1> node-role.llm-d/inference=true
oc label node <baremetal-node-2> node-role.llm-d/inference=true
# repeat for all baremetal GPU nodes
Verify NFD has already labeled them with GPU info (should be there from the NVIDIA operator):
bashoc get nodes -l nvidia.com/gpu.present=true --show-labels

Step 1.2 — Instantiate the MetalLB CR
The MetalLB Operator is installed but you said no CR has been created yet. This is the instance that actually starts the controller and speaker pods:
yaml# metallb-instance.yaml
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: metallb-system
spec:
  nodeSelector:
    node-role.llm-d/inference: "true"   # speakers only on baremetal nodes
  speakerTolerations:
    - key: "node-role.llm-d/inference"
      operator: "Exists"
      effect: "NoSchedule"
Apply and verify:
bashoc apply -f metallb-instance.yaml

# Wait for controller and speakers to come up
oc get pods -n metallb-system -w

# You should see:
# controller-xxxx   1/1   Running
# speaker-xxxx      1/1   Running   (one per baremetal node)