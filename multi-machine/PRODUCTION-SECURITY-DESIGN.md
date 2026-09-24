# NAMA Monitoring Platform — Secure Production Design (3-VM, F5-backed)

> Status: **authoritative hardening + migration design** for the existing `grafana-key-vmagent-project`.
> Supersedes the Traefik-backed multi-machine variant of the main README (the `traefik/` dirs and Traefik
> services in `docker-compose.yml` become obsolete and are removed as part of the migration below).
> Scope is exactly the three existing VMs — no new servers are invented.

---

## 0. Weaknesses in the CURRENT architecture and how this design fixes them

| # | Current weakness | Fixed by this design |
|---|---|---|
| W1 | Services published on `0.0.0.0` (`8428`, `3000`, `9100`, `8080`) — reachable from any interface | Every published port is bound to the VM's specific LAN IP (`172.29.50.x`) or `127.0.0.1`; UFW default-deny enforces source restrictions |
| W2 | vmagent writes to VictoriaMetrics over plain HTTP `172.29.50.2:8428` with no auth | Write path goes through vmauth: HTTPS (internal-CA TLS) + per-user Basic Auth; VM port 8428 is no longer published at all |
| W3 | VictoriaMetrics read/write both unrestricted on one port | vmauth enforces **read/write separation** with path-scoped per-user rules; the raw VM API is only reachable on the Docker bridge |
| W4 | Secrets in `docker-compose.yml`, `.env`, and git (admin pw, OIDC secret, DB pw, SMTP pw) | All secrets live in root-only `secrets/*` files, injected via `*__FILE` / `*_FILE` / `passwordFile` / rendered `0600` configs; nothing in compose or `docker inspect` |
| W5 | No host firewall | UFW default-deny inbound on all three VMs + Docker `DOCKER_USER` chain rules |
| W6 | Traefik + let's-encrypt + docker.sock mounted into a container | Traefik removed; TLS terminated at the existing enterprise F5; no container gets the Docker socket |
| W7 | `latest` / floating image tags | All images pinned to exact versions + digests; provenance + SBOM process |
| W8 | No backups defined | vmbackup (VictoriaMetrics snapshots), Grafana sqlite + API export, `pg_dump` for Keycloak; age-encrypted, off-host, with restore drills |
| W9 | Grafana admin + OIDC secret in environment | `GF_*__FILE` + rendered provisioning (`$__file{}`), stored encrypted only in `grafana.db` after provisioning |
| W10 | No brute-force / session limits / MFA policy documented | Keycloak realm hardening (Brute Force Protection, session timeouts, TOTP for admins) |
| W11 | Role mapping trusts any current expression without strictness review | `realm_access.roles` claim (server-signed) is the only role source; escalation prevented (see §7.3) |
| W12 | No health checks / resource limits / capability drops on containers | `healthcheck:` everywhere, `deploy.resources.limits`, `security_opt/read_only/cap_drop` where the image supports it |

---

## 1. Final architecture

```
                          User network
                               │  HTTPS :443  (TLS 1.2+, browser)
                               ▼
                 Enterprise F5 / firewall / LB
                 - TLS termination (Option A: F5 re-injects behind a HTTP VIP)
                 - only 443 inbound; everything else denied at F5
                 - injects X-Forwarded-For / X-Forwarded-Proto: https
                               │
            ┌──────────────────┴──────────────────┐
            │  HTTP :3000 (LAN VIP)               │  HTTP :8080 (LAN VIP)
            ▼                                     ▼
 ┌──────────────────────────┐        ┌──────────────────────────────┐
 │  VM1  nama-mon-stack     │        │  VM3  nama-auth-vm           │
 │  172.29.50.2             │        │  172.29.50.4                 │
 │                          │        │                              │
 │  Grafana :3000           │        │  Keycloak :8080 (app)        │
 │   │  OIDC (browser) ─────┼─HTTPS──►    identitynama.otech.om     │
 │   │  token/userinfo (cb) │  :443  │    :9000 (management)        │
 │   ▼                      │        │   │                          │
 │  vmauth :8427 (TLS+auth) │        │   ▼ Postgres :5432 (kcnet)   │
 │   │  read paths (graph)  │        │  keycloak-db  (NO host port) │
 │   ▼                      │        └──────────────────────────────┘
 │  victoria-metrics:8428   │
 │  (Docker bridge only,    │        ┌──────────────────────────────┐
 │   never published)       │        │  VM2  namastorage  172.29.50.3│
 │  node-exporter :9100     │        │  vmagent :8429  (127.0.0.1)  │
 └──────────────────────────┘        │  node/blackbox/fortigate/    │
                                     │    oci/veean exporters        │
                                     │     (LAN-only publishes)      │
                                     │    │                          │
                                     │    │ HTTPS + Basic Auth       │
                                     │    └──►172.29.50.2:8427 /api/v1/write
                                     └──────────────────────────────┘
```

Key changes vs today:
- **No reverse proxy on any VM** — external TLS stays on the F5.
- **VictoriaMetrics 8428 never reaches the LAN** — all metric traffic flows through vmauth.
- **Postgres is bridged-only** (`kcnet`), no host publish.
- **vmagent's HTTP/status page binds loopback only**; exporters bind the LAN IP and are source-restricted.
- **Read/write split** enforced in vmauth: VM2 may only write, Grafana may only read.

---

## 2. Network zones

| Zone | Members | Trust | Notes |
|---|---|---|---|
| **User network** | Internal/users, web browsers | Low | Only TLS 443 to F5 VIPs; nothing to the VMs |
| **F5 / edge zone** | F5 LTM/big-IP, firewall cluster | Controlled | Single TLS termination point; source of all HTTP to Grafana/Keycloak VIPs |
| **Management zone** | Admins, jump host | High but restricted | Source of SSH (22) into all VMs; no app ports |
| **Application zone** | VM1 (Grafana/VM/vmauth), VM3 (Keycloak) | Medium | Serving the two public web apps; reachable **only from F5** on 3000/8080 |
| **Monitoring zone** | VM2 (vmagent + exporters) | Medium | Scrapes targets and the monitoring hosts; the only writer of metrics |
| **Storage / data plane** | `mon-net` on VM1, `kcnet` on VM3 | High (Docker-internal) | VM→vmauth, Grafana→vmauth, Keycloak→Postgres; never exposed to the host bridge |

Separation principles:
1. traffic between zones crosses a firewall (host UFW **and** F5) with explicit source/dest rule.
2. Nothing the world can reach listens on `0.0.0.0`.
3. The two Docker bridge networks carry **only** intra-host traffic; they are not routed.

---

## 3. Corrected communication / port matrix

> **IP parameterization (provider-assigned static IPs).** The `172.29.50.2/.3/.4`
> values in this document are **examples**. In your deployment the three VMs use
> whatever STATIC addresses the provider assigns. Nothing is hardcoded in the
> repo: set `MON_IP` (VM1) in `machine1/.env`, `STORAGE_IP`/`VMAUTH_IP`/`AUTH_IP`
> in `machine2/.env`, `AUTH_IP` in `machine3/.env`, and everything renders from
> them — compose port binds, `scrape.yml.tpl`, the vmauth CA SAN (`gen-ca.sh`),
> and the UFW rules. `provision-all.sh <MON_IP> <STORAGE_IP> <AUTH_IP>` writes
> these keys automatically and passes them to bootstrap + firewall. The matrix
> below is written against the example subnet for readability; substitute your
> assigned addresses.

Legend: `IN` inbound to host, `OUT` outbound from host. Source is the entity that initiates.

| # | Source | Destination | Port/Proto | Purpose | Required | Rule |
|---|---|---:|---|---|---|---|
| M1 | Users/browsers | F5 VIP `cockpitnama.otech.om` | 443/TCP | Grafana UI | YES | F5 policy |
| M2 | Users/browsers | F5 VIP `identitynama.otech.om` | 443/TCP | Keycloak SSO | YES | F5 policy |
| M3 | F5 | VM1 `172.29.50.2:3000` | 3000/TCP | Grafana (HTTP VIP) | YES | UFW: allow from F5 → 172.29.50.2:3000 |
| M4 | F5 | VM3 `172.29.50.4:8080` | 8080/TCP | Keycloak (HTTP VIP) | YES | UFW: allow from F5 → 172.29.50.4:8080 |
| M5 | VM2 (vmagent) | VM1 `172.29.50.2:8427` | 8427/TCP (HTTPS) | `remote_write` via vmauth | YES | UFW: allow 172.29.50.3 → :8427 |
| M6 | Grafana (VM1) | vmauth `mon-net:8427` | 8427/TCP | metric queries (read-only) | YES | Docker bridge only; no host rule |
| M7 | Grafana (VM1) | F5 VIP `identitynama.otech.om` | 443/TCP | OIDC token + userinfo exchange at login | YES | OUT from VM1 |
| M7a | Grafana (VM1) | VM3 `172.29.50.4:8080` | 8080/TCP | OIDC **discovery + JWKS** (server-side, bypasses F5) | YES | UFW: allow 172.29.50.2 → :8080 |
| M8 | VM2 | VM1 `172.29.50.2:9100` | 9100/TCP | node-exporter (M1 host) | YES | UFW: allow 172.29.50.3 → :9100 |
| M9 | VM2 | VM3 `172.29.50.4:9100` | 9100/TCP | node-exporter (M3 host, added) | YES | UFW: allow 172.29.50.3 → :9100 |
| M10 | VM2 | VM3 `172.29.50.4:9000` | 9000/TCP | Keycloak metrics/health (KC26 management port) | YES | UFW: allow 172.29.50.3 → :9000 |
| M11 | VM2 (vmagent) | itself `127.0.0.1:8429` | 8429/TCP | local status/targets page | YES (local only) | bind 127.0.0.1; no inbound |
| M12 | VM2 (blackbox) | monitoring targets (blackbox/fortigate/oci/veeam) | OUT various | scrape / probes | YES | OUT allowed |
| M13 | VM2 (pushgateway) | pushgateway `127.0.0.1:9091` | 9091/TCP | Veeam backup push | YES (local) | bind 127.0.0.1 |
| M14 | Keycloak | Postgres `kcnet:5432` | 5432/TCP | Keycloak DB | YES | Docker bridge only; **no host publish** |
| M15 | All VMs | NTP / DNS / pkg repos | 123/53/whatever | time sync + updates | YES | OUT allowed |
| M16 | VM1 | smtp2go `mail-eu.smtp2go.com:2525` | 2525/TCP | Grafana alerts SMTP | YES | OUT |
| M17 | F5 / admin | vmauth, VM, vmagent status | any | operator browsing UI | NO | Reach through Grafana; not opened |
| M18 | Internet | `172.29.50.2:8428` | 8428/TCP | VictoriaMetrics direct | **NO** | port not published, denied |
| M19 | Internet | `172.29.50.3:8429` | 8429/TCP | vmagent UI | **NO** | loopback only, denied |
| M20 | Internet | `172.29.50.x:9100/9115/9710/9091/3000/8080/5432` | various | exporters / apps / DB | **NO** | bind + default deny |
| M21 | Internet | `172.29.50.4:8080` (Keycloak) | 8080/TCP | direct KC access | **NO** | UFW: allow F5 + VM1 + VM2 only |

**Corrections to the requested matrix:** VM2→VM1 write is **8427 (vmauth, HTTPS)**, never 8428;
Grafana reads via **vmauth over the Docker bridge** (not a host port); Keycloak metrics are on the
**KC26 management port 9000** (not 8080); the old `172.29.50.2:9102` / `172.29.50.4:9102` Traefik
metric endpoints are **removed**; Postgres has **no host path at all**.

---

## 4. Docker architecture (per VM)

### 4.0 Shared principles

- **No plaintext secrets in compose.** Secrets live in `./secrets/` (root:root `0700` **on the host**,
  files `0600`, git-ignored) and are injected one of four ways:
  1. `GF_*__FILE` (Grafana official entrypoint reads the file) — config values like admin password,
     OIDC client secret, SMTP password.
  2. `*_FILE` env (Postgres official image) — `POSTGRES_PASSWORD_FILE`.
  3. Render-time substitution for file-based configs (`vmauth.yml`, Grafana `datasources/*.yaml`)
     executed by `deploy.sh`, output `chmod 0600`, mount `:ro`.
  4. Runtime file flags: vmagent `-remoteWrite.basicAuth.passwordFile` / `usernameFile` /
     `-remoteWrite.tlsCAFile`.
  > Docker mounts compose `secrets:` as `root:root` — so the in-container `mode:` is `0444`
  > (readable by the images' non-root `USER`; host files stay `0600`). Never `0400` for these
  > images or the app user cannot read them.
- **Keycloak's official image has no `_FILE` support** (unlike Postgres). Compose top-level `secrets:`
  mounts `/run/secrets/*`, and the Keycloak container's `entrypoint` exports them, then runs
  `/opt/keycloak/bin/kc.sh "$@"`. Secrets stay out of `docker inspect`.
- Every published port is bound to the VM's LAN IP (or `127.0.0.1`).
- Every service gets `healthcheck:`, `restart: unless-stopped`, and `deploy.resources.limits`;
  `read_only` / `cap_drop` / `no-new-privileges` where the image allows.
- Images: **exact tag + digest** (see §13; `ops/pin-images.sh` resolves digests).

### 4.1 VM1 — `nama-mon-stack` (172.29.50.2)

Files: `docker-compose.yml`, `.env.example`, `vmauth.yml.tpl`, `deploy.sh`,
`provisioning/datasources/victoriametrics.yml.tpl`, `secrets/`.

Published port map (host):
```
172.29.50.2:3000 -> grafana:3000        (F5 only, UFW)
172.29.50.2:8427 -> vmauth:8427 (TLS)   (172.29.50.3 only, UFW)
172.29.50.2:9100 -> node-exporter:9100  (172.29.50.3 only, UFW)
NOT published: 8428 victimia-metrics (bridge only)
```

`vmauth.yml` (rendered — read/write split):

> vmauth semantics used below: `src_paths` regexes must match the **whole** request path; by default
> vmauth preserves the request path when proxying (only `drop_src_path_prefix_parts` strips it);
> deny is expressed as `deny_paths` **inside** a `url_map` entry; requests that match no user/route
> get `401`.

```yaml
# rendered by deploy.sh from vmauth.yml.tpl ; chmod 0600 ; mounted read-only
users:
  # ---- VM2 -> remote_write (WRITE ONLY) ----
  - username: "${VMAUTH_VMAGENT_USERNAME}"
    password: "${VMAUTH_VMAGENT_PASSWORD}"
    url_map:
      - src_paths:
          - "/api/v1/write"
          - "/api/v1/import"
          - "/api/v1/import/.*"
          - "/api/v1/export"
        url_prefix: "http://victoria-metrics:8428/"
      - src_paths:          # /vm/... -> /...   (e.g. /vm/metrics -> /metrics)
          - "/vm/.*"
        drop_src_path_prefix_parts: 1
        url_prefix: "http://victoria-metrics:8428/"
    max_concurrent_requests: 4

  # ---- Grafana -> read queries (READ ONLY) ----
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
```

> (No `/metrics` route is mapped for the Grafana user: vmauth answers `/metrics` with its **own**
> metrics regardless of the auth config, and VM self-metrics are pulled by VM2 via `/vm/metrics`.)

Write/read split is enforced purely by the path sets above: the VM2 user can only hit
`/api/v1/write|import|export` and the `/vm/`-prefixed routes (used for `/vm/metrics` — VM's own
metrics, reached through vmauth without exposing the 8428 port); the Grafana user can only hit the
read/query endpoints. In both cases unmatched paths return `401`, and admin/delete/import paths are
not present in either user's route set.

vmauth runs `-tls -tlsCertFile=/run/secrets/vmauth_tls.crt -tlsKeyFile=/run/secrets/vmauth_tls.key`
serving HTTPS on 8427. Certificate and CA issued by the internal CA in `ops/` (SAN:
`nama-mon-stack`, `nama-mon-stack.otech.om`, **`vmauth`**, `172.29.50.2`, `localhost`).

Grafana key env (see full file below):

```yaml
    environment:
      - GF_SECURITY_ADMIN_PASSWORD__FILE=/run/secrets/grafana_admin_password
      - GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET__FILE=/run/secrets/grafana_oidc_client_secret
      - GF_SMTP_PASSWORD__FILE=/run/secrets/smtp_password
      # ... hardening vars from §8 ...
```

Grafana datasource (rendered, `%DATASOURCE%`-free — uses `$__file{}` so the Basic-Auth password stays
out of `docker inspect`):

```yaml
apiVersion: 1
datasources:
  - name: VictoriaMetrics
    type: prometheus
    access: proxy
    url: https://vmauth:8427
    editable: false
    basicAuth: true
    basicAuthUser: $VMAUTH_GRAFANA_USERNAME           # rendered by deploy.sh
    jsonData:
      tlsAuthWithCACert: true
      tlsSkipVerify: false
      httpMethod: POST
    secureJsonData:
      basicAuthPassword: $__file{/run/secrets/vmauth_grafana_password}
      tlsCACert: $__file{/run/secrets/vmauth_ca.pem}
```

> `$__file{}` is Grafana's native "read a value from a mounted file" syntax for datasource
> provisioning, so the password never appears as an environment value in `docker inspect`.

### 4.2 VM2 — `namastorage` (172.29.50.3)

Files: `docker-compose.yml`, `.env.example`, `scrape.yml`, `blackbox.yml`, `secrets/`.

Published port map (host):
```
127.0.0.1:8429  -> vmagent:8429        (status page — loopback only)
172.29.50.3:9100 -> node-exporter      (mon LAN sources)
172.29.50.3:9115 -> blackbox           (mon LAN sources)
172.29.50.3:9710 -> fortigate exporter (mon LAN sources)
172.29.50.3:9091 -> pushgateway        (loopback only; veeam pushes locally)
OCI exporters: LAN-bound, source-restricted
```

vmagent flags (secrets via files, TLS to vmauth):

```
-promscrape.config=/etc/prometheus/scrape.yml
-remoteWrite.url=https://172.29.50.2:8427/api/v1/write
-remoteWrite.basicAuth.usernameFile=/run/secrets/vmagent_user
-remoteWrite.basicAuth.passwordFile=/run/secrets/vmagent_pass
-remoteWrite.tlsCAFile=/run/secrets/vmauth_ca.pem
-remoteWrite.tlsServerName=nama-mon-stack
-remoteWrite.showURL=false
-remoteWrite.maxDiskUsagePerURL=10GB
```

`scrape.yml` (merge base preserved — full production targets stay; only the `traefik` job is deleted
and read/write self-monitoring jobs kept):

```yaml
global:
  scrape_interval: 15s
  scrape_timeout: 10s

scrape_configs:
  - job_name: "node-self"
    static_configs:
      - targets: ["172.29.50.2:9100", "172.29.50.3:9100", "172.29.50.4:9100"]
        labels: { role: monitoring-host }
  - job_name: "victoriametrics"      # VM's own metrics via vmauth /vm/metrics (8428 never exposed)
    scheme: https
    metrics_path: /vm/metrics
    static_configs: [{ targets: ["172.29.50.2:8427"], labels: { instance: "victoria-metrics-primary" } }]
    basic_auth: { username_file: /run/secrets/vmagent_user, password_file: /run/secrets/vmagent_pass }
    tls_config: { ca_file: /run/secrets/vmauth_ca.pem, server_name: nama-mon-stack }
  - job_name: "vmauth-self"          # vmauth's own /metrics is served locally by vmauth
    scheme: https
    metrics_path: /metrics
    static_configs: [{ targets: ["172.29.50.2:8427"], labels: { instance: "vmauth" } }]
    basic_auth: { username_file: /run/secrets/vmagent_user, password_file: /run/secrets/vmagent_pass }
    tls_config: { ca_file: /run/secrets/vmauth_ca.pem, server_name: nama-mon-stack }
  - job_name: "keycloak"
    metrics_path: /metrics
    static_configs: [{ targets: ["172.29.50.4:9000"], labels: { instance: "keycloak" } }]
  - job_name: "blackbox_http_probes"
    metrics_path: /probe
    params: { module: [http_2xx] }
    static_configs:
      - targets: ["https://cockpitnama.otech.om", "https://identitynama.otech.om"]
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 172.29.50.3:9115
  - job_name: "blackbox_tls_expiry"
    metrics_path: /probe
    params: { module: [tls_1_2] }
    static_configs: [{ targets: ["https://75.2.13.1:443", "https://75.2.20.5:443"] }]   # example (validated against real certs)
    relabel_configs: [relabel as above -> 172.29.50.3:9115]
  # ... existing node/fortigate/oci/veeam production jobs (unchanged) ...
```

> **Cert-expiry note:** point `blackbox_tls_expiry` at the F5 VIP addresses (the DNS names already
> probe the app), so it monitors the edge certificate lifetime; alert on `probe_ssl_earliest_cert_expiry`.

### 4.3 VM3 — `nama-auth-vm` (172.29.50.4)

Files: `docker-compose.yml`, `.env.example`, `secrets/` + `realm/grafana-namawater.json` (import).

Published port map (host):
```
172.29.50.4:8080 -> keycloak:8080     (F5 + VM1 + VM2 only, UFW)
172.29.50.4:9000 -> keycloak:9000     (VM2 only, UFW)  # KC26 management metrics/health
172.29.50.4:9100 -> node-exporter     (M2 only, UFW)
NOT published: postgres 5432 (kcnet only)
```

Compose highlights (full file in `docker-compose.yml`):

```yaml
secrets:
  kc_db_password:      { file: ./secrets/kc_db_password,      mode: 0444 }
  kc_admin_username:   { file: ./secrets/kc_admin_username,   mode: 0444 }
  kc_admin_password:   { file: ./secrets/kc_admin_password,   mode: 0444 }

services:
  postgres:
    image: postgres:16@sha256:...
    secrets: [kc_db_password]
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD_FILE: /run/secrets/kc_db_password
    volumes: [ "./postgres:/var/lib/postgresql/data" ]
    networks: [kcnet]

  keycloak:
    image: quay.io/keycloak/keycloak:26.7.4@sha256:...
    secrets: [kc_db_password, kc_admin_username, kc_admin_password]
    entrypoint:
      - /bin/bash
      - -c
      - |
        export KC_DB_PASSWORD="$(cat /run/secrets/kc_db_password)"
        export KEYCLOAK_ADMIN="$(cat /run/secrets/kc_admin_username)"
        export KEYCLOAK_ADMIN_PASSWORD="$(cat /run/secrets/kc_admin_password)"
        exec /opt/keycloak/bin/kc.sh "$@"
    command: ["start"]
    environment:
      KC_DB: postgres
      KC_DB_URL_HOST: postgres
      KC_DB_URL_DATABASE: keycloak
      KC_PROXY: edge
      KC_PROXY_HEADERS: xforwarded
      KC_HOSTNAME: ${KC_HOSTNAME}
      KC_HOSTNAME_STRICT: "true"
      KC_HOSTNAME_STRICT_HTTPS: "true"
      KC_HTTP_ENABLED: "true"
      KC_HTTP_PORT: 8080
      KC_HTTP_MANAGEMENT_PORT: 9000
      KC_HEALTH_ENABLED: "true"
      KC_METRICS_ENABLED: "true"
      KC_SPI_REALM_REST_CACHE_ENABLED: "true"
      KC_LOG_LEVEL: INFO
    ports:
      - "172.29.50.4:8080:8080"
      - "172.29.50.4:9000:9000"
    depends_on:
      postgres: { condition: service_healthy }
    networks: [kcnet]
```

> `KC_HTTP_PORT`/`KC_HTTP_MANAGEMENT_PORT` map the KC26 two-port model: public app on 8080,
> health+metrics on 9000. Postgres has no `ports:` block.

### 4.4 `.env` and secrets hygiene

```bash
secrets/          # root:root 0700 ; each file 0600 ; git-ignored
  vmauth_ca.pem             vmauth_tls.crt            vmauth_tls.key
  vmauth_vmagent_username   vmauth_vmagent_password
  vmauth_grafana_username   vmauth_grafana_password
  grafana_admin_password    grafana_oidc_client_secret   smtp_password
  kc_db_password            kc_admin_username           kc_admin_password
  vmagent_user              vmagent_pass                vmauth_ca.pem (VM2)
.env          # root:root 0600 ; git-ignored ; non-secret config only
.gitignore    # adds secrets/ and .env
```

- Generate with `ops/gen-secrets.sh` (openssl rand), CA with `ops/gen-ca.sh`.
- Optional at-rest encryption: `age`-encrypt a nightly tarball of `secrets/` + `.env` off-host
  (§10) and in backups. Decryption key lives outside the VMs (password manager / KMS / offline).
- `.env` contains **no passwords** — only hostnames, IPs, ports, retentions, image references.

---

## 5. TLS architecture

### 5.1 F5 → backend: Option A (recommended) vs Option B

| | Option A — F5 terminates TLS | Option B — F5 → HTTPS re-encrypt |
|---|---|---|
| Path | browser──HTTPS──►F5──HTTP──►backend VIP | browser──HTTPS──►F5──HTTPS──►backend VIP |
| Certificates on VMs | none | internal CA cert on Grafana + Keycloak + trust validation both ways |
| Keycloak | Fits `KC_PROXY=edge` exactly: KC trusts `X-Forwarded-Proto: https` and sets secure cookies; hostname strict works | needs KC to serve its own TLS, another trust store, and `KC_PROXY_HEADERS` interplay |
| Attack surface on VMs | TLS terminates at the hardened F5; VMs only accept HTTP on restricted VIPs | VMs must run OpenSSL/TLS handling |
| Cert rotation | F5/edge only | per-VM rotation + CA distribution |
| Wire | `F5⇄VM` payload is plaintext on the private monitoring VLAN | encrypted on the private VLAN |

**Recommendation: Option A.** The F5 is already the mandated TLS boundary; Keycloak's
`KC_PROXY=edge` + `KC_HOSTNAME_STRICT_HTTPS=true` are designed for exactly this model, and it
minimizes per-VM cert administration and attack surface. The `F5⇄CRM` hop must stay **inside the
trusted monitoring/application VLAN** (ACL/VLAN at the switch, which the F5 ruleset also governs);
if that hop ever crosses an untrusted segment, apply Option B with the internal CA below.

### 5.2 Certificate issuance

| Certificate | Issuer | Purpose |
|---|---|---|
| `*.otech.om` / `cockpitnama.otech.om` + `identitynama.otech.om` | Public/DigiCert or enterprise public-CA on the F5 | User trust anchor; SANs match both DNS names |
| vmauth server cert + client-trust CA | **Internal CA** (`ops/gen-ca.sh` — openssl, or step-ca if available) | VM2→vmauth HTTPS; `server_name=nama-mon-stack` validated against `tlsServerName`; Grafana→vmauth over mon-net validates the Docker name **`vmauth`** via the SAN below |

Internal-CA SANs for the vmauth leaf: `DNS:nama-mon-stack`, `DNS:nama-mon-stack.otech.om`,
`DNS:vmauth` (the mon-net service name Grafana uses), `IP:172.29.50.2`, `IP:127.0.0.1`.

Why internal CA (not self-signed, not F5-issued, not public) for the metric plane:
- **Internal CA** — one trust anchor, revocable/rotatable, SAN-controlled, distributed to the exact
  hosts that need it; exactly the "private trust for private services" model.
- **Public certs** — wrong fit: hosts aren't on the public DNS; issuing and validating requires
  outbound ACME and public name, and the CN/SAN semantics don't match private IPs.
- **F5-issued** — couples the monitoring plane to the F5 operator and certificate lifecycle; avoid.
- **Self-signed** — no central rotation, no revocation, "every host its own CA" maintenance spiral.

### 5.3 Parameters + rotation

- TLS ≥ 1.2 (disable 1.0/1.1). Cipher list on F5: ECDHE(GCM/AES128/AES256/SHA384) set; no RC4,
  no MD5, no export ciphers, no CBC-where-GCM-available exceptions.
- F5 client-profile: `cipher-group` — keep trailing-DHS; set `tls1.x` versions 1.2, 1.3.
- Rotation: renew `*.otech.om` ≥30 days before expiry (alert via blackbox `probe_ssl_earliest_*`).
  Internal CA certs: 5-year CA, 1-year leaf for vmauth; rotate annually with `ops/gen-ca.sh --renew`.
- `secHeaders` removed with Traefik — header policy moves to F5 IRules/profiles: HSTS
  (`max-age=31536000; includeSubDomains`), X-Content-Type-Options, X-Frame-Options SAMEORIGIN.

---

## 6. Keycloak security

### 6.1 Realm (`grafana-namawater`) settings

| Setting | Value |
|---|---|
| `bruteForce` | enabled; max-failures 10 / per-user; wait-increase 2m doubling; min-wait 1h; failure-Reset after 5m |
| Session (SSO) idle | 30 min |
| SSO maximum | 12 h |
| Client session idle | 10 min (Grafana `grafana-nama` client) |
| Offline sessions / offline access | disabled (no `offline_access` scope granted to clients) |
| Access token lifespan | 5 min |
| Direct access grants | **disabled** on `grafana-nama` / `oauth2-proxy` clients (only browser flow) |
| Default auth methods | Username+password; **TOTP (freeOTP/Google Authenticator) enforced for `grafana-admin` role members**; consider email OTP as secondary |
| Kerberos / External IDP | none needed; keep disabled |
| Storage providers | db; `infispan` cache only in-process |
| Events | error events ON + events liveness off; log to `events` (audible via log) |

### 6.2 Clients

| Client | Type | Redirect URIs (exact) | Web origins |
|---|---|---|---|
| `grafana-nama` | confidential | `https://cockpitnama.otech.om/login/generic_oauth` | `https://cockpitnama.otech.om` |
| `oauth2-proxy` | confidential | see §6.5 (internal UIs, if enabled) | restricted to `*.otech.om` / `*.127.0.0.1.nip.io` lab hosts |

- Standard flow `authorization_code` only; `pkce` none (public? confidential clients may still use S256 — enable PKCE S256 for the browser flow, supported by KC26 + Grafana OAuth with `auth_style`).
- Token mapper: add a **realm-role → token claim** (`realm_access.roles` already ships with the token).
- Client scopes: start from `openid profile email roles`; remove `web-origins` exposures not needed.
- Boostrap admin: **create a dedicated admin user** (e.g. `kc-admin-ops`), revoke default `admin`;
  enable TOTP; disable password login for admins if MFA is enforced; restrict admin console to the
  management zone via UFW + F5 (never serve `*admin*` publicly).

### 6.3 Admin console

- `KC_HOSTNAME_ADMIN` = same strict hostname; console reachable only via `identitynama.otech.om`
  (never a separate lax hostname).
- UFW: F5 allow on 8080 **plus** VM1 allow (Grafana OIDC discovery/JWKS); nothing else.

### 6.4 Keycloak runtime (compose) hardening list (applied above)

- no `KC_*_FILE` env (unavailable) — secrets via entrypoint export.
- `KC_HTTP_MANAGEMENT_PORT=9000` keeps metrics/health off the app path.
- Restrict `/metrics` exposure to VM2 only (UFW), management port bound to LAN IP.
- Data stays in Postgres on `kcnet`; host has no 5432 listener (§4.3).
- Upgrade in place from 26.0: see §7 migration (one-time `kc.sh start --optimized`/`start` at new tag
  is fine for 26.0→26.7 **minor** upgrades; follow Keycloak's upgrading guide for the running
  `26.0.x → 26.7.x` step, including DB migration automatically applied at first start).

### 6.5 Optional internal-UI ForwardAuth (only if you keep oauth2-proxy for vmagent/vm/vm UI)

The single-machine lab proved this pattern. Keep it away from the public edge: bind oauth2-proxy to
loopback, serve `/oauth2/*` through Grafana as a sub-path or on a locked-down internal host, and
treat `OAUTH2_PROXY` as an internal-service proxy only, never on F5. The production decision is
**not** to expose oauth2-proxy — vmagent/vmauth/VM status pages stay loopback-only and are viewed via
Grafana, which is already SSO-protected.

---

## 7. Grafana security

### 7.1 Environment (compose.VM1) — see full file

```yaml
    environment:
      - GF_SECURITY_ADMIN_USER=${GF_SECURITY_ADMIN_USER}
      - GF_SECURITY_ADMIN_PASSWORD__FILE=/run/secrets/grafana_admin_password
      - GF_SECURITY_DISABLE_INITIAL_ADMIN_CREATION=true        # never create default admin
      - GF_AUTH_GENERIC_OAUTH_ENABLED=true
      - GF_AUTH_GENERIC_OAUTH_NAME=Otech IDP
      - GF_AUTH_GENERIC_OAUTH_CLIENT_ID=grafana-nama
      - GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET__FILE=/run/secrets/grafana_oidc_client_secret
      - GF_AUTH_GENERIC_OAUTH_SCOPES=openid profile email
      - GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://identitynama.otech.om/realms/grafana-namawater/protocol/openid-connect/auth
      - GF_AUTH_GENERIC_OAUTH_TOKEN_URL=https://identitynama.otech.om/realms/grafana-namawater/protocol/openid-connect/token
      - GF_AUTH_GENERIC_OAUTH_API_URL=https://identitynama.otech.om/realms/grafana-namawater/protocol/openid-connect/userinfo
      - GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH=contains(realm_access.roles[*], 'grafana-admin') && 'Admin' || contains(realm_access.roles[*], 'grafana-editor') && 'Editor' || 'Viewer'
      - GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_STRICT=false
      - GF_AUTH_GENERIC_OAUTH_ALLOW_ASSIGN_GRAFANA_ADMIN=true    # only true because mapping is Admin; see 7.3
      - GF_AUTH_GENERIC_OAUTH_AUTH_STYLE=auto
      - GF_AUTH_BASIC_ENABLED=false
      - GF_AUTH_LOGIN_FORM_ENABLED=false
      - GF_AUTH_DISABLE_LOGIN_FORM=true
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_AUTH_ANONYMOUS_ENABLED=false
      - GF_SECURITY_COOKIE_SECURE=true
      - GF_SECURITY_COOKIE_SAMESITE=lax
      - GF_SERVER_ROOT_URL=https://cockpitnama.otech.om
      - GF_PANELS_DISABLE_SANITIZE_HTML=true
      - GF_SMTP_ENABLED=true
      - GF_SMTP_HOST=mail-eu.smtp2go.com:2525
      - GF_SMTP_USER=cockpit-alerts@otech.om
      - GF_SMTP_PASSWORD__FILE=/run/secrets/smtp_password
      - GF_SMTP_FROM_ADDRESS=cockpit-alerts@otech.om
      - GF_SMTP_STARTTLS_POLICY=Mandatory
      - GF_SERVER_ROUTER_LOGGING=false
      - GF_LOG_LEVEL=info
      - GF_LOG_FILTERS=teamsignaling:debug
```

### 7.2 Provisioning-based security

- `datasources/victoriametrics.yml` — read-only (`editable: false`), `$__file{}` secret (4.1
  above); `jsonData.tlsAuthWithCACert: true`.
- `dashboards` provider with `allowUiUpdates: true` limited to the admin org; dashboard files
  scanned (no arbitrary HTML) — `GF_PANELS_DISABLE_SANITIZE_HTML` keeps CSP/lazy-rendering safe.

### 7.3 Role mapping and privilege-escalation review

The expression `contains(realm_access.roles[*], 'grafana-admin') && 'Admin' || contains(...,'grafana-editor') && 'Editor' || 'Viewer'` is **correct for current Grafana (13.x)**:
`role_attribute_path` supports the `contains()` helper, and the result maps to `Admin/Editor/Viewer`.

Escalation protections:
1. Role source is **`realm_access.roles` from the Keycloak-issued token/userinfo**, which Grafana
   fetches server-side from Keycloak with the bearer token — an end-user can never forge it. Do not
   switch the attribute to `userinfo` overrides or any mapdev/IDP-arbitrary claim.
2. `GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_STRICT=false` means unknown attributes still land in
   `Viewer` (safe fallback); set `true` if you want unknown → no-access (both acceptable; the strict
   variant further reduces the blast radius of a mis-issued role).
3. Keep `GF_AUTH_ANONYMOUS_ENABLED=false` and `GF_USERS_ALLOW_SIGN_UP=false`; disable the local
   login (`basic`, `login_form`) so there is **no second auth path** that bypasses the role mapping.
4. `GF_AUTH_GENERIC_OAUTH_ALLOW_ASSIGN_GRAFANA_ADMIN=true` is only safe because the mapping
   explicitly yields `Admin`; if you later introduce a "breakglass" or client-credential admin
   account, keep that account **outside** the OIDC mapping (local `org admin`), so OIDC users can
   never self-claim Grafana-admin regardless of realm roles.

---

## 8. VictoriaMetrics security

| Concern | Design |
|---|---|
| External exposure | `victoria-metrics` publishes **no host port**; only `mon-net` (`victoria-metrics:8428`) is used by vmauth and self-tests |
| Authentication | Two service identities (`vmauth_vmagent_*`, `vmauth_grafana_*`) enforced at vmauth; VM itself trusts the bridge only |
| Read/write split | vmauth `url_map`/`deny` per user (§4.1); Grafana cannot write, vmagent cannot query |
| TLS | vmauth terminates internal-CA TLS on 8427; vmagent verifies `server_name`, `CA` file |
| Retention | `--retentionPeriod` from `.env` (30d today — evaluate app data RPO: see §10) |
| Filesystem | storage bind-mounted `victoria-metrics-data`, owned `root:root 0750`, container runs read-only image with data dir writable; backups via `vmbackup` snapshots (§10) |
| Health | `healthcheck` on `/health`; M2 scrapes `/metrics` |
| Corruption | VM appends PartitionedTSDB; use `--search.disableCache` for debugging only; regular `vmbackup -snapshot.createUrl` snapshots before any upgrade; restore with `vmrestore` |
| Disk | alert on `vm_data_size_bytes{type="storage"}` growth + node `node_filesystem_avail_bytes` ≥ 20% goal |

---

## 9. Firewall configuration (UFW — consistent choice)

Why **UFW**: one consistent, auditable tool; `default-deny incoming`; the app identity is simple;
rules below are idempotent. Docker-published ports are DNAT'd, so **UFW alone cannot filter them** —
we therefore (a) bind every publish to a specific IP and (b) add `DOCKER_USER` chain rules that apply
UFW allow/deny logic to the docker-forwarded traffic. `ops/ufw-*.sh` apply both.

### 9.1 VM1 (172.29.50.2)

```bash
# ops/ufw-m1.sh
ufw default deny incoming
ufw default allow outgoing
# SSH: management only
ufw allow from ${MGMT_CIDR} to any port 22 proto tcp
# F5 -> Grafana
ufw allow from ${F5_IP} to 172.29.50.2 port 3000 proto tcp
# VM2 -> vmauth (TLS)
ufw allow from 172.29.50.3 to 172.29.50.2 port 8427 proto tcp
# VM2 -> node-exporter
ufw allow from 172.29.50.3 to 172.29.50.2 port 9100 proto tcp
ufw enable

# Docker-forwarded traffic mirrors the same policy (docker bypasses ufw):
iptables -I DOCKER-USER 1 -s 172.29.50.3 -p tcp -d 172.29.50.2 --dport 8427 -j ACCEPT
iptables -I DOCKER-USER 2 -p tcp -s ${F5_IP} -d 172.29.50.2 --dport 3000 -j ACCEPT
iptables -I DOCKER-USER 3 -p tcp -s 172.29.50.3 -d 172.29.50.2 --dport 9100 -j ACCEPT
iptables -I DOCKER-USER 4 -j DROP          # default deny for the rest of forwarded traffic
```

### 9.2 VM2 (172.29.50.3)

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow from ${MGMT_CIDR} to any port 22 proto tcp
# inbound scraping destinations are loopback for vmagent/pushgateway, and reachable LAN-only
# for node/blackbox/fortigate/oci exporters — restrict source to the monitoring/admin LAN:
for p in 9100 9115 9710 9710 9664 9091; do
  ufw allow from 172.29.50.0/24 to 172.29.50.3 port $p proto tcp
  ufw allow from ${MGMT_CIDR} to 172.29.50.3 port $p proto tcp
done
# no inbound port for vmagent itself (loopback only)
ufw enable
# DOCKER-USER mirror for any LAN-published exporter port:
iptables -I DOCKER-USER 1 -p tcp --dport 9100 -j DROP; ... # allow-listed first
```

### 9.3 VM3 (172.29.50.4)

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow from ${MGMT_CIDR} to any port 22 proto tcp
ufw allow from ${F5_IP}    to 172.29.50.4 port 8080 proto tcp   # Keycloak app (browser, via F5)
ufw allow from 172.29.50.2 to 172.29.50.4 port 8080 proto tcp   # Grafana OIDC discovery/JWKS
ufw allow from 172.29.50.3 to 172.29.50.4 port 9000 proto tcp   # KC metrics/health (VM2)
ufw allow from 172.29.50.3 to 172.29.50.4 port 9100 proto tcp   # node-exporter (M3 host)
ufw enable
# DOCKER-USER mirror: allow F5->8080, VM1->8080, VM2->9000 and 9100; DROP everything else forwarded.
```

> All `ufw allow from <src> to <ip> port` forms use the **specific destination IP** so a stray
> `0.0.0.0` publish is still blocked by the firewall.

### 9.4 Host hardening (all VMs)

```bash
# ops/harden-host.sh (idempotent)
apt install -y unattended-upgrades ufw fail2ban
sed -i 's/^Unattended-Upgrade::Automatic-Reboot[^;]*;/Unattended-Upgrade::Automatic-Reboot "true";/' /etc/apt/apt.conf.d/50unattended-upgrades
systemctl enable --now unattended-upgrades
# SSH hardening
sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin no/; s/^#?PasswordAuthentication.*/PasswordAuthentication no/; s/^#?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd
# fail2ban: sshd jail, 5 failures -> 10m ban
cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
maxretry = 5
bantime = 600
EOF
systemctl enable --now fail2ban
# journald retention
mkdir -p /etc/systemd/journald.conf.d
echo -e "[Journal]\nSystemMaxUse=2G\nMaxRetentionSec=30d" > /etc/systemd/journald.conf.d/size.conf
systemctl restart systemd-journald
# docker daemon
cat > /etc/docker/daemon.json <<'EOF'
{ "log-driver": "json-file", "log-opts": { "max-size": "20m", "max-file": "5" } }
EOF
systemctl restart docker
# chrony / ntpsec
apt install -y chrony && systemctl enable --now chrony
```
Remember: **no container mounts `/var/run/docker.sock`** in the new architecture (removed with Traefik).

---

## 10. Backup and restore

### 10.1 What to back up and where

| Asset | Tool | Target | Frequency | RPO | RTO |
|---|---|---|:---:|---:|---:|
| Grafana DB (sqlite at `onelast-data/grafana.db`) | `sqlite3 .backup` inside the stack (or `docker exec` with a database binary) or Grafana API export of dashboards/users | `vm1:/srv/backups/grafana` → off-host | daily | 24h | <1h (config+data restore) |
| Grafana dashboards / datasources (provisioning YAML) | Git + `tar` of `provisioning/` | same | git push + nightly | 24h | minutes |
| VictoriaMetrics data | **vmbackup** (official) each evening: `--snapshotNamePattern=...` + `vmbackup -storageDataPath=/storage -snapshot.createURL=... -dst=...` | `vm1:/srv/backups/vm` → off-host | daily (rotate 30d) | 24h | <4h (vmrestore) |
| vmauth.yml + secrets | tar (age-encrypted) | off-host | weekly + on-change | 7d | minutes |
| Keycloak Postgres | `docker exec keycloak-db pg_dump -U keycloak -Fc keycloak` | `vm3:/srv/backups/kc` → off-host | daily | 24h | <30m |
| Keycloak realm (idempotent import JSON) | admin-API export + `kc.sh export` snapshot | same | weekly | 7d | minutes |

Off-host transport: `restic`/`rclone` to the existing Veeam storage or an NFS share, **age-encrypted**
(age public key held outside the VM; SealedStorage). Retention: daily × 14, weekly × 8, monthly × 12.

### 10.1.1 Credential rotation (procedures)

All previously committed credentials are treated as **compromised** — rotate each once at migration
cutover, then on this cadence (or immediately on suspected exposure). `ops/rotate-secrets.sh <target>`
regenerates the host-side file and restarts the affected service; the *consuming side* must be updated
in the same change window:

| Credential | File (rotate) | Consuming side to update | Cadence |
|---|---|---|---|
| Grafana admin password | `machine1/.../secrets/grafana_admin_password` | (local only; OIDC is the real login) | 90d |
| Grafana OIDC client secret | `machine1/.../secrets/grafana_oidc_client_secret` | Keycloak client `grafana-nama` → Credentials → Secret; then `restart onetech` | 180d |
| SMTP password | `machine1/.../secrets/smtp_password` | smtp2go account; then `restart onetech` | 180d |
| vmauth Grafana user | `machine1/.../secrets/vmauth_grafana_password` | render (`./deploy.sh`) + Grafana datasource re-provision | 180d |
| vmauth vmagent user | `machine1/.../secrets/vmauth_vmagent_password` | render on VM1 **and** `machine2/.../secrets/vmagent_pass` must match → `restart vmagent` | 180d |
| vmagent remote-write pass | `machine2/.../secrets/vmagent_pass` | matches vmauth vmagent password (rotate both together) | 180d |
| Keycloak admin password | `machine3/.../secrets/kc_admin_password` | `kc.sh reset-password -u <user>` then `restart keycloak` | 90d |
| Keycloak DB password | `machine3/.../secrets/kc_db_password` | `ALTER ROLE keycloak WITH PASSWORD` in postgres, then `restart keycloak` | 180d |
| Exporter tokens (FortiGate/OCI) | `.env` (root-only) + consumer device/API key | exporter container restart | 180d |
| TLS keys (`vmauth_tls.key`, F5 key) | `ops/gen-ca.sh --renew` / F5 renewal | distribute new cert; `restart vmauth` | 1y (or on compromise) |

Rules: no secret in git (`git grep -iE 'password|secret|token'`), no secret in `docker inspect`
env (only `*_FILE`/`passwordFile`/rendered `0600` files), rotate on staff departure, rotate both
halves of a *pair* together (vmauth↔vmagent), and never reuse a value across roles.

### 10.2 Commands (ops/backup-m1.sh on VM1, ops/backup-m3.sh on VM3)

```bash
# VM3 — Keycloak Postgres
docker exec keycloak-db pg_dump -U keycloak -Fc -d keycloak \
  | age -r "$AGE_PUB" > /srv/backups/kc/kc-$(date +%F).dump.age
# VM3 — realm export (restorable JSON, no plaintext passwords omitted)
docker exec keycloak /opt/keycloak/bin/kc.sh export --realm grafana-namawater --file /tmp/realm.json
docker cp keycloak:/tmp/realm.json /srv/backups/kc/  && age ... 
# VM1 — VictoriaMetrics snapshot via vmbackup
curl -s -XPOST "http://victoria-metrics:8428/snapshot/create" > /tmp/snap.json
SNAP=$(jq -r .snapshot /tmp/snap.json)
docker run --rm -v victoria-metrics-data:/storage:ro -v /srv/backups/vm:/backup \
  victoriametrics/vmbackup:v1.151.0 -storageDataPath=/storage -snapshotName="$SNAP" \
  -dst=file:///backup
curl -s -XPOST "http://victoria-metrics:8428/snapshot/delete?snapshot=$SNAP"
# VM1 — Grafana
docker exec ${ONETECH_CONTAINER} sqlite3 /var/lib/grafana/grafana.db ".backup '/tmp/grafana.db'"
docker cp ${ONETECH_CONTAINER}:/tmp/grafana.db /srv/backups/grafana/grafana-$(date +%F).db
age -r "$AGE_PUB" < /srv/backups/grafana/grafana-$(date +%F).db \
  > /srv/backups/grafana/grafana-$(date +%F).db.age
# rotate
find /srv/backups -name '*.age' -mtime +14 -delete
```

### 10.3 Restore procedures

- **Grafana**: stop container → replace `grafana.db` → start. Config from provisioning is
  reproducible; dashboards regenerated.
- **VictoriaMetrics**: `vmrestore -src=file:///srv/backups/vm -storageDataPath=/storage`
  after rotating the live data dir, then start VM.
- **Keycloak**: restore the `.dump` into a fresh `postgres` (`pg_restore -Fc`) then start KC;
  realm import JSON is the deterministic fallback for clients/roles/users but loses DB-local
  sessions/tokens (acceptable for RPO 24h).
- **Restore testing**: quarterly full-drill (`ops/restore-drill.sh`) on a scratch VM1/VM3 copy.
  All five restore paths exercised and documented.

---

## 11. Monitoring the monitoring platform

Health/self-monitoring jobs (already in §4.2 scrape) plus alert rules (prometheus-format)

```yaml
groups:
- name: nama-platform
  rules:
  - alert: GrafanaDown
    expr: up{job="blackbox_http_probes",instance="https://cockpitnama.otech.om"} == 0
    for: 5m
  - alert: KeycloakUnreachable
    expr: up{job="blackbox_http_probes",instance="https://identitynama.otech.om"} == 0
    for: 5m
  - alert: EdgeCertExpiresSoon
    expr: probe_ssl_earliest_cert_expiry - time() < 21*24*3600   # blackbox tls_1_2 module
    for: 1h
  - alert: VMAgentDown
    expr: up{job="victoriametrics",instance="172.29.50.2:8428"} == 0
  - alert: VMWriteFlushing
    expr: vmagent_remotewrite_bytes_sent_total - (vmagent_remotewrite_bytes_sent_total offset 5m) <= 0
    for: 10m
  - alert: DiskAlmostFull (per host)
    expr: 100 - 100 * node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay"}
          / node_filesystem_size_bytes{mountpoint="/"} < 20
    for: 15m
  - alert: KeycloakDBDown
    expr: up{job="keycloak",instance="172.29.50.4:9000"} == 0
  - alert: InternalTLSRevoked
    expr: vmauth_user_requests_total{result="error"} > 0 or up{job="vmauth-self"} == 0
```
Deliver through Grafana alerting (cloud-appropriate severity → SMTP + optional PagerDuty). Also add
`cron` + `systemd timers` for: nightly backup success (restic/systemd status check), cert pulling
(blackbox), and `docker ps` healthcheck summary (`ops/health-report.sh`, emitted every 5m into
Grafana via node_exporter textfile collector or vmagent job).

---

## 12. Security validation (how to PROVE it)

```bash
# 1) Only intended ports listening:
ss -lntup
#   Expect on VM1: 22, 3000(172.29.50.2), 8427(172.29.50.2), 9100(172.29.50.2)
#   On VM2: 22, 9100/9115/9710/9091(bound to LAN/loopback), no :8429 to the world
#   On VM3: 22, 8080(172.29.50.4), 9000(172.29.50.4), 9100(172.29.50.4); NO 5432 on the host
# 2) Containers minimal:
docker ps --format '{{.Image}} {{.Ports}} {{.Status}}'
docker inspect vmauth  | jq '.[0].Config.Env'          # must contain NO plaintext secrets
docker inspect grafana  | jq '.[0].Config.Env'          # __FILE vars, no password values
# 3) No secret in image history/env:
docker exec grafana   printenv | grep -iE 'PASSWORD|SECRET|TOKEN' || true   # expect GF_*__FILE only paths
docker exec keycloak  printenv | grep -iE 'PASSWORD|SECRET'                  # expect none (entrypoint exported)
# 4) Firewall state:
ufw status numbered
iptables -L DOCKER-USER -n --line-numbers
# 5) External surface (from a non-privileged box):
nmap -p443 cockpitnama.otech.om              # only 443 open externally (F5)
nmap -sS -p 3000,8080,8427,8428,9000,5432,9102 172.29.50.2 172.29.50.4   # from F5/management expect filtered
curl -sk https://172.29.50.2:8428/health || echo "8428 not reachable: OK" # from outside deny
# 6) TLS checkpoints:
openssl s_client -connect cockpitnama.otech.om:443 -servername cockpitnama.otech.om -tls1_2 </dev/null | grep -E 'Protocol|Cipher'
openssl s_client -connect 172.29.50.2:8427 -servername nama-mon-stack -CAfile secrets/vmauth_ca.pem </dev/null | grep -E 'Verify|Subject'
# 7) auth gate:
curl -si https://cockpitnama.otech.om/login/generic_oauth | head -3   # 302 -> identitynama
# 8) logs/audit:
journalctl -u docker -n 50 --no-pager
docker logs --tail 20 keycloak vmauth grafana
auditctl never needed — journald retention set; add `auditd` if the org requires AIDE/audit rules.
```

---

## 13. Image and dependency pinning

| Component | Image | Pin (current, verify at build) |
|---|---|---|
| VictoriaMetrics (+ vmauth, + vmagent) | `victoriametrics/victoria-metrics`, `victoriametrics/vmauth`, `victoriametrics/vmagent` | **`v1.151.0`** (OSS latest, contains the 2026-08 Basic-Auth security fix); prefer the **`v1.148.3` LTS** line if the org standardizes on LTS |
| Grafana | `otech-grafana` (custom, rebuild off the official base) | Base `grafana/grafana:13.2.2` (2026-09-15); bump the Dockerfile base and re-pin |
| Keycloak | `quay.io/keycloak/keycloak` | `26.7.4` (2026-09-16); sticky to 26.x line |
| PostgreSQL | `postgres` | `16` (current 16.x; **also 17+ supported** — recommend staying on the installed 16 for the migration, then schedule the next major: `16` → latest LTS) |
| node-exporter | `prom/node-exporter` | `v1.12.1` (2026-07-14) |
| blackbox-exporter | `quay.io/prometheus/blackbox-exporter` | `v0.28.0` (2025-12-04) |
| pushgateway | `prom/pushgateway` | pin the tagged release used today (no `latest`) |
| fortigate / OCI / esmacancs mirrors | `ghcr.io/esmacancs/...` | pin whatever digest is currently in `.env`; rebuild pinned from upstream releases |

Mechanics:
- Replace `:tag` with `:tag@sha256:…` in compose; `ops/pin-images.sh` resolves digests from a
  registry pull and rewrites the files, so the pinned digest is always reproducible.
- Provenance: prefer images that ship signed manifests (Keycloak/Grafana/VM do via GHCR/quay
  trust); `cosign verify` where available; scan with `trivy image` on each pinned tag and store an
  SBOM (`syft`) per tag in the repo (`artifacts/sbom/`).
- CVE tracking: trivy `--exit-code 1 --severity HIGH,CRITICAL` in CI; review monthly.
- Private mirror: if upgrades must be air-gapped, mirror the pinned tags + digests into a private
  registry (e.g. Harbor) and point compose at `registry.otech.om/victoria-metrics:<tag>@digest`.
- Upgrade cadence: patch ≤ monthly (auto via the pinned source), minor quarterly on the 1st Sunday,
  major twice a year; always upgrade **Keycloak `26.0.x → 26.7.x` under §7's run-step** and rerun
  `vmbackup` snapshot before VM upgrades; document `docker compose pull` + `up -d` + `ps` validation.

---

## 14. HA / failure analysis (exactly 3 VMs — SPOFs are real)

Single points of failure and blast radius:

| Failure | Auth | Grafana UI | Live sessions | Metric collection | History | Alerting | Backups |
|---|---|---|---|---|---|---|---|
| **VM1 down** | unaffected (auth on VM3) | **down** | **lost** | **STALLED** (writes queue at vmagent on VM2 disk up to `maxDiskUsagePerURL`) | safe (VM2 buffers; restorable) | no queries/alerts evaluate | VM1 backups absent |
| **VM2 down** | unaffected | up | up | **down** (no scraping) | safe | staleness alerts fire | VM1/VM3 backups continue |
| **VM3 down** | **down** | up but **no login** (OIDC unavailable) | existing sessions remain until cookie expiry | unaffected (metrics don't need KC) | safe | alert channel still works (SMTP out) | VM3 backups absent |
| **F5 down** | internet-facing 443 down → **both apps unreachable** from the user network | via LAN VIP only | browsers can't refresh token; Cookie sessions still valid until expiry | unaffected | safe | unaffected (server-side) | unaffected |
| **DNS down** (public) | name resolution fails → same as F5 | same | | unaffected | | | |
| **Postgres corrupt** | **down** after KC restart | up until you try to log in | existing sessions can linger until they hit KC | | | | **restore required** |
| **VM corruption** (storage) | unaffected | queries serve stale/partial | | | affected until restore | `vm_data_too_few_partitions` alerts | restore within RTO |
| cert expiry (edge) | browser warnings → login blocked in practice | UIs warn/broken | | | | | |

Design consequences (stay truthful about a 3-node deployment):
- **No active HA** — that is inherent to 3 app servers. Mitigations: rapid cold restart (compose
  boot < 1 min), dependency separation (auth ≠ metrics ≠ UI), at-least-once buffering at vmagent,
  and the toolbox above for restart/restore.
- The **only** writes to VM happen from VM2's vmagent, buffered with back-pressure; a VM1 outage
  does not lose data historically stored (the `remoteWrite` queues on VM2 disk).
- If strict HA is ever required, the migration path is horizontal scaling of the same compose
  (a second cow of VM1 + F5 pool on 3000, and shared Postgres), but that is **out of scope** here.

---

## 15. Migration procedure (preserve everything)

### Phase 0 — Workspace (repo hygiene)
```bash
cd grafana-key-vmagent-project
git rm -r multi-machine/machine1-nama-mon-stack/traefik multi-machine/machine3-nama-auth-vm/traefik 2>/dev/null || true
# or `git rm -r --cached` and delete later; keep single-machine/ unaffected.
echo -e "secrets/\n.env\n*.age\n" >> .gitignore
```
### Phase 1 — Backup (on each VM, before ANY change)
Run §10 on VM1 and VM3. Verify a file exists with a nonzero size; write down RPO timestamp.

### Phase 2 — Validation of current state
`docker compose config` passes; login to grafana via OIDC works; `curl 172.29.50.2:8428/health` = 200;
vmagent shows all targets up; note the exact `.env` values replaced by secrets.

### Phase 3 — Build the new config on VM1
1. `mkdir -p secrets && chmod 700 secrets`
2. `ops/gen-ca.sh` (creates CA + vmauth server cert/key) → secrets/vmauth_ca.pem + secrets/vmauth_tls.{crt,key}
3. `ops/gen-secrets.sh` → all secret files (modes 0600)
4. Ensure `victoria-metrics` stops publishing 8428 (remove `ports:` from its service)
5. Start `vmauth` WITH TLS + new auth users; validate: `docker logs vmauth` + `curl -k https://172.29.50.3@...` not yet — first from VM1 itself:
   `curl -k -u vmagent:$(cat secrets/vmauth_vmagent_password) https://vmauth:8427/api/v1/query?query=up`
6. Point Grafana datasource at `https://vmauth:8427` with `$__file{}` secret; OIDC env → `GF_*__FILE`; restart Grafana; verify dashboards render.

### Phase 4 — Build config on VM2
7. Add cipher files `secrets/vmauth_ca.pem`; switch vmagent from
   `http://172.29.50.2:8428/api/v1/write` to the HTTPS vmauth URL + file auth + CA (remove the direct URL).
8. `scrape.yml`: keep production jobs; delete the `traefik` job; add self jobs (§4.2). Reload
   (`docker restart vmagent`). Watch `vmagent` logs + Grafana "Writing in VictoriaMetrics" panels.

### Phase 5 — Build config on VM3
9. `secrets/kc_*`; new `docker-compose.yml` (no 8080→?:8080 world publish; entrypoint export; KC26
   management port 9000). **Upgrade Keycloak 26.0 → 26.7.4** as the single motion (DB migration is
   automatic at first start of a newer patch; verify logs; keep the `26.0` image tag for rollback).
10. Import the preserved realm JSON newly with `--override true`? No — DB persists, realm already present; only prove login works.

### Phase 6 — Cutover
11. Apply `ops/ufw-*.sh` on all three VMs and the F5 VIP rewrite (F5 pool member `172.29.50.2:3000`
    + member `172.29.50.4:8080`; remove any Traefik 9102/9091 pool members; confirm `X-Forwarded-Proto: https` is injected and `X-Forwarded-For` trusted).

### Phase 7 — Post-cutover verification set
```bash
# on every VM:
ss -lntup                # exactly the §12 list
ufw status numbered
docker ps
# functional:
curl -si https://cockpitnama.otech.om/login/generic_oauth | head -3
curl -si https://identitynama.otech.om/realms/grafana-namawater/.well-known/openid-configuration | grep HTTP
# remote_write proof:
curl -k -u "vmagent:$(cat secrets/vmauth_vmagent_password)" https://vmauth:8427/api/v1/query_range?query=up\&start=-5m\&end=now  | jq '.data.result|length'   # > 0
```

### Phase 8 — Decommission
12. After 2 weeks steady-state: remove obsolete `traefik/` artifact dirs from the repo, delete the
    `traefik` services in compose, remove docker labels, disable any old F5 pool member pointing at
    Traefik. Keep single-machine lab untouched.

---

## 16. Rollback procedure

Rollback = revert to the checked-out previous commit (old compose) + restart the stack.

```bash
# On the affected VM:
docker compose -f docker-compose.yml.backup-prehardening up -d   # pre-staged copy
# VM1 rollback specifics:
#  - restore old compose (no $__file secrets, no __FILE env): ensure old .env has real values
#  - if remote_write URL changed, VM2 stays compatible: old URL http(s)://172.29.50.2:8428 must be
#    reachable again → re-add `ports: [8428]` in the rollback compose and remove UFW 8427 rules.
# VM3 rollback: keep `keycloak:26.0` image tag pulled; swap compose back; DB is backward-compatible
#   (Postgres schema unchanged for 26.0->26.7 readers if you roll back before 24h; after that, restore
#   the Phase-1 pg_dump if the newer minor has written incompatible schema).
ufw --force disable        # and remove /etc/ufw rules if the rollback needs open ports
```
CRM: whenever a migration step touches a service, the previous compose file is saved as
`docker-compose.yml.pre-<date>` **and** a full VM snapshot (VMware/OCI snapshot) is taken beforehand
for the immediate-undo path. Firewall rollback = `ufw reset`.

---

## 17. Security checklist

- [ ] **No plaintext passwords in Git** — grep `-rEi 'pass(word)?|secret|token' .git --include=*.yml --include=*.example`
- [ ] **All credentials rotated** (grafana admin, OIDC secret, SMTP, KC DB, KC admin, vmagent creds)
- [ ] **Default-deny firewall enforced** on VM1/VM2/VM3 (`ufw status` shows default DROP)
- [ ] **PostgreSQL private only** — no host 5432 listener (`ss` check), kcnet only
- [ ] **VictoriaMetrics private only** — `8428` unbound; read/write via vmauth
- [ ] **vmagent + exporters private only** — loopback or restricted LAN bind
- [ ] **HTTPS everywhere appropriate** — user plane uses F5 TLS; metric plane uses internal-CA TLS
- [ ] **F5 backend TLS model decided (Option A)** and documented with the VLAN/ACL condition
- [ ] **Keycloak OIDC configured** — browser `authorization_code`, PKCE, `realm_access.roles` mapping
- [ ] **Grafana local login disabled** — `basic`/`login_form` off, anonymous off, signup off
- [ ] **MFA evaluated** — TOTP enforced for admin-role users (KC policy)
- [ ] **Docker hardened** — read-only where possible, cap_drop/no-new-privileges, resource limits, no docker.sock mounts, healthChecks all around
- [ ] **Images pinned to digest** — `pin-images.sh` output committed
- [ ] **Backups encrypted** (age) + **off-host**
- [ ] **Restore tested** — quarterly drill documented (`ops/restore-drill.sh`)
- [ ] **Certificate monitoring enabled** — blackbox `probe_ssl_earliest_cert_expiry` alert
- [ ] **Disk monitoring enabled** — node filesystem alerts ≥20% free
- [ ] **Audit logging enabled** — journald retention, fail2ban, docker log limits, KC events on

---

## 18. Unattended provisioning (fresh Ubuntu hosts)

If the stack starts on **new** hosts instead of migrating the existing 3 VMs, the repo
contains a fully unattended path (the equivalent of §15 Phase 3–5, automated):

```
# on your admin workstation (Linux, WSL, or Git-Bash):
#   1. machines first get IP + SSH via cloud-init (ops/cloud-init/*) OR a DHCP reservation
#   2. then run the one-shot provisioner — the 3 positional args are the
#      provider-assigned STATIC IPs (they are written into each machine's .env
#      and passed to bootstrap + UFW):
ops/provision-all.sh <MON_IP> <STORAGE_IP> <AUTH_IP> \
    --user ubuntu --mgmt-cidr 10.0.10.0/24 --f5-ip 172.29.50.1 --gateway 172.29.50.1
```

`provision-all.sh` does, per machine and fully unattended:
1. waits for SSH; 2. pushes the machine tree + `ops/` to `/opt/nama/<role>/` (tar-over-SSH,
   root-owned); 3. runs `ops/bootstrap.sh <role>` (hostname, optional `--set-ip` netplan,
   Docker Engine + compose plugin, envsubst/ufw/openssl, sysctl baseline); 4. generates
   secrets (`gen-secrets.sh`) + internal CA (`gen-ca.sh`) **once** and distributes them
   (incl. `vmauth_ca.pem` → VM2); 5. deploys the stack (`deploy.sh` renders vmauth+datasource
   on VM1; `docker compose up -d` elsewhere); 6. applies the per-VM firewall (UFW +
   DOCKER-USER) and re-probes SSH; 7. runs `health-report.sh` and prints the hand-off list.

**IP assignment — Ubuntu does not self-IP this stack.** Choose one:

| Method | Zero-touch? | Notes |
|---|---|---|
| **DHCP reservation** keyed to MAC (recommended) | yes | NIC stays default-DHCP; server hands out exactly `172.29.50.2/3/4`. No `--set-ip`. |
| **cloud-init netplan** (ops/cloud-init/network-config-example + user-data-example.yaml) | yes | inject as NoCloud seed / VMware guestinfo / autoinstall; deterministic, no DHCP dependency. |
| `--set-ip` in bootstrap | partial | safe only when the NIC is already on the 172.29.50.0/24 VLAN (SSH session drops on IP change). |

Release guidance: use **24.04 LTS or 26.04 LTS**. 25.04/25.10 are non-LTS and EOL within
~9 months; `bootstrap.sh` warns (and continues) on non-LTS releases.

---

## Files introduced (this doc → repo)

```
multi-machine/
  PRODUCTION-SECURITY-DESIGN.md        # THIS document
  machine1-nama-mon-stack/{docker-compose.yml, .env.example, vmauth.yml.tpl,
                           deploy.sh, provisioning/datasources/victoriametrics.yml.tpl}
  machine2-namastorage/{docker-compose.yml, .env.example, scrape.yml.tpl,
                        blackbox.yml, deploy.sh}
  machine3-nama-auth-vm/{docker-compose.yml, .env.example}
  ops/{gen-ca.sh, gen-secrets.sh, rotate-secrets.sh, ufw-m1.sh, ufw-m2.sh, ufw-m3.sh,
       harden-host.sh, backup-m1.sh, backup-m3.sh, restore-drill.sh, health-report.sh,
       pin-images.sh, bootstrap.sh, provision-all.sh,
       cloud-init/{user-data-example.yaml, network-config-example}}
```