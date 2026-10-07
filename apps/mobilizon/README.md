# Mobilizon

Federated event and group platform — <https://mobilizon.org>, source at
<https://framagit.org/kaihuri/mobilizon>. Framasoft handed the project to
Kaihuri in 2025, so current images are `kaihuri/mobilizon` on Docker Hub, not
`framasoft/mobilizon`.

Served at <https://mobilizon.6j0.org>. The wildcard `https` listener on
`eg-public` and the `*.6j0.org` DNS record already cover it, so the HTTPRoute
from `values.yaml` is all the routing needed.

## How it is wired

- The in-house `devopscoop/app` chart (same as gathio), as a StatefulSet with a
  1Gi `uploads` volumeClaimTemplate at `/var/lib/mobilizon/uploads`.
- Image digest-pinned to 5.2.4 (multi-arch index: `linux/amd64` +
  `linux/arm64`). When bumping, re-derive the digest from the tag:
  `docker buildx imagetools inspect kaihuri/mobilizon:<tag>`.
- All config is `MOBILIZON_*` env vars, read by upstream's `config/docker.exs`
  (baked into the image as `/etc/mobilizon/config.exs`). The full list of
  variables is in that file. Plain ones are `envConfigMap` in `values.yaml`;
  the two signing keys are `envSecret` in the SOPS-encrypted `helm_secrets.yaml`.
- `command` is overridden only to recreate `uploads/exports/{csv,pdf,ods}` on
  the PVC before exec-ing the image's own entrypoint, which waits for Postgres,
  runs migrations, then starts. Without it, PDF and ODS participant exports
  fail: the PVC hides the directories the image pre-creates, and only the CSV
  exporter makes its own.
- The startup probe allows 10 minutes, because migrations on a fresh database
  run before the HTTP listener comes up.

## First admin account

Registrations are closed (`MOBILIZON_INSTANCE_REGISTRATIONS_OPEN: "false"`)
and no SMTP is configured, so create the admin from the CLI. The command
prints a generated password unless you pass `--password`:

```shell
kubectl -n mobilizon exec -it statefulset/mobilizon -- \
  /bin/mobilizon_ctl users.new <email> --admin
```

Then log in, create a profile, and fill in the instance settings
(Admin → Instance settings: description, contact, rules, terms).

Other `mobilizon_ctl` tasks (`users.modify`, `users.show`, `actors.refresh`,
`maintenance.fix_unattached_media_in_body`, …) run the same way.

## Email

Not configured. Mobilizon has no "mail off" switch, so it tries
`localhost:25` and logs the failures. Account confirmation, password resets and
participation notifications do not go out. To enable it, add
`MOBILIZON_SMTP_SERVER`, `_PORT`, `_TLS`/`_SSL` to `envConfigMap` and
`MOBILIZON_SMTP_USERNAME`/`_PASSWORD` to `envSecret` (`sops
apps/mobilizon/helm_secrets.yaml`), set real `MOBILIZON_INSTANCE_EMAIL` /
`MOBILIZON_REPLY_EMAIL` addresses, and only then consider opening registrations.

## Federation

`MOBILIZON_INSTANCE_HOST` is baked into every actor and event URL. Changing it
after the instance has federated orphans everything it has published, so treat
`mobilizon.6j0.org` as permanent.

## Database

CloudNativePG cluster `mobilizon-database` (`cloudnative-pg.yaml`), on CNPG's
PostGIS image — Mobilizon requires PostGIS for event locations. `postgis`,
`pg_trgm` and `unaccent` are created at bootstrap by `postInitApplicationSQL`,
because the app role is not a superuser and `postgis` is not a trusted
extension, so Mobilizon's own first migration cannot create it.

Mobilizon connects as the `mobilizon` owner role. Its password is pinned in
`db-owner.secrets.yaml` and read by both CNPG (at `initdb`) and the app (via
`secretKeyRef`), so it lives in exactly one file. As with PeerTube,
`initdb` only runs once: editing that file does not rotate the password on an
existing database.

Superuser access is disabled for the same reason as PeerTube's. Connect with:

```shell
kubectl exec -it -n mobilizon mobilizon-database-1 -c postgres -- psql -U postgres mobilizon
```

No backups are configured.

## Secrets

| File | Holds | Rotating it |
| --- | --- | --- |
| `helm_secrets.yaml` | `MOBILIZON_INSTANCE_SECRET_KEY_BASE`, `MOBILIZON_INSTANCE_SECRET_KEY` | Logs every user out; nothing else breaks |
| `db-owner.secrets.yaml` | `mobilizon` DB role password | `ALTER ROLE` in psql first, then the file |

## Local prototyping

```shell
helm install mobilizon oci://registry.gitlab.com/devopscoop/charts/app \
  --namespace mobilizon --version 0.11.1 \
  --values values.yaml --values <(sops -d helm_secrets.yaml)
```

This needs the `mobilizon-database` cluster and `mobilizon-db-owner` secret
applied first (`kubectl apply -f cloudnative-pg.yaml` and
`sops -d db-owner.secrets.yaml | kubectl apply -f -`).
