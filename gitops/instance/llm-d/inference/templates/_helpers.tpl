{{/*
Validate deploymentType. Fails render if not one of the allowed values.
*/}}
{{- define "inference.validateDeploymentType" -}}
{{- if and (ne .Values.deploymentType "intelligent-inference") (ne .Values.deploymentType "pd-disaggregation") }}
{{- fail (printf "deploymentType must be one of intelligent-inference, pd-disaggregation, got %q" .Values.deploymentType) }}
{{- end }}
{{- end }}

{{/*
Validate storage: must be set, have uri, and type must be hf or oci.
*/}}
{{- define "inference.validateStorageType" -}}
{{- if not .Values.storage }}
{{- fail "values.storage is required" }}
{{- end }}
{{- if not .Values.storage.uri }}
{{- fail "values.storage.uri is required" }}
{{- end }}
{{- if and (ne .Values.storage.type "hf") (ne .Values.storage.type "oci") }}
{{- fail (printf "values.storage.type must be one of hf, oci, got %q" .Values.storage.type) }}
{{- end }}
{{- end }}
