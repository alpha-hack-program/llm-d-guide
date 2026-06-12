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
{{- $storageType := .Values.storage.type | default "hf" }}
{{- if and (ne $storageType "hf") (ne $storageType "oci") }}
{{- fail (printf "values.storage.type must be one of hf, oci, got %q" $storageType) }}
{{- end }}
{{- end }}

{{/*
Build vLLM arguments from structured configuration.
Auto-adds --enable-prefix-caching for intelligent-inference when vllm.prefixCaching.enabled is "auto" (default).
User extraArgs are appended after framework-managed flags.
*/}}
{{- define "inference.vllmArgs" -}}
{{- $args := list -}}
{{- /* Determine if prefix caching should be enabled */ -}}
{{- $shouldEnablePrefixCaching := false -}}
{{- $mode := "auto" -}}
{{- if and .Values.vllm (hasKey .Values.vllm "prefixCaching") (hasKey .Values.vllm.prefixCaching "enabled") -}}
{{- $mode = .Values.vllm.prefixCaching.enabled -}}
{{- end -}}
{{- /* Handle mode: true (boolean or string), false (boolean or string), auto (string) */ -}}
{{- if kindIs "bool" $mode -}}
{{- $shouldEnablePrefixCaching = $mode -}}
{{- else if eq $mode "auto" -}}
{{- if eq .Values.deploymentType "intelligent-inference" -}}
{{- $shouldEnablePrefixCaching = true -}}
{{- end -}}
{{- end -}}
{{- /* Add prefix caching flag */ -}}
{{- if $shouldEnablePrefixCaching -}}
{{- $args = append $args "--enable-prefix-caching" -}}
{{- end -}}
{{- /* Append user extra args */ -}}
{{- if and .Values.vllm .Values.vllm.extraArgs -}}
{{- range .Values.vllm.extraArgs -}}
{{- $args = append $args . -}}
{{- end -}}
{{- end -}}
{{- join " " $args -}}
{{- end -}}
