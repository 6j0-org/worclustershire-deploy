# Gathio

Self-hosted event organiser — <https://github.com/lowercasename/gathio>.

Scaffolded with `deploy_new_app.sh` against the in-house chart:

```shell
./deploy_new_app.sh --app-name gathio --repo-name devopscoop \
  --repo-url oci://registry.gitlab.com/devopscoop/charts \
  --chart-name app --chart-version 0.11.1
```

## How it is wired

This directory holds **two** HelmReleases: gathio and the MongoDB it needs. The
`mongodb.*` files are the second release's half of the same four-file pattern
(source, release, values, helm secrets), and gathio's HelmRelease `dependsOn`
the mongodb one. The dot in `mongodb.helm_secrets.yaml` is load-bearing —
`.sops.yaml` picks its rule by filename, and `mongodb-helm_secrets.yaml` would
match no rule at all.

- StatefulSet, because user-uploaded event images are written to disk at
  `/app/public/events`. That path is the `events` volumeClaimTemplate (5Gi).
- `config.yaml` holds the `config` ConfigMap, mounted over
  `/app/config/config.toml` — the only config file gathio reads (it looks for
  `./config/config.toml` relative to its `/app` workdir).
- Any string in `config.toml` can interpolate a `GATHIO_`-prefixed environment
  variable as `${GATHIO_FOO}`. The MongoDB URL is set that way, from
  `envSecret.GATHIO_MONGODB_URL` in the SOPS-encrypted `helm_secrets.yaml`.
- Image is digest-pinned to 1.6.5 from `ghcr.io/lowercasename/gathio` (upstream
  publishes `linux/amd64`, `linux/arm/v7` and `linux/arm64`). Note upstream
  re-pushes release tags: the `1.6.4` tag no longer resolves to the digest that
  was labelled 1.6.4, so always re-derive the digest from the tag when bumping.

## Before this can be enabled

1. **MongoDB.** Nothing to do — it deploys from this directory alongside the
   app, and credentials are already generated and matched on both sides. See
   [MongoDB](#mongodb) below. (Gathio does not crash when the DB is
   unreachable: it still starts and serves `/`, it just 500s on every event
   operation.)
1. **Contact email.** Set to `b41jplz8@anonaddy.me` in `config.yaml`.
   `mail_service` is `none`, so gathio will not send mail (no event
   edit links by email, no attendee notifications) until it is set to
   `nodemailer`/`sendgrid`/`mailgun` with credentials in `helm_secrets.yaml`.
1. **Open instance.** `creator_email_addresses = []` means anyone who can reach
   the URL can create events. Populate it to restrict creation.
1. **Federation.** `is_federated = true` publishes events over ActivityPub using
   `domain`. Changing the domain later breaks existing federated events.
1. Uncomment `- gathio.yaml` in `flux/flux-system/kustomization.yaml`.

Already done: MongoDB ships in this directory, and the `gathio-6j0-org` HTTPS
listener is in `apps/eg-custom-resources/gateway-public.yaml`.
DNS needs nothing — `*.6j0.org` is a wildcard record, so `gathio.6j0.org`
resolves and cert-manager's HTTP-01 challenge can complete on its own.

## MongoDB

Chart: `mongodb` 0.8.1 (appVersion 8.3.8) from
<https://groundhog2k.github.io/helm-charts> — a plain StatefulSet around the
official `mongo` image, no operator and no CRDs. Picked over Bitnami, whose
chart can only pull `bitnami/mongodb:latest` since the August 2025 catalogue
change moved every pinned tag to the frozen `bitnamilegacy` repo, and over
Percona's `psmdb` operator, which is a lot of machinery for one instance.

Its four files (`mongodb.helmrepo.yaml`, `mongodb.release.yaml`,
`mongodb.values.yaml`, `mongodb.helm_secrets.yaml`) were written by hand rather
than scaffolded, since `deploy_new_app.sh` only ever produces a whole app
directory of its own.

### Connection details

| | |
| --- | --- |
| Service | `mongodb.gathio.svc.cluster.local:27017` |
| Headless | `mongodb-internal` |
| Database | `gathio` |
| App user | `gathio`, `readWrite` + `dbAdmin` **on the `gathio` database** |
| Root user | `root`, in `admin` |
| Storage | 5Gi PVC, default StorageClass (Longhorn) |

Because the chart's `userDatabase` block runs `createUser` against the `gathio`
database itself, gathio's connection string needs no `?authSource=admin`.

Credentials live in `mongodb.helm_secrets.yaml` — edit with
`sops apps/gathio/mongodb.helm_secrets.yaml`. The app user's password is
duplicated in the app's own `helm_secrets.yaml` as part of
`GATHIO_MONGODB_URL` — **change both together or gathio cannot log in.**

> **These values only apply on first start.** `MONGO_INITDB_*` and the init
> script are the official `mongo` image's behaviour: they run once, against an
> empty data directory. Editing `mongodb.helm_secrets.yaml` after the PVC
> exists changes nothing in the database. To rotate, exec in and do it in mongosh:
>
> ```shell
> kubectl -n gathio exec -it statefulset/mongodb -- mongosh \
>   -u root -p --authenticationDatabase admin \
>   --eval 'db.getSiblingDB("gathio").changeUserPassword("gathio", "<new>")'
> ```
>
> then update both secret files and restart gathio.

### MongoDB notes

- Standalone, not a replica set (`replicaSet.enabled: false`, the chart
  default) — so no transactions and no failover. Gathio's mongoose 5 driver
  doesn't use transactions.
- Gathio 1.6.x pins `mongoose ^5.13.22` (Node driver 3.x), which MongoDB only
  officially supports against server 4.4 and older. Upstream runs `mongo:latest`
  in `docker-compose.yml` and CI, so 8.x is what it is actually tested against —
  but the image here is digest-pinned so a server major cannot change on its
  own. On x86-64, MongoDB 5.0+ requires AVX support on the node CPU.
- The chart's defaults already run non-root (uid/gid 999, `fsGroup: 999`,
  `readOnlyRootFilesystem: true`); nothing in `mongodb.values.yaml`
  overrides that.
- No backups are configured. `metrics.enabled` (percona/mongodb_exporter) is
  off; turn it on if you want it in kube-prometheus-stack.

## Local prototyping

```shell
helm install mongodb groundhog2k/mongodb \
  --namespace gathio --version 0.8.1 \
  --values mongodb.values.yaml --values <(sops -d mongodb.helm_secrets.yaml)

helm install gathio oci://registry.gitlab.com/devopscoop/charts/app \
  --namespace gathio --version 0.11.1 \
  --values values.yaml --values <(sops -d helm_secrets.yaml)
```
