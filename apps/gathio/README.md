# Gathio

Self-hosted event organiser — <https://github.com/lowercasename/gathio>.

Scaffolded with `deploy_new_app.sh` against the in-house chart:

```shell
./deploy_new_app.sh --app-name gathio --repo-name devopscoop \
  --repo-url oci://registry.gitlab.com/devopscoop/charts \
  --chart-name app --chart-version 0.11.1
```

## How it is wired

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

1. **MongoDB.** Enable `- mongodb-gathio.yaml` in
   `flux/flux-system/kustomization.yaml` as well — this app `dependsOn` it, so
   Flux will not apply gathio until that Kustomization is ready. Credentials are
   already generated and matched on both sides. (Gathio does not crash when the
   DB is unreachable: it still starts and serves `/`, it just 500s on every
   event operation.)
1. **Contact email.** `config.yaml` has `email = "contact@6j0.org"` as a
   placeholder. `mail_service` is `none`, so gathio will not send mail (no event
   edit links by email, no attendee notifications) until it is set to
   `nodemailer`/`sendgrid`/`mailgun` with credentials in `helm_secrets.yaml`.
1. **Open instance.** `creator_email_addresses = []` means anyone who can reach
   the URL can create events. Populate it to restrict creation.
1. **Federation.** `is_federated = true` publishes events over ActivityPub using
   `domain`. Changing the domain later breaks existing federated events.
1. Uncomment `- gathio.yaml` in `flux/flux-system/kustomization.yaml`.

Already done: MongoDB is scaffolded in `apps/mongodb-gathio/`, and the
`gathio-6j0-org` HTTPS listener is in `apps/eg-custom-resources/gateway-public.yaml`.
DNS needs nothing — `*.6j0.org` is a wildcard record, so `gathio.6j0.org`
resolves and cert-manager's HTTP-01 challenge can complete on its own.

## MongoDB

Lives in [`../mongodb-gathio`](../mongodb-gathio/README.md) — chart
`groundhog2k/mongodb` 0.8.1, deployed into this same `gathio` namespace, so the
Service is `mongodb-gathio.gathio.svc.cluster.local:27017`. The app user's
password appears in both `apps/mongodb-gathio/helm_secrets.yaml`
(`userDatabase.password`) and this app's `GATHIO_MONGODB_URL`; rotate them
together. See that README for the rotation procedure and the driver/server
version caveat.

## Local prototyping

```shell
helm install gathio oci://registry.gitlab.com/devopscoop/charts/app \
  --namespace gathio --version 0.11.1 \
  --values values.yaml --values <(sops -d helm_secrets.yaml)
```
