# MCP Gateway (shared RHCL/Kuadrant)

One cluster-scoped `Gateway` object, shared by any number of isolated tenants, giving external MCP
clients (agents, IDEs, sandboxes) OIDC-authenticated HTTP access to MCP tool servers. Deploy once;
add tenants over time without touching anything already deployed.

Full phase-by-phase walkthrough (operator install, verification commands, smoke tests, human
gates): [`docs/phases/08-mcp-gateway.md`](../../../docs/phases/08-mcp-gateway.md). This README is
the chart reference — what each value does and why, not a step-by-step guide.

## Prerequisites

Two **separate** OLM packages, both already installed on the cluster — this chart only creates CRs
their CRDs define, never the operators themselves:

| Package | Channel | Provides | Install |
|---|---|---|---|
| `rhcl-operator` | `stable`, 1.4.1+ | RHCL/Kuadrant core — Authorino, Limitador | [`gitops/operators/connectivity-link`](../../operators/connectivity-link) |
| `mcp-gateway` | `preview`, 0.7.x | `MCPGatewayExtension`/`MCPServerRegistration` CRDs | [`gitops/operators/mcp-gateway-operator`](../../operators/mcp-gateway-operator) |

These are easy to conflate because of the similar name — a cluster with only `rhcl-operator`
installed has neither CRD, and `helm template | oc apply` fails with `no matches for kind
"MCPGatewayExtension"`, which reads like an RHCL version problem but isn't. 1.4.0 has known
auth-failure/memory-pressure issues; 1.4.1+ is required.

## Quick start

Deploy just the default tenant, no OIDC:

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
helm template . --name-template mcp-gateway \
  --set gateway.publicHost="mcp.${CLUSTER_DOMAIN}" \
  --include-crds | oc apply -f -
```

With OIDC enforced — `oidc.issuer` is the only switch, no separate enable flag:

```bash
helm template . --name-template mcp-gateway \
  --set gateway.publicHost="mcp.${CLUSTER_DOMAIN}" \
  --set oidc.issuer="https://<idp-host>/realms/<realm>" \
  --include-crds | oc apply -f -
```

Both forms use `--set` safely — the default tenant's fields are plain top-level scalars, not list
items.

## The default tenant vs. `extraTenants`

The **default tenant** (`gateway.publicHost` / `oidc.issuer` / `auth.*`) always exists and uses the
exact same flat field shape as the original single-tenant chart this was generalized from — on
purpose, so it matches upstream's own documented `values.yaml` and reproduces an already-deployed
single-tenant release's object names exactly (`mcp-gateway-authn`, `mcp-gateway-authz`,
`mcp-gateway-ext`, `Route` `mcp-gateway`). It's never a list item, so it's never exposed to Helm's
list-merge-replaces-the-whole-item behavior.

Every tenant beyond the default is **additive**, via `extraTenants`. Each entry requires only
`name` and `publicHost` (Helm `required` fails fast otherwise) and gets, independently:

- a `Gateway` listener `<tenant>-mcp` (external, has a hostname), its own `Route`, its own
  `MCPGatewayExtension` — always.
- if `oidcIssuer` is also set: a second listener `<tenant>-mcps` (internal, post-routing,
  authn+authz) and its own `AuthPolicy` pair, trusting only that tenant's issuer.

Adding an `extraTenants` entry and re-running `helm upgrade` only appends new objects — it never
edits the default tenant's objects or another extra tenant's.

```yaml
# owl-tenant-values.yaml
gateway:
  publicHost: mcp.apps.ocp.example.com
oidc:
  issuer: https://keycloak.apps.ocp.example.com/realms/openshell   # omit if default tenant has no OIDC

extraTenants:
  - name: owl
    publicHost: owl-mcp.apps.ocp.example.com
    oidcIssuer: https://keycloak.apps.ocp.example.com/realms/owl
```

```bash
helm template . --name-template mcp-gateway -f owl-tenant-values.yaml --include-crds | oc apply -f -
```

**Never use `--set` for anything under `extraTenants`** — confirmed live: `--set
extraTenants[0].x=y` replaces the *entire* list item, silently dropping even `name` (objects render
as `mcp-gateway-authn-`, listeners as `-mcp`/`-mcps`, no error). Always use `-f <file>.yaml`, and
list every tenant you want kept — the list from `-f` replaces the previous release's whole list,
it's not merged by name.

## OIDC: authentication is generic, authorization defaults to Keycloak

`oidc.issuer`/`oidcIssuer` is genuinely provider-agnostic for **authentication** — issuer-URL JWT
validation and `.well-known/openid-configuration` discovery are standard OIDC, any compliant
provider works.

**Authorization is not generic by default.** The authz `AuthPolicy`'s CEL
(`auth.toolAccessPredicate`/`promptAccessPredicate`, and the `extraTenants[].auth.*` equivalents)
defaults to checking `resource_access.<servername>.roles` — Keycloak's own JWT claim shape for
per-client roles, not a generic OIDC/JWT claim. This matches Kuadrant's own upstream MCP Gateway
docs — confirmed against
[docs.kuadrant.io/dev/mcp-gateway's "User-Based Tool Filtering" guide](https://docs.kuadrant.io/dev/mcp-gateway/docs/guides/user-based-tool-filter/)
and [github.com/Kuadrant/mcp-gateway's `authorization.md`](https://github.com/Kuadrant/mcp-gateway/blob/main/docs/guides/authorization.md):
both present the AuthPolicy/Authorino policy engine as portable across identity providers, but
every worked authorization example hardcodes `resource_access`, with no documented adaptation path
for other providers (Okta, Auth0, Entra ID, ...).

Pointing a tenant at a non-Keycloak issuer makes authentication work fine; authorization silently
fails closed (every tool call gets 403, not an error) unless that provider emits a matching claim —
**or** `toolAccessPredicate`/`promptAccessPredicate` are overridden for that tenant. These are raw
CEL strings Authorino evaluates as-is; nothing else in the chart parses or depends on their shape,
so a structurally different expression (not just a different claim *path*) is fully supported:

```yaml
extraTenants:
  - name: contoso
    publicHost: contoso-mcp.apps.ocp.example.com
    oidcIssuer: https://login.contoso-idp.example.com/v2
    auth:
      # This provider puts flat "tool:<name>" strings directly in a `groups`
      # claim, with no per-server nesting at all — unlike Keycloak's shape.
      toolAccessPredicate: |-
        ('tool:' + request.headers['x-mcp-toolname']) in auth.identity.groups
      promptAccessPredicate: |-
        ('prompt:' + request.headers['x-mcp-promptname']) in auth.identity.groups
```

Verified by rendering this exact override: the resulting `AuthPolicy` carries the custom CEL
unchanged, with no Keycloak-specific scaffolding left over, alongside other tenants that still use
the default `resource_access` CEL. An invalid CEL expression is rejected by Authorino at apply time
(that `AuthPolicy`'s `Enforced` condition goes `False`), not silently.

Available at CEL evaluation time: `auth.identity` (the decoded token claims) and the headers the
gateway's `ext_proc` sets — `request.headers['x-mcp-servername']`,
`request.headers['x-mcp-toolname']`, `request.headers['x-mcp-promptname']`.

## No separate `auth.enabled` boolean, by design

OIDC enforcement is derived purely from whether an issuer is non-empty — not a separate flag. An
earlier version of this chart had both an issuer field and an `auth.enabled` boolean, which meant
setting an issuer without also flipping the flag silently left a tenant unauthenticated, no error.
One field, one meaning: empty = disabled, set = enabled, nothing to forget to pair with it.

## Values reference

| Key | Default | Required? | Notes |
|---|---|---|---|
| `gateway.name` | `mcp-gateway` | | `Gateway`/`Route`/Service name base. |
| `gateway.namespace` | `openshift-ingress` | | Where the `Gateway` object lives. |
| `gateway.className` | `mcp-gateway-class` | | OpenShift's own Gateway API controller, not RHCL-specific. |
| `gateway.port` | `8080` | | Shared by every tenant's listener pair — required for `ext_proc`'s `:authority` rewrite between a tenant's `-mcp`/`-mcps` listeners. Never give a tenant a different port. |
| `gateway.publicHost` | `""` | **yes** | Default tenant's external hostname, e.g. `mcp.apps.<cluster-domain>`. |
| `gateway.allowedNamespaces` | `[openshift-ingress, mcp-gateway-system]` | | Must include `extension.namespace` and every `extraTenants[].extensionNamespace`. |
| `extension.name` / `.namespace` | `mcp-gateway-ext` / `mcp-gateway-system` | | Default tenant's `MCPGatewayExtension` name/namespace. |
| `oidc.issuer` | `""` | | Default tenant's OIDC issuer URL. Empty disables OIDC for the default tenant entirely — the on/off switch, see above. |
| `auth.authorinoNamespace` / `.authorinoService` | `kuadrant-system` / `authorino-authorino-authorization` | | Where Kuadrant's own generated `EnvoyFilter` reaches Authorino's gRPC check (it omits TLS by default; this chart patches that in). |
| `auth.toolAccessPredicate` / `.promptAccessPredicate` | Keycloak `resource_access` CEL | | Default tenant's authz CEL — see OIDC section above. |
| `auth.tokenExchange.*` | disabled | | RFC 8693 token exchange, Keycloak-specific, Tech Preview path — see inline `values.yaml` comment for the Keycloak-side setup it requires. |
| `extraTenants` | `[]` | | See "The default tenant vs. `extraTenants`" above. Each entry: `name`/`publicHost` required, `oidcIssuer` optional, `enabled`/`extensionNamespace`/`auth.*` default the same way the top-level fields do. |

## Known gotchas

Full list with context: [`docs/phases/08-mcp-gateway.md`](../../../docs/phases/08-mcp-gateway.md#known-gotchas).
The highlights:

- **Two separate OLM packages** — see Prerequisites above.
- **`--set` on `extraTenants[N]` silently drops `name`** — see "The default tenant vs.
  `extraTenants`" above.
- **Authorization defaults to Keycloak's claim shape, not generic OIDC** — see the OIDC section
  above; overridable per tenant, no template edits needed.
- **The `<gateway-name>-istio` `ExternalName` alias is required on OpenShift** (any `className`
  other than `istio`) — a Tech Preview operator bug where the broker dials itself back through a
  Service name OpenShift's own Gateway API controller never creates. Without it, tool discovery
  works but every tool *invocation* fails with a DNS lookup error.
- **A tenant's hostname needs its own `Route`** — the Gateway's Service is deliberately
  `ClusterIP`; a hostname with no matching `Route` gets a bare `HTTP/1.0 503` from the OpenShift
  router, easy to mistake for a broken `Gateway`/`HTTPRoute`.
- **Kuadrant allows only one `AuthPolicy` per `(targetRef, sectionName)`** — exactly why each
  tenant needs its own `sectionName`s.
- **`httpRouteManagement` on a live `MCPGatewayExtension` defaults to `Enabled`** (operator
  default, not set by this chart) — unverified whether this makes a hand-authored `HTTPRoute`
  (created by whichever project registers MCP servers against a tenant) redundant or conflicting.
  Check `oc explain mcpgatewayextension.spec.httpRouteManagement` before assuming both are needed
  together.
- **Technology Preview** — the `mcp-gateway` operator (0.7.x) is not covered by production SLAs.
