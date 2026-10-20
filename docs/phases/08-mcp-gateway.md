# Phase 8 — MCP Gateway

> Part of the [llm-d-guide Co-pilot Runbook](../../AGENTS.md). See the
> [Phase Map](../../AGENTS.md#phase-map) for the full sequence.
> Requires [Phase 3 — Core Operators + RHOAI](03-operators-rhoai.md) to be complete
> (Connectivity Link / RHCL 1.4.1+ installed — this phase layers a second operator on top).

**Optional — standalone from the RHOAI/llm-d install.** This phase deploys a shared RHCL
(Kuadrant) MCP Gateway: one `Gateway` object that lets external MCP clients (agents, IDEs,
sandboxes) reach any number of MCP tool servers over OIDC-authenticated HTTP, instead of each
project wiring up its own ingress and auth per server. It does not touch llm-d, RHOAI, or MaaS —
it exists for projects (this one or others) that need to expose MCP servers behind a gateway with
per-tenant OIDC isolation.

**Goal:** Deploy a default MCP Gateway tenant, verify it end-to-end, then show how to add further
tenants — each with its own Keycloak realm, hostname, and auth policy, fully isolated from every
other tenant on the same shared `Gateway`.

**Architecture:** One cluster-scoped `Gateway` (`mcp-gateway`, in `openshift-ingress`) is shared by
every tenant. The **default tenant** (`gateway.publicHost` / `oidc.issuer` / `auth.*`) always
exists and uses the exact same flat field names as the original single-tenant chart this was
generalized from — on purpose, so it matches upstream's own documented `values.yaml` shape and is
never exposed to any list-merge behavior. It creates the `mcp`/`mcps` listeners and objects named
`mcp-gateway-authn`/`mcp-gateway-authz`/`mcp-gateway-ext`/`mcp-gateway`, identical to a plain
single-tenant deployment.

Every tenant beyond the default is **additive**, via `extraTenants` in values. Each entry requires
`name`, `publicHost`, and `extensionNamespace` — the chart fails fast (Helm's `required`) if any is
missing — and gets, independently:
- a `Gateway` listener, `<tenant>-mcp` (external, has a hostname).
- its own `Route` (OpenShift needs one per public hostname; the Gateway's own Service is
  deliberately `ClusterIP`).
- its own `MCPGatewayExtension` in its own `extensionNamespace` (own `publicHost`, own trusted OIDC
  issuer if one is set), plus a matching `ReferenceGrant` entry (created automatically) allowing
  that namespace to reference the shared `Gateway`. `extensionNamespace` has no default and must be
  unique across every tenant, default included — see the gotcha on why.
- if `oidcIssuer` is also set: a second listener `<tenant>-mcps` (internal, post-routing,
  authn+authz, no hostname — RHCL 1.4's two-listener pattern; a JSON-RPC-body-parsing `ext_proc`
  rewrites `:authority` and re-evaluates routing between the two, which is why both listeners in a
  pair must share the same port) and its own `AuthPolicy` pair (own Keycloak realm issuer; the
  authz policy's CEL checks `resource_access.<servername>.roles`, so Keycloak clients must be named
  `<extensionNamespace>/<server-name>` with `tool:<toolname>` / `prompt:<promptname>` client
  roles). `oidcIssuer` empty (the default) means that tenant has no gateway-level auth at all —
  there is deliberately no separate on/off flag beyond the issuer itself; see the gotcha on why.

**`oidc.issuer`/`oidcIssuer` is genuinely provider-agnostic for authentication only.** Issuer-URL
JWT validation is standard OIDC — any compliant provider works there. Authorization is not
provider-agnostic: the CEL above checks `resource_access`, which is Keycloak's own claim shape for
per-client roles, not a generic OIDC/JWT claim. This isn't a gap unique to this chart — it's how
Kuadrant's own upstream MCP Gateway docs do it too (confirmed against
[docs.kuadrant.io/dev/mcp-gateway's "User-Based Tool Filtering" guide](https://docs.kuadrant.io/dev/mcp-gateway/docs/guides/user-based-tool-filter/)
and [github.com/Kuadrant/mcp-gateway's `authorization.md`](https://github.com/Kuadrant/mcp-gateway/blob/main/docs/guides/authorization.md)):
both present the AuthPolicy/Authorino policy engine itself as portable across identity providers,
but every worked authorization example is hardcoded to `resource_access`, with no documented
adaptation path for providers (Okta, Auth0, Entra ID, ...) that emit a different claim shape.
Pointing this chart at a non-Keycloak OIDC provider makes authentication work fine; authorization
silently fails closed (every `tool-access-check`/`prompt-access-check` evaluates false, not an
error) unless that provider is configured to also emit a `resource_access`-shaped claim, or the
CEL is adapted to match whatever claim shape it actually produces.

**This chart supports that adaptation directly, per tenant — no template edits needed.**
`auth.toolAccessPredicate`/`auth.promptAccessPredicate` (default tenant) and
`extraTenants[].auth.toolAccessPredicate`/`promptAccessPredicate` (per extra tenant) are raw CEL
strings, defaulted to today's Keycloak-shaped expressions, evaluated by Authorino exactly as given.
Override them in a values file to adapt a tenant to a different provider's claim shape — e.g. a
provider that puts flat `tool:<name>` strings directly in a `groups` claim, with no per-server
nesting at all:
```yaml
extraTenants:
  - name: contoso
    publicHost: contoso-mcp.apps.ocp.example.com
    extensionNamespace: mcp-gateway-contoso
    oidcIssuer: https://login.contoso-idp.example.com/v2
    port: 8082
    auth:
      toolAccessPredicate: |-
        ('tool:' + request.headers['x-mcp-toolname']) in auth.identity.groups
      promptAccessPredicate: |-
        ('prompt:' + request.headers['x-mcp-promptname']) in auth.identity.groups
```
Verified by rendering this exact override through the chart: the resulting `AuthPolicy` carries
the custom CEL unchanged, with no Keycloak-specific scaffolding left over, alongside other tenants
that still use the default `resource_access` CEL untouched. An invalid CEL expression is rejected
by Authorino at apply time (that `AuthPolicy`'s `Enforced` condition goes `False`), not silently.

Adding an entry to `extraTenants` and re-running `helm upgrade` only appends new objects — it never
edits or re-targets the default tenant's listeners/Route/extension/AuthPolicy, or another extra
tenant's. This is what makes multiple isolated tenants possible on one shared `Gateway`: nothing
about tenant B's realm, hostname, or policy is visible to tenant A, and vice versa.

**Chart:** [`gitops/instance/mcp-gateway`](../../gitops/instance/mcp-gateway). **Operator:**
[`gitops/operators/mcp-gateway-operator`](../../gitops/operators/mcp-gateway-operator).

**Pre-flight checks the assistant must run before starting:**
```bash
# Phase 3's Connectivity Link must already be installed and Ready
oc get csv -A | grep -E "rhcl-operator|authorino-operator|limitador-operator"
oc get kuadrant kuadrant -n kuadrant-system

# RHCL must be 1.4.1+ — 1.4.0 has known auth-failure/memory-pressure issues
oc get csv -n openshift-operators -l operators.coreos.com/rhcl-operator.openshift-operators -o jsonpath='{.items[0].spec.version}'
```

**Ask the user, in order:**
1. The default tenant's public hostname (e.g. `mcp.apps.<cluster-domain>`) — always required,
   regardless of the next answer.
2. Whether OIDC should be enforced at the gateway for the default tenant — **defaults to no /
   disabled**, the chart does not assume OIDC for the default tenant unless asked for. If the user
   says yes, ask for the Keycloak **issuer URL** — explain that the issuer URL *is* how the realm
   is specified: it already has the shape `https://<keycloak-host>/realms/<realm>`, so there is no
   separate "realm name" question, just this one URL, and there is no separate on/off flag either —
   providing the URL *is* what turns OIDC on (see Step 2). If no (or no answer — the default), skip
   the issuer question entirely.
3. Whether a new (extra) tenant is needed now, beyond the default. If yes, for **each** tenant ask:
   - a short **name** (used to derive its listener/object names, e.g. `owl` → `owl-mcp`/`owl-mcps`)
   - its own public hostname (same shape as #1, but must be a different hostname than the default's
     and any other tenant's)
   - its **issuer URL** — same explanation as #2: the URL already encodes the realm
     (`https://<keycloak-host>/realms/<realm>`), so just ask for the one URL, and providing it is
     what enables OIDC for that tenant, no separate flag. Unlike the default tenant, an extra
     tenant's issuer is effectively always wanted in practice (that is the entire point of adding
     one — a separate, isolated OIDC realm from the default tenant's), but it can be left unset too
     if that tenant genuinely needs no gateway-level auth.
   If no, stand up just the default gateway — tenants can always be added later via Step 4.

---

### Step 1 — Install the MCP Gateway Operator

**Easy to miss: a second, differently-named OLM package, not part of `rhcl-operator`.** A cluster
with only Connectivity Link installed has no `mcpgatewayextensions.mcp.kuadrant.io` CRD at all —
`helm template | oc apply` fails with `no matches for kind "MCPGatewayExtension"`, which reads
like an RHCL version problem but isn't.

```bash
oc get packagemanifest mcp-gateway -n openshift-marketplace

oc apply -k gitops/operators/mcp-gateway-operator
```

Verify the CSV reaches `Succeeded` and the CRDs exist:
```bash
oc -n mcp-gateway-system get csv -l operators.coreos.com/mcp-gateway.mcp-gateway-system
oc get crd | grep mcp.kuadrant.io
```

> **Technology Preview** — not covered by production SLAs. See Red Hat's
> [MCP Gateway install guide](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html-single/install_the_mcp_gateway/index)
> for the full upstream instructions this summarizes.

### Step 2 — Deploy the default tenant

The default tenant's fields are plain top-level scalars (`gateway.publicHost`, `oidc.issuer`),
exactly like the original single-tenant chart — so `--set` is safe here, unlike `extraTenants`
(see Step 4, and the gotcha about why).

**`oidc.issuer` is the only switch — there is no separate `auth.enabled` field.** Leaving it
empty disables OIDC entirely for the default tenant; setting it enables OIDC. One field, one
meaning, nothing to forget to pair with it.

**If OIDC is not enforced** (question 2's answer was no, or no answer — this is the chart's
default): only `gateway.publicHost` is needed. The gateway then has a single, unauthenticated
`mcp` listener, and neither `AuthPolicy` nor the `EnvoyFilter` is created:

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

helm template gitops/instance/mcp-gateway --name-template mcp-gateway \
  --set gateway.publicHost="mcp.${CLUSTER_DOMAIN}" \
  --include-crds | oc apply -f -

oc get gatewayclass mcp-gateway-class
oc get gateway mcp-gateway -n openshift-ingress
oc get route mcp-gateway -n openshift-ingress
oc get mcpgatewayextension mcp-gateway-ext -n mcp-gateway-system
```

> **Only safe if every backend MCP server enforces its own JWT/RBAC independently** (e.g. a
> per-pod Envoy sidecar) — with no issuer set, the gateway itself performs no authentication or
> authorization at all.

**If OIDC is enforced for the default tenant** (question 2's answer was yes): set `oidc.issuer`
— that alone is sufficient:

```bash
helm template gitops/instance/mcp-gateway --name-template mcp-gateway \
  --set gateway.publicHost="mcp.${CLUSTER_DOMAIN}" \
  --set oidc.issuer="https://<keycloak-host>/realms/<realm>" \
  --include-crds | oc apply -f -

oc get gatewayclass mcp-gateway-class
oc get gateway mcp-gateway -n openshift-ingress
oc get route mcp-gateway -n openshift-ingress
oc get mcpgatewayextension mcp-gateway-ext -n mcp-gateway-system
oc get authpolicy mcp-gateway-authn mcp-gateway-authz -n openshift-ingress
```

> **Human gate:** `Gateway` reports `Programmed: True`, the `Route` resolves (a bare `curl -k
> https://mcp.${CLUSTER_DOMAIN}` should reach the gateway, not a router 503), and both `AuthPolicy`
> objects show `Enforced: True`.

Either way, these object names (`mcp-gateway-authn`, `mcp-gateway-authz`, `mcp-gateway-ext`,
`Route` `mcp-gateway`) are identical to a plain single-tenant deployment of the original chart this
was generalized from — if you're pointing this chart at a cluster that already has one of those
deployed with OIDC enforced, `helm upgrade` onto the existing release with `oidc.issuer` set
reproduces it exactly, it does not rename anything.

### Step 3 — Confirm the GatewayClass private-host workaround applied

**Confirmed upstream bug on OpenShift, Tech Preview operator:** the broker's own private-host
assumption is hardcoded the Istio way (`<gateway-name>-istio.<namespace>.svc.cluster.local`), but
OpenShift's Gateway API controller names the Service `<gateway-name>-<gatewayclass-name>`. Without
the chart's `broker-private-host-alias.yaml` workaround, `tools/list` still succeeds (the broker
answers from its own cache) but every tool **invocation** fails with `dial tcp: lookup
mcp-gateway-istio... no such host` — a confusing, delayed failure since discovery looks fine.

```bash
oc get service mcp-gateway-istio -n openshift-ingress -o jsonpath='{.spec.externalName}'
# expect: mcp-gateway-mcp-gateway-class.openshift-ingress.svc.cluster.local
```

Drop this workaround once the operator derives the private host from the `GatewayClass` itself
(or exposes it as a setting) — not the case as of the `0.7.x` Tech Preview channel.

### Step 4 — Adding a tenant

Each extra tenant needs three required fields: `name`, `publicHost`, and `extensionNamespace`.
`oidcIssuer` is optional, same on/off-switch behavior as the default tenant's `oidc.issuer` — leave
it unset for a tenant with no gateway-level auth, set it to enable OIDC for that tenant (and then
also set `port` — see the gotcha on why), no separate flag either way.

**`extensionNamespace` has no default and must be unique across every tenant, default included** —
the MCP Gateway Operator allows only one `MCPGatewayExtension` per *namespace* (confirmed live, see
the gotcha on why `mcp-gateway-system`, the default tenant's own extension namespace, can never be
reused). A matching `ReferenceGrant` entry is created automatically; nothing to apply by hand.

**Never use `--set` for anything under `extraTenants`** — confirmed live: `--set
extraTenants[0].x=y` replaces the *entire* list item, not just the field given, silently dropping
even `name`. The result still applies without error, but produces mangled objects
(`mcp-gateway-authn-`, `sectionName: -mcp`) that fail in ways that look like a routing problem, not
a config mistake. Always render from a values file, and keep the default tenant's own fields in
the same file so they aren't reset to their chart defaults — carry `gateway.publicHost` forward
always, and `oidc.issuer` too if the default tenant has OIDC enforced:

```yaml
# owl-tenant-values.yaml
gateway:
  publicHost: mcp.apps.ocp.example.com
oidc:
  issuer: https://keycloak.apps.ocp.example.com/realms/openshell   # omit this line entirely if the default tenant has no OIDC enforced

extraTenants:
  - name: owl
    publicHost: owl-mcp.apps.ocp.example.com
    extensionNamespace: mcp-gateway-owl   # must differ from mcp-gateway-system
    oidcIssuer: https://keycloak.apps.ocp.example.com/realms/owl
    port: 8081   # required because oidcIssuer is set
```

```bash
oc create namespace mcp-gateway-owl   # the chart doesn't create it — same as mcp-gateway-system wasn't chart-created either

helm template gitops/instance/mcp-gateway --name-template mcp-gateway \
  -f owl-tenant-values.yaml --include-crds | oc apply -f -

# only the NEW tenant's objects appear — nothing default-tenant-named changes
oc get gateway mcp-gateway -n openshift-ingress -o jsonpath='{.spec.listeners[*].name}'
oc get route mcp-gateway-owl -n openshift-ingress
oc get mcpgatewayextension mcp-gateway-ext-owl -n mcp-gateway-owl
oc get authpolicy mcp-gateway-authn-owl mcp-gateway-authz-owl -n openshift-ingress
oc get referencegrant allow-mcp-gateway-ext -n openshift-ingress -o jsonpath='{.spec.from[*].namespace}'
# expect: mcp-gateway-owl mcp-gateway-system
```

> **Human gate:** `spec.listeners` on the `Gateway` now lists four entries
> (`mcp`, `mcps`, `owl-mcp`, `owl-mcps`); the default tenant's own
> `Route`/`MCPGatewayExtension`/`AuthPolicy` objects (`mcp-gateway`, `mcp-gateway-ext`,
> `mcp-gateway-authn`/`mcp-gateway-authz`) are untouched (compare `resourceVersion` before/after if
> in doubt).

> **If adding a second extra tenant later**, list every existing `extraTenants` entry you want kept
> in the values file, not just the new one — an `extraTenants:` list from `-f` replaces the
> previous release's whole list, it is not merged by name. The default tenant's own fields are
> unaffected by this either way, since they're not part of the list.

A tenant's actual MCP servers (the `HTTPRoute`s and `MCPServerRegistration`s that back specific
tools) are **not** created by this chart — they belong to whichever project owns those servers,
targeting `sectionName: <tenant>-mcps` on this same `Gateway` and registering into the tenant's
`extensionNamespace`. See that project's own chart/docs for how it wires up its servers' Keycloak
clients (named `<extensionNamespace>/<server-name>`, with `tool:<toolname>` client roles) against
this tenant's realm.

### Step 5 — Smoke test

```bash
TOKEN=$(curl -sk -X POST "https://<keycloak-host>/realms/<realm>/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=<client>&username=<user>&password=<pass>" | jq -r .access_token)

# Discovery (expected: 200, tool list)
curl -sk "https://mcp.${CLUSTER_DOMAIN}/mcp" -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'

# No token (expected: 401, WWW-Authenticate: Bearer resource_metadata=...)
curl -sk -i "https://mcp.${CLUSTER_DOMAIN}/mcp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

**Human gate:** an authenticated `tools/list` returns 200 with a tool catalog; an unauthenticated
request returns 401 with the `WWW-Authenticate` discovery header. If a second tenant was added in
Step 4, repeat against its own hostname and realm token, and confirm a token minted for one
tenant's realm is rejected against the other tenant's hostname (cross-tenant isolation).

---

## Known gotchas

- **`oidc.issuer` only makes authentication provider-agnostic by itself — authorization defaults to
  Keycloak's claim shape, but is overridable per tenant.** The default CEL (`auth.toolAccessPredicate`/
  `promptAccessPredicate`, and the `extraTenants[].auth.*` equivalents) checks
  `resource_access.<servername>.roles`, a Keycloak-specific JWT claim, not a generic OIDC one —
  confirmed this is also how Kuadrant's own upstream MCP Gateway docs do it (no IdP-agnostic
  alternative documented there either; see the Architecture section above for citations). A
  non-Keycloak issuer authenticates fine and then silently authorizes nothing (403 on every tool
  call) *unless* `toolAccessPredicate`/`promptAccessPredicate` are overridden for that tenant to
  match its provider's actual claim shape — see the worked `contoso` example above. No chart
  changes needed; these are plain values.
- **No separate `auth.enabled`/`extraTenants[].auth.enabled` boolean, by design.** OIDC enforcement
  is derived purely from whether `oidc.issuer` (default tenant) or `extraTenants[].oidcIssuer`
  is non-empty. An earlier version of this chart had both an issuer field and a separate on/off
  flag — which meant setting an issuer without also flipping the flag silently left a tenant
  unauthenticated, no error. Collapsing to one field removes that failure mode entirely: there is
  nothing to forget to pair with the issuer.
- **Two separate OLM packages, easy to miss the second one.** `rhcl-operator` (Phase 3) does not
  bring in the `mcp-gateway` (MCP Gateway Operator) package — confirmed live: a cluster with only
  the former installed has no `MCPGatewayExtension`/`MCPServerRegistration` CRDs at all.
- **`--set extraTenants[N].x=y` replaces the whole list item, including `name`.** Confirmed live:
  `--set extraTenants[0].publicHost=... --set extraTenants[0].oidcIssuer=...` alone produces a
  tenant with no `name` at all — objects render as `mcp-gateway-authn-`, listeners as
  `-mcp`/`-mcps`, with no error from `helm template`. Always use `-f <file>.yaml` for
  `extraTenants`, never `--set`. Separately: an `extraTenants:` list passed via `-f` replaces the
  *previous release's* whole list too — it is not merged by name, so every extra tenant you want to
  keep must be listed every time. The default tenant's own fields (`gateway.publicHost`,
  `oidc.issuer`) are plain scalars, not part of any list, so `--set` is safe for them and they
  are never affected by what's in `extraTenants`.
- **The MCP Gateway Operator allows only one `MCPGatewayExtension` per NAMESPACE, not per Gateway
  — confirmed live, and the install guide is internally inconsistent about it.** One section states
  flatly "Each Gateway object can have only one `MCPGatewayExtension` CR"; a later section
  describes the valid working pattern as "team-specific `MCPGatewayExtension` CRs in individual
  namespaces that all target a shared Gateway object." The second is correct — the actual live
  error is `conflict: namespace <ns> already has MCPGatewayExtension <name> (only one per namespace
  allowed)`, a namespace conflict, not a Gateway one. Every tenant (default included) needs a
  distinct `extensionNamespace`; the chart fails fast on a collision rather than producing a
  silently non-functional `MCPGatewayExtension` (`Ready: False`, no admission-time error).
- **A `ReferenceGrant` is required whenever an extension's namespace differs from the Gateway's**
  (true for the default tenant out of the box: `mcp-gateway-system` vs. `openshift-ingress`) — the
  install guide's own prerequisite, confirmed live: without it the extension sits at `Ready: False,
  Reason: ReferenceGrantRequired` indefinitely. This chart creates one automatically
  (`templates/referencegrant.yaml`), covering every tenant's `extensionNamespace`.
- **Both listeners in a tenant's pair must share `gateway.port`.** The gateway's `ext_proc`
  rewrites `:authority` and re-evaluates routing between `<tenant>-mcp` and `<tenant>-mcps` after
  parsing the JSON-RPC body — different ports break that hand-off silently.
- **A tenant's external hostname needs its own `Route`.** The Gateway's Service is deliberately
  `ClusterIP` (see `configmap-override.yaml`) — a hostname with no matching `Route` resolves to a
  bare `HTTP/1.0 503` from the OpenShift router, easily mistaken for a broken `Gateway`/`HTTPRoute`
  when both are in fact `Ready`.
- **The `<gateway-name>-istio` private-host alias is required on OpenShift**, any `className`
  other than `istio`. Without it, tool discovery works but every tool *invocation* fails with a
  DNS lookup error, since the broker dials itself back through a Service name OpenShift's own
  Gateway API controller never creates.
- **Kuadrant allows only one `AuthPolicy` per `(targetRef, sectionName)`.** This is exactly why
  each tenant needs its own `sectionName`s (`<tenant>-mcp`/`<tenant>-mcps`) — two tenants cannot
  share a `sectionName` and each bring their own `AuthPolicy`.
- **`httpRouteManagement` on a live `MCPGatewayExtension` defaults to `Enabled`** (an operator
  default, not set by this chart) — **[VERIFY]** whether this means the operator auto-manages
  `HTTPRoute`s for servers registered under an extension, which could make a hand-authored
  `HTTPRoute` (as used by whichever project registers MCP servers against a tenant) redundant or
  conflicting. Check `oc explain mcpgatewayextension.spec.httpRouteManagement` and the upstream
  install guide before assuming both are needed together.
- **Technology Preview** — the `mcp-gateway` operator (0.7.x) is not covered by production SLAs
  and has its own versioning scheme, unrelated to RHCL's 1.4.x.

**End of Phase 8:** Stop here and report: the default tenant's `Gateway`/`Route`/
`MCPGatewayExtension`/`AuthPolicy` status, the smoke test results (200 with a token, 401 without),
and — if any further tenants were added — each tenant's own smoke test plus the cross-tenant
isolation check.
