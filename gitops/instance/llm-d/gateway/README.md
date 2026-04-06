# Deployment of a k8s Gateway based on OpenShift Connectivity Link for llm-d

This helm chart deploys all the elements needed for ingress traffic using Kubernetes Gateway API.

## Example Deployments

### Uisng load balancer with pre-existing certificate

```bash
APP_NAME=gateway
GATEWAY_NAME=${GATEWAY_NAME:=openshift-ai-inference}
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"
helm template gitops/instance/llm-d/gateway \
  --name-template ${APP_NAME} \
  --set gatewayName="${GATEWAY_NAME}" \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --set subdomain=inference \
  --set useOpenShiftRoute=false \
  --set tls.secretName=ingress-certs --include-crds > gw-lb-certificate.tmp.yaml
```
### Using load balancer and generating a self-signed certificate:

```bash
APP_NAME=gateway
GATEWAY_NAME=${GATEWAY_NAME:=openshift-ai-inference}
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"
helm template gitops/instance/llm-d/gateway \
  --name-template ${APP_NAME} \
  --set gatewayName="${GATEWAY_NAME}" \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --set subdomain=inference \
  --set useOpenShiftRoute=false \
  --set tls.secretName="${GATEWAY_NAME}" \
  --set tls.generate=true --include-crds > gw-lb-selfsigned.tmp.yaml
```

### Using load balancer and generating a letsencrypt certificate:

```bash
APP_NAME=gateway
GATEWAY_NAME=${GATEWAY_NAME:=openshift-ai-inference}
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"
helm template gitops/instance/llm-d/gateway \
  --name-template ${APP_NAME} \
  --set gatewayName="${GATEWAY_NAME}" \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --set subdomain=inference \
  --set useOpenShiftRoute=false \
  --set tls.secretName="${GATEWAY_NAME}" \
  --set tls.generate=true \
  --set tls.issuerName=letsencrypt --include-crds > gw-lb-letsencrypt.tmp.yaml
```

### Uisng OpenShift router with pre-existing certificate

```bash
APP_NAME=gateway
GATEWAY_NAME=${GATEWAY_NAME:=openshift-ai-inference}
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"
helm template gitops/instance/llm-d/gateway \
  --name-template ${APP_NAME} \
  --set gatewayName="${GATEWAY_NAME}" \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --set subdomain=inference \
  --set useOpenShiftRoute=true \
  --set tls.secretName=ingress-certs --include-crds > gw-ocp-route-certificate.tmp.yaml
```

### Using OpenShift router and generating a self-signed certificate:

```bash
APP_NAME=gateway
GATEWAY_NAME=${GATEWAY_NAME:=openshift-ai-inference}
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"
helm template gitops/instance/llm-d/gateway \
  --name-template ${APP_NAME} \
  --set gatewayName="${GATEWAY_NAME}" \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --set subdomain=inference \
  --set useOpenShiftRoute=true \
  --set tls.secretName="${GATEWAY_NAME}" \
  --set tls.generate=true --include-crds > gw-ocp-route-selfsigned.tmp.yaml
```

### Using OpenShift router and generating a letsencrypt certificate:

```bash
APP_NAME=gateway
GATEWAY_NAME=${GATEWAY_NAME:=openshift-ai-inference}
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"
helm template gitops/instance/llm-d/gateway \
  --name-template ${APP_NAME} \
  --set gatewayName="${GATEWAY_NAME}" \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  --set subdomain=inference \
  --set useOpenShiftRoute=true \
  --set tls.secretName="${GATEWAY_NAME}" \
  --set tls.generate=true \
  --set tls.issuerName=letsencrypt --include-crds > gw-ocp-route-letsencrypt.tmp.yaml
```

Then use `oc apply -f <filename>`

## Gateway tests with some NGINX services

Test it:

On OpenShift, pods run as an arbitrary non-root UID. The stock `nginx` image expects root and fails with `Permission denied` under `/var/cache/nginx`. Use an unprivileged image (it listens on **8080**). Do not rely on `oc exec` to edit `/usr/share/nginx/html`: that path is typically root-owned in the image while your process runs as a random UID, so writes fail with **Permission denied**. Mount a **ConfigMap** for `index.html` instead.

```bash
# Run this block in one shell (or export vars first). Empty --image= yields
# "containers: Required value" if NGINX_IMAGE is unset.
PROJECT="${PROJECT:-llm-d-demo}"
NGINX_IMAGE="${NGINX_IMAGE:-docker.io/nginxinc/nginx-unprivileged:alpine}"

oc create deployment nginx-a --image="${NGINX_IMAGE}" -n "${PROJECT}"
oc create deployment nginx-b --image="${NGINX_IMAGE}" -n "${PROJECT}"
oc expose deployment nginx-a --port=8080 -n "${PROJECT}"
oc expose deployment nginx-b --port=8080 -n "${PROJECT}"

oc wait deployment nginx-a nginx-b \
  --for=condition=available \
  --timeout=60s -n "${PROJECT}"

# Different body text per app: ConfigMap volume (writable html via exec fails on OpenShift).
oc create configmap nginx-a-html -n "${PROJECT}" --from-literal=index.html="Hello from A" --dry-run=client -o yaml | oc apply -f -
oc create configmap nginx-b-html -n "${PROJECT}" --from-literal=index.html="Hello from B" --dry-run=client -o yaml | oc apply -f -

oc set volumes deployment/nginx-a --add --name=html -t configmap --configmap-name=nginx-a-html --mount-path=/usr/share/nginx/html -n "${PROJECT}" --overwrite
oc set volumes deployment/nginx-b --add --name=html -t configmap --configmap-name=nginx-b-html --mount-path=/usr/share/nginx/html -n "${PROJECT}" --overwrite

oc rollout status deployment/nginx-a -n "${PROJECT}" --timeout=120s
oc rollout status deployment/nginx-b -n "${PROJECT}" --timeout=120s
```

Routes:

```sh
oc apply -n ${PROJECT} -f - <<EOF
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: route-a
  namespace: ${PROJECT}
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ${GATEWAY_NAME}
      namespace: openshift-ingress
  hostnames:
  # - "apps.example.com"
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
      port: 8080
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: route-b
  namespace: ${PROJECT}
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ${GATEWAY_NAME}
      namespace: openshift-ingress
  hostnames:
  # - "apps.example.com"
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
      port: 8080
EOF
```

### Troubleshooting HTTPRoutes (`route-a` / `route-b`)

Use one shell with `PROJECT` and `GATEWAY` set (same values as when you applied the routes).

With **`useOpenShiftRoute: true`**, the Gateway chart renders the **Route** with **`targetPort`** set to the listener port name (`https` / `http`) and **`tls.termination: passthrough`** when the Gateway uses TLS (`templates/gateway.yaml`). You should not need manual Route patches for wrong **`targetPort`** or **edge-vs-HTTPS** **502**s unless an old Route is out of date—re-apply or upgrade the Helm release.

**1. Parent Gateway and status**

```bash
oc get httproute route-a route-b -n "${PROJECT}" -o wide
oc describe httproute route-a -n "${PROJECT}"
oc get gateway "${GATEWAY}" -n openshift-ingress -o yaml
oc get httproute route-a -n "${PROJECT}" -o jsonpath='{range .status.parents[*]}{.parentRef.name}{": "}{range .conditions[*]}{.type}={.status} ({.message}){" | "}{end}{"\n"}{end}'
```

- **`parentRefs`**: `name` / `namespace` must match your `Gateway` (this lab: **`openshift-ingress`**). Mismatches show as **Accepted=False**.
- **`sectionName`**: If the Gateway has multiple listeners and attachment is ambiguous, set **`sectionName`** on `parentRefs` to the listener **`name`** (`http` / `https`).
- Expect **Accepted** and **ResolvedRefs**; backends show up as **ResolvedRefs=False** when the Service name, port, or namespace is wrong.

**2. `backendRefs.port` vs Service**

```bash
oc get svc nginx-a nginx-b -n "${PROJECT}" -o custom-columns=NAME:.metadata.name,PORT:.spec.ports[0].port,TARGET:.spec.ports[0].targetPort
```

`backendRefs.port` must match the Service **`spec.ports[].port`** (this README uses **8080**).

**3. Curl: real host, path `/a` or `/b`**

Use a real hostname or IP in the URL (placeholder text will yield **Bad hostname**). If you curl via IP but the listener has a **`hostname`**, set **`Host:`** to that name. When DNS points at the ingress and the URL host is **`GW_HOST`**, this is enough:

```bash
GW_HOST="$(oc get gateway "${GATEWAY}" -n openshift-ingress -o jsonpath='{.spec.listeners[0].hostname}')"
LISTENER_PORT="$(oc get gateway "${GATEWAY}" -n openshift-ingress -o jsonpath='{.spec.listeners[0].port}')"
GATEWAY_ADDR="${GW_HOST}"
[ "${LISTENER_PORT}" = "443" ] && SCHEME=https || SCHEME=http
curl -sS "${SCHEME}://${GATEWAY_ADDR}/a"
```

These HTTPRoutes match **`/a`** and **`/b`** only; **`URLRewrite`** sends **`/`** to nginx. **`/`** on the host will not select `route-a` / `route-b`.

**4. `allowedRoutes`**

If **Accepted** says routes from this namespace are not allowed, check the Gateway listener **`allowedRoutes`** (the chart defaults to **`namespaces.from: All`**).

### Reference: errors we have already debugged

Short map from **symptom → cause → fix** so the next time one of these appears you can recognize it quickly.

| Symptom | Likely cause | What to do |
|--------|----------------|------------|
| **`error: Unexpected args: [-]`** from `oc apply … -f -` | **`${PROJECT}`** (or **`${NAMESPACE}`**) was **empty**, so **`-n`** swallowed **`-f`** as the namespace value and the stdin **`-`** became an extra argument. | Export **`PROJECT`** before applying, or put **`-f -`** before **`-n`**, or use **`oc apply -f file.yaml`**. |
| **`Deployment … is invalid: spec.template.spec.containers: Required value`** | **`--image=`** was empty because **`NGINX_IMAGE`** was unset in that shell (often after copying only part of the script). | Set **`NGINX_IMAGE`** or rely on the **`${NGINX_IMAGE:-…}`** default in one pasted block; always quote **`--image="${NGINX_IMAGE}"`**. |
| **`Error from server (AlreadyExists): services "nginx-…" already exists`** | **`oc expose`** was run again; the Service from an earlier attempt is still there. | Safe to ignore if the Service still points at the right Deployment/port; otherwise **`oc delete svc …`** and **`oc expose`** again, or fix **`targetPort`** if you changed container ports. |
| **`timed out waiting for the condition on deployments/…`** and **`oc exec` … `container not found ("nginx")`** | Pods never became **Ready** (image pull, SCC, crash loop), so there is no running container to exec into. | **`oc get pods`**, **`oc describe pod`**, **`oc logs`**; fix the underlying pod issue first. |
| **`mkdir() "/var/cache/nginx/client_temp" failed (13: Permission denied)`** in nginx logs | Default **`nginx`** image expects **root**; OpenShift runs the container as an **arbitrary non-root UID**. | Use an unprivileged image (e.g. **`nginxinc/nginx-unprivileged`**) and Service/backend port **8080**, or add **emptyDir** mounts under **`/var/cache/nginx`** (harder for demos). |
| **`sh: can't create …/index.html: Permission denied`** via **`oc exec`** | **`/usr/share/nginx/html`** is not writable by the UID used in the pod. | Do not **`exec`** to edit static files; use a **ConfigMap** volume (as in the script above). |
| **`curl: (3) URL rejected: Bad hostname`** | The URL still contains a **placeholder** (e.g. angle brackets) or another invalid host string. | Use a real DNS name or IP; derive **`GW_HOST`** from the Gateway listener if needed. |
| **OpenShift HTML page: “Application is not available”** while **HTTPRoute** is **Accepted** | **Route** **`spec.port.targetPort`** did not match a **port name** on the Gateway **Service** (e.g. **`http`** vs **`https`**). | With current Helm (**`useOpenShiftRoute: true`**), the chart sets the right **`targetPort`**; **re-apply the chart** if the Route predates the fix. |
| **`502 Bad Gateway`** / “invalid or incomplete response” from the router | **Route** used **`tls.termination: edge`**: the router spoke **plain HTTP** to a **Gateway listener on 443 that expects TLS**. | Current Helm uses **`passthrough`** for TLS Gateways; **re-apply the chart**. Alternative: **`reencrypt`** with a correct destination CA if you must terminate at the edge. |

**`cat: apply: No such file or directory`** (or similar): usually a **copy-paste** or line break so **`cat`** received **`apply`** / **`-f`** as filenames instead of running **`oc apply`**. Re-run the intended **`oc`** command as a single line or heredoc.
