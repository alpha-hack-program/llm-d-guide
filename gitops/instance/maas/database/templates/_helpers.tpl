{{/*
Resolve the database password using a three-tier priority:
  1. db.password from values (explicit — works with ArgoCD)
  2. Existing secret in the cluster (stable across helm upgrades)
  3. Random 24-char string (first install only)
*/}}
{{- define "maas-database.password" -}}
{{- if .Values.db.password -}}
  {{- .Values.db.password -}}
{{- else -}}
  {{- $existing := lookup "v1" "Secret" .Release.Namespace .Values.db.secretName -}}
  {{- if $existing -}}
    {{- index $existing.data "password" | b64dec -}}
  {{- else -}}
    {{- randAlphaNum 24 -}}
  {{- end -}}
{{- end -}}
{{- end -}}

