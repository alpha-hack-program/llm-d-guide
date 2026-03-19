# MetalLB on Kind + Podman Desktop

A step-by-step guide to running MetalLB locally using a Kind cluster managed by Podman Desktop, with the speaker restricted to worker nodes only.

---

## Prerequisites

- [Podman Desktop](https://podman-desktop.io/) installed and running
- `kind` CLI available (ships with Podman Desktop)
- `kubectl` CLI available

---

## 1. Create the Kind Cluster

Create a `kind-config.yaml` with one control-plane and one worker node:

```bash
cat > kind-config.yaml << 'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
EOF
```

Then create the cluster:

```bash
kind create cluster --name metallb-demo --config kind-config.yaml
```

---

## 2. Label the Worker Node

MetalLB's speaker will be restricted to nodes with this label:

```bash
kubectl label node metallb-demo-worker node-role=worker
```

Verify the label was applied:

```bash
kubectl get nodes --show-labels
```

---

## 3. Install MetalLB

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
```

Wait for the pods to be ready:

```bash
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s
```

---

## 4. Restrict the Speaker to the Worker Node

By default the speaker DaemonSet runs on all nodes, including the control-plane. Patch it with a `nodeSelector` to restrict it to the labeled worker:

```bash
kubectl patch daemonset speaker -n metallb-system --type=merge -p '{
  "spec": {
    "template": {
      "spec": {
        "nodeSelector": {
          "node-role": "worker"
        }
      }
    }
  }
}'
```

Verify the speaker is running **only on the worker node**:

```bash
kubectl get pods -n metallb-system -o wide
```

You should see the speaker on `metallb-demo-worker` only, while the controller can run anywhere.

```bash
NAME                         READY   STATUS    RESTARTS   AGE   IP           NODE                  NOMINATED NODE   READINESS GATES
controller-7dcb87658-g4zz8   1/1     Running   0          98s   10.244.1.3   metallb-demo-worker   <none>           <none>
speaker-qvbtl                1/1     Running   0          49s   10.89.0.2    metallb-demo-worker   <none>           <none>
```

---

## 5. Configure an IP Address Pool

Find the Podman network subnet:

```bash
podman network inspect kind | grep subnet
```

Pick a range within that subnet (e.g. if the subnet is `10.89.0.0/24`):

```yaml
# metallb-pool.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: local-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.89.0.200-10.89.0.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: local-advert
  namespace: metallb-system
```

Apply it:

```bash
kubectl apply -f metallb-pool.yaml
```

---

## 6. Test It

Deploy a simple nginx service of type `LoadBalancer`:

```bash
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --port=80 --type=LoadBalancer
```

Watch for the external IP to be assigned:

```bash
kubectl get svc nginx --watch

# NAME    TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
# nginx   LoadBalancer   10.96.74.147   10.89.0.200   80:31255/TCP   17s
```

Once `EXTERNAL-IP` is populated, test connectivity.

> **Note:** On macOS and Windows, Podman runs inside a VM so the MetalLB IPs are not directly reachable from your host. Use one of these alternatives:

```bash
# Option A: port-forward
kubectl port-forward svc/nginx 8080:80
curl localhost:8080

# Option B: SSH into the Podman VM and curl directly
podman machine ssh
curl 10.89.0.200
```

On **Linux**, the IP is directly reachable from your host.

## 7. Install the Gateway API CRDs

Gateway API is not bundled with Kubernetes — it must be installed separately regardless of your Kubernetes version. It is an independent project that releases on its own cadence.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml
```

Verify the CRDs are installed:

```bash
kubectl get crd | grep gateway.networking.k8s.io
```

You should see `gatewayclasses`, `gateways`, `httproutes`, and related resources. The CRDs alone do nothing — you still need a provider in the next step to implement them.

---

## 8. Install Envoy Gateway

Envoy Gateway provides the `GatewayClass` controller that implements the Gateway API. When a `Gateway` resource is created, Envoy Gateway will create a `LoadBalancer` service for it, which MetalLB will then assign an IP to.

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.1.0 \
  -n envoy-gateway-system \
  --create-namespace
```

Wait for it to be ready:

```bash
kubectl wait --timeout=5m \
  -n envoy-gateway-system \
  deployment/envoy-gateway \
  --for=condition=Available
```

---

## 8. Create a GatewayClass and Gateway

The `GatewayClass` registers Envoy Gateway as the controller for this class. The `Gateway` is the actual entry point — MetalLB will assign it an IP from the pool configured in step 5.

```yaml
# gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg
  namespace: default
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
```

```bash
kubectl apply -f gateway.yaml
```

Watch for MetalLB to assign an IP to the Gateway:

```bash
kubectl get gateway eg --watch
```

Once the `ADDRESS` column is populated (e.g. `10.89.0.200`), the Gateway is ready.

---

## 9. Deploy a Test App and HTTPRoute

Deploy nginx and expose it via an `HTTPRoute` attached to the Gateway:

```bash
kubectl create deployment nginx-eg --image=nginx
kubectl expose deployment nginx-eg --port=80
```

```yaml
# httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: nginx-eg
  namespace: default
spec:
  parentRefs:
  - name: eg
  rules:
  - backendRefs:
    - name: nginx-eg
      port: 80
```

```bash
kubectl apply -f httproute.yaml
```

Test connectivity using the Gateway's IP:

```bash
export GW_IP=$(kubectl get gateway eg -o jsonpath='{.status.addresses[0].value}')
curl http://$GW_IP
```

> **Note:** On macOS and Windows, Podman runs inside a VM so the IP is not directly reachable from your host. Use one of these alternatives:

```bash
# Option A: port-forward
kubectl port-forward -n default svc/nginx-eg 8080:80
curl localhost:8080

# Option B: SSH into the Podman VM and curl directly
podman machine ssh
curl http://10.89.0.200
```

On **Linux**, the IP is directly reachable from your host.

## Extra

```bash
# Two separate nginx deployments with different content so we can tell them apart
kubectl create deployment nginx-a --image=nginx
kubectl create deployment nginx-b --image=nginx
kubectl expose deployment nginx-a --port=80
kubectl expose deployment nginx-b --port=80

kubectl wait deployment nginx-a nginx-b \
  --for=condition=available \
  --timeout=60s

# Give them different content
kubectl exec -it deploy/nginx-a -- sh -c 'echo "Hello from A" > /usr/share/nginx/html/index.html'
kubectl exec -it deploy/nginx-b -- sh -c 'echo "Hello from B" > /usr/share/nginx/html/index.html'
```

```yaml
# gateway-ab.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg-b
  namespace: default
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostname: "apps.example.com"
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: route-a
  namespace: default
spec:
  parentRefs:
  - name: eg-b
  hostnames:
  - "apps.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /a
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - name: nginx-a
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: route-b
  namespace: default
spec:
  parentRefs:
  - name: eg-b
  hostnames:
  - "apps.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /b
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - name: nginx-b
      port: 80
```

```bash
kubectl apply -f gateway-ab.yaml
```

```bash
export GW_AB=$(kubectl get gateway eg-b -o jsonpath='{.status.addresses[0].value}')
``

Since apps.example.com doesn't resolve to anything locally, add it to /etc/hosts:

```bash
echo "$GW_AB apps.example.com" | sudo tee -a /etc/hosts
```

curl http://apps.example.com/a   # → Hello from A
curl http://apps.example.com/b   # → Hello from B

---

## 10. Cleanup

**Delete just the test workload:**

```bash
kubectl delete -f httproute.yaml
kubectl delete deployment nginx
kubectl delete svc nginx
```

**Delete the Gateway resources:**

```bash
kubectl delete -f gateway.yaml
```

**Uninstall Envoy Gateway:**

```bash
helm uninstall eg -n envoy-gateway-system
```

**Delete the MetalLB configuration:**

```bash
kubectl delete -f metallb-pool.yaml
```

**Uninstall MetalLB entirely:**

```bash
kubectl delete -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
```

**Delete the entire Kind cluster** (fastest full reset):

```bash
kind delete cluster --name metallb-demo
```

This removes the cluster, all workloads, and all resources in one shot. Local files (`kind-config.yaml`, `metallb-pool.yaml`, `gateway.yaml`, `httproute.yaml`) are not affected.

---

## Summary

| Step | What it does |
|---|---|
| Kind cluster | Creates a local Kubernetes cluster via Podman |
| Node label | Marks the worker node for speaker placement |
| MetalLB manifest | Installs controller and speaker |
| DaemonSet patch | Restricts speaker to labeled worker nodes |
| `IPAddressPool` | Assigns IPs from the Podman network range |
| `L2Advertisement` | Announces IPs via ARP (L2 mode) |
| Gateway API CRDs | Installs the Gateway API types (not bundled with Kubernetes) |
| Envoy Gateway | Implements the `GatewayClass` and manages Envoy proxies |
| `GatewayClass` + `Gateway` | Declares the entry point — MetalLB assigns it an IP |
| `HTTPRoute` | Routes traffic from the Gateway to a backend service |