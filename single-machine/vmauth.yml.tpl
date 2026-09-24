unauthorized_user:
  url_prefix: http://victoria-metrics:8428

users:
  - username: "${VMAGENT_USER}"
    password: "${VMAGENT_PASS}"
    url_prefix: http://victoria-metrics:8428

  - username: "${GRAFANA_USER}"
    password: "${GRAFANA_PASS}"
    url_prefix: http://victoria-metrics:8428