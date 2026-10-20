{{- define "mcp-gateway.allowedRoutes" -}}
namespaces:
  from: Selector
  selector:
    matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: In
        values:
          {{- range .Values.gateway.allowedNamespaces }}
          - {{ . }}
          {{- end }}
{{- end -}}

{{/*
Fills in every optional field an extraTenants[] entry can omit. Values' own
list merging does NOT deep-merge per-field (an extraTenants override in a -f
file replaces the whole list item), so a minimal tenant entry — just name,
publicHost — would otherwise nil-pointer on fields like
auth.tokenExchange.enabled. Call as:
  {{- $tenant := include "mcp-gateway.extraTenant" (dict "tenant" $t "root" $root) | fromYaml }}
(`root` is the top-level `.` — needed here because the tool/prompt access
predicate defaults fall back to the top-level auth.toolAccessPredicate/
promptAccessPredicate, so there's exactly one place to change the default
CEL for every tenant that doesn't override it.)

Does NOT apply to the default tenant (gateway.publicHost/oidc.issuer/
auth.*), which uses plain top-level scalar fields instead, specifically so
it is never exposed to this list-merge footgun.

There is no `auth.enabled` field, by design: whether OIDC is enforced for a
tenant is derived entirely from whether its oidcIssuer is set (empty =
disabled, set = enabled) — see values.yaml's comment on oidc.issuer for why
a separate boolean was dropped, and for the Keycloak-specific-authz caveat
that applies regardless of which OIDC issuer is configured. A tenant on a
different OIDC provider overrides auth.toolAccessPredicate/
promptAccessPredicate (see values.yaml's extraTenants example) to match
that provider's claim shape instead of Keycloak's.
*/}}
{{- define "mcp-gateway.extraTenant" -}}
{{- /*
extensionNamespace has NO default (unlike the chart's other namespace
fields) — see gateway.yaml/mcpgatewayextension.yaml/referencegrant.yaml's
`required` checks. Defaulting it to mcp-gateway-system (the default
tenant's own extension namespace) would guarantee a collision, since the
MCP Gateway Operator allows only one MCPGatewayExtension per namespace.
*/}}
{{- $defaults := dict "enabled" true "extensionNamespace" "" "oidcIssuer" "" "port" "" "auth" (dict "toolAccessPredicate" .root.Values.auth.toolAccessPredicate "promptAccessPredicate" .root.Values.auth.promptAccessPredicate "tokenExchange" (dict "enabled" false "cacheTtlSeconds" 300 "credentialSecretName" "" "credentialSecretKey" "") "filterToolList" (dict "enabled" false "privateKeySecretName" "" "publicKeySecretName" "" "capabilitiesRego" .root.Values.auth.filterToolList.capabilitiesRego)) -}}
{{- mergeOverwrite $defaults .tenant | toYaml -}}
{{- end -}}

{{/*
True if the default tenant OR at least one enabled extra tenant has OIDC
enforcement on (a non-empty issuer) — used to gate the gateway-wide
EnvoyFilter, which only needs to exist if something actually terminates
auth at the gateway layer.
*/}}
{{- define "mcp-gateway.anyAuthEnabled" -}}
{{- $root := . -}}
{{- $any := ne .Values.oidc.issuer "" -}}
{{- range $t := .Values.extraTenants -}}
{{- $tenant := include "mcp-gateway.extraTenant" (dict "tenant" $t "root" $root) | fromYaml -}}
{{- if and $tenant.enabled (ne $tenant.oidcIssuer "") -}}
{{- $any = true -}}
{{- end -}}
{{- end -}}
{{- $any -}}
{{- end -}}
