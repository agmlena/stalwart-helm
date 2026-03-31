# stalwart-mail

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square)
![AppVersion: 0.14.0](https://img.shields.io/badge/AppVersion-0.14.0-informational?style=flat-square)

Stalwart Mail Server - full mail stack (SMTP, IMAP, JMAP, CalDAV, CardDAV) with optional webmail and antivirus.

## TL;DR

```console
helm install my-mail ./stalwart-mail \
  --set hostname=mail.example.com \
  --set stalwart.storage.postgres.host=postgres.example.com \
  --set stalwart.storage.postgres.existingSecret=my-db-secret
```

## Introduction

This chart deploys [Stalwart Mail Server](https://stalw.art) on Kubernetes. Stalwart is a single Rust binary that implements SMTP, IMAP, JMAP, CalDAV, CardDAV, and ManageSieve. The chart supports:

- **PostgreSQL** (recommended) or **RocksDB** storage backends
- **S3-compatible** blob storage for email bodies and attachments
- **OIDC** authentication via any OpenID Connect provider
- **SnappyMail** webmail frontend
- **ClamAV** antivirus integration
- **Automated backups** via pg_dump and/or restic
- **NetworkPolicy** for pod-to-pod traffic isolation
- **Pod Security Standards** "restricted" profile out of the box

## Prerequisites

- Kubernetes >= 1.21
- Helm >= 3.8
- A PostgreSQL database (CloudNativePG, Zalando Postgres Operator, managed, or external)
- A LoadBalancer-capable network (MetalLB, cloud LB) for SMTP/IMAP ports
- [cert-manager](https://cert-manager.io/) (if `certificate.enabled=true`)

## Installing the Chart

```console
helm install my-mail ./stalwart-mail \
  --namespace mail --create-namespace \
  --set hostname=mail.example.com \
  --set stalwart.storage.postgres.host=postgres.svc.cluster.local \
  --set stalwart.storage.postgres.existingSecret=my-db-secret
```

Or with a values file:

```console
helm install my-mail ./stalwart-mail -n mail -f my-values.yaml
```

## Uninstalling the Chart

```console
helm uninstall my-mail -n mail
```

> **Note:** PersistentVolumeClaims for ClamAV, backup PVCs, and local data (if enabled) are not deleted automatically. Remove them manually if you want to clean up completely.

## Configuration

### PostgreSQL Backend

PostgreSQL is the default and recommended backend. All data (mail, FTS index, lookup tables) is stored in PostgreSQL, making pods fully stateless and safe for rolling updates.

```yaml
stalwart:
  storage:
    backend: postgres
    postgres:
      host: postgres.svc.cluster.local
      port: 5432
      existingSecret: my-db-secret  # recommended
```

### Using Existing Secrets

Each functional area uses its own dedicated Secret. You can either let the chart create them (by setting credentials directly) or reference pre-existing Secrets:

| Area | Values key | Default secret keys |
|------|-----------|-------------------|
| PostgreSQL | `stalwart.storage.postgres.existingSecret` | `user`, `dbname`, `password` |
| S3 | `stalwart.storage.s3.existingSecret` | `access-key`, `secret-key` |
| OIDC | `stalwart.oidc.existingSecret` | `oidc-client-secret` |
| Restic | `backup.restic.existingSecret` | `RESTIC_PASSWORD` + provider credentials |

The key names are configurable via `secretUserKey`, `secretDatabaseKey`, etc. This makes the chart compatible with secrets created by CloudNativePG, Zalando Postgres Operator, and similar operators.

Example with CloudNativePG (which creates a secret with `user`, `dbname`, `password` keys):

```yaml
stalwart:
  storage:
    postgres:
      host: pg-cluster-rw.db.svc
      existingSecret: pg-cluster-app
      secretUserKey: user
      secretDatabaseKey: dbname
      secretPasswordKey: password
```

### S3 Blob Storage

For large deployments, email bodies and attachments can be stored in S3-compatible object storage instead of PostgreSQL:

```yaml
stalwart:
  storage:
    blobBackend: s3
    s3:
      bucket: mail-blobs
      region: us-east-1
      endpoint: https://s3.example.com  # for MinIO, Ceph, etc.
      existingSecret: my-s3-secret
```

### OIDC Authentication

Stalwart can validate OAUTHBEARER tokens against any OIDC provider (Authelia, Keycloak, Authentik, etc.). Mail clients must obtain tokens from the provider themselves; Stalwart only validates them.

```yaml
stalwart:
  oidc:
    enabled: true
    endpointUrl: https://auth.example.com/api/oidc/userinfo
    endpointMethod: userinfo  # or "introspect"
    auth:
      method: basic           # "none", "basic", or "token"
      username: stalwart      # OIDC client_id
    existingSecret: my-oidc-secret
```

When OIDC is enabled, `directory = "oidc"` is set in Stalwart's config. The internal directory is kept as a fallback for local admin accounts.

> **Note:** Stalwart only learns about OIDC-managed users after their first login. Until then, inbound mail for those addresses will bounce. Pre-create accounts via the admin API if needed.

### Webmail (SnappyMail)

```yaml
webmail:
  enabled: true

ingress:
  enabled: true
  hosts:
    - host: mail.example.com
      paths:
        - path: /
          pathType: Prefix
          service: stalwart
```

SnappyMail is automatically added to the Ingress at the path configured in `webmail.ingressPath` (default: `/webmail`).

### Antivirus (ClamAV)

```yaml
clamav:
  enabled: true
```

ClamAV is deployed as a separate Deployment with its own PVC for the virus database. It takes several minutes to load the virus DB on startup (the startup probe allows up to 10 minutes).

Configure Stalwart to use ClamAV via `configOverrides`:

```yaml
stalwart:
  configOverrides: |
    [spam-filter.header.antivirus]
    enable = true
    host = "RELEASE-NAME-stalwart-mail-clamav"
    port = 3310
```

### Backups

Three backup methods are available:

| Method | Backend | Description |
|--------|---------|-------------|
| `pgdump-restic` | PostgreSQL | pg_dump to emptyDir, then push to restic (recommended) |
| `pgdump` | PostgreSQL | pg_dump to a PVC with file rotation |
| *(auto)* | RocksDB | restic backup of the data PVC |

#### pg_dump + restic (recommended for PostgreSQL)

```yaml
backup:
  enabled: true
  method: pgdump-restic
  schedule: "0 3 * * *"
  restic:
    repository: s3:s3.example.com/mail-backups
    existingSecret: restic-credentials
  retention:
    keepDaily: 7
    keepWeekly: 4
    keepMonthly: 6
```

The restic Secret must contain `RESTIC_PASSWORD` and any credentials required by the repository backend (e.g. `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` for S3).

#### pg_dump to PVC

```yaml
backup:
  enabled: true
  method: pgdump
  pgdump:
    retainCount: 7
    persistence:
      size: 20Gi
```

Restore with:

```console
pg_restore -h HOST -U USER -d DB /backup/stalwart-YYYYMMDD-HHMMSS.dump
```

### TLS / cert-manager

The chart can create a cert-manager Certificate resource:

```yaml
certificate:
  enabled: true
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - mail.example.com
  secretName: mail-tls
```

Mount the resulting TLS secret into Stalwart via `extraVolumeMounts` and configure TLS in `configOverrides`.

### Network Policies

```yaml
networkPolicy:
  enabled: true
```

Three NetworkPolicies are created:

- **Stalwart**: ingress on all listener ports; egress to DNS, PostgreSQL, S3, ClamAV, outbound SMTP, and HTTP/HTTPS (OCSP, ACME)
- **ClamAV**: ingress only from Stalwart pods; egress to DNS and HTTP/HTTPS (freshclam updates)
- **Webmail**: ingress on service port; egress to DNS and Stalwart IMAP/HTTP

Each policy supports `extraIngress` and `extraEgress` for custom rules.

### Prometheus Metrics

```yaml
metrics:
  enabled: true
  interval: 30s
```

Creates a ServiceMonitor resource for Prometheus Operator.

### Security

All pods follow the Pod Security Standards **"restricted"** profile by default:

- `runAsNonRoot: true` with explicit UID/GID
- `readOnlyRootFilesystem: true` with emptyDir for `/tmp`
- `allowPrivilegeEscalation: false`
- `capabilities: drop: [ALL]` (Stalwart adds `NET_BIND_SERVICE` for privileged ports)
- `seccompProfile: RuntimeDefault`
- `automountServiceAccountToken: false` on all pods

## Parameters

### Global

| Parameter | Description | Default |
|-----------|-------------|---------|
| `hostname` | Mail server FQDN | `mail.example.com` |

### Stalwart

| Parameter | Description | Default |
|-----------|-------------|---------|
| `stalwart.image.repository` | Image repository | `stalwartlabs/stalwart` |
| `stalwart.image.tag` | Image tag | `.Chart.AppVersion` |
| `stalwart.image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `stalwart.replicas` | Number of replicas | `1` |
| `stalwart.revisionHistoryLimit` | Deployment revision history | `3` |
| `stalwart.terminationGracePeriodSeconds` | Graceful shutdown timeout | `60` |
| `stalwart.strategy` | Deployment strategy | `RollingUpdate` |
| `stalwart.resources` | Resource requests/limits | `500m/512Mi` - `2/2Gi` |
| `stalwart.env` | Extra environment variables | `[]` |
| `stalwart.extraVolumeMounts` | Extra volume mounts | `[]` |
| `stalwart.extraVolumes` | Extra volumes | `[]` |
| `stalwart.imagePullSecrets` | Image pull secrets | `[]` |
| `stalwart.nodeSelector` | Node selector | `{}` |
| `stalwart.tolerations` | Tolerations | `[]` |
| `stalwart.affinity` | Affinity rules | `{}` |
| `stalwart.topologySpreadConstraints` | Topology spread constraints | `[]` |
| `stalwart.podAnnotations` | Pod annotations | `{}` |
| `stalwart.podSecurityContext` | Pod security context | *restricted profile* |
| `stalwart.securityContext` | Container security context | *restricted + NET_BIND_SERVICE* |
| `stalwart.configOverrides` | Raw TOML appended to config | `""` |
| `stalwart.logLevel` | Log level | `info` |

### Storage

| Parameter | Description | Default |
|-----------|-------------|---------|
| `stalwart.storage.backend` | Primary backend: `postgres` or `rocksdb` | `postgres` |
| `stalwart.storage.blobBackend` | Blob backend: `postgres` or `s3` | `postgres` |
| `stalwart.storage.dataDir` | Local data directory | `/opt/stalwart-mail/data` |
| `stalwart.storage.postgres.host` | PostgreSQL hostname | `""` |
| `stalwart.storage.postgres.port` | PostgreSQL port | `5432` |
| `stalwart.storage.postgres.database` | Database name | `stalwart` |
| `stalwart.storage.postgres.user` | Username | `stalwart` |
| `stalwart.storage.postgres.password` | Password | `""` |
| `stalwart.storage.postgres.existingSecret` | Existing Secret name | `""` |
| `stalwart.storage.postgres.secretUserKey` | Key for username | `user` |
| `stalwart.storage.postgres.secretDatabaseKey` | Key for database name | `dbname` |
| `stalwart.storage.postgres.secretPasswordKey` | Key for password | `password` |
| `stalwart.storage.postgres.tls.enabled` | Enable TLS | `false` |
| `stalwart.storage.postgres.tls.allowInvalidCerts` | Allow invalid certs | `false` |
| `stalwart.storage.postgres.pool.maxConnections` | Connection pool size | `10` |
| `stalwart.storage.s3.bucket` | S3 bucket | `""` |
| `stalwart.storage.s3.region` | S3 region | `us-east-1` |
| `stalwart.storage.s3.endpoint` | Custom S3 endpoint | `""` |
| `stalwart.storage.s3.accessKey` | S3 access key | `""` |
| `stalwart.storage.s3.secretKey` | S3 secret key | `""` |
| `stalwart.storage.s3.existingSecret` | Existing Secret name | `""` |
| `stalwart.storage.s3.timeout` | Request timeout | `30s` |

### Persistence

| Parameter | Description | Default |
|-----------|-------------|---------|
| `stalwart.persistence.enabled` | Enable local PVC | `false` |
| `stalwart.persistence.storageClass` | Storage class | `""` |
| `stalwart.persistence.accessMode` | Access mode | `ReadWriteOnce` |
| `stalwart.persistence.size` | Volume size | `10Gi` |
| `stalwart.persistence.existingClaim` | Existing PVC name | `""` |

### OIDC

| Parameter | Description | Default |
|-----------|-------------|---------|
| `stalwart.oidc.enabled` | Enable OIDC directory | `false` |
| `stalwart.oidc.endpointUrl` | UserInfo/Introspection URL | `""` |
| `stalwart.oidc.endpointMethod` | `userinfo` or `introspect` | `userinfo` |
| `stalwart.oidc.timeout` | HTTP timeout | `15s` |
| `stalwart.oidc.auth.method` | `none`, `basic`, or `token` | `none` |
| `stalwart.oidc.auth.username` | Client ID (for basic auth) | `""` |
| `stalwart.oidc.auth.secret` | Client secret / bearer token | `""` |
| `stalwart.oidc.existingSecret` | Existing Secret name | `""` |
| `stalwart.oidc.secretKey` | Key in the Secret | `oidc-client-secret` |
| `stalwart.oidc.fields.email` | Email claim name | `email` |
| `stalwart.oidc.fields.username` | Username claim name | `preferred_username` |
| `stalwart.oidc.fields.fullName` | Display name claim | `name` |

### Listeners

| Parameter | Description | Default |
|-----------|-------------|---------|
| `stalwart.listeners.smtp.port` | SMTP | `25` |
| `stalwart.listeners.smtps.port` | SMTPS (implicit TLS) | `465` |
| `stalwart.listeners.submission.port` | Submission | `587` |
| `stalwart.listeners.imap.port` | IMAP | `143` |
| `stalwart.listeners.imaps.port` | IMAPS (implicit TLS) | `993` |
| `stalwart.listeners.sieve.port` | ManageSieve | `4190` |
| `stalwart.listeners.https.port` | HTTPS (web UI) | `443` |
| `stalwart.listeners.http.port` | HTTP (health/metrics) | `8080` |

### Services

| Parameter | Description | Default |
|-----------|-------------|---------|
| `mailService.type` | Mail service type | `LoadBalancer` |
| `mailService.annotations` | Service annotations | `{}` |
| `mailService.externalTrafficPolicy` | Traffic policy | `Local` |
| `mailService.loadBalancerIP` | Static IP | `""` |
| `webService.type` | Web service type | `ClusterIP` |
| `webService.annotations` | Service annotations | `{}` |

### ServiceAccount

| Parameter | Description | Default |
|-----------|-------------|---------|
| `serviceAccount.create` | Create ServiceAccount | `true` |
| `serviceAccount.name` | ServiceAccount name | chart fullname |
| `serviceAccount.annotations` | Annotations | `{}` |
| `serviceAccount.automountServiceAccountToken` | Mount API token | `false` |

### Ingress

| Parameter | Description | Default |
|-----------|-------------|---------|
| `ingress.enabled` | Enable Ingress | `false` |
| `ingress.className` | Ingress class | `""` |
| `ingress.annotations` | Annotations | `{}` |
| `ingress.hosts` | Host rules | *see values.yaml* |
| `ingress.tls` | TLS configuration | `[]` |

### Certificate

| Parameter | Description | Default |
|-----------|-------------|---------|
| `certificate.enabled` | Create Certificate | `false` |
| `certificate.issuerRef.name` | Issuer name | `letsencrypt-prod` |
| `certificate.issuerRef.kind` | Issuer kind | `ClusterIssuer` |
| `certificate.dnsNames` | DNS names | `[]` |
| `certificate.secretName` | TLS secret name | `mail-tls` |

### Webmail

| Parameter | Description | Default |
|-----------|-------------|---------|
| `webmail.enabled` | Enable SnappyMail | `false` |
| `webmail.image.repository` | Image repository | `djmaze/snappymail` |
| `webmail.image.tag` | Image tag | `2.38.2` |
| `webmail.replicas` | Number of replicas | `1` |
| `webmail.resources` | Resource requests/limits | `100m/128Mi` - `500m/256Mi` |
| `webmail.service.port` | Service port | `8888` |
| `webmail.ingressPath` | Ingress path prefix | `/webmail` |

### ClamAV

| Parameter | Description | Default |
|-----------|-------------|---------|
| `clamav.enabled` | Enable ClamAV | `false` |
| `clamav.image.repository` | Image repository | `clamav/clamav` |
| `clamav.image.tag` | Image tag | `1.4` |
| `clamav.replicas` | Number of replicas | `1` |
| `clamav.resources` | Resource requests/limits | `200m/1Gi` - `1/2Gi` |
| `clamav.persistence.enabled` | Persist virus DB | `true` |
| `clamav.persistence.size` | Volume size | `5Gi` |
| `clamav.service.port` | clamd TCP port | `3310` |

### Backup

| Parameter | Description | Default |
|-----------|-------------|---------|
| `backup.enabled` | Enable backup CronJob | `false` |
| `backup.schedule` | Cron schedule | `0 3 * * *` |
| `backup.method` | `pgdump-restic` or `pgdump` | `pgdump-restic` |
| `backup.successfulJobsHistoryLimit` | Successful jobs to retain | `3` |
| `backup.failedJobsHistoryLimit` | Failed jobs to retain | `3` |
| `backup.startingDeadlineSeconds` | Late start deadline | `3600` |
| `backup.pgdump.image.tag` | pg_dump image tag | `17-alpine` |
| `backup.pgdump.persistence.size` | PVC size (pgdump method) | `20Gi` |
| `backup.pgdump.retainCount` | Dump files to keep | `7` |
| `backup.restic.image.tag` | restic image tag | `0.17.3` |
| `backup.restic.repository` | Restic repository URL | `""` |
| `backup.restic.existingSecret` | Secret with RESTIC_PASSWORD | `""` |
| `backup.retention.keepDaily` | Daily snapshots | `7` |
| `backup.retention.keepWeekly` | Weekly snapshots | `4` |
| `backup.retention.keepMonthly` | Monthly snapshots | `6` |
| `backup.resources` | Resource requests/limits | `200m/256Mi` - `1/1Gi` |

### Network Policy

| Parameter | Description | Default |
|-----------|-------------|---------|
| `networkPolicy.enabled` | Enable NetworkPolicies | `false` |
| `networkPolicy.stalwart.extraIngress` | Extra ingress rules | `[]` |
| `networkPolicy.stalwart.extraEgress` | Extra egress rules | `[]` |
| `networkPolicy.webmail.extraIngress` | Extra ingress rules | `[]` |
| `networkPolicy.webmail.extraEgress` | Extra egress rules | `[]` |
| `networkPolicy.clamav.extraIngress` | Extra ingress rules | `[]` |
| `networkPolicy.clamav.extraEgress` | Extra egress rules | `[]` |

### Monitoring

| Parameter | Description | Default |
|-----------|-------------|---------|
| `metrics.enabled` | Enable ServiceMonitor | `false` |
| `metrics.interval` | Scrape interval | `30s` |
| `metrics.path` | Metrics path | `/metrics` |
| `metrics.port` | Metrics port | `http` |

## DNS and MX Setup

After installation, configure DNS records:

```
; MX record — directs mail to your server
example.com.    IN  MX  10  mail.example.com.

; A record — points to the LoadBalancer IP
mail.example.com.  IN  A  <EXTERNAL-IP>

; SPF — authorizes the server to send mail for the domain
example.com.    IN  TXT "v=spf1 a:mail.example.com -all"

; DKIM — configure via the Stalwart admin UI, then add the TXT record
; DMARC
_dmarc.example.com.  IN  TXT "v=DMARC1; p=reject; rua=mailto:dmarc@example.com"

; Reverse DNS (PTR) — configure with your hosting provider
<EXTERNAL-IP>   IN  PTR mail.example.com.
```

Get the LoadBalancer IP:

```console
kubectl get svc -n mail my-mail-stalwart-mail-mail -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

## Upgrading

### From 0.x to 0.x

No breaking changes yet. This section will be updated as the chart evolves.

## Links

- [Stalwart Mail Server](https://stalw.art)
- [Stalwart Documentation](https://stalw.art/docs/)
- [Stalwart GitHub](https://github.com/stalwartlabs/stalwart)
