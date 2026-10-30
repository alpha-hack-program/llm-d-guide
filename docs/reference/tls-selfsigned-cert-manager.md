# TLS autofirmado gestionado por cert-manager — Gateways y Authorino

Guía de referencia para configurar **todo el TLS del stack (llm-d, MaaS, MCP Gateway y Authorino)
con certificados autofirmados, automatizados al máximo con el operador cert-manager**, evitando
la gestión manual de certificados (`openssl`, copiar/pegar PEMs, renovaciones a mano). Pensada para
labs, demos o clústeres sin DNS pública, antes de pasar a una CA externa reconocida.

> Esta guía complementa — no sustituye — [docs/phases/01-tls-cert-automation/README.md](../phases/01-tls-cert-automation/README.md),
> [docs/phases/06-maas.md](../phases/06-maas.md) y [docs/phases/08-mcp-gateway.md](../phases/08-mcp-gateway.md).
> Úsala como referencia de comandos exactos cuando el objetivo sea "todo autofirmado, cero
> intervención manual, cert-manager donde sea posible".

---

## 1. Dos capas de TLS independientes

El stack tiene **dos capas de TLS que no tienen nada que ver entre sí**. Confundirlas es la causa
más común de errores 500 o de certificados que no cuadran:

| Capa | Qué protege | Dónde se configura | Mecanismo recomendado aquí |
|---|---|---|---|
| **TLS externo del Gateway** | La conexión HTTPS del cliente (curl, SDK, navegador) contra la ruta pública del Gateway (llm-d, MaaS, MCP Gateway) | `Gateway` (Gateway API) + `Route` de OpenShift, namespace `openshift-ingress` | cert-manager, cadena de CA local autofirmada (Fase 1, `TLS_ISSUER=local-ca`) |
| **TLS interno de Authorino** | La conexión Envoy ↔ Authorino dentro del clúster (necesaria para que `POST /v1/api-keys` no devuelva `500`) | CR `Authorino` + `Service` `authorino-authorino-authorization`, namespace `kuadrant-system` | service-ca-operator de OpenShift (nativo, autofirmado, cero mantenimiento) |

Ambas capas son **self-signed** por diseño en este documento. Ninguna depende de Let's Encrypt ni
de una CA corporativa — eso se cubre en la [sección 6](#6-migración-futura-a-una-ca-externa-reconocida).

---

## 2. Por qué se elige cert-manager para el Gateway y service-ca-operator para Authorino

- **Gateway → cert-manager**: hay una elección real de herramienta (cert-manager vs. nada vs.
  scripts manuales de `openssl`). cert-manager renueva solo, está ya instalado como operador, y es
  el camino documentado y probado en Fase 1 (`TLS_ISSUER=local-ca`). Se usa aquí tal cual.
- **Authorino → service-ca-operator (no cert-manager)**: aunque el campo `certSecretRef` de la CR
  `Authorino` es agnóstico — acepta cualquier `Secret` tipo `kubernetes.io/tls` con ese nombre, lo
  emita quien lo emita (ver [sección 5.2](#52-variante-avanzada-no-validada-authorino-con-cert-manager))
  —, el controlador `gateway-auth-bootstrap` de `odh-model-controller` que genera automáticamente el
  `EnvoyFilter` de confianza mTLS está construido y probado contra el bundle de CA interno de
  OpenShift (`/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt`). Sustituir el emisor por
  cert-manager sin verificar que ese `EnvoyFilter` confía también en la nueva CA puede dejar la
  llamada Envoy→Authorino rota de forma silenciosa. Por eso, para Authorino se usa aquí el camino
  **ya probado** por la guía — que, igualmente, es 100 % autofirmado y 100 % automático (el
  service-ca-operator rota el certificado solo, sin tocar nada a mano).

Si prefieres no instalar cert-manager en absoluto para el Gateway, existe una alternativa aún más
simple: reutilizar el certificado autofirmado que OpenShift ya genera por defecto para el router
(`router-certs-default`, namespace `openshift-ingress`) — ver [sección 4.4](#44-alternativa-sin-cert-manager-router-certs-default).

---

## 3. Prerrequisitos

```bash
oc whoami  # debe ser cluster-admin
CLUSTER_DOMAIN=$(oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}')
[[ -z "${CLUSTER_DOMAIN}" ]] && { echo "Error: no se pudo detectar CLUSTER_DOMAIN"; exit 1; }
echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"
```

---

## 4. Capa 1 — TLS externo del Gateway con cert-manager (cadena de CA local)

### 4.1 Instalar el operador cert-manager

```bash
for i in $(seq 1 60); do
  if helm template gitops/operators/cert-manager-operator \
       --set cloud=${CLOUD} --name-template cert-manager | oc apply -f -; then
    break
  fi
  [[ $i -eq 60 ]] && { echo "Gave up after 60 attempts"; exit 1; }
  sleep 5
done
```

Espera a que el CSV esté `Succeeded` y repite el mismo comando una segunda vez (la `CertManager` CR
falla en el primer intento si el operador aún no está listo — comportamiento documentado en
Fase 1).

### 4.2 Crear la cadena de CA autofirmada (chart `cert-manager-local-ca`)

```bash
helm template gitops/operators/cert-manager-local-ca \
  --name-template cert-manager-local-ca \
  --set clusterDomain="${CLUSTER_DOMAIN}" | oc apply -f -
```

Esto crea, todo gestionado por cert-manager:

1. `selfsigned-issuer` (`ClusterIssuer`) — bootstrap de la clave raíz.
2. `selfsigned-ca` (`Certificate`, namespace `cert-manager`) — el certificado de la CA (ECDSA P-256).
3. `local-ca` (`ClusterIssuer`) — emite certificados firmados por esa CA local.
4. `ocp-ingress` (`Certificate`) — `*.apps.${CLUSTER_DOMAIN}`, secreto **`ingress-certs`** en
   `openshift-ingress`.
5. `ocp-api` (`Certificate`) — `api.${CLUSTER_DOMAIN}`, secreto `api-certs` en `openshift-config`.

Verificación obligatoria — **`Issuing` no es suficiente, hace falta `READY=True`**:

```bash
oc wait --for=condition=Ready certificate/selfsigned-ca -n cert-manager --timeout=120s
oc wait --for=condition=Ready certificate/ocp-api -n openshift-config --timeout=300s
oc wait --for=condition=Ready certificate/ocp-ingress -n openshift-ingress --timeout=300s
oc get certificates.cert-manager.io --all-namespaces \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status'
```

### 4.3 Inyectar la CA en el trust bundle del clúster (obligatorio)

Sin este paso, componentes del clúster (incluido el sidecar `maas-ui`) rechazan los certificados
firmados por la CA local:

```bash
oc wait --for=condition=Ready certificate/selfsigned-ca -n cert-manager --timeout=120s

oc get secret cert-manager-ca -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/local-ca.crt

oc create configmap user-ca-bundle -n openshift-config \
  --from-file=ca-bundle.crt=/tmp/local-ca.crt \
  --dry-run=client -o yaml | oc apply -f -

oc patch proxy/cluster --type=merge \
  -p '{"spec":{"trustedCA":{"name":"user-ca-bundle"}}}'
```

RHOAI fusiona `user-ca-bundle` en `odh-trusted-ca-bundle`/`odh-ca-bundle`, que es lo que usa
`maas-ui` para validar el certificado del Gateway. La propagación tarda normalmente menos de 60 s;
si el dashboard sigue rechazando el cert, reinicia el pod:

```bash
oc rollout restart deployment/rhods-dashboard -n redhat-ods-applications
```

### 4.4 Configurar cada Gateway para usar el certificado `ingress-certs`

#### llm-d (Fase 5)

```bash
helm template gitops/instance/llm-d/gateway \
  --set tls.secretName=ingress-certs \
  ... | oc apply -f -
```

El `Gateway` se crea en `openshift-ingress` (mismo namespace que el secreto `ingress-certs` — no
hace falta `ReferenceGrant`).

#### MaaS (Fase 6 y 7)

```bash
helm template gitops/instance/maas/gateway \
  --set tls.secretName=ingress-certs \
  ... | oc apply -f -
```

> ⚠️ **Nota de troubleshooting real del repo** (`README.md`): si al probar el endpoint aparece un
> error tipo `x509: certificate is valid for ...openshift-ingress.svc, not maas.<cluster-domain>`,
> es señal de que algo ha sobrescrito el secreto `ingress-certs` con un certificado interno. La
> solución documentada es volver a aplicar el chart con:
> ```bash
> helm template gitops/instance/maas/gateway \
>   --set tls.secretName=router-certs-default \
>   ... | oc apply -f -
> ```
> Esto cambia de "certificado emitido por cert-manager" a "certificado autofirmado nativo de
> OpenShift" solo para el Gateway de MaaS — sigue siendo 100 % autofirmado y cero gestión manual,
> simplemente deja de pasar por cert-manager en ese punto concreto. Pruébalo primero con
> `ingress-certs`; cae a `router-certs-default` solo si ves ese error de x509.

#### MCP Gateway (Fase 8)

El chart `gitops/instance/mcp-gateway` **no expone ningún campo `tls.secretName`** — el `Route`
que genera usa terminación `edge` sin certificado explícito, por lo que siempre toma el
**certificado por defecto del `IngressController`** del clúster. Si quieres que el MCP Gateway
presente el mismo certificado de la CA local que los otros dos Gateways, parchea el
`IngressController` por defecto una sola vez (afecta a todas las rutas `edge` del clúster que no
fijan su propio secreto, así que hazlo con conocimiento):

```bash
oc patch ingresscontroller/default -n openshift-ingress-operator \
  --type=merge -p '{"spec":{"defaultCertificate":{"name":"ingress-certs"}}}'
```

Si no aplicas este parche, el MCP Gateway seguirá usando el certificado autofirmado nativo de
OpenShift (`router-certs-default`) — igualmente válido como "certificado interno autofirmado",
simplemente no es el emitido por cert-manager.

### 4.4 Alternativa sin cert-manager: `router-certs-default`

Si en algún Gateway prefieres no depender de cert-manager en absoluto, `router-certs-default`
(namespace `openshift-ingress`) es el certificado autofirmado que OpenShift genera y rota él solo
desde el día de instalación del clúster — cero pasos, cero mantenimiento:

```bash
helm template gitops/instance/maas/gateway \
  --set tls.secretName=router-certs-default \
  ... | oc apply -f -
```

Es exactamente el patrón que usa la documentación oficial de Red Hat para MaaS multi-tenant.

---

## 5. Capa 2 — TLS interno de Authorino (self-signed CA)

### 5.1 Camino recomendado y probado: service-ca-operator

```bash
# 4a. Anotar el Service de Authorino para que el service-ca-operator le genere certificado
oc annotate service authorino-authorino-authorization \
  -n kuadrant-system \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
  --overwrite

# 4b. Habilitar TLS en la CR de Authorino
oc patch authorino authorino -n kuadrant-system --type=merge --patch '{
  "spec": {
    "listener": {
      "tls": {
        "enabled": true,
        "certSecretRef": {"name": "authorino-server-cert"}
      }
    }
  }
}'

# 4c. Hacer que Authorino confíe en el bundle de CA interno del clúster
oc -n kuadrant-system set env deployment/authorino \
  SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
oc rollout status deployment/authorino -n kuadrant-system --timeout=90s
```

Verificación:

```bash
oc get secret authorino-server-cert -n kuadrant-system
# Esperado: kubernetes.io/tls, 2 entradas de datos (tls.crt, tls.key)
```

Después, dispara la generación del `EnvoyFilter` de confianza mTLS (paso 4d de Fase 6):

```bash
oc annotate gateway maas-default-gateway -n openshift-ingress \
  security.opendatahub.io/authorino-tls-bootstrap="true" --overwrite
```

El controlador `gateway-auth-bootstrap` de `odh-model-controller` hace una comprobación **de un
solo intento** al ver esta anotación: si en ese momento Authorino todavía no tiene TLS activo,
registra "Authorino has TLS disabled, skipping EnvoyFilter creation" y **no vuelve a intentarlo**.
Por eso 4a–4c deben estar verificados (`READY`/secreto creado/rollout completo) **antes** de este
paso. Si el `EnvoyFilter` `maas-default-gateway-authn-ssl` no aparece en `openshift-ingress`
después de 30 s, reinicia el controlador:

```bash
oc rollout restart deployment/odh-model-controller -n redhat-ods-applications
```

Esto ya es, por sí mismo, "una CA autofirmada para Authorino sin gestión manual": el
service-ca-operator es la CA interna del propio clúster (autofirmada en la instalación de
OpenShift) y rota los certificados automáticamente.

### 5.2 Variante avanzada (no validada): Authorino con cert-manager

Técnicamente es posible, porque `certSecretRef.name` en la CR `Authorino` solo exige que exista un
`Secret` tipo `kubernetes.io/tls` con ese nombre — no le importa quién lo haya emitido:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: authorino-server-cert
  namespace: kuadrant-system
spec:
  secretName: authorino-server-cert
  issuerRef:
    name: local-ca        # el ClusterIssuer creado en el paso 4.2
    kind: ClusterIssuer
  dnsNames:
    - authorino-authorino-authorization.kuadrant-system.svc
    - authorino-authorino-authorization.kuadrant-system.svc.cluster.local
```

Con esto, **omites el paso 5a** (la anotación del `Service`) y aplicas directamente 5b/5c sobre el
secreto que genera cert-manager.

> ⚠️ **Riesgo no verificado**: el `EnvoyFilter` que `odh-model-controller` genera automáticamente
> en el paso 4d está construido para confiar en el bundle de CA interno de OpenShift
> (`openshift-service-ca`), no en la CA local de cert-manager. Aunque hayas inyectado esa misma CA
> en `user-ca-bundle` (paso 4.3), ese es un bundle distinto del que usa el `EnvoyFilter` para
> validar la conexión mTLS Envoy→Authorino. Antes de usar esta variante en algo que no sea una
> prueba rápida, verifica manualmente el contenido del `EnvoyFilter` generado y confirma que la
> conexión Envoy→Authorino no falla (comprueba logs de Envoy/istio-proxy en el pod del Gateway).
> Si falla, vuelve al camino de la sección 5.1 — es el único camino probado por esta guía.

---

## 6. Verificación final de extremo a extremo

```bash
# Certificados del Gateway
oc get certificates.cert-manager.io --all-namespaces

# Secreto de Authorino
oc get secret authorino-server-cert -n kuadrant-system -o jsonpath='{.type}'  # kubernetes.io/tls

# EnvoyFilter de confianza mTLS
oc get envoyfilter maas-default-gateway-authn-ssl -n openshift-ingress

# Prueba real: creación de una API key de MaaS (el síntoma de TLS de Authorino roto es un 500 aquí)
curl -sk -X POST https://maas.${CLUSTER_DOMAIN}/v1/api-keys -d '{}' -o /dev/null -w '%{http_code}\n'
```

---

## 7. Migración futura a una CA externa reconocida

Todo lo anterior es autofirmado. Cuando llegue el momento de pasar a una CA pública (Let's Encrypt)
o corporativa, esto es lo que cambia — y lo que **no** hace falta tocar:

### 7.1 Gateway: de `local-ca` a Let's Encrypt (Route53)

En este repo ambos caminos (`cert-manager-local-ca` y `cert-manager-route53`) generan los mismos
`Certificate` (`ocp-ingress`, `ocp-api`) con **los mismos nombres de secreto** (`ingress-certs`,
`api-certs`). Lo único que cambia es `spec.issuerRef.name`. Por tanto, migrar es:

```bash
./scripts/validate-cluster-domain.sh   # obligatorio, confirma el dominio antes de aplicar
# detente y confirma el dominio extraído con el usuario antes de continuar

helm template gitops/operators/cert-manager-route53 \
  --set clusterDomain="${CLUSTER_DOMAIN}" \
  ... | oc apply -f -
```

cert-manager detecta el cambio de `issuerRef` en los `Certificate` existentes y **vuelve a emitir
el certificado automáticamente** (comportamiento estándar de cert-manager) — no hace falta borrar
secretos ni `Certificate` a mano. Como los nombres de secreto no cambian, **ningún chart de
Gateway (llm-d/MaaS/MCP) necesita volver a aplicarse** — todos siguen apuntando a `ingress-certs`.

### 7.2 Gateway con CA corporativa interna

Si la CA no es Let's Encrypt sino una CA corporativa propia:

1. Crea un `Issuer`/`ClusterIssuer` de cert-manager de tipo `ca` (apuntando a un `Secret` con el
   certificado+clave de la CA corporativa) o `vault`/`acme` si la CA expone esos protocolos.
2. Cambia `spec.issuerRef` de los `Certificate` `ocp-ingress`/`ocp-api` (y, si usaste la variante
   de la sección 5.2, también `authorino-server-cert`) a ese nuevo issuer.
3. Si en vez de cert-manager usaste directamente `router-certs-default` para algún Gateway
   (sección 4.4), el reemplazo es manual sobre el propio `IngressController`:
   ```bash
   oc create secret tls ingress-certs -n openshift-ingress \
     --cert=fullchain.pem --key=privkey.pem \
     --dry-run=client -o yaml | oc apply -f -
   oc patch ingresscontroller/default -n openshift-ingress-operator \
     --type=merge -p '{"spec":{"defaultCertificate":{"name":"ingress-certs"}}}'
   ```

### 7.3 Authorino

- Si se quedó en **service-ca-operator** (camino recomendado, sección 5.1): su CA es
  intrínsecamente la CA interna del clúster — no se puede apuntar a una CA externa sin migrar
  primero a la variante cert-manager de la sección 5.2.
- Si ya se migró a **cert-manager** (sección 5.2): basta con cambiar `spec.issuerRef` del
  `Certificate` `authorino-server-cert` al nuevo issuer, igual que en 7.1. El parche de la CR
  `Authorino` (`certSecretRef.name: authorino-server-cert`) no cambia — es agnóstico a quién emite
  el secreto.

### 7.4 Qué hacer con el trust bundle local (`user-ca-bundle`)

Es seguro dejarlo tal cual tras añadir la CA externa — `user-ca-bundle` es **aditivo** (se fusiona
con el bundle del sistema), no sustituye nada. La CA local autofirmada simplemente deja de emitir
nada nuevo en cuanto ningún `Certificate` siga referenciando `local-ca`/`selfsigned-issuer`.
Opcionalmente, por higiene de auditoría, puedes limpiarlo más adelante:

```bash
oc patch proxy/cluster --type=merge -p '{"spec":{"trustedCA":{"name":""}}}'
oc delete configmap user-ca-bundle -n openshift-config
```

### 7.5 Cosas a revisar tras el cambio (gotchas de clientes)

- **`maas-ui` / `rhods-dashboard`**: la propagación del nuevo bundle de confianza tarda normalmente
  menos de 60 s, pero el pod puede necesitar un reinicio explícito para recoger el montaje
  actualizado: `oc rollout restart deployment/rhods-dashboard -n redhat-ods-applications`.
- **Authorino es independiente del certificado del Gateway**: cambiar el cert del router/Gateway
  no afecta a Authorino, y viceversa — son rutas de confianza totalmente separadas.
- **Clientes externos** que durante la fase autofirmada usaban workarounds (`-k`, `verify=False`,
  un CA bundle custom) deben quitarlos tras el cambio a CA reconocida; en caso contrario seguirán
  funcionando igual, simplemente de forma innecesaria.
- **Procesos de larga duración** que cachean el bundle de CA en memoria (p. ej. `requests`/`certifi`
  en Python, truststores de JVM cargados al arrancar) necesitan un reinicio — no basta con
  actualizar el `ConfigMap`/`Secret`, hay que relanzar el pod para que recargue la cadena.

---

## Referencias

- [Fase 1 — TLS Certificate Automation](../phases/01-tls-cert-automation/README.md)
- [Fase 6 — MaaS](../phases/06-maas.md)
- [Fase 7 — MaaS Multi-Tenant](../phases/07-maas-multi-tenant.md)
- [Fase 8 — MCP Gateway](../phases/08-mcp-gateway.md)
- [MaaS Troubleshooting](maas-troubleshooting.md)
