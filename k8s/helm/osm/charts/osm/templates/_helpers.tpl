{{/*
#######################################################################################
# Copyright ETSI Contributors and Others.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#######################################################################################
*/}}
{{/*
Expand the name of the chart.
*/}}
{{- define "osm.name" -}}
{{- default .Chart.Name .Values.global.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "osm.fullname" -}}
{{- if .Values.global.fullnameOverride }}
{{- .Values.global.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.global.nameOverride }}
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
{{- define "osm.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "osm.labels" -}}
helm.sh/chart: {{ include "osm.chart" . }}
{{ include "osm.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "osm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "osm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "osm.serviceAccountName" -}}
{{- if .Values.global.serviceAccount.create }}
{{- default (include "osm.fullname" .) .Values.global.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.global.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the name of the images to be used
*/}}
{{ define "osm.nbi.image" -}}
{{ printf "%s:%s" (.Values.nbi.image.repository | default (printf "%s/nbi" (.Values.global.image.repositoryBase))) (.Values.nbi.image.tag | default .Values.global.image.tag) }}
{{- end }}
{{ define "osm.lcm.image" -}}
{{ printf "%s:%s" (.Values.lcm.image.repository | default (printf "%s/lcm" (.Values.global.image.repositoryBase))) (.Values.lcm.image.tag | default .Values.global.image.tag) }}
{{- end }}
{{ define "osm.ro.image" -}}
{{ printf "%s:%s" (.Values.ro.image.repository | default (printf "%s/ro" (.Values.global.image.repositoryBase))) (.Values.ro.image.tag | default .Values.global.image.tag) }}
{{- end }}
{{ define "osm.mon.image" -}}
{{ printf "%s:%s" (.Values.mon.image.repository | default (printf "%s/mon" (.Values.global.image.repositoryBase))) (.Values.mon.image.tag | default .Values.global.image.tag) }}
{{- end }}
{{ define "osm.pol.image" -}}
{{ printf "%s:%s" (.Values.pol.image.repository | default (printf "%s/pol" (.Values.global.image.repositoryBase))) (.Values.pol.image.tag | default .Values.global.image.tag) }}
{{- end }}
{{ define "osm.pla.image" -}}
{{ printf "%s:%s" (.Values.pla.image.repository | default (printf "%s/pla" (.Values.global.image.repositoryBase))) (.Values.pla.image.tag | default .Values.global.image.tag) }}
{{- end }}
{{ define "osm.ngui.image" -}}
{{ printf "%s:%s" (.Values.ngui.image.repository | default (printf "%s/ng-ui" (.Values.global.image.repositoryBase))) (.Values.ngui.image.tag | default .Values.global.image.tag) }}
{{- end }}
{{ define "osm.webhookTranslator.image" -}}
{{ printf "%s:%s" (.Values.webhookTranslator.image.repository | default (printf "%s/webhook" (.Values.global.image.repositoryBase))) (.Values.webhookTranslator.image.tag | default .Values.global.image.tag) }}
{{- end }}
{{ define "osm.keystone.image" -}}
{{ printf "%s:%s" (.Values.keystone.image.repository | default (printf "%s/keystone" (.Values.global.image.repositoryBase))) (.Values.keystone.image.tag | default .Values.global.image.tag) }}
{{- end }}

{{/*
Return the MongoDB URI based on whether authentication is enabled.
*/}}
{{- define "osm.databaseUri" -}}
  {{- if .Values.global.db.mongo.auth.enabled }}
    {{- $secret := (lookup "v1" "Secret" .Release.Namespace .Values.global.db.mongo.auth.secretName ) }}
    {{- $password := (index $secret.data .Values.global.db.mongo.auth.secretKeyRootPassword ) | b64dec }}
    {{ printf "mongodb://root:%s@%s:27017/?replicaSet=rs0" $password .Values.global.db.mongo.mongoService | b64enc | quote }}
  {{- else }}
    {{ printf "mongodb://%s:27017/?replicaSet=rs0" .Values.global.db.mongo.mongoService | b64enc | quote }}
  {{- end }}
{{- end }}
