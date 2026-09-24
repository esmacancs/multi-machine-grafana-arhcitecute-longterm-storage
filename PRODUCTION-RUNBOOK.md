# NAMA Monitoring Platform — Production Runbook

> **The step-by-step "how to run it in production" guide.** It covers the exact order of
> operations, which command runs on which machine, the one-time workstation prep, per-VM
> deploy and firewall steps, post-deploy Keycloak/Grafana wiring, ongoing operations
> (backup/update/rotate), and the full **F5 cutover** procedure.
>
> For the *why* (architecture, threat model, port matrix, secrets model, HA analysis) read
> **[multi-machine/PRODUCTION-SECURITY-DESIGN.md](multi-machine/PRODUCTION-SECURITY-DESIGN.md)**.
> This runbook tells you *what to type, on which machine, in which order*.

---

## 0. Machine inventory (the 3 VMs)

| Role | Hostname | Static IP (this deployment) | Runs | Deploy tree on disk |
|---|---|---|---|---|
| **M1** | `nama-mon-stack` | `10.0.170.159` | Grafana `onetech` (:3000, HTTPS), victoria-metrics (bridge only), vmauth (:8427 TLS), node-exporter (:9100) | `/opt/nama/mon` |
| **M2** | `namastorage` | `10.0.170.151` | vmagent (:8429 loopback), node-exporter (:9100), blackbox (:9115), veeam-pushgateway (:9091 loopback), FortiGate/OCI exporters | `/opt/nama/storage` |
| **M3** | `nama-auth-vm` | `10.0.170.115` | Keycloak 26.7.x (:8080 app / :8443 interim HTTPS / :9000 management), postgres `keycloak-db` (bridge only), node-exporter (:9100) | `/opt/nama/auth` |

`MON_IP`, `STORAGE_IP`, `AUTH_IP` are provider-assigned **static** addresses. They are written
into each machine's `.env` and every config (compose binds, scrape targets, CA SAN, UFW) renders
from them. `<IP>` values below are your actual IPs.

### Interim (no-F5) public hostnames — nip.io

Until F5 lands, DNS is faked with nip.io (resolves to the VM IP), and TLS is served **by the VMs
themselves** using internal-CA signed leaves:

- Grafana: `https://grafana.10.0.170.159.nip.io:3000` (M1 serves HTTPS directly)
- Keycloak: `https://auth.10.0.170.115.nip.io:8443` (KC serves HTTPS directly, `KC_PROXY=passthrough`)

Browsers will warn about the internal CA — expected until the F5 cutover (§ F5).

---

## 1. One-time workstation prep (Windows / WSL / Git-Bash)

> You need: `ssh`, `scp`, `openssl`, `bash`, `tar`, and SSH key access (`ubuntu@`) to all three VMs.
> All commands marked **[WS]** run from your admin workstation (in a WSL/bash shell).

**[WS] 1.1 — Checkout and inspect the tree**

```bash
cd grafana-key-vmagent-project
git status
ls multi-machine/          # machine1-nama-mon-stack / machine2-namastorage / machine3-nama-auth-vm / ops
```

**[WS] 1.2 — Stamp the static IPs (writes each `machine*/…/.env` from `.env.example`)**

```bash
# Creates .env files if missing and sets the IP + interim nip.io hostnames.
# Easy path: the provisioner (multi-machine/ops/provision-all.sh, run from repo root)
# does EVERYTHING: .env stamping + secrets + CA/TLS + bootstrap + deploy + firewall + health.
bash multi-machine/ops/provision-all.sh 10.0.170.159 10.0.170.151 10.0.170.115 \
    --user ubuntu \
    --mgmt-cidr 10.0.10.0/24 \
    --f5-ip 172.29.50.1 \
    --gateway 172.29.50.1 \
    --mon-cidr 10.0.170.0/24

# Manual path: create each .env from the example and edit the IP keys yourself.
cp multi-machine/machine1-nama-mon-stack/.env.example multi-machine/machine1-nama-mon-stack/.env
cp multi-machine/machine2-namastorage/.env.example       multi-machine/machine2-namastorage/.env
cp multi-machine/machine3-nama-auth-vm/.env.example      multi-machine/machine3-nama-auth-vm/.env
```

Map the IP keys exactly:

| Machine | `.env` keys to set |
|---|---|
| M1 | `MON_IP=10.0.170.159`, `GF_SERVER_ROOT_URL=https://grafana.10.0.170.159.nip.io:3000`, `KC_PUBLIC_URL=https://auth.10.0.170.115.nip.io:8443` |
| M2 | `STORAGE_IP=10.0.170.151`, `VMAUTH_IP=10.0.170.159`, `MON_IP=10.0.170.159`, `AUTH_IP=10.0.170.115`, `GF_PUBLIC_URL=…`, `KC_PUBLIC_URL=…` |
| M3 | `AUTH_IP=10.0.170.115`, `KC_HOSTNAME=auth.10.0.170.115.nip.io` |

**[WS] 1.3 — Generate secrets (root-only files, git-ignored)**

```bash
bash multi-machine/ops/gen-secrets.sh          # all password/secret files
```

Output (NON-exhaustive — full list in design doc §4.4):
`machine1/…/secrets/{grafana_admin_password, grafana_oidc_client_secret, smtp_password,
vmauth_vmagent_username, vmauth_vmagent_password, vmauth_grafana_username, vmauth_grafana_password}`
`machine2/…/secrets/{vmagent_user, vmagent_pass}` (same pair as vmauth_vmagent_*)
`machine3/…/secrets/{kc_db_password, kc_admin_username, kc_admin_password}`

**[WS] 1.4 — Internal CA + vmauth TLS + nip.io leaf certs**

```bash
VMAUTH_IP=10.0.170.159 bash multi-machine/ops/gen-ca.sh     # vmauth_ca.pem/.key + vmauth_tls.{crt,key}
cp multi-machine/machine1-nama-mon-stack/secrets/vmauth_ca.pem multi-machine/machine2-namastorage/secrets/vmauth_ca.pem
MON_IP=10.0.170.159 AUTH_IP=10.0.170.115 bash multi-machine/ops/gen-vm-tls.sh   # grafana_tls.* + kc_tls.*
```

**[WS] 1.5 — (Recommended) Pin images to digests**

```bash
bash multi-machine/ops/pin-images.sh     # rewrites compose files with :tag@sha256:… ; commit the result
```

**[WS] 1.6 — Merge YOUR existing production scrape targets into the M2 scrape template**

`scrape.yml.tpl` ships with a `_placeholder_production_targets` job. Paste the existing
node / FortiGate / OCI / Veeam / blackbox jobs from the current production `scrape.yml`
into the **PRODUCTION TARGETS** section (see the commented examples in the file). Only the
self-monitoring jobs at the top are authoritative — do not delete them.

---

## 2. Bootstrap — run ONCE per fresh VM

Installs Docker Engine + compose, sets the hostname, verifies the static IP, applies a sysctl
baseline. Idempotent. Order: **M1, M2, M3** (any order works).

> SSH from your workstation into each VM. Each machine must already have its static IP
> (DHCP reservation or cloud-init) — or pass `--set-ip`.
>
> **Manual path only:** copy the repo's `ops/` and the role's machine dir to each VM first
> (the provisioner's `push_tree()` does this):
> `tar -C ops -cf - . | ssh ubuntu@<ip> sudo tar -C /opt/nama/ops -xf -` and similarly
> `tar -C machine1-nama-mon-stack -cf - . | ssh ubuntu@10.0.170.159 sudo tar -C /opt/nama/mon -xf -`
> (repeat for M2/M3 with storage/auth). Then run bootstrap from `/opt/nama/ops`.

**On M1** (fresh host):

```bash
# either via the provisioner (already covered in §1.2), or manually:
ssh ubuntu@10.0.170.159
sudo MON_IP=10.0.170.159 bash /path/to/ops/bootstrap.sh mon        # no --set-ip if the IP is already right
```

**On M2:**

```bash
sudo STORAGE_IP=10.0.170.151 bash /path/to/ops/bootstrap.sh storage
```

**On M3:**

```bash
sudo AUTH_IP=10.0.170.115 bash /path/to/ops/bootstrap.sh auth
```

Each finishes with: `bootstrap OK: role=… host=… ip=…`.

---

## 3. Initial deploy (stack bring-up)

Deploy in this order so dependencies exist before they're scraped: **M1 → M3 → M2 → verify**.
(Intra-host dependencies make the compose order safe; this order makes *verification* smooth.)

### Step 3.1 — M1 (monitoring hub)

Push the machine1 tree + ops to `/opt/nama/mon` (or copy files directly), then:

```bash
# On M1, as root (files under /opt/nama/mon, secrets root:root 0600):
cd /opt/nama/mon
sudo ./deploy.sh
```

`deploy.sh` does, for you:
1. sources `.env`, reads `secrets/*` (never prints them)
2. renders `vmauth.yml` and `provisioning/datasources/victoriametrics.yml` via `envsubst`
   (the datasource uses `$__file{...}` refs for password + CA — do **not** edit the rendered file)
3. `docker compose up -d`

Verify on M1:

```bash
docker compose ps                     # victoria-metrics, vmauth, onetech, node-exporter = Up (healthy)
docker logs --tail 30 onetech         # no errors; datasource provisioning ran
sudo docker exec onetech curl -skf https://127.0.0.1:3000/api/health  # {"database":"ok"}
docker compose logs --tail 10 vmauth  # TLS up, no auth errors
ss -lntup                             # 3000/8427/9100 bound to 10.0.170.159 only; NO 8428 to the LAN
```

### Step 3.2 — M3 (Keycloak)

```bash
# On M3, as root:
cd /opt/nama/auth
sudo ./deploy.sh          # chowns ./postgres, docker compose up -d
```

Verify on M3:

```bash
docker compose ps                                   # keycloak-db Healthy, keycloak Up (healthy)
curl -s http://10.0.170.115:9000/health/ready       # 200
docker logs --tail 30 keycloak                      # "Running the server in production mode"
ss -lntup                                           # 8080/8443/9000/9100 on 10.0.170.115; NO 5432
```

### Step 3.3 — M2 (scraper hub)

```bash
# On M2, as root:
cd /opt/nama/storage
sudo ./deploy.sh          # renders scrape.yml from scrape.yml.tpl, docker compose up -d
```

Verify on M2:

```bash
docker compose ps                                   # vmagent, node-exporter, blackbox, veeam-pushgateway Up
docker logs vmagent 2>&1 | grep -i error | tail     # none
curl -s http://127.0.0.1:8429/api/v1/targets | head # status pages reachable (loopback)
curl -s http://127.0.0.1:8429/-/reload              # reload scrape config if you edit scrape.yml
```

### Step 3.4 — Verify the write path (M2 → vmauth → VictoriaMetrics)

```bash
# On M2 (vmagent is loopback-bound; config + targets prove the scrape side):
curl -s http://127.0.0.1:8429/api/v1/status/config | head -c 300
curl -s http://127.0.0.1:8429/api/v1/targets | head -c 400

# Also from M2 — proves vmauth on M1 accepts the vmagent user over TLS (UFW allows STORAGE_IP -> 8427):
curl -sku "vmagent:$(sudo cat /opt/nama/storage/secrets/vmagent_pass)" \
     'https://10.0.170.159:8427/api/v1/query' --data-urlencode 'query=up' | head -c 600
```

Wait ~1 minute, then from M1 confirm series are stored:

```bash
docker exec victoria-metrics wget -qO- 'http://127.0.0.1:8428/api/v1/query?query=up&nocache=1' | python3 -m json.tool | head -40
# expect up=1 with labels: job=node-self / job=keycloak / job=victoriametrics ...
```

---

## 4. Post-deploy wiring (Keycloak realm/client + Grafana OIDC)

This is done in the Keycloak admin console (or via kcadm). One-time per realm **`grafana-namawater`**.

### 4.1 — OIDC client for Grafana

| Setting | Value |
|---|---|
| Client ID | `grafana-nama` (match `KC_GRAFANA_CLIENT_ID` in M1/M3 `.env`) |
| Client type | **Confidential** |
| Standard flow | ON (authorization code); PKCE S256 ON; **Direct access grants OFF** |
| Valid redirect URIs | `https://grafana.10.0.170.159.nip.io:3000/login/generic_oauth` |
| Valid web origins | `https://grafana.10.0.170.159.nip.io:3000` |
| Client secret | exactly the contents of `machine1/…/secrets/grafana_oidc_client_secret` |

Client scopes: `openid profile email roles`.

### 4.2 — Roles (drive Grafana Role → permission mapping)

Realm roles **`grafana-admin`** and **`grafana-editor`** must exist and be assigned to users.
Grafana maps them via env (`GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH`):
`grafana-admin → Admin`, `grafana-editor → Editor`, anything else → `Viewer`.
Local Grafana login is disabled — OIDC is the only path.

### 4.3 — Verify end-to-end login

```bash
# Browser: https://grafana.10.0.170.159.nip.io:3000  →  redirects to Keycloak login  →  back into Grafana.
# Expect: you land as the OIDC user, role applied, dashboards load with data.
```

---

## 5. Firewall (enable last)

Apply the UFW + DOCKER-USER rules **after** every container is started, so container
interfaces are up (the script reads the docker bridge subnets).

> Order matters: run these in the same change window; the scripts are idempotent and
> re-probe SSH. Make sure `MGMT_CIDR` includes your workstation, or you lock yourself out.

```bash
# M1
sudo MGMT_CIDR=10.0.10.0/24 F5_IP=172.29.50.1 MON_IP=10.0.170.159 STORAGE_IP=10.0.170.151 \
     bash /opt/nama/ops/ufw-m1.sh

# M2
sudo MGMT_CIDR=10.0.10.0/24 MON_CIDR=10.0.170.0/24 STORAGE_IP=10.0.170.151 \
     bash /opt/nama/ops/ufw-m2.sh

# M3
sudo MGMT_CIDR=10.0.10.0/24 F5_IP=172.29.50.1 AUTH_IP=10.0.170.115 MON_IP=10.0.170.159 STORAGE_IP=10.0.170.151 \
     bash /opt/nama/ops/ufw-m3.sh
```

Post-firewall smoke (from workstation):

```bash
ssh ubuntu@10.0.170.159  sudo ss -lntup          # still reachable = firewall sane
nmap -p 3000,8428,8427,9100 10.0.170.159         # expect: 3000/9100 filtered or open to selective src, 8428 nothing
nmap -sS -p 8080,8443,9000,5432 10.0.170.115     # 9000/9100 open to VM2, 5432 closed
```

Optionally harden hosts: `sudo bash /opt/nama/ops/harden-host.sh` (SSH keys, fail2ban,
unattended-upgrades, journald/docker log limits, chrony) — repeat on all three VMs.

---

## 6. Dashboards & self-monitoring (already provisioned)

The Grafana **datasource + dashboards are auto-provisioned** from `/opt/nama/mon/provisioning/`:

| Asset | Notes |
|---|---|
| Datasource `VictoriaMetrics` (uid `victoriametrics`) | `https://vmauth:8427`, basic-auth + internal-CA TLS, read-only user |
| Dashboard **Public URL Probes (Blackbox)** | Grafana + Keycloak URL health/status/latency/cert-expiry |
| Dashboard **Keycloak Troubleshooting** | official `keycloak-grafana-dashboard`; filters `namespace=keycloak`, `realm=grafana-namawater` |
| Dashboard **Keycloak Capacity Planning** | official; needs `keycloak_user_events_total` (enabled on M3 via `KC_EVENT_METRICS_USER_ENABLED=true`) |
| Dashboard **Traefik Traffic** | kept for reference (Traefik is not deployed in production) |

> Datasource changes are read **only at Grafana startup** — after editing the datasource,
> `docker restart onetech`. Dashboard JSONs are re-scanned every 30s automatically.

### Key scraped label contract (do not change casually)

The official KC dashboards filter on `namespace/container/pod`. M2's `keycloak` job stamps
`namespace=keycloak, container=keycloak, pod=keycloak-1`. The leading `realm` variable
defaults to `grafana-namawater`.

---

## 7. Day-2 operations

### 7.1 Routine health check

```bash
# From any VM:
sudo bash /opt/nama/ops/health-report.sh
# Or schedule:  */5 * * * * root /opt/nama/ops/health-report.sh >> /var/log/nama-health.log 2>&1
```

### 7.2 Update a single component (e.g. Grafana image)

```bash
# On the affected machine:
#   1. edit .env  (new image tag)
#   2. cd /opt/nama/<role> && sudo ./deploy.sh     # re-renders + `docker compose up -d`
#   3. docker compose ps AND docker logs --tail 30 <container>   # verify
# VM data: do a vmbackup snapshot first (see §7.4) — never `up` an image upgrade blind.
# Keycloak minor upgrade (26.0.x → 26.7.x): design doc §15 Phase 5 — follow KC upgrade guide; DB migration is automatic.
```

### 7.3 Secret rotation

Use `multi-machine/ops/rotate-secrets.sh <target>` (documented cadence in design doc
§10.1.1). Critical rule: the vmauth↔vmagent pair is **one shared credential** — rotate both
halves together, then `docker restart vmagent` (M2) after re-rendering on M1.

### 7.4 Backups

Scripts: `ops/backup-m1.sh` (VM snapshots + Grafana sqlite), `ops/backup-m3.sh` (KC `pg_dump`
+ realm export). Encrypt with `age` → off-host. Quarterly restore drill: `ops/restore-drill.sh`.

---

## 8. F5 cutover — what to change and where

> **Goal:** F5 terminates all user TLS on the public VIPs; the VMs serve plain HTTP on the LAN
> VIPs only. Every interim artifact (internal-CA leaf certs on the apps, nip.io hostnames,
> `passthrough` proxy mode, blackbox TLS-skip modules, the "PRE-F5 TEMP" firewall rules) is
> removed. Option A (TLS on F5, HTTP to backends) is the recommended model — design doc §5.1.

### 8.0 F5 / DNS side (F5 + DNS team)

- DNS:
  - `cockpitnama.otech.om`  A → F5 VIP pool member `10.0.170.159:3000`
  - `identitynama.otech.om` A → F5 VIP pool member `10.0.170.115:8080`
- F5 LTM (Option A):
  - Terminate TLS on F5 with the **public** `*.otech.om` / `cockpitnama`+`identitynama` cert.
  - HTTP VIPs → `10.0.170.159:3000` (Grafana) and `10.0.170.115:8080` (Keycloak).
  - Inject `X-Forwarded-Proto: https` and `X-Forwarded-For` (and trust the latter).
  - Only `443` inbound; keep the pools healthy by HTTP 200 on `/login` (Grafana) / `/health/ready` (KC via 9000, or a probe path on 8080).
- Remove any old pool members pointing at `:9102/:9091` (Traefik leftovers) or `:8443`.

### 8.1 M1 (Grafana)

| File (on M1) | Change |
|---|---|
| `/opt/nama/mon/.env` | `GF_SERVER_ROOT_URL=https://cockpitnama.otech.om` |
| `/opt/nama/mon/.env` | `KC_PUBLIC_URL=https://identitynama.otech.om` |
| `/opt/nama/mon/docker-compose.yml` | remove `GF_SERVER_PROTOCOL=https`, `GF_SERVER_CERT_FILE`, `GF_SERVER_CERT_KEY` from `onetech`; remove `grafana_tls.crt`/`grafana_tls.key` secrets; keep `onetech` bound to `10.0.170.159:3000` (**HTTP** when F5 fronts it) |
| `/opt/nama/mon/docker-compose.yml` | `onetech` env: remove `GF_AUTH_GENERIC_OAUTH_TLS_SKIP_VERIFY_INSECURE` and `GF_AUTH_GENERIC_OAUTH_TLS_CLIENT_CA` (no direct-VM TLS anymore); keep `KC_PUBLIC_URL` pointing at the F5 VIP for OIDC endpoints |
| Run | `sudo ./deploy.sh` then `docker restart onetech` (datasource is read at startup), or a full `up -d` |
| `ops/ufw-m1.sh` | drop the "PRE-F5 TEMP" MGMT/ADMIN→3000 rules and the STORAGE_IP→3000 interim probe rule; keep F5→3000 (DOCKER-USER), VM2→8427, VM2→9100 |
| cert files | `secrets/grafana_tls.{crt,key}` become obsolete — remove from secret list (keep for rollback briefly) |

### 8.2 M3 (Keycloak)

| File (on M3) | Change |
|---|---|
| `/opt/nama/auth/.env` | `KC_HOSTNAME=identitynama.otech.om`; `KC_PROXY=edge`; `KC_PROXY_HEADERS=xforwarded` |
| `/opt/nama/auth/.env` | remove `KC_HTTPS_PORT` / `KC_HTTPS_CERTIFICATE_FILE` / `KC_HTTPS_CERTIFICATE_KEY_FILE`; `KC_HTTP_MANAGEMENT_SCHEME=http` stays |
| `/opt/nama/auth/docker-compose.yml` | remove the `:8443:8443` publish and the `kc_tls.{crt,key}` secrets; keep `:8080:8080` (HTTP) and `:9000:9000` (metrics from VM2) |
| Run | `sudo ./deploy.sh` |
| `ops/ufw-m3.sh` | drop MGMT/ADMIN→8080/8443 PRE-F5 TEMP rules and STORAGE_IP→8443 probe; keep F5→8080, MON_IP→8080 (Grafana OIDC discovery), VM2→9000 + 9100 |
| verify | `curl -sk https://identitynama.otech.om/realms/grafana-namawater/.well-known/openid-configuration \| grep -i http` shows the VIP, not nip.io |

### 8.3 M2 (vmagent / blackbox — scrape + probe targets)

| File (on M2) | Change |
|---|---|
| `/opt/nama/storage/.env` | `GF_PUBLIC_URL=https://cockpitnama.otech.om` ; `KC_PUBLIC_URL=https://identitynama.otech.om` |
| `/opt/nama/storage/blackbox.yml` | use `http_2xx` (strict TLS verify, `insecure_skip_verify: false`) instead of `http_2xx_nipio`; set `tls_conn` module `insecure_skip_verify: false` |
| `/opt/nama/storage/scrape.yml.tpl` | `blackbox_http_public` → `module: [http_2xx]`; `blackbox_tls_public` targets → F5 VIP hostnames (e.g. `cockpitnama.otech.om:443`, `identitynama.otech.om:443`) so `probe_ssl_earliest_cert_expiry` monitors the **public** cert lifetime |
| Run | `sudo ./deploy.sh` then `docker restart vmagent` |
| verify | `docker exec vmagent wget -qO- 'http://127.0.0.1:8429/api/v1/targets'` → new targets `up`; Grafana "Public URL Probes" shows `probe_success=1` and correct cert expiry |

### 8.4 M1 Grafana (OIDC endpoints) — same change, other side

The Grafana OIDC env (`GF_AUTH_GENERIC_OAUTH_*_URL`) must switch from `auth…nip.io` to
`https://identitynama.otech.om/…`. Also update the Keycloak client (`grafana-nama`):
valid redirect URIs become `https://cockpitnama.otech.om/login/generic_oauth`,
web origins `https://cockpitnama.otech.om`.

### 8.5 Cutover ordering (safe sequence)

1. F5: create the VIPs + pools **but keep them disabled/disconnected**.
2. M1 + M3: apply the config above, restart, verify internally:
   - M1: `curl -s http://10.0.170.159:3000/api/health` → 200 (plain HTTP now)
   - M3: `curl -s http://10.0.170.115:9000/health/ready` → 200; `curl -s -o /dev/null -w '%{http_code}' http://10.0.170.115:8080/` → 302 to https
3. M2: re-render scrape + blackbox, restart vmagent, targets up.
4. Firewall: re-run `ufw-m1.sh` + `ufw-m3.sh` (removes TEMP rules, tightens to F5-only).
5. **Cut DNS/VIP**: point `cockpitnama` / `identitynama` at F5; enable the pools.
6. Final validation (below).

### 8.6 F5 post-cutover validation

```bash
# from the workstation (F5 VIP):
curl -sI https://cockpitnama.otech.om/login/generic_oauth | head -3    # 302 → identitynama
curl -sI https://identitynama.otech.om/realms/grafana-namawater/.well-known/openid-configuration | head -1  # 200/302
openssl s_client -connect cockpitnama.otech.om:443 -servername cockpitnama.otech.om -tls1_2 </dev/null | grep -E 'Protocol|Cipher'   # TLS1.2+, public CA
curl -sk https://identitynama.otech.om/.well-known/openid-configuration | python3 -m json.tool | grep -E 'issuer|authorization_endpoint'   # issuer == VIP, no nip.io

# from M2 (proof that nothing bypasses F5):
curl -v --connect-timeout 3 http://10.0.170.159:8428/health   # must fail (8428 not published)
curl -v --connect-timeout 3 https://10.0.170.159:3000/        # must fail (firewall: F5 only)
```

Browser flow: `https://cockpitnama.otech.om` → Keycloak login on `identitynama.otech.om` → back
to Grafana as the mapped role, dashboards rendering.

### 8.7 After 2 weeks steady-state (design §15 Phase 8)

- Remove obsolete files: `secrets/grafana_tls.*`, `secrets/kc_tls.*`, the `nip.io` comments/vars, `KC_HTTPS_*` remnants.
- Disable/delete any interim firewall rules and old F5 pool members (Traefik `:9102/:9091`).
- Confirm blackbox probes now monitor the F5 public certs; set a cert-expiry alert on
  `probe_ssl_earliest_cert_expiry` (design doc §11).

---

## 9. Troubleshooting cheat-sheet

| Symptom | Check |
|---|---|
| Grafana dashboards 400 / "x509: certificate signed by unknown authority" | The rendered datasource got mangled by `envsubst`. Re-run `deploy.sh` on M1 (it exports `$__file{}` refs safe) then `docker restart onetech`. Verify: `ssh … 'docker logs onetech 2>&1 | grep -i datasource'` |
| No series for a new scrape job | On M2: `docker exec vmagent wget -qO- 'http://127.0.0.1:8429/api/v1/targets'`; then `curl -u … https://vmauth:8427/api/v1/query?query=…&nocache=1` from M1 (stale-query cache needs `&nocache=1`) |
| Keycloak metrics absent | M3 `9000` reachable only from `STORAGE_IP` (UFW). On M3: `curl -s http://10.0.170.115:9000/health/ready`. KC app metrics live on the **management** port, job `keycloak` in scrape.yml |
| `keycloak_user_events_total` empty | Event metrics need `KC_EVENT_METRICS_USER_ENABLED=true` on M3 + a real login to create series (counters reset on KC restart). Already set in compose |
| Blackbox probe fails (URL targets) | `http_2xx` module takes a **full URL**; `tls_conn` (tcp prober) takes **host:port, no scheme**. Wrong scheme on a `tls_conn` target ⇒ `probe_success=0` |
| PromQL parse error on `\.` | You wrote `foo\.bar` inside a quoted PromQL string — backslash is an invalid escape in PromQL. Use exact match `instance="a.b:3000"` or a regex without the dot-escape |
| Grafana API 401 with admin/esmacan | Basic auth is disabled; auth is **OIDC-only**. Check via `sudo docker exec onetech wget -q -S --no-check-certificate https://127.0.0.1:3000/api/health` (health doesn't need auth) |
| FortiGate/OCI/Veeam exporters missing | They run as separate containers (ports 9710/9108/9109…). Uncomment/fill the compose blocks in `machine2` compose and merge the jobs into `scrape.yml.tpl` (§1.6) |

---

## 10. Rollback (quick)

```bash
# Every deploy-step saves the composed tree under /opt/nama/<role>; a prior compose is kept as:
#   /opt/nama/<role>/docker-compose.yml.pre-<date>
# Revert = restore that file + `sudo ./deploy.sh` (or `docker compose up -d`), then re-run the
# matching ufw script. Pre-F5, rollback just re-enables the nip.io/TEMP rules. Post-F5, point
# the F5 pool back at the interim ports only if you kept the interim certs; otherwise use the
# design doc §16 (VM snapshot + pg_dump) as the guaranteed undo path.
```

---

## 11. Order-of-operations summary (cheat table)

| # | Phase | Where | Command / story |
|---|---|---|---|
| 1 | Prep | **WS** | `.env` create + set IPs, `gen-secrets.sh`, `gen-ca.sh`, `gen-vm-tls.sh`, `pin-images.sh`, merge M2 scrape targets |
| 2 | Bootstrap | **all VMs** | `bootstrap.sh mon` → `storage` → `auth` |
| 3 | Deploy | **M1** | `cd /opt/nama/mon && sudo ./deploy.sh` → verify |
| 4 | Deploy | **M3** | `cd /opt/nama/auth && sudo ./deploy.sh` → verify health/ready |
| 5 | Deploy | **M2** | `cd /opt/nama/storage && sudo ./deploy.sh` → verify targets + write path |
| 6 | Wiring | **M3 console** | client `grafana-nama` (secret = M1 `grafana_oidc_client_secret`), roles, PKCE |
| 7 | Login check | **browser** | Grafana → OIDC → dashboards with data |
| 8 | Firewall | **M1, M2, M3** | `ufw-m1.sh` / `ufw-m2.sh` / `ufw-m3.sh` (last!) |
| 9 | Day-2 | **all** | backups, health-report cron, secret rotation cadence |
| 10 | Cutover | **F5 + all VMs** | §8 sequence (DNS → VIPs → config per VM → firewall → validate) |