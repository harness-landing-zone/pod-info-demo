{{/* Chart name for labels */}}
{{- define "podinfo.name" -}}
{{- default "podinfo" .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Release fullname */}}
{{- define "podinfo.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "podinfo" .Values.nameOverride -}}
{{- printf "%s" $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Common labels for everything */}}
{{- define "podinfo.labels" -}}
app.kubernetes.io/name: {{ include "podinfo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* Selector labels — must be stable (do not change across revisions) */}}
{{- define "podinfo.selectorLabels" -}}
app: {{ include "podinfo.name" . }}
{{- end -}}

{{/*
Service names, derived from fullname unless explicitly pinned.

Two releases of this chart in ONE namespace (podinfo + frontend, say) must not
both create a Service called "podinfo". Deriving from fullname means a second
release needs only `nameOverride` - nothing else to keep in sync. Argo Rollouts
also rewrites these Services' selectors during a canary, so a collision here
would hand one service's traffic to the other's pods with nothing erroring.
*/}}
{{- define "podinfo.stableServiceName" -}}
{{- default (include "podinfo.fullname" .) .Values.service.stableName -}}
{{- end -}}

{{- define "podinfo.canaryServiceName" -}}
{{- default (printf "%s-canary" (include "podinfo.fullname" .)) .Values.service.canaryName -}}
{{- end -}}
