# =============================================================================
#  vmagent scrape config — MACHINE 2 (namastorage)
#
#  TEMPLATE — rendered by deploy.sh (envsubst) into scrape.yml from the
#  non-secret vars in .env (MON_IP / STORAGE_IP / VMAUTH_IP / AUTH_IP).
#  NEVER edit the rendered scrape.yml directly.
#
#  IMPORTANT:
#   * This file is a MERGE BASE. Copy your existing production jobs (node,
#     FortiGate, OCI appliance exporters, Veeam push, blackbox probes, etc.)
#     from the current /root/nama-stack/scrape.yml into the
#     PRODUCTION TARGETS section below, then delete the placeholder block.
#   * The self-monitoring jobs below are authoritative: the `traefik` job was
#     REMOVED (Traefik is gone) and VictoriaMetrics is scraped through vmauth.
#   * All jobs that reach vmauth use file-based Basic Auth + internal-CA TLS
#     (secrets mounted at /run/secrets).
# =============================================================================

global:
  scrape_interval: 15s
  scrape_timeout: 10s

scrape_configs:

  # ---- VM's own metrics via vmauth (/vm/metrics -> /metrics on VM; 8428 not exposed) ----
  - job_name: "victoriametrics"
    scheme: https
    metrics_path: /vm/metrics
    static_configs:
      - targets: ["${VMAUTH_IP}:8427"]
        labels:
          instance: 'victoria-metrics:nama-mon-stack'
          host: nama-mon-stack
          service: victoriametrics
          site: nama
    basic_auth:
      username_file: /run/secrets/vmagent_user
      password_file: /run/secrets/vmagent_pass
    tls_config:
      ca_file: /run/secrets/vmauth_ca.pem
      server_name: nama-mon-stack

  # ---- vmauth's own metrics (served locally by vmauth at /metrics) ----
  - job_name: "vmauth-self"
    scheme: https
    metrics_path: /metrics
    static_configs:
      - targets: ["${VMAUTH_IP}:8427"]
        labels:
          instance: 'vmauth:nama-mon-stack'
          host: nama-mon-stack
          service: vmauth
          site: nama
    basic_auth:
      username_file: /run/secrets/vmagent_user
      password_file: /run/secrets/vmagent_pass
    tls_config:
      ca_file: /run/secrets/vmauth_ca.pem
      server_name: nama-mon-stack

  # ---- Keycloak runtime metrics (M3, KC26 management port) ----
  # Container/pod/namespace labels emulate the K8s labels the official
  # keycloak-grafana-dashboard dashboards filter on (see keycloak.org
  # observability guide "Visualizing activities in dashboards").
  - job_name: "keycloak"
    metrics_path: /metrics
    static_configs:
      - targets: ["${AUTH_IP}:9000"]
        labels:
          instance: 'keycloak:nama-auth-vm'
          host: nama-auth-vm
          service: keycloak
          site: nama
          namespace: keycloak
          container: keycloak
          pod: keycloak-1

  # ---- the 3 monitoring hosts (fill-in-the-blanks topology) ----
  - job_name: "node-self"
    static_configs:
      - targets:
          - "${MON_IP}:9100"   # nama-mon-stack
          - "${STORAGE_IP}:9100"   # namastorage
          - "${AUTH_IP}:9100"   # nama-auth-vm
        labels:
          role: monitoring-host
          site: nama

  # ---- blackbox: HTTP probes of Grafana + Keycloak (interim nip.io HTTPS) ----
  # Uses http_2xx_nipio (skip TLS verify: internal-CA leaves). When F5 is live
  # point GF/KC_PUBLIC_URL at the VIPs and flip module back to http_2xx.
  - job_name: "blackbox_http_public"
    metrics_path: /probe
    params:
      module: [http_2xx_nipio]
    static_configs:
      - targets:
          - "${GF_PUBLIC_URL}"
          - "${KC_PUBLIC_URL}"
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: "${STORAGE_IP}:9115"

  # ---- blackbox: TLS handshake/cert-expiry probe of the public hosts ----
  # Interim (no F5): probes the nip.io leaf certs and exposes
  # probe_ssl_earliest_cert_expiry for the URL-dashboard / cert alerts.
  # NOTE: tls_conn (TCP prober) takes host:port, NOT full URLs.
  # When F5 is live, replace these targets with the F5 VIPs (wildcard SANs).
  - job_name: "blackbox_tls_public"
    metrics_path: /probe
    params:
      module: [tls_conn]
    static_configs:
      - targets:
          - "grafana.10.0.170.159.nip.io:3000"
          - "auth.10.0.170.115.nip.io:8443"
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: "${STORAGE_IP}:9115"

  # ---- Veeam pushgateway (same compose network — Docker DNS, not host loopback) ----
  # NOTE: pushgateway binds 127.0.0.1 on this host. If the Veeam backup server
  # pushes from ANOTHER host, bind it to ${STORAGE_IP}:9091 and add a UFW rule.
  - job_name: "veeam_pushgateway"
    honor_labels: true
    static_configs:
      - targets: ["veeam-pushgateway:9091"]

  # ----------------------------------------------------------------------
  #  PRODUCTION TARGETS  (paste your existing jobs from the original
  #  scrape.yml here — node/blackbox/fortigate/oci exporters, etc.)
  #
  #  Reference example (existing style):
  #
  #  - job_name: "node"
  #    static_configs:
  #      - targets:
  #        - 10.160.51.25:9182
  #        labels:
  #          instance: 'OCI-AdMgrVT01: 10.160.51.25'
  #          vm_name: OCI-AdMgrVT01
  #          private_ip: 10.160.51.25
  #          application_type: ADManager App
  #          role: windows
  #
  #  - job_name: "fortigate"
  #    metrics_path: /probe
  #    scheme: http
  #    params:
  #      token: ["<token>"]
  #    static_configs:
  #      - targets: ["https://10.160.32.11"]
  #    relabel_configs:
  #      - source_labels: [__address__]
  #        target_label: __param_target
  #      - source_labels: [__param_target]
  #        target_label: instance
  #        replacement: 'NAMA-OCI-FW'
  #        regex: '(?:.+)://([^:/]+).*'
  #      - target_label: __address__
  #        replacement: "${STORAGE_IP}:9710"
  #
  #  - job_name: 'blackbox_http_internal'
  #    metrics_path: /probe
  #    params:
  #      module: [http_2xx]
  #    static_configs:
  #      - targets:
  #        - https://negc.nama.om
  #    relabel_configs:
  #      - source_labels: [__address__]
  #        target_label: __param_target
  #      - source_labels: [__param_target]
  #        target_label: instance
  #      - target_label: __address__
  #        replacement: "${STORAGE_IP}:9115"
  #
  #  - job_name: 'oci_*'
  #    ... (OCI backup/appliance exporters, as deployed today)
  # ----------------------------------------------------------------------

  # ----------------------------------------------------------------------
  #  DELETE THE PLACEHOLDER SECTION BELOW after pasting production targets
  # ----------------------------------------------------------------------
  - job_name: "_placeholder_production_targets"
    scrape_interval: 1h
    static_configs:
      - targets: ["127.0.0.1:0"]
        labels:
          note: "replace-with-real-targets"