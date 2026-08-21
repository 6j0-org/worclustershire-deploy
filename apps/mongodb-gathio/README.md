# MongoDB (gathio)

Single-node MongoDB backing [`../gathio`](../gathio/README.md). Named after the
`valkey-nextcloud` pattern: a dependency chart deployed into its consumer's
namespace, so it lives in `gathio`, not one of its own.

Chart: `mongodb` 0.8.1 (appVersion 8.3.8) from
<https://groundhog2k.github.io/helm-charts> — a plain StatefulSet around the
official `mongo` image, no operator and no CRDs. Picked over Bitnami, whose
chart can only pull `bitnami/mongodb:latest` since the August 2025 catalogue
change moved every pinned tag to the frozen `bitnamilegacy` repo, and over
Percona's `psmdb` operator, which is a lot of machinery for one instance.

Scaffolded by hand from `apps/templates/helm/` rather than with
`deploy_new_app.sh`, because that script's HelmRepository branch runs
`helm repo add` (writes to `~/.config/helm`) and registers the app *enabled* in
`flux/flux-system/kustomization.yaml`. The resulting files are the same.

## Connection details

| | |
| --- | --- |
| Service | `mongodb-gathio.gathio.svc.cluster.local:27017` |
| Headless | `mongodb-gathio-internal` |
| Database | `gathio` |
| App user | `gathio`, `readWrite` + `dbAdmin` **on the `gathio` database** |
| Root user | `root`, in `admin` |
| Storage | 5Gi PVC, default StorageClass (Longhorn) |

Because the chart's `userDatabase` block runs `createUser` against the `gathio`
database itself, gathio's connection string needs no `?authSource=admin`.

Credentials are in `helm_secrets.yaml` (`sops apps/mongodb-gathio/helm_secrets.yaml`).
The app user's password is duplicated in `apps/gathio/helm_secrets.yaml` as part
of `GATHIO_MONGODB_URL` — **change both together or gathio cannot log in.**

> **These values only apply on first start.** `MONGO_INITDB_*` and the init
> script are the official `mongo` image's behaviour: they run once, against an
> empty data directory. Editing `helm_secrets.yaml` after the PVC exists changes
> nothing in the database. To rotate, exec in and do it in mongosh:
>
> ```shell
> kubectl -n gathio exec -it statefulset/mongodb-gathio -- mongosh \
>   -u root -p --authenticationDatabase admin \
>   --eval 'db.getSiblingDB("gathio").changeUserPassword("gathio", "<new>")'
> ```
>
> then update both `helm_secrets.yaml` files and restart gathio.

## Notes

- Standalone, not a replica set (`replicaSet.enabled: false`, the chart
  default) — so no transactions and no failover. Gathio's mongoose 5 driver
  doesn't use transactions.
- Gathio 1.6.x pins `mongoose ^5.13.22` (Node driver 3.x), which MongoDB only
  officially supports against server 4.4 and older. Upstream runs `mongo:latest`
  in `docker-compose.yml` and CI, so 8.x is what it is actually tested against —
  but the image here is digest-pinned so a server major cannot change on its
  own. On x86-64, MongoDB 5.0+ requires AVX support on the node CPU.
- The chart's defaults already run non-root (uid/gid 999, `fsGroup: 999`,
  `readOnlyRootFilesystem: true`); nothing in `values.yaml` overrides that.
- No backups are configured. `metrics.enabled` (percona/mongodb_exporter) is
  off; turn it on if you want it in kube-prometheus-stack.
