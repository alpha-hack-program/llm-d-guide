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

Every tenant beyond the default is **additive**, via `extraTenants`. Each entry requires `name`,
`publicHost`, and `extensionNamespace` (Helm `required` fails fast otherwise) and gets,
independently:

- a `Gateway` listener `<tenant>-mcp` (external, has a hostname), its own `Route`, its own
  `MCPGatewayExtension` in its own `extensionNamespace` — always. A matching `ReferenceGrant` entry
  is added automatically — see "Per-tenant extension namespaces" below for why this field has no
  default and must be unique.
- if `oidcIssuer` is also set: a second listener `<tenant>-mcps` (internal, post-routing,
  authn+authz) and its own `AuthPolicy` pair, trusting only that tenant's issuer. This tenant must
  also set its own `port`, distinct from `gateway.port` and every other OIDC-enabled tenant's port
  — see "Per-tenant ports" below.

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
    extensionNamespace: mcp-gateway-owl   # must differ from mcp-gateway-system (the default tenant's)
    oidcIssuer: https://keycloak.apps.ocp.example.com/realms/owl
    port: 8081   # required because oidcIssuer is set — see "Per-tenant ports" below
```

```bash
helm template . --name-template mcp-gateway -f owl-tenant-values.yaml --include-crds | oc apply -f -
```

**Never use `--set` for anything under `extraTenants`** — confirmed live: `--set
extraTenants[0].x=y` replaces the *entire* list item, silently dropping even `name` (objects render
as `mcp-gateway-authn-`, listeners as `-mcp`/`-mcps`, no error). Always use `-f <file>.yaml`, and
list every tenant you want kept — the list from `-f` replaces the previous release's whole list,
it's not merged by name.

## Per-tenant ports

Every tenant's two-listener pair shares one port (required for `ext_proc`'s `:authority` rewrite
between `<tenant>-mcp` and `<tenant>-mcps`) — but that port must also be **unique across every
OIDC-enabled tenant**, default included. The `-mcps` listener has no hostname, so Gateway API's
`port`+`protocol`+`hostname` uniqueness rule collapses to "port must be unique" across that whole
set; two OIDC-enabled tenants on the same port make the entire `Gateway` object invalid
(`spec.listeners: Invalid value: Combination of port, protocol and hostname must be unique for each
listener`) — confirmed live, and the failure gives no hint which tenant caused it.

- The default tenant always uses `gateway.port` (`8080`).
- Every `extraTenants[]` entry with `oidcIssuer` set **must** also set its own `port` — the chart's
  `required` check fails fast, naming the tenant, if it's missing; a second `fail` check catches a
  collision with the default tenant's or another tenant's port before it ever reaches the Gateway
  API server.
- A tenant with no `oidcIssuer` doesn't need `port` at all — it only gets the external `-mcp`
  listener, disambiguated by `hostname`, which has no such constraint.

## Per-tenant extension namespaces

The MCP Gateway Operator allows only **one `MCPGatewayExtension` per namespace** — confirmed live,
not just from the (internally inconsistent) install guide: a second extension in an
already-claimed namespace sits at `Ready: False` with
`conflict: namespace <ns> already has MCPGatewayExtension <name> (only one per namespace allowed)`.
It does *not* care about the target `Gateway` or `sectionName` — the conflict is purely
namespace-scoped, which is also why multiple tenants *can* safely share one `Gateway` object as
long as each has its own namespace for its extension.

Because of this, `extensionNamespace` has **no default** on `extraTenants[]` entries (unlike this
chart's other namespace fields) — defaulting it to `mcp-gateway-system` would guarantee a collision
with the default tenant's own extension, which lives there. Every enabled tenant (default included)
needs a distinct `extensionNamespace`; the chart fails fast on a missing value or a collision,
naming the two tenants involved, rather than letting it surface as a confusing live `Ready: False`.

Whenever an extension's namespace differs from `gateway.namespace` (true by default, since the
default tenant's own `mcp-gateway-ext` already lives in `mcp-gateway-system` while the `Gateway`
lives in `openshift-ingress`), a `ReferenceGrant` is required or the extension sits at `Ready:
False, Reason: ReferenceGrantRequired` indefinitely. This chart creates one automatically
(`templates/referencegrant.yaml`), with one `from` entry per unique tenant `extensionNamespace` —
nothing to apply by hand, unlike the original single-tenant chart this was generalized from, which
required it as a separate, manually-applied resource for its first several revisions.

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

## Filtering `tools/list`/`discover_tools` by authorization

`auth.toolAccessPredicate`/`promptAccessPredicate` (and their `extraTenants[]` equivalents) gate
`tools/call`/`prompts/call` — they do **not** affect what `tools/list` or the broker's own
`discover_tools` meta-tool show. Confirmed live: with only those predicates configured, every
authenticated caller sees the full tool catalog of every registered server regardless of role; the
per-tool CEL check only runs once a call is actually attempted. `ext_proc` never routes a `tools/list`
request to the `-mcps` listener at all — there's no tool name or server name in that request for the
CEL to check against.

Filtering discovery itself needs a second, independent mechanism: a signed `x-mcp-authorized` header,
computed on the `mcp` listener (the authn-only one `tools/list` actually lands on) and verified by the
broker via `MCPGatewayExtension.spec.trustedHeadersKey`. This is RHCL's own documented mechanism
(install guide §6.3, "Filter revoked tools and prompts from display"; also assumed by `MCPVirtualServer`
curation, which filters on top of whatever this header already allows). Off by default — enable per
tenant with `auth.filterToolList.enabled: true` (and the `extraTenants[].auth.filterToolList`
equivalent).

This chart does not generate the signing keypair — Helm has no function to derive an EC public key
from a private key, and the two halves must live in different namespaces (below). Create them once per
tenant, **exactly like this** — every deviation below was tried live and failed with a different,
unhelpful error:

```bash
# Plain SEC1 output of ecparam, NOT converted to PKCS8 — Authorino's wristband
# signer rejects a PKCS8-wrapped EC key with "Invalid signing key algorithm"
# even though the key itself is valid. No official doc mentions this; found
# by trial.
openssl ecparam -name prime256v1 -genkey -noout -out private-key.pem
openssl ec -in private-key.pem -pubout -out public-key.pem

# Private half: data key MUST be named "key.pem" (confirmed from the AuthConfig
# CRD's own field description) — "key" decodes to the wrong field and fails
# with "failed to decode PEM file", which reads like a format problem but is
# actually just a wrong field name. Lives in auth.authorinoNamespace
# (kuadrant-system) — Authorino only resolves signingKeyRefs against its own
# namespace, same restriction as auth.tokenExchange.credentialSecretName.
# SHARED across every tenant on this Gateway, so the secret name must be
# unique per tenant.
oc create secret generic <privateKeySecretName> \
  --from-file=key.pem=private-key.pem -n kuadrant-system

# Public half: data key MUST be named "key" (per MCPGatewayExtension's own
# TrustedHeadersKey field description — the opposite convention from the
# private half above). Lives in the tenant's own extension namespace
# (already isolated, so the name can be reused across tenants).
oc create secret generic <publicKeySecretName> \
  --from-file=key=public-key.pem -n <extension-namespace>

rm -f private-key.pem public-key.pem
```

Then set, per tenant:

```yaml
auth:
  filterToolList:
    enabled: true
    privateKeySecretName: mcp-gateway-trusted-headers-private-key   # unique across every tenant
    publicKeySecretName: mcp-gateway-trusted-headers-public-key     # namespace already isolates this
```

After applying, the broker (`MCPGatewayExtension`'s deployment) needs to restart once to pick up
`TRUSTED_HEADER_PUBLIC_KEY` — if `oc rollout status` doesn't show a fresh generation on its own,
`oc rollout restart deployment/<gateway-name> -n <tenant-extension-namespace>`.

**The OPA rule needs `allValues: true`, not just `rego`.** Without it, Authorino evaluates the policy
and the request succeeds, but `auth.authorization.authorized-capabilities.capabilities` — the variable
the response's wristband selector reads — is never exposed outside the `allow` boolean, so the signed
header ends up carrying an empty string. The broker then logs `failed to parse x-mcp-authorized header:
failed to unmarshal allowed-capabilities JSON: unexpected end of JSON input` and — because the broker
fails closed on a malformed trusted header rather than falling back to unfiltered — **every** caller
sees an empty tool list, not the unfiltered list. This chart's `authpolicy.yaml` template sets
`allValues: true`; if copying this pattern elsewhere, don't drop it.

`auth.filterToolList.capabilitiesRego` is overridable per tenant for the same reason
`toolAccessPredicate`/`promptAccessPredicate` are — the default assumes Keycloak's `resource_access`
shape with `tool:`/`prompt:`-prefixed roles; a different provider needs different Rego, written against
`input.auth...` (Authorino's OPA integration passes the whole AuthJSON as `input`, unlike the CEL
predicates above which see `auth` directly).

Verified live on sandbox341 against both the default tenant (Keycloak users `alice`/`bob`, `openshell`
realm) and the `owl` extra tenant: each user's `discover_tools` response now lists only the servers and
tools their own `resource_access` roles actually grant, matching what `tools/call` already enforced.

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
| `gateway.port` | `8080` | | Default tenant's own `-mcp`/`-mcps` pair port — required for `ext_proc`'s `:authority` rewrite between them. Every OIDC-enabled `extraTenants[]` entry needs its own distinct port instead — see "Per-tenant ports" below. |
| `gateway.publicHost` | `""` | **yes** | Default tenant's external hostname, e.g. `mcp.apps.<cluster-domain>`. |
| `gateway.allowedNamespaces` | `[openshift-ingress, mcp-gateway-system]` | | Must include `extension.namespace` and every `extraTenants[].extensionNamespace`. |
| `extension.name` / `.namespace` | `mcp-gateway-ext` / `mcp-gateway-system` | | Default tenant's `MCPGatewayExtension` name/namespace. |
| `oidc.issuer` | `""` | | Default tenant's OIDC issuer URL. Empty disables OIDC for the default tenant entirely — the on/off switch, see above. |
| `auth.authorinoNamespace` / `.authorinoService` | `kuadrant-system` / `authorino-authorino-authorization` | | Where Kuadrant's own generated `EnvoyFilter` reaches Authorino's gRPC check (it omits TLS by default; this chart patches that in). |
| `auth.toolAccessPredicate` / `.promptAccessPredicate` | Keycloak `resource_access` CEL | | Default tenant's authz CEL — see OIDC section above. |
| `auth.tokenExchange.*` | disabled | | RFC 8693 token exchange, Keycloak-specific, Tech Preview path — see inline `values.yaml` comment for the Keycloak-side setup it requires. |
| `auth.filterToolList.enabled` | `false` | | Filters `tools/list`/`discover_tools` by the caller's own authorization instead of showing every registered tool — see "Filtering `tools/list` by authorization" above. |
| `auth.filterToolList.privateKeySecretName` / `.publicKeySecretName` | `""` / `""` | **yes, if `filterToolList.enabled`** | Pre-existing ECDSA keypair secrets this chart does not generate — see above for the exact `openssl`/`oc create secret` recipe and the namespaces each half must live in. |
| `auth.filterToolList.capabilitiesRego` | Keycloak `resource_access` Rego | | Default tenant's capability-computation Rego — override together with `toolAccessPredicate`/`promptAccessPredicate` for a non-Keycloak provider. |
| `extraTenants` | `[]` | | See "The default tenant vs. `extraTenants`" above. Each entry: `name`/`publicHost`/`extensionNamespace` required, `oidcIssuer` optional, `port` required only if `oidcIssuer` is set (see "Per-tenant ports"), `enabled`/`auth.*` default the same way the top-level fields do. |

## Known gotchas

Full list with context: [`docs/phases/08-mcp-gateway.md`](../../../docs/phases/08-mcp-gateway.md#known-gotchas).
The highlights:

- **Two separate OLM packages** — see Prerequisites above.
- **`--set` on `extraTenants[N]` silently drops `name`** — see "The default tenant vs.
  `extraTenants`" above.
- **A second OIDC-enabled tenant on the same port makes the whole `Gateway` invalid** — see
  "Per-tenant ports" above; every OIDC-enabled tenant (default included) needs a unique `port`.
- **A second `MCPGatewayExtension` in an already-claimed namespace is silently non-functional**
  (`Ready: False`, no admission rejection) — see "Per-tenant extension namespaces" above; every
  tenant (default included) needs a unique `extensionNamespace`, and the matching `ReferenceGrant`
  is created automatically.
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
