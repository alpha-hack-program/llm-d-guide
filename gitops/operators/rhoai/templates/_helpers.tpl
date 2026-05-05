{{- define "rhoai-operator.subscriptionChannel" -}}
{{- if .Values.channel -}}
{{- .Values.channel -}}
{{- else -}}
{{- $p := index .Values.presets .Values.olmProfile -}}
{{- if not $p -}}
{{- fail (printf "unknown olmProfile %q — use stable or ea" .Values.olmProfile) -}}
{{- end -}}
{{- index $p "channel" -}}
{{- end -}}
{{- end -}}

{{- define "rhoai-operator.subscriptionStartingCSV" -}}
{{- if .Values.startingCSV -}}
{{- .Values.startingCSV -}}
{{- else -}}
{{- $p := index .Values.presets .Values.olmProfile -}}
{{- if not $p -}}
{{- fail (printf "unknown olmProfile %q — use stable or ea" .Values.olmProfile) -}}
{{- end -}}
{{- index $p "startingCSV" -}}
{{- end -}}
{{- end -}}

{{- define "rhoai-operator.validateOverrides" -}}
{{- if or .Values.channel .Values.startingCSV -}}
{{- if not (and .Values.channel .Values.startingCSV) -}}
{{- fail "channel and startingCSV must both be set when overriding the preset, or leave both empty" -}}
{{- end -}}
{{- end -}}
{{- end -}}
