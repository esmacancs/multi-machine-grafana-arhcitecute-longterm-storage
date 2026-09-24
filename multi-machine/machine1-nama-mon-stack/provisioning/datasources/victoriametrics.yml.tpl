# =============================================================================
#  Grafana datasource — RENDERED BY deploy.sh from victoriametrics.yml.tpl
#  url: https://vmauth:8427 (read-only user; TLS via internal CA).
#  Username is injected at render time; the password and CA cert are read
#  from files at provisioning time using Grafana's $__file{} syntax, so
#  neither ever appears in env / docker inspect.
#  deploy.sh exports VMAUTH_*_FILE_REF='$__file{...}' so that envsubst
#  substitutes the safe placeholders below with the literal $__file{} strings
#  (envsubst would otherwise mangle a bare $__file{...}).
# =============================================================================

apiVersion: 1

datasources:
  - name: VictoriaMetrics
    uid: victoriametrics
    type: prometheus
    access: proxy
    url: https://vmauth:8427
    editable: false
    isDefault: true
    basicAuth: true
    basicAuthUser: ${VMAUTH_GRAFANA_USERNAME}
    jsonData:
      timeInterval: 15s
      httpMethod: POST
      tlsAuthWithCACert: true
      tlsSkipVerify: false
    secureJsonData:
      basicAuthPassword: ${VMAUTH_GRAFANA_PASSWORD_FILE_REF}
      tlsCACert: ${VMAUTH_CA_FILE_REF}