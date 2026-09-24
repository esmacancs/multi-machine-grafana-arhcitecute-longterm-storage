# =============================================================================
#  vmauth auth config for MACHINE 1 (nama-mon-stack) — RENDERED BY deploy.sh
#
#  This .tpl is the source; deploy.sh emits `vmauth.yml` (chmod 600) with the
#  actual values from ./secrets/. NEVER commit vmauth.yml or real passwords.
#
#  Semantics (vmauth docs):
#   * src_paths regexes must match the WHOLE request path.
#   * vmauth preserves the request path unless drop_src_path_prefix_parts is set.
#   * deny_paths carve paths OUT of the same url_map entry (403/401).
#   * Requests matching no user / no route get 401.
#
#  Write/read split:
#    VM2 user  -> only /api/v1/write|import|export  and /vm/* (=> /metrics on VM)
#    Grafana   -> only read/query endpoints
# =============================================================================

users:

  # ---- VM2 (vmagent) -> remote_write (WRITE ONLY) ----
  - username: "${VMAUTH_VMAGENT_USERNAME}"
    password: "${VMAUTH_VMAGENT_PASSWORD}"
    url_map:
      - src_paths:
          - "/api/v1/write"
          - "/api/v1/import"
          - "/api/v1/import/.*"
          - "/api/v1/export"
        url_prefix: "http://victoria-metrics:8428/"
      - src_paths:            # /vm/... -> /...  (e.g. /vm/metrics -> /metrics on VM)
          - "/vm/.*"
        drop_src_path_prefix_parts: 1
        url_prefix: "http://victoria-metrics:8428/"
    max_concurrent_requests: 4

  # ---- Grafana -> read queries only (READ ONLY) ----
  - username: "${VMAUTH_GRAFANA_USERNAME}"
    password: "${VMAUTH_GRAFANA_PASSWORD}"
    url_map:
      - src_paths:
          - "/api/v1/query"
          - "/api/v1/query_range"
          - "/api/v1/series"
          - "/api/v1/series/.*"
          - "/api/v1/labels"
          - "/api/v1/label/.*"
          - "/api/v1/status/.*"
          - "/api/v1/metadata"
          - "/api/v1/tsdb"
        url_prefix: "http://victoria-metrics:8428/"
    max_concurrent_requests: 8