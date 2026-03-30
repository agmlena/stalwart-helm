{{/*
Expand the name of the chart.
*/}}
{{- define "stalwart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "stalwart.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "stalwart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "stalwart.labels" -}}
helm.sh/chart: {{ include "stalwart.chart" . }}
{{ include "stalwart.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.stalwart.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "stalwart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "stalwart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name
*/}}
{{- define "stalwart.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "stalwart.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Stalwart image
*/}}
{{- define "stalwart.image" -}}
{{- printf "%s:%s" .Values.stalwart.image.repository (.Values.stalwart.image.tag | default .Chart.AppVersion) }}
{{- end }}

{{/*
Webmail labels
*/}}
{{- define "stalwart.webmail.labels" -}}
{{ include "stalwart.labels" . }}
app.kubernetes.io/component: webmail
{{- end }}

{{- define "stalwart.webmail.selectorLabels" -}}
{{ include "stalwart.selectorLabels" . }}
app.kubernetes.io/component: webmail
{{- end }}

{{/*
ClamAV labels
*/}}
{{- define "stalwart.clamav.labels" -}}
{{ include "stalwart.labels" . }}
app.kubernetes.io/component: clamav
{{- end }}

{{- define "stalwart.clamav.selectorLabels" -}}
{{ include "stalwart.selectorLabels" . }}
app.kubernetes.io/component: clamav
{{- end }}
