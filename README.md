# NAMA Monitoring Stack — Keycloak SSO + Traefik Edge + Centralized Traffic Monitoring

> **⚠ Production multi-machine deployment (F5-backed) — superseding doc**
> The enterprise deployment uses the external **F5** as the TLS edge and has **no Traefik /
> Nginx / HAProxy on the VMs**. The authoritative production design, port matrix, firewall
> rules, secrets model, backups, migration plan and rollback are in
> **[multi-machine/PRODUCTION-SECURITY-DESIGN.md](multi-machine/PRODUCTION-SECURITY-DESIGN.md)**
> (with rewritten `docker-compose.yml` / `vmauth.yml.tpl` / `scrape.yml` / `.env.example`
> files and `multi-machine/ops/` hardening scripts).
>
> Everything below that refers to the **multi-machine Traefik edge** is historical/superseded
> (the `multi-machine/*/traefik/` dirs have been **deleted** from this tree; migration Phase 0 in
> the design doc records that removal).
> Only the **single-machine lab** variant (a single Docker host, Traefik + oauth2-proxy
> + Keycloak on loopback, for local validation) still matches the Traefik content below —
> see §6 and §21. ForwardAuth for that lab must point at
> `http://oauth2-proxy:4180/oauth2/auth` (the decision endpoint).

This document describes how to extend the **existing 3-machine NAMA monitoring deployment**
with:

- **Traefik** as the TLS-terminating reverse-proxy entry point for all user-facing URLs
- **Keycloak** as SSO/authentication (already deployed on Machine 3 — kept, hardened)
- **Centralized traffic observability** across all machines (Traefik metrics + access logs → VictoriaMetrics → Grafana)

It also shows how the **same architecture can be replicated on a single machine**
(all-in-one), and how the multi-machine variant maps onto the existing 3-box layout.

---

## Table of Contents

0. [Production multi-machine design (F5-backed, no proxy on VMs)](multi-machine/PRODUCTION-SECURITY-DESIGN.md)
1. [Goal](#goal)
2. [Current Architecture (existing deployment)](#2-current-architecture-existing-deployment)
3. [Findings / Issues in the existing setup](#3-findings--issues-in-the-existing-setup)
4. [Architecture Decision](#4-architecture-decision)
5. [Proposed Architecture — Multi-Machine](#5-proposed-architecture--multi-machine)
6. [Single-Machine (All-in-One) Variant](#6-single-machine-all-in-one-variant)
7. [Deployment Changes per Machine](#7-deployment-changes-per-machine)
8. [Docker Compose Configuration](#8-docker-compose-configuration)
9. [Traefik Configuration](#9-traefik-configuration)
10. [Keycloak Configuration](#10-keycloak-configuration)
11. [vmagent Configuration](#11-vmagent-configuration)
12. [Grafana Dashboards & PromQL](#12-grafana-dashboards--promql)
13. [Access Logs](#13-access-logs)
14. [DNS](#14-dns)
15. [Firewall / Networking](#15-firewall--networking)
16. [Security Boundaries](#16-security-boundaries)
17. [Testing / Validation](#17-testing--validation)
18. [Failure Testing & HA](#18-failure-testing--ha)
19. [Rollback](#19-rollback)
20. [Optional Roadmap](#20-optional-roadmap)
21. [Project Layout & Quickstart](#21-project-layout--quickstart)

---

## 1. Goal

```
Internet / Users
       |
       v
    Traefik
       |
  +----+----+
  |         |
  v         v
Keycloak    Grafana
  |         |
  +-- Auth -+
  |
  +--> other monitoring services
```

- Traefik becomes the **single entry point** for all HTTP(S) traffic
- Keycloak provides **SSO** for monitoring URLs
- All edge traffic (requests/sec, status codes, latency, per-hostname, per-backend, per-machine) is collected centrally in VictoriaMetrics and visualized in Grafana
- Internal monitoring APIs (VictoriaMetrics, vmauth, vmagent, exporters, Traefik dashboard) stay **internal**

---

## 2. CURRENT Architecture (existing deployment)

### 2.1 Machine inventory

| | Machine 1 – `nama-mon-stack` | Machine 2 – `namastorage` | Machine 3 – `nama-auth-vm` |
|---|---|---|---|
| Internal IP | `172.29.50.2` | `172.29.50.3` | `172.29.50.4` |
| Role | Monitoring hub (Grafana + VictoriaMetrics) | Scraper / collector hub | IdP (Keycloak) |
| Compose dir | `~/nama-stack` | `~/nama-stack` | `~/keycloak` |
| Docker networks | compose default bridge | compose default bridge | `kcnet` (bridge) |

### 2.2 Containers / services today

**Machine 1 — `nama-mon-stack` (`~/nama-stack`)**

| Container | Image | Published port | Notes |
|---|---|---|---|
| `victoria-metrics` | `${VICTORIA_IMAGE}` (victoriametrics latest) | `8428:8428` (all IFs) | retention 30d, storage `./victoria-metrics-data` |
| `vmauth` | `victoriametrics/vmauth:latest` | `172.29.50.2:8427:8427` | `vmauth.yml` (generated from `.tpl` via envsubst). Currently **bypassed** |
| `onetech` (Grafana 13) | `otech-grafana:13` | `3000:3000` (all IFs) | root URL `https://cockpitnama.otech.om`; OIDC → Keycloak realm `grafana-namawater`, client `grafana-nama`; SMTP2GO |
| `node-exporter` | ghcr prom/node-exporter | `9100:9100` | |

**Machine 2 — `namastorage` (`~/nama-stack`)**

| Container | Image | Published port | Notes |
|---|---|---|---|
| `vmagent` | `victoriametrics-vmagent` | `8429:8429` | `-promscrape.config=./scrape.yml`; remote-write `http://172.29.50.2:8428/api/v1/write` (direct, unauthenticated) |
| `node-exporter` | quay prom/node-exporter v1.6.1 | `9100:9100` | |

M2 also runs (bare-metal, not compose): **blackbox_exporter** `:9115`, **FortiGate exporter** `:9710`, **veeam pushgateway** `:9091`.
Its `scrape.yml` (~200 targets) monitors OCI production VMs (10.160.x), FortiGate, the OCI exporter at `172.29.50.2:8100`, and OCI backup exporters (`10.8.123.243:9108/9109`).

**Machine 3 — `nama-auth-vm` (`~/keycloak`)**

| Container | Image | Published port | Notes |
|---|---|---|---|
| `postgres` | `postgres:16` | none (kcnet) | DB `keycloak`, healthcheck, volume `./postgres` |
| `keycloak` | `quay.io/keycloak/keycloak:26.0` | `172.29.50.4:8080:8080` | `KC_PROXY=edge` + `xforwarded`; `KC_HOSTNAME=identitynama.otech.om`, strict host & strict HTTPS; health + metrics enabled |

### 2.3 Current URLs

| URL | Backend | Notes |
|---|---|---|
| `https://cockpitnama.otech.om` | Grafana on M1 `:3000` | through existing F5/LTM, OIDC to Keycloak |
| `https://identitynama.otech.om` | Keycloak on M3 `:8080` | through existing F5/LTM; `KC_PROXY=edge` already trusts a fronting LB |

### 2.4 Current traffic flow (ASCII)

```
 Internet / Users
        |
        v
   F5 / LTM (existing edge; TLS usually terminated here or passed through)
   ├── vhost cockpitnama.otech.om  ──►  M1:3000  (Grafana/onetech)
   └── vhost identitynama.otech.om ──►  M3:8080  (Keycloak)

 Monitoring / East-West:
   vmagent (M2:8429) ──remote-write──► VictoriaMetrics (M1:8428) ◄── Grafana (M1:3000) datasource
   blackbox (M2:9115) ──probes──► public https URLs
   Grafana (M1) ──OIDC redirect──► identitynama (M3)
```

### 2.5 Monitoring components / config details

- **Grafana** (M1): native generic-oauth OIDC; realm roles `grafana-admin` / `grafana-editor` mapped via
  `GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH`.
- **vmagent** (M2): single central scraper, `scrape_interval: 15s`, remote-write to M1.
- **VictoriaMetrics** (M1): `--retentionPeriod=30`, storage `./victoria-metrics-data`.
- **vmauth** (M1): auth gateway `172.29.50.2:8427` (exists, currently bypassed — see §3).
- **Blackbox** (M2): modules `http_2xx` (strict SSL) and `http_2xx_insecure` (wildcard/internal), probing `*.nama.om` / `*.owwsc.nama.om`.

---

## 3. Findings / Issues in the existing setup

### CURRENT (already wrong — fix regardless of Traefik)

1. **Plaintext secrets**: `.env` (M1) contains GF admin `P@ssw0rd`, SMTP password, Keycloak client secret; M3 `.env` holds KC DB + admin passwords in the clear. Move to `chmod 600 .env` and reuse the existing `gpg -d .env.gpg` pattern (already used by M1's `deploy.sh`).
2. **VictoriaMetrics `8428`, Grafana `3000`, node-exporter `9100` published on all host interfaces without auth**. `vmauth` (`8427`) exists with Basic-auth creds but is bypassed (M2 remote-write goes straight to `8428`).
3. **Monitoring stack not self-monitored**: the M1/M2/M3 `node-exporter` containers are not in any scrape config. Fix by adding a `node-self` job (§11).
4. **Subnet overlap risk**: the machines' LAN is `172.29.50.0/24`, inside Docker's default bridge auto-assign range (172.17–172.30). A compose network could be auto-assigned `172.29.x/16` and collide. Pin explicit `ipam` subnets on every stack (§8).
5. **No backup for Keycloak Postgres** in the README. Add nightly `pg_dump`.

### PROPOSED (this project)

- Insert **Traefik** as the TLS edge for the two public hostnames (and future ones).
- Add **Prometheus edge metrics** for Traefik on the machines that expose user-facing services.
- Centralize per-machine traffic visibility in the existing VM → Grafana pipeline.

### OPTIONAL (hardening, not blocking)

- Rotate KC client secret + DB/admin passwords.
- Re-enable vmauth for authenticated remote-write and Grafana datasource auth.
- Add local vmagent per machine (scrape HA) and Promtail+Loki for log dashboards.

---

## 4. Architecture Decision

| Option | Verdict | Why |
|---|---|---|
| Traefik on **all 3** machines | ✗ rejected | M2 has no user-facing services; a Traefik there only serves its own dashboard → unnecessary complexity |
| Traefik on **one hub machine (M1 only)** | ✗ rejected | Turns M1 into a hard dependency for **all authentication**; M1 outage kills login everywhere even though Keycloak (M3) is healthy |
| Traefik on **M1 + M3** (machines that serve users) | ✔ chosen | Local TLS edge next to each public service; identical config; auth path stays independent of the monitoring hub; metrics centralize easily |

**Reasoning**

- M1 hosts Grafana (and the whole monitoring hub); M3 hosts Keycloak (SSO). These are the only two machines whose services the browser actually reaches, so **two Traefik instances — one per public machine — cover 100% of user-facing traffic**.
- Keeping Keycloak's edge **co-located on M3** means a plaintext monitoring-hub outage (M1) does not take down SSO. Cross-machine auth relaying would create that coupling for no benefit.
- Both instances share the **same static/dynamic config**, so a 3rd Traefik can be dropped onto M2 later (copy-paste) if you ever expose `vmagent.<domain>` etc.
- F5/LTM (already in front per README comments) keeps DNS/VIP/health-check semantics; point its pools at `M1:443` and `M3:443`.

**HA stance (see §18):** no active HA for Traefik or Keycloak at this scale. Documented failure behavior + alerts on `up{job=...}`. Keycloak + its single Postgres remain the SSO single point of failure — acceptable for one environment; 2-node Keycloak is OPTIONAL.

---

## 5. PROPOSED Architecture — Multi-Machine

```
                        Internet / Users
                               │ TLS 443 (+ 80 for redirect / ACME)
                               ▼
                     F5 / LTM (existing) — or direct DNS
              ┌──────────────────┴──────────────────┐
              ▼                                     ▼
   M1 nama-mon-stack 172.29.50.2          M3 nama-auth-vm 172.29.50.4
   ┌────────────────────────────┐        ┌──────────────────────────────┐
   │ Traefik :80 :443 :9102     │        │ Traefik :80 :443 :9102        │
   │  ├─ cockpitnama.otech.om   │        │  ├─ identitynama.otech.om     │
   │  │   → onetech:3000        │        │  │   → keycloak:8080 (kcnet)  │
   │  ├─ grafana.otech.om (opt) │        │  │   → keycloak admin console │
   │  ├─ vm.otech.om (internal) │        │  │      [IP-allowlisted]      │
   │  └─ traefik.otech.om dash  │        │  └─ traefik.otech.om dash     │
   │  VM 8428 / vmauth 8427     │        │  keycloak:8080 ──► postgres   │
   │  Grafana:3000 node:9100    │        │  node-exporter:9100 (NEW)     │
   └────────────┬───────────────┘        └────────────┬──────────────────┘
                │                                     │
          remote writes                              │
                ▼                                     │
   M2 namastorage 172.29.50.3                        │
   ┌─────────────────────────────┐                   │
   │ vmagent 8429                │                   │
   │ node-exporter 9100          │                   │
   │ blackbox 9115               │                   │
   │ fortigate 9710 pushgw 9091  │                   │
   └────────────┬────────────────┘                   │
                │                                    │
                │  scrape: traefik:9102 (M1+M3),     │
                │  node-self 9100, keycloak 8080     │
                └────────────┬───────────────────────┘
                             ▼
                   VictoriaMetrics (M1, 8428/8427)
                             ▼
                       Grafana (M1) — traffic dashboards
```

**Flows**

| Flow | Path |
|---|---|
| Edge (user → app) | Browser → F5 → Traefik (TLS) → backend (Grafana on kcnet/KC on kcnet) |
| Auth (Grafana) | Grafana OIDC → `https://identitynama.otech.om` → M3 Traefik → Keycloak |
| Auth (internal UIs, optional) | Browser → Traefik router → ForwardAuth → oauth2-proxy → Keycloak → backend |
| Metrics | Traefik `/metrics` (M1+M3 `:9102`) + keycloak `/metrics` → M2 vmagent → VM → Grafana |
| Logs | Traefik JSON access logs → local disk (rotate); OPTIONAL Promtail → Loki |

---

## 6. Single-Machine (All-in-One) Variant

The whole stack can be collapsed onto **one host**. This is useful for a lab, a DR site, or a smaller deployment where the 3-way split is unnecessary. Everything connects over a single docker network, so **no cross-machine firewall rules** are needed.

```
Internet / Users
       │ 443 (+80 redirect/ACME)
       ▼
   ┌────────────────────────────────────────────┐
   │  ONE HOST  (e.g. 172.29.50.2)              │
   │  ┌──────────┐                              │
   │  │ Traefik  │  :80 :443 :9102 :9091(dash)  │
   │  └────┬─────┘                              │
   │       │  docker network "mon-net"          │
   │       ▼                                    │
   │  ┌──────────────┐  ┌─────────────────────┐ │
   │  │ grafana:3000 │  │ keycloak:8080       │ │
   │  │ (OIDC)       │  │        │ postgres:5432│
   │  └──────┬───────┘  └────────┬────────────┘ │
   │         ▼                   │              │
   │  ┌──────────────────────────┘              │
   │  │ victoria-metrics:8428  vmauth:8427      │
   │  └──────────────┬────────────────────────┘ │
   │                 ▼                          │
   │  ┌──────────────────────────┐              │
   │  │ vmagent:8429 (scrapes     │              │
   │  │  traefik, node, "self")   │              │
   │  └──────────────────────────┘              │
   │  node-exporter:9100 blackbox:9115 (opt)    │
   └────────────────────────────────────────────┘
```

### Single-host composition (one `docker-compose.yml`)

```yaml
version: "3.8"

networks:
  mon-net:
    name: mon-net
    driver: bridge
    ipam:
      config:
        - subnet: 10.90.0.0/16

services:
  traefik:
    image: traefik:v3.2
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "9102:9102"      # metrics
      - "9091:8080"      # dashboard (internal)
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik:/etc/traefik:ro
      - ./traefik/certs:/etc/traefik/certs
      - ./traefik/logs:/var/log/traefik
    networks: [mon-net]
    command:            # shared static options — see §9
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=mon-net"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--providers.file.watch=true"
      - "--entryPoints.web.address=:80"
      - "--entryPoints.web.http.redirections.entryPoint.to=websecure"
      - "--entryPoints.web.http.redirections.entryPoint.scheme=https"
      - "--entryPoints.websecure.address=:443"
      - "--entryPoints.metrics.address=:9102"
      - "--entryPoints.traefik.address=:8080"
      - "--api.dashboard=true"
      - "--api.insecure=false"
      - "--accesslog=true"
      - "--accesslog.format=json"
      - "--accesslog.filepath=/var/log/traefik/access.log"
      - "--metrics.prometheus=true"
      - "--metrics.prometheus.entryPoint=metrics"
      - "--metrics.prometheus.addEntryPointsLabels=true"
      - "--metrics.prometheus.addServicesLabels=true"
      - "--certificatesResolvers.letsencrypt.acme.email=it@otech.om"
      - "--certificatesResolvers.letsencrypt.acme.storage=/etc/traefik/certs/acme.json"
      - "--certificatesResolvers.letsencrypt.acme.httpChallenge.entryPoint=web"

  victoria-metrics:
    image: victoriametrics/victoria-metrics:latest
    container_name: victoria-metrics
    restart: unless-stopped
    ports:
      - "8428:8428"
    command: ["--storageDataPath=/storage", "--retentionPeriod=30"]
    volumes:
      - ./victoria-metrics-data:/storage
    networks: [mon-net]

  vmauth:                      # OPTIONAL hardening: authenticated gateway
    image: victoriametrics/vmauth:latest
    container_name: vmauth
    restart: unless-stopped
    ports:
      - "172.29.50.2:8427:8427"   # bind to internal IP only
    volumes:
      - ./vmauth.yml:/etc/vmauth.yml
    command: ["-auth.config=/etc/vmauth.yml"]
    networks: [mon-net]

  grafana:
    image: grafana/grafana-oss:11.3.0
    container_name: grafana
    restart: unless-stopped
    environment:
      - GF_SERVER_ROOT_URL=https://grafana.otech.om
      - GF_AUTH_GENERIC_OAUTH_ENABLED=true
      - GF_AUTH_BASIC_ENABLED=false
      - GF_AUTH_LOGIN_FORM_ENABLED=false
      - GF_SECURITY_ADMIN_USER=${GF_SECURITY_ADMIN_USER}
      - GF_SECURITY_ADMIN_PASSWORD=${GF_SECURITY_ADMIN_PASSWORD}
      - GF_AUTH_GENERIC_OAUTH_CLIENT_ID=grafana-nama
      - GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=${KC_GRAFANA_CLIENT_SECRET}
      - GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://identitynama.otech.om/realms/grafana-namawater/protocol/openid-connect/auth
      - GF_AUTH_GENERIC_OAUTH_TOKEN_URL=https://identitynama.otech.om/realms/grafana-namawater/protocol/openid-connect/token
      - GF_AUTH_GENERIC_OAUTH_API_URL=https://identitynama.otech.om/realms/grafana-namawater/protocol/openid-connect/userinfo
      - GF_AUTH_GENERIC_OAUTH_SCOPES=openid profile email
    volumes:
      - ./grafana-data:/var/lib/grafana
      - ./provisioning:/etc/grafana/provisioning
    networks: [mon-net]
    labels:                    # Traefik discovers by label
      - "traefik.enable=true"
      - "traefik.http.routers.grafana.rule=Host(`grafana.otech.om`) || Host(`cockpitnama.otech.om`)"
      - "traefik.http.routers.grafana.entrypoints=websecure"
      - "traefik.http.routers.grafana.tls=true"
      - "traefik.http.routers.grafana.tls.certresolver=letsencrypt"
      - "traefik.http.routers.grafana.middlewares=secHeaders"
      - "traefik.http.services.grafana.loadbalancer.server.port=3000"

  keycloak-db:
    image: postgres:16
    container_name: keycloak-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: ${KC_DB_PASSWORD}
    volumes:
      - ./kc-postgres:/var/lib/postgresql/data
    networks: [mon-net]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U keycloak"]
      interval: 10s
      timeout: 5s
      retries: 10

  keycloak:
    image: quay.io/keycloak/keycloak:26.0
    container_name: keycloak
    restart: unless-stopped
    command: start
    environment:
      KC_DB: postgres
      KC_DB_URL_HOST: keycloak-db
      KC_DB_URL_DATABASE: keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: ${KC_DB_PASSWORD}
      KEYCLOAK_ADMIN: ${KEYCLOAK_ADMIN}
      KEYCLOAK_ADMIN_PASSWORD: ${KEYCLOAK_ADMIN_PASSWORD}
      KC_HOSTNAME: identitynama.otech.om
      KC_HOSTNAME_STRICT: "true"
      KC_HOSTNAME_STRICT_HTTPS: "true"
      KC_PROXY: edge
      KC_PROXY_HEADERS: xforwarded
      KC_HTTP_ENABLED: "true"
      KC_HEALTH_ENABLED: "true"
      KC_METRICS_ENABLED: "true"
    networks: [mon-net]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.kc.rule=Host(`identitynama.otech.om`)"
      - "traefik.http.routers.kc.entrypoints=websecure"
      - "traefik.http.routers.kc.tls=true"
      - "traefik.http.routers.kc.tls.certresolver=letsencrypt"
      - "traefik.http.services.kc.loadbalancer.server.port=8080"

  vmagent:                     # local scraper (single-host self-monitoring)
    image: victoriametrics/vmagent:latest
    container_name: vmagent
    restart: unless-stopped
    command:
      - "-promscrape.config=/etc/prometheus/scrape.yml"
      - "-remoteWrite.url=http://victoria-metrics:8428/api/v1/write"
    volumes:
      - ./scrape.yml:/etc/prometheus/scrape.yml:ro
    networks: [mon-net]

  node-exporter:
    image: quay.io/prometheus/node-exporter:v1.6.1
    container_name: node-exporter
    restart: unless-stopped
    networks: [mon-net]

  oauth2-proxy:                # OPTIONAL: ForwardAuth for internal-only dashboards
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.6.0
    container_name: oauth2-proxy
    restart: unless-stopped
    networks: [mon-net]
    environment:
      - OAUTH2_PROXY_PROVIDER=oidc
      - OAUTH2_PROXY_OIDC_ISSUER_URL=https://identitynama.otech.om/realms/grafana-namawater
      - OAUTH2_PROXY_CLIENT_ID=${KC_OAUTH2_CLIENT_ID}
      - OAUTH2_PROXY_CLIENT_SECRET=${KC_OAUTH2_CLIENT_SECRET}
      - OAUTH2_PROXY_COOKIE_SECRET=${KC_OAUTH2_COOKIE_SECRET}
      - OAUTH2_PROXY_COOKIE_SECURE=true
      - OAUTH2_PROXY_EMAIL_DOMAINS=*
      - OAUTH2_PROXY_HTTP_ADDRESS=0.0.0.0:4180
```

### Single-machine equivalent of the multi-machine vmagent jobs

```yaml
  - job_name: "traefik"
    static_configs:
      - targets: ["victoria-metrics:9102"]   # or the host LAN IP of the single box
        labels:
          instance: 'traefik:all-in-one'
          host: <single-host>
          service: traefik
  - job_name: "node-self"
    static_configs:
      - targets: ["node-exporter:9100"]
        labels:
          role: monitoring-host
```

Since single-host keycloak is on `mon-net`, Grafana OIDC and Traefik both reach it by service name; **no firewall rules between components are required** — only `80`/`443` inbound to Traefik.

> DNS differs slightly: on the single host all public hostnames (`cockpitnama`, `identitynama`, `grafana`, `keycloak`) point to **one** IP/load-balancer pool.

---

## 7. Deployment Changes per Machine

### Machine 1 — `nama-mon-stack` (172.29.50.2)

| # | Change | Type |
|---|---|---|
| 1 | Add `traefik` service + `traefik/` config dir to `~/nama-stack` | PROPOSED (new files) |
| 2 | Add Docker labels to the existing `onetech` service | PROPOSED (modify compose) |
| 3 | Add `node-self` job to M2 scrape.yml (references M1:9100) | PROPOSED (fix gap) |
| 4 | Pin network subnet `mon-net` = `10.90.0.0/16` | PROPOSED (avoid 172.29.x clash) |
| 5 | Add local `vmagent` (optional, scrape HA) | OPTIONAL |
| 6 | Re-enable `vmauth` for remote-write + datasource auth | OPTIONAL (security) |
| 7 | Restrict `8428/3000/9100` to internal net (firewall, not compose) | PROPOSED |

### Machine 2 — `namastorage` (172.29.50.3)

| # | Change | Type |
|---|---|---|
| 1 | Append `traefik` + `keycloak` + `node-self` jobs to existing `scrape.yml` | PROPOSED (modify) |
| 2 | (If vmauth enabled) switch `VMAGENT_REMOTE_WRITE_URL` to `http://vmagent:<pass>@172.29.50.2:8427/api/v1/write` | OPTIONAL |
| 3 | No Traefik, no new containers | — |

### Machine 3 — `nama-auth-vm` (172.29.50.4)

| # | Change | Type |
|---|---|---|
| 1 | Add `traefik` service to `~/keycloak/docker-compose.yml`, join existing `kcnet` | PROPOSED (modify) |
| 2 | Add labels to the `keycloak` service (router `Host(identitynama.otech.om)` → `keycloak:8080`) | PROPOSED (modify) |
| 3 | Keep `172.29.50.4:8080:8080` published during staging for health/metrics scraping; restrict firewall to `172.29.50.0/24` after | PROPOSED (cutover) |
| 4 | Add `node-exporter` to M3 | PROPOSED (gap fix) |
| 5 | `chmod 600 .env`; rotate KC admin + DB passwords | OPTIONAL (security) |

---

## 8. Docker Compose Configuration

Preserve all existing services. Add only what is shown.

### 8.1 M1 — `~/nama-stack/docker-compose.yml` (additions)

```yaml
  traefik:
    image: traefik:v3.2
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "172.29.50.2:9102:9102"      # metrics — internal only
      - "172.29.50.2:9091:8080"      # dashboard — internal only
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik:/etc/traefik:ro
      - ./traefik/certs:/etc/traefik/certs
      - ./traefik/logs:/var/log/traefik
    networks:
      - mon-net
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=mon-net"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--providers.file.watch=true"
      - "--entryPoints.web.address=:80"
      - "--entryPoints.web.http.redirections.entryPoint.to=websecure"
      - "--entryPoints.web.http.redirections.entryPoint.scheme=https"
      - "--entryPoints.websecure.address=:443"
      - "--entryPoints.metrics.address=:9102"
      - "--entryPoints.traefik.address=:8080"
      - "--api.dashboard=true"
      - "--api.insecure=false"
      - "--accesslog=true"
      - "--accesslog.format=json"
      - "--accesslog.filepath=/var/log/traefik/access.log"
      - "--metrics.prometheus=true"
      - "--metrics.prometheus.entryPoint=metrics"
      - "--metrics.prometheus.addEntryPointsLabels=true"
      - "--metrics.prometheus.addServicesLabels=true"
      - "--certificatesResolvers.letsencrypt.acme.email=it@otech.om"
      - "--certificatesResolvers.letsencrypt.acme.storage=/etc/traefik/certs/acme.json"
      - "--certificatesResolvers.letsencrypt.acme.httpChallenge.entryPoint=web"

networks:
  mon-net:
    name: mon-net
    driver: bridge
    ipam:
      config:
        - subnet: 10.90.0.0/16   # avoid 172.29.x Docker-default collision
```

Labels appended to the existing `onetech` service:

```yaml
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=mon-net"
      - "traefik.http.routers.grafana.rule=Host(`cockpitnama.otech.om`) || Host(`grafana.otech.om`)"
      - "traefik.http.routers.grafana.entrypoints=websecure"
      - "traefik.http.routers.grafana.tls=true"
      - "traefik.http.routers.grafana.tls.certresolver=letsencrypt"
      - "traefik.http.routers.grafana.middlewares=secHeaders"
      - "traefik.http.services.grafana.loadbalancer.server.port=3000"
```

> Grafana has its own Keycloak login — do **not** attach ForwardAuth to the Grafana router.

### 8.2 M3 — `~/keycloak/docker-compose.yml` (modifications)

Append:

```yaml
  traefik:
    image: traefik:v3.2
    container_name: keycloak-traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "172.29.50.4:9102:9102"
      - "172.29.50.4:9092:8080"   # dashboard, internal only
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik:/etc/traefik:ro
    networks:
      - kcnet
    command:            # identical static options as M1 (see §9)
      # ...same CLI flags as M1 (changed: providers.docker.network=kcnet, dashboard port 9092)
```

Labels appended to the `keycloak` service:

```yaml
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=kcnet"
      - "traefik.http.routers.kc.rule=Host(`identitynama.otech.om`)"
      - "traefik.http.routers.kc.entrypoints=websecure"
      - "traefik.http.routers.kc.tls=true"
      - "traefik.http.routers.kc.tls.certresolver=letsencrypt"
      - "traefik.http.services.kc.loadbalancer.server.port=8080"
```

**Cutover note:** keep `172.29.50.4:8080:8080` published during staging so M2 can still scrape `keycloak /metrics` and KC health checks work. After verification, keep the port published (for the M2 scrape job and direct KC metrics) but **restrict the firewall** to `172.29.50.0/24` + corp CIDR.

### 8.3 Key points

- **Traefik reaches backends over docker networks** (`mon-net` on M1, `kcnet` on M3) — no host port needed between Traefik and Grafana/Keycloak.
- Keep `expose` (container only) vs `ports` semantics: only the *edge* Traefik and necessary monitoring ports get published; everything else is on bridge networks.
- Never remove the existing services / volumes; `docker compose down` will destroy the named volumes if declared local — use `docker compose up -d` to apply changes only.
- If you add Traefik to an existing compose file, first run `docker compose config` to validate; then `docker compose up -d traefik`.

---

## 9. Traefik Configuration

Shared static + dynamic config, identical on M1 and M3 (only docker network and dashboard bind differ).

### 9.1 `traefik/traefik.yml` (static)

```yaml
providers:
  docker:
    exposedByDefault: false
    network: mon-net        # kcnet on M3
  file:
    directory: /etc/traefik/dynamic
    watch: true

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
    http:
      tls:
        minVersion: VersionTLS12
      middlewares:
        - secHeaders
  metrics:
    address: ":9102"
  traefik:
    address: ":8080"

api:
  dashboard: true
  insecure: false

accessLog:
  filePath: /var/log/traefik/access.log
  format: json
  bufferingSize: 100

metrics:
  prometheus:
    entryPoint: metrics
    addEntryPointsLabels: true
    addServicesLabels: true

certificatesResolvers:
  letsencrypt:
    acme:
      email: it@otech.om
      storage: /etc/traefik/certs/acme.json
      httpChallenge:
        entryPoint: web

serversTransport:
  insecureSkipVerify: true   # ONLY if you opt for internal-CA certs on backends
```

> **TLS versions/ciphers:** `minVersion: VersionTLS12` is set above; Traefik's default cipher suites are safe, use them. Do not lower the minimum.
> **Internal CA alternative:** if Let's Encrypt is not usable (no inbound port 80 through F5, or an offline/internal footprint), drop the whole `certificatesResolvers` block, mount your CA-issued wildcard cert in `certs/`, and set `tls.certificates` for the routers:
> ```yaml
> tls:
>   certificates:
>     - certFile: /etc/traefik/certs/internal.crt
>       keyFile: /etc/traefik/certs/internal.key
> ```

### 9.2 `traefik/dynamic/middlewares.yml`

```yaml
http:
  middlewares:
    secHeaders:
      headers:
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        frameDeny: true
        contentTypeNosniff: true
        browserXssFilter: true
        referrerPolicy: strict-origin-when-cross-origin
        customFrameOptionsValue: "SAMEORIGIN"
    ipAllowCorp:
      ipAllowList:
        sourceRange:
          - 10.160.0.0/16        # corp RFC1918 space
          - 172.29.50.0/24       # monitoring LAN
    forwardAuthKc:
      forwardAuth:
        # Point at oauth2-proxy's DECISION endpoint, NOT its root.
        # Traefik forwards to this exact path; hitting oauth2-proxy at "/"
        # yields 404 with a valid session (no app behind its root) and the
        # sign-in 403 otherwise — forwardAuth then can never allow the request.
        address: http://oauth2-proxy:4180/oauth2/auth
        trustForwardHeader: true
```

### 9.3 `traefik/dynamic/internal.yml` (internal-only routes)

```yaml
http:
  routers:
    vm-ui:
      rule: "Host(`vm.otech.om`)"
      entryPoints: [traefik]
      service: vm-svc
      middlewares: [ipAllowCorp, forwardAuthKc]
    vmagent-ui:
      rule: "Host(`vmagent.otech.om`)"
      entryPoints: [traefik]
      service: vmagent-svc
      middlewares: [ipAllowCorp, forwardAuthKc]
    traefik-dash:
      rule: "Host(`traefik.otech.om`) && (PathPrefix(`/api`) || PathPrefix(`/dashboard`))"
      entryPoints: [traefik]
      service: api@internal
      middlewares: [ipAllowCorp, forwardAuthKc]

    # Browser-facing oauth2-proxy endpoints (/oauth2/start, /oauth2/callback, ...).
    # MUST bypass forwardAuthKc, otherwise oauth2-proxy is asked to prove its own
    # auth (Traefik turns its sign-in response into a 403 for its own URLs).
    oauth2-run:
      rule: "(Host(`vm.otech.om`) || Host(`vmagent.otech.om`) || Host(`traefik.otech.om`)) && PathPrefix(`/oauth2`)"
      entryPoints: [traefik]
      service: oauth2-svc
      middlewares: [ipAllowCorp]
  services:
    oauth2-svc:
      loadBalancer:
        servers:
          - url: "http://oauth2-proxy:4180"
    vm-svc:
      loadBalancer:
        servers:
          - url: "http://172.29.50.2:8428"     # M1 instance
    vmagent-svc:
      loadBalancer:
        servers:
          - url: "http://172.29.50.3:8429"      # M2 vmagent status/targets page
```

> These hostnames must **not** resolve in public DNS (see §14).

### 9.4 oauth2-proxy (OPTIONAL — ForwardAuth for internal UIs)

```yaml
  oauth2-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.6.0
    container_name: oauth2-proxy
    restart: unless-stopped
    networks: [mon-net]          # kcnet on M3
    environment:
      - OAUTH2_PROXY_PROVIDER=oidc
      - OAUTH2_PROXY_OIDC_ISSUER_URL=https://identitynama.otech.om/realms/grafana-namawater
      - OAUTH2_PROXY_CLIENT_ID=${KC_OAUTH2_CLIENT_ID}
      - OAUTH2_PROXY_CLIENT_SECRET=${KC_OAUTH2_CLIENT_SECRET}
      - OAUTH2_PROXY_COOKIE_SECRET=${KC_OAUTH2_COOKIE_SECRET}
      - OAUTH2_PROXY_COOKIE_SECURE=true
      - OAUTH2_PROXY_EMAIL_DOMAINS=*
      - OAUTH2_PROXY_HTTP_ADDRESS=0.0.0.0:4180
```

> **Wiring requirements (verified in the single-machine lab):**
> - The `forwardAuth` middleware must target `…:4180/oauth2/auth` (§9.2) — the decision endpoint. Without it, authenticated requests to protected apps reach oauth2-proxy at `/` and get `404` (`OriginStatus=0` in the access log), so the gate can never open.
> - oauth2-proxy's own URLs (`/oauth2/start`, `/oauth2/callback`, `/oauth2/sign_in`, …) must be routable **without** the forwardAuth middleware on them (§9.3 `oauth2-run`), or the browser hits `403` sign-in-page responses for its own flow.
> - For Keycloak on a self-signed internal CA set `OAUTH2_PROXY_SSL_INSECURE_SKIP_VERIFY=true` (oauth2-proxy resolves OIDC discovery itself over TLS).
> - If any protected entrypoint is plain HTTP (internal loopback UI), keep `OAUTH2_PROXY_COOKIE_SECURE=false` — a `Secure` cookie is never sent over HTTP and the login loops forever.

### 9.5 What Traefik provides (mapped to requirements)

| Requirement | Mechanism |
|---|---|
| HTTP/HTTPS receive, TLS termination, host routing | `entryPoints web/websecure`, routers via labels/file |
| Access logs | `accesslog.json` (per machine, rotated) |
| Metrics | Prometheus `/metrics` on `:9102` |
| Request count / status / latency / source | Prometheus metrics + access-log fields |
| HTTP → HTTPS redirect | `web` entrypoint redirection |
| Secure headers | `secHeaders` middleware |
| TLS versions/ciphers | `entryPoints.websecure.http.tls.minVersion: VersionTLS12` |

---

## 10. Keycloak Configuration

### 10.1 Realm & client (existing → keep/extend)

| Item | CURRENT | PROPOSED |
|---|---|---|
| Realm | `grafana-namawater` | keep |
| Client `grafana-nama` | confidential; redirect `https://cockpitnama.otech.om/login/generic_oauth` | add redirect `https://grafana.otech.om/login/generic_oauth` if you use the canonical host |
| Client `oauth2-proxy` | — | add **only if** enabling ForwardAuth; redirect `https://traefik.otech.om/oauth2/callback` |
| Roles | realm roles `grafana-admin`, `grafana-editor` (mapped in Grafana env) | keep; optionally add `traefik-viewer` |
| Admin console | default `admin` user | create a dedicated admin user; restrict via Traefik `ipAllowCorp` middleware; never expose `/admin` publicly |

### 10.2 Runtime settings (the deployment already constrains these — keep)

```
KC_DB=postgres
KC_DB_URL_HOST=postgres           # M3 kcnet; postgres container name
KC_PROXY=edge                     # Traefik terminates TLS
KC_PROXY_HEADERS=xforwarded       # Traefik injects X-Forwarded-*
KC_HOSTNAME=identitynama.otech.om
KC_HOSTNAME_STRICT=true
KC_HOSTNAME_STRICT_HTTPS=true     # -> inner hop MUST be plain HTTP to keycloak:8080
KC_HTTP_ENABLED=true
KC_HEALTH_ENABLED=true
KC_METRICS_ENABLED=true           # /metrics on 8080 for M2 scraping
```

### 10.3 Integration modes (why native OIDC, not blind ForwardAuth)

| Approach | Verdict | Notes |
|---|---|---|
| **Native OIDC (chosen for Grafana)** | ✔ | Grafana already supports generic OAuth; keeps Keycloak-issued roles → Grafana roles; no extra hop, works offline-style with direct browser↔KC redirects |
| ForwardAuth → oauth2-proxy (chosen for internal UIs) | ✔ (limited) | Only for services with **no** native auth (vmagent status page, Traefik dashboard, VM UI). oauth2-proxy performs the OIDC dance and injects `X-Auth-Request-*`; Traefik gatekeeps with `forwardAuth` |
| Traefik-only ForwardAuth → Keycloak REST directly | ✗ | Keycloak has no forward-auth endpoint out of the box; you would re-implement token introspection — oauth2-proxy exists for this |
| OAuth2/OIDC on every service | ✗ | Max security, high complexity; overkill for internal dashboards behind allowlists |

**Security notes:** never expose VictoriaMetrics, vmauth, vmagent, exporters, or the Traefik dashboard publicly; the Keycloak admin console is protected by both a role and the `ipAllowCorp` network allowlist.

---

## 11. vmagent Configuration

Append to the **existing** `scrape.yml` on M2 (keeps the current central-scraper design):

```yaml
  - job_name: "traefik"
    scrape_interval: 15s
    static_configs:
      - targets: ["172.29.50.2:9102"]
        labels:
          instance: 'traefik-m1:nama-mon-stack'
          host: nama-mon-stack
          service: traefik
          site: nama
      - targets: ["172.29.50.4:9102"]
        labels:
          instance: 'traefik-m3:nama-auth-vm'
          host: nama-auth-vm
          service: traefik
          site: nama

  - job_name: "keycloak"
    metrics_path: /metrics
    static_configs:
      - targets: ["172.29.50.4:8080"]
        labels:
          instance: 'keycloak:nama-auth-vm'
          host: nama-auth-vm
          service: keycloak
          site: nama

  - job_name: "node-self"
    static_configs:
      - targets:
          - "172.29.50.2:9100"
          - "172.29.50.3:9100"
          - "172.29.50.4:9100"     # add node-exporter to M3 first
        labels:
          role: monitoring-host
```

Reload config: `docker exec vmagent kill -HUP 1` (or `docker restart vmagent`).

Optional hardening — re-enable vmauth for remote writes (M2 `.env`):

```dotenv
VMAGENT_REMOTE_WRITE_URL=http://vmagent:strongpassword@172.29.50.2:8427/api/v1/write
```

---

## 12. Grafana Dashboards & PromQL

Use the **VictoriaMetrics** datasource. Metric names assume Traefik v3 — verify on your version:

```bash
curl -s http://localhost:9102/metrics | grep -E 'traefik_(router|service|entrypoint).*(bucket|seconds)' | head
```

(v3 uses `traefik_*_request_seconds_bucket`; older v2 used `traefik_*_request_duration_seconds_bucket`.)

| Panel | PromQL |
|---|---|
| Requests/sec | `sum(rate(traefik_router_requests_total[5m]))` |
| Total requests | `sum(increase(traefik_router_requests_total[$__range]))` |
| 2xx/3xx/4xx/5xx | `sum by (code) (rate(traefik_router_requests_total{code=~"2.."}[5m]))` (repeat with 3.., 4.., 5..) |
| Error rate % | `100 * sum(rate(traefik_router_requests_total{code=~"5.."}[5m])) / clamp_min(sum(rate(traefik_router_requests_total[5m])), 0.000001)` |
| Latency p50/p95/p99 | `histogram_quantile(0.99, sum(rate(traefik_router_request_duration_seconds_bucket[5m])) by (le))` (repeat 0.5 / 0.95) |
| Requests by router/host | `sum by (router) (rate(traefik_router_requests_total[5m]))` |
| Requests by backend | `sum by (service) (rate(traefik_service_requests_total[5m]))` |
| Traffic by machine | `sum by (instance) (rate(traefik_router_requests_total[5m]))` |
| Active connections | `sum by (entrypoint) (traefik_entrypoint_open_connections)` |
| HTTP vs HTTPS | `sum by (protocol) (rate(traefik_entrypoint_requests_total[5m]))` |
| Backend up / retries | `traefik_service_server_up` ; `sum(rate(traefik_service_retries_total[5m]))` |
| Traefik uptime | `time() - process_start_time_seconds{job="traefik"}` |
| Config reloads | `sum(increase(traefik_config_reloads_total[$__range]))` |

### Dashboard layout

- **Row "Traffic"**: Requests/sec, Total requests, HTTP status stacked (2xx/3xx/4xx/5xx)
- **Row "Latency"**: p50/p95/p99 over time; response time by service
- **Row "Breakdown"**: by router/host, by service/backend, by HTTP method, by machine (`instance`)
- **Row "Edge health"**: open connections, HTTP vs HTTPS, TLS-route 4xx count, config reloads, Traefik uptime
- **Row "Backends"**: `traefik_service_server_up` table + retries; alert on `server_up==0`

Use a dashboard variable `$instance` sourced from `label_values(up{job="traefik"}, instance)`.

> TLS handshake/connection errors are **not** a dedicated Traefik Prometheus metric — they appear as connection resets in access logs and `code=400` on websecure routers. Alert on `code="400"` spikes; optionally add a blackbox cert-expiry probe.

---

## 13. Access Logs

The stack has **no Loki / Promtail / OpenSearch today**, so:

- **PROPOSED (now):** Traefik JSON access logs on each machine (`/var/log/traefik/access.log`), rotated daily, retained 30 days. Use them for client-IP / User-Agent / raw-URL forensics and 5xx debugging — the Prometheus metrics answer the counting questions.
- **OPTIONAL (later, only if you want log dashboards):** add `Promtail → Loki` scraping both Traefiks' JSON logs. Do not route access logs to an OpenSearch/SIEM cluster — none exists in this stack and it's not required.

---

## 14. DNS

### Public (otech.om)

```
cockpitnama.otech.om   A  → existing F5 VIP (pool: M1:443 Traefik)
identitynama.otech.om  A  → existing F5 VIP (pool: M3:443 Traefik)
grafana.otech.om       A  → alias of cockpitnama          (OPTIONAL canonical)
keycloak.otech.om      A  → alias of identitynama         (OPTIONAL canonical)
```

### Internal (corp / split-horizon — must NOT resolve publicly)

```
vm.otech.om            A  → 172.29.50.2   (Traefik internal entrypoint)
vmagent.otech.om       A  → 172.29.50.3   (status page via Traefik)
traefik.otech.om       A  → 172.29.50.2   (M1 dashboard; per-machine via loopback)
```

> Keep `KC_HOSTNAME=identitynama.otech.om` unchanged — it is embedded in Grafana OIDC env, Keycloak client redirect URIs, and all existing sessions.

---

## 15. Firewall / Networking

OCI NSG / security-list rules — only the flows actually needed.

| Source | Destination | Port | Proto | Purpose |
|---|---|---:|---|---|
| Users / F5 pool | M1 Traefik (`172.29.50.2`) | 443 | tcp | HTTPS — Grafana + future hostnames |
| Users / F5 pool | M1 Traefik | 80 | tcp | HTTP→HTTPS redirect + ACME http-01 |
| Users / F5 pool | M3 Traefik (`172.29.50.4`) | 443 | tcp | HTTPS — Keycloak |
| Users / F5 pool | M3 Traefik | 80 | tcp | redirect + ACME |
| M2 vmagent (`172.29.50.3`) | M1 VM (`172.29.50.2`) | 8428 | tcp | remote write (existing) |
| M2 vmagent | M1 vmauth | 8427 | tcp | authenticated remote write (if re-enabled) |
| M2 vmagent | M1 Traefik metrics | 9102 | tcp | scrape traefik-m1 |
| M2 vmagent | M3 Traefik metrics | 9102 | tcp | scrape traefik-m3 |
| M2 vmagent | M3 Keycloak | 8080 | tcp | scrape `/metrics` |
| M2 vmagent | M1/M2/M3 node-exporter | 9100 | tcp | self-monitoring |
| Grafana (M1) | VM / vmauth (M1) | 8428 / 8427 | tcp | datasource |
| Grafana (M1) | identitynama (→ M3 Traefik) | 443 | tcp | OIDC endpoints |
| M2 vmagent | oci-backup (`10.8.123.243`) | 9108 / 9109 | tcp | existing |
| M2 vmagent | blackbox / fortigate / pushgw (`172.29.50.3`) | 9115 / 9710 / 9091 | tcp | existing |

**Must NOT be user-reachable:** VM 8428, vmauth 8427, Grafana 3000, node-exporter 9100, Traefik dashboard (9091/9092), blackbox 9115, pushgw 9091, fortigate 9710, Docker API, Keycloak host port 8080 (limit to `172.29.50.0/24`).

**Single-machine variant:** only `80`/`443` inbound to Traefik; everything else is intra-`mon-net`.

---

## 16. Security Boundaries

| Component | Public | Internal | Notes |
|---|---|---|---|
| Traefik `:443/:80` | ✔ | — | Only exposed edge |
| Traefik `/metrics` `:9102` | ✗ | ✔ | Bound to internal IPs |
| Traefik dashboard | ✗ | ✔ | `traefik` entrypoint + `ipAllowCorp` + ForwardAuth (optional) |
| Grafana `:3000` | ✗ | ✔ (via Traefik only) | OIDC-enforced |
| Keycloak `:8080` | ✗ | ✔ | OIDC + admin console allowlisted |
| VictoriaMetrics `:8428` / vmauth `:8427` | ✗ | ✔ | Never public; auth via vmauth (re-enable) |
| vmagent `:8429` | ✗ | ✔ | Status UI internal only |
| node-exporter / blackbox / pushgw / fortigate | ✗ | ✔ | Internal LAN only |
| Docker API (`/var/run/docker.sock`) | ✗ | ✗ | Mounted read-only into Traefik; never exposed over the network |

---

## 17. Testing / Validation

```bash
# 1. Start Traefik (staging — keep existing F5/direct routes until verified)
ssh nama-mon-stack  "cd ~/nama-stack && docker compose up -d traefik"
ssh nama-auth-vm   "cd ~/keycloak   && docker compose up -d traefik"

# 2. Logs clean?
ssh nama-mon-stack  "docker logs --tail=50 traefik"
ssh nama-auth-vm   "docker logs --tail=50 keycloak-traefik"

# 3. Routes + dashboard reachable (internal checks)
curl -sI -H 'Host: cockpitnama.otech.om'  http://127.0.0.1/            # 301 → https
curl -skI https://172.29.50.2/  -H 'Host: cockpitnama.otech.om'        # 302 → Grafana
curl -sk   https://172.29.50.4/  -H 'Host: identitynama.otech.om' -o /dev/null -w '%{http_code}\n'
curl -sk https://172.29.50.2:9091/api/rawdata -H 'Host: traefik.otech.om' | head -50

# 4. After F5 cutover, confirm direct backends are NOT reachable from outside:
curl -v --connect-timeout 3 http://<f5-vip>:3000/    # must fail/refused
curl -v --connect-timeout 3 http://<f5-vip>:8428/    # must fail/refused

# 5. Keycloak behind Traefik — issuer must stay identitynama:
curl -sk https://identitynama.otech.om/.well-known/openid-configuration | python3 -m json.tool | head

# 6. Browser: https://grafana.otech.om → redirect → identitynama login → back to Grafana

# 7. Generate traffic
for i in {1..50}; do curl -sk https://grafana.otech.om/ >/dev/null; done
for i in {1..20}; do curl -sk -o /dev/null https://identitynama.otech.om/realms/grafana-namawater/.well-known/openid-configuration; done

# 8. Traefik metrics present
curl -s http://172.29.50.2:9102/metrics | grep -E '^traefik_(router|entrypoint|service)_requests_total' | head
curl -s http://172.29.50.4:9102/metrics | grep -c '^traefik_'

# 9. vmagent scraping (on M2)
docker exec vmagent sh -c 'wget -qO- http://localhost:8429/targets | grep traefik'

# 10. Ingested into VictoriaMetrics
curl -s 'http://172.29.50.2:8428/api/v1/query?query=count%28traefik_router_requests_total%29'
curl -s 'http://172.29.50.2:8428/api/v1/query?query=count%28keycloak_db_connections%29'

# 11. Grafana panels: refresh; confirm series for instance=traefik-m1 / traefik-m3
```

---

## 18. Failure Testing & HA

| Scenario | Expected behavior |
|---|---|
| **M1 down** | Grafana, VM, vmauth, Traefik-m1 die; Traefik-m3 + Keycloak stay up (SSO still works for other apps). M2 scraping unaffected; vmagent buffers remote-write. |
| **M2 down** | All scraping stops (single collector) — existing gap; edge still served. Fix by adding local vmagents (OPTIONAL). |
| **M3 down** | `identitynama` unreachable → **all logins fail** (Grafana OIDC + ForwardAuth). Grafana serves but login loops. |
| **Traefik-m1 down** | `cockpitnama`/`grafana.otech.om` unreachable; Keycloak unaffected; direct `172.29.50.2:3000` must be blocked. |
| **Traefik-m3 down** | `identitynama` unreachable → no auth anywhere. F5 health-checks Traefik and fails over if a 2nd backend is configured. |
| **VM down** | Dashboards empty; vmagent buffers; Traefik still serves edge (no metrics but traffic works). |
| **vmagent down** | No new metrics; edge unaffected. |

**HA verdict:** single Traefik per public machine + single Keycloak + single Postgres is acceptable at this scale. Add alerts on `up{job="traefik"}` and `up{job="keycloak"}`. Real HA is OPTIONAL (§20).

---

## 19. Rollback

Per machine, revert is clean because existing services/labels are additive:

```bash
# M1 / M3: stop Traefik, remove the onetech/keycloak labels, drop F5 pool changes
ssh nama-mon-stack  "cd ~/nama-stack && docker compose up -d --no-deps traefik"   # validate first
# To fully roll back:
ssh nama-mon-stack  "cd ~/nama-stack && docker compose rm -sf traefik"
ssh nama-auth-vm   "cd ~/keycloak   && docker compose rm -sf traefik"
```

F5/DNS revert: point pools back at `M1:3000` / `M3:8080` as they are today. No container was replaced, only added.

---

## 20. Optional Roadmap

- [ ] Re-enable `vmauth` for authenticated remote-write + Grafana datasource
- [ ] Rotate all secrets (KC client, KC admin, KC DB, GF admin, SMTP); encrypt per-machine `.env`
- [ ] Add `node-exporter` to M3 + `node-self` job (monitor the monitoring hosts)
- [ ] Nightly `pg_dump` of the Keycloak Postgres
- [ ] Local vmagent per machine (scrape HA) with `hashMod` sharding
- [ ] Third Traefik on M2 if `vmagent.<domain>` / `vm.<domain>` become public
- [ ] Promtail + Loki for access-log dashboards
- [ ] Keycloak cluster (2nd node, shared Postgres) when HA is required
- [ ] Traefik on M1 + M3 behind F5 pools with health checks (load-breakout without extra nodes)

---

## 21. Project Layout & Quickstart

```
grafana-key-vmagent-project/
├── README.md                                  # this document
├── .gitignore
│
├── single-machine/                            # ★ all-in-one stack (lab / DR site)
│   ├── docker-compose.yml                     # traefik, vm, vmauth, grafana, keycloak+db, vmagent, node, oauth2-proxy
│   ├── .env.example                           # copy to .env and fill in
│   ├── deploy.sh                              # renders vmauth.yml from .tpl, starts stack
│   ├── vmauth.yml.tpl
│   ├── scrape.yml                             # vmagent scrape config (mon-net DNS names)
│   ├── traefik/
│   │   ├── traefik.yml                        # static config (mon-net)
│   │   └── dynamic/
│   │       ├── middlewares.yml                # secHeaders / ipAllowCorp / forwardAuthKc
│   │       └── internal.yml                   # vm/vmagent/traefik internal routers
│   ├── provisioning/
│   │   ├── datasources/victoriametrics.yml    # Grafana datasource (auto-provisioned)
│   │   └── dashboards/                        # provider + traefik-traffic.json
│   ├── traefik/certs/                         # acme.json lives here (git-ignored)
│   └── traefik/logs/                          # access.log lives here (git-ignored)
│
├── multi-machine/                             # ★ production variant (your 3 hosts)
│   ├── machine1-nama-mon-stack/               # 172.29.50.2 — hub + Traefik #1
│   │   ├── docker-compose.yml                 # existing services + traefik + mon-net
│   │   ├── .env.example                       # drop-in compatible with existing .env
│   │   ├── deploy.sh / vmauth.yml.tpl
│   │   ├── traefik/{traefik.yml, dynamic/}    # static (mon-net) + dynamic
│   │   └── provisioning/                      # Grafana datasource + dashboard
│   ├── machine2-namastorage/                  # 172.29.50.3 — scraper (NO Traefik)
│   │   ├── docker-compose.yml                 # vmagent + node-exporter (as today)
│   │   ├── .env.example
│   │   └── scrape.yml                         # MERGE BASE — paste existing targets + new jobs
│   └── machine3-nama-auth-vm/                 # 172.29.50.4 — Keycloak + Traefik #2
│       ├── docker-compose.yml                 # postgres + keycloak + traefik (kcnet)
│       ├── .env.example                       # drop-in compatible with existing .env
│       └── traefik/{traefik.yml, dynamic/}    # static (kcnet) + dynamic
│
└── shared/
    └── grafana/traefik-traffic.json           # canonical dashboard (copied into provisioning dirs)
```

### Quickstart — single machine

```bash
cd single-machine
cp .env.example .env        # fill in real values (change example domains/secrets)
./deploy.sh                 # renders vmauth.yml and starts everything
docker compose ps           # all services up
docker logs -f traefik      # note: Traefik logs here are minimal; use logs/access.log
```

**Lab / DR-site notes (validated on Windows Docker Desktop):**
- On hosts whose Docker daemon socket can't be mounted into a Linux container (Docker Desktop), the docker provider is disabled — use `docker-compose.override.yml` + `traefik/local-static.yml` + the `traefik/dynamic-local/` file provider, and `docker compose up -d --force-recreate traefik` after routing changes.
- `EDGE_BIND=127.0.0.1:9091` and `.127.0.0.1.nip.io` hosts mean the internal UIs are reachable on this box only — no public DNS needed. Public edge (`*.10.0.160.236.nip.io`) is served by Let's Encrypt only if it can complete the HTTP-01 challenge; on the internal test box the stack is self-signed.
- Self-signed TLS requires the two skip-verify switches, verified against a live box:
  - Grafana: `GF_AUTH_GENERIC_OAUTH_TLS_SKIP_VERIFY_INSECURE=true` (generic-oauth key `tls_skip_verify_insecure`; the `GF_AUTH_GENERIC_OAUTH_TLS_CLIENT_SKIP_VERIFY_INTERNAL` / `*_CLIENT_*` variants do **not** apply to the `tls_skip_verify_insecure` field).
  - oauth2-proxy: `OAUTH2_PROXY_SSL_INSECURE_SKIP_VERIFY=true`.
- If the internal UI doesn't open from a loopback hostname, flip `OAUTH2_PROXY_COOKIE_SECURE=false` (plain HTTP never receives a `Secure` cookie).
- Keycloak 26: admin REST takes a password-grant token (`client_id=admin-cli`, `grant_type=password` → `Authorization: Bearer`), HTTP Basic is rejected; management metrics live on `:9000`, not `:8080`.
- Keycloak users must be fully provisioned (`firstName`, `lastName`, `emailVerified=true`). A missing `lastName` fires the `VERIFY_PROFILE` required-action, which blocks every non-browser grant with `invalid_grant "Account is not fully set up"`. The kc-import realm JSON ships with this already satisfied.

**Confirm the three paths (validated end-to-end):**
```bash
# 1. Grafana ← native OIDC: browser → https://grafana.…/login/generic_oauth → Keycloak → back
curl -k -s -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  https://grafana.…/login/generic_oauth            # expect 302 → keycloak …/auth
# 2. Keycloak /.well-known/openid-configuration reachable behind Traefik (KC26)
curl -s https://keycloak.…/realms/grafana-namawater/.well-known/openid-configuration
# 3. Internal UI ← ForwardAuth: http://vm.127.0.0.1.nip.io:9091/ → 401 + X-Auth-Request-Redirect
#    → open /oauth2/start?rd=/ → Keycloak login → session cookie → /vmui/ 200
```

### Quickstart — multi machine (production cutover)

```bash
# 0) Pre-flight: verify Traefik ports 80/443 are free on M1 and M3
#    ss -ltnp | grep -E ':(80|443)\s'     (must be empty)

# 1) M1 — deploy Traefik edge + attach existing stack to mon-net
ssh nama-mon-stack
 cd ~/nama-stack
 cp .env.example .env        # merge with existing .env (same keys + new KC_/GF_SMTP_ vars)
 docker compose config       # validate
 docker compose up -d traefik
 docker compose up -d        # recreates existing containers onto mon-net (data volumes persist)

# 2) M3 — deploy Traefik edge for Keycloak
ssh nama-auth-vm
 cd ~/keycloak
 cp .env.example .env        # keep existing KC_HOSTNAME etc.
 docker compose config
 docker compose up -d traefik
 docker compose up -d

# 3) M2 — add scrape jobs (merge scrape.yml), reload vmagent
ssh namastorage
 cd ~/nama-stack
 # paste existing production targets into scrape.yml, keep the new jobs
 docker exec vmagent kill -HUP 1     # or: docker restart vmagent

# 4) Point F5/DNS pools at Traefik (M1:443, M3:443), then restrict firewalls (§15)
```

### Validation order (from README §17)

1. Traefik logs clean on M1 + M3
2. `curl -sI` host-header tests reach Grafana / Keycloak behind Traefik
3. Keycloak `.well-known/openid-configuration` still shows `identitynama.otech.om` issuer
4. Grafana log-in through Keycloak (native OIDC unchanged)
5. Generate traffic, then confirm `traefik_router_requests_total` appears in VictoriaMetrics
6. Open `Traefik Traffic` dashboard → per-machine series (`instance=traefik-m1` / `traefik-m3`)

### Editing the dashboard

Edit `shared/grafana/traefik-traffic.json` (canonical), then copy into the machine provisioning dirs (the copies are git-ignored). Grafana reloads JSON files automatically when `updateIntervalSeconds` elapses (`30s`), so there is no need to restart Grafana after a dashboard change.

---

## 22. Appendix — Reference Data

| Item | Value |
|---|---|
| Machine 1 | `172.29.50.2` nama-mon-stack: VM 8428, vmauth 8427, Grafana 3000, node 9100, **Traefik 80/443/9102**, dashboard 9091 |
| Machine 2 | `172.29.50.3` namastorage: vmagent 8429, node 9100, blackbox 9115, fortigate 9710, pushgw 9091 |
| Machine 3 | `172.29.50.4` nama-auth-vm: Keycloak 8080 (kcnet), postgres 5432, **Traefik 80/443/9102**, dashboard 9092 |
| Keycloak realm | `grafana-namawater` — clients: `grafana-nama` (Grafana OIDC), `oauth2-proxy` (optional ForwardAuth) |
| Certificates | Let's Encrypt via Traefik ACME (`acme.json`); internal-CA alternative in §9.1 |
| Logs | Traefik JSON access logs per machine (`traefik/logs/access.log`), rotate 30d |

---

*Single-machine note: the all-in-one compose (§6/§21) is the fastest path for a lab or DR site; the multi-machine variant (§5) reuses the existing 3 hosts with the fewest changes — only M1 and M3 gain a Traefik container, and M2 only gains scrape jobs.*