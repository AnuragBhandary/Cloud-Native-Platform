{{- define "jobq.labels" -}}
app.kubernetes.io/part-of: jobq
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "jobq.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end }}

{{/* Environment shared by every jobq process. */}}
{{/* Application traffic goes through PgBouncer when the pooler is enabled. */}}
{{- define "jobq.env" -}}
{{- if .Values.postgres.pooler.enabled }}
- name: JOBQ_DB_PASSWORD
  valueFrom:
    secretKeyRef: { name: {{ .Release.Name }}-db-app, key: password }
- name: JOBQ_DATABASE_URL
  value: postgresql://jobq:$(JOBQ_DB_PASSWORD)@{{ .Release.Name }}-db-pooler-rw:5432/jobq
{{- else }}
- name: JOBQ_DATABASE_URL
  valueFrom:
    secretKeyRef: { name: {{ .Release.Name }}-db-app, key: uri }
{{- end }}
- name: JOBQ_REDIS_URL
  value: redis://{{ .Release.Name }}-redis:6379/0
- name: JOBQ_LOG_JSON
  value: "true"
{{- end }}

{{/* Every component runs migrations first; `jobq migrate` holds an advisory lock and is a no-op
     once applied, so concurrent pods are safe. */}}
{{/* Migrations hold a session-level advisory lock, which transaction pooling can't keep, so they
     connect to the primary directly rather than through PgBouncer. */}}
{{- define "jobq.migrate" -}}
- name: migrate
  image: {{ include "jobq.image" . }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  args: ["migrate"]
  env:
    - name: JOBQ_DATABASE_URL
      valueFrom:
        secretKeyRef: { name: {{ .Release.Name }}-db-app, key: uri }
    - name: JOBQ_REDIS_URL
      value: redis://{{ .Release.Name }}-redis:6379/0
  {{- include "jobq.containerSecurity" . | nindent 2 }}
{{- end }}

{{/* Pod-level settings shared by jobq pods. enableServiceLinks is off because Kubernetes would
     otherwise inject Docker-style variables for every Service in the namespace, and the
     "jobq-api" Service becomes JOBQ_API_PORT=tcp://..., which jobq reads as its own setting. */}}
{{- define "jobq.podSecurity" -}}
enableServiceLinks: false
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  seccompProfile: { type: RuntimeDefault }
{{- end }}

{{- define "jobq.containerSecurity" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: { drop: ["ALL"] }
{{- end }}
