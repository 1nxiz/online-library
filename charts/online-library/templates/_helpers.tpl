{{/* Коротке ім'я чарта */}}
{{- define "library.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Повне ім'я об'єктів: <release>-<chart>. Будується з імені релізу,
тож чарт можна встановити двічі в один кластер.
*/}}
{{- define "library.fullname" -}}
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

{{/* Ім'я компонента: <fullname>-<component>. Виклик: include "library.componentName" (list . "backend") */}}
{{- define "library.componentName" -}}
{{- $root := index . 0 }}
{{- $component := index . 1 }}
{{- printf "%s-%s" (include "library.fullname" $root) $component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Мітки, спільні для всіх об'єктів чарта */}}
{{- define "library.commonLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: online-library
{{- end }}

{{/* Набір міток для об'єктів без компонента (ConfigMap, Secret, Ingress) */}}
{{- define "library.labels" -}}
{{ include "library.commonLabels" . }}
app.kubernetes.io/name: {{ include "library.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Мітки селектора компонента. Виклик: include "library.selectorLabels" (list . "backend") */}}
{{- define "library.selectorLabels" -}}
{{- $root := index . 0 -}}
app.kubernetes.io/name: {{ include "library.name" $root }}
app.kubernetes.io/instance: {{ $root.Release.Name }}
app.kubernetes.io/component: {{ index . 1 }}
{{- end }}

{{/* Повний набір міток компонента = спільні + селектор */}}
{{- define "library.componentLabels" -}}
{{ include "library.commonLabels" (index . 0) }}
{{ include "library.selectorLabels" . }}
{{- end }}

{{/* Ім'я Secret: власний або вже наявний у кластері (existingSecret) */}}
{{- define "library.secretName" -}}
{{- if .Values.secret.existingSecret }}
{{- .Values.secret.existingSecret }}
{{- else }}
{{- include "library.componentName" (list . "secret") }}
{{- end }}
{{- end }}

{{/* Повна назва образу: repository:tag (tag за замовчуванням = appVersion) */}}
{{- define "library.image" -}}
{{- printf "%s:%s" .image.repository (.image.tag | default .chart.AppVersion | toString) }}
{{- end }}

{{/* Шаблон пода backend — спільний для Deployment і Rollout */}}
{{- define "library.backendPod" -}}
metadata:
  labels:
    {{- include "library.componentLabels" (list . "backend") | nindent 4 }}
  annotations:
    # перезапуск подів, якщо змінився ConfigMap
    checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
spec:
  containers:
    - name: backend
      image: {{ include "library.image" (dict "image" .Values.backend.image "chart" .Chart) }}
      imagePullPolicy: {{ .Values.backend.image.pullPolicy }}
      ports:
        - name: http
          containerPort: 5000
      {{- with .Values.backend.env }}
      # ЛР-7: довільні змінні оточення з values (наприклад FAIL_RATE)
      env:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      envFrom:
        - configMapRef:
            name: {{ include "library.componentName" (list . "config") }}
        - secretRef:
            name: {{ include "library.secretName" . }}
      readinessProbe:
        httpGet: { path: /health, port: http }
        initialDelaySeconds: 5
        periodSeconds: 5
      livenessProbe:
        httpGet: { path: /health, port: http }
        initialDelaySeconds: 40
        periodSeconds: 10
      resources:
        {{- toYaml .Values.backend.resources | nindent 8 }}
{{- end }}
