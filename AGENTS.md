# AGENTS.md

`worclustershire-deploy` — Kubernetes cluster managed by Flux CD (GitOps). K8s platform: Talos.

Cluster identity lives in `variables.sh`: cluster `worclustershire`, repo `github.com/6j0-org/worclustershire-deploy`, `KUBECONFIG=~/.kube/worclustershire`. That file also pins the flux/kubectl/sops/yq versions `deploy.sh` installs.

## Commands

- `./deploy.sh` — bootstrap Flux, install managed binaries (kubectl, flux, sops, yq) into `bin/<os>-<arch>/`, reconcile. **It commits and pushes to `main` on its own** (with `git commit -n`) for each step that changes files; don't run it casually.
- `./deploy_new_app.sh app_name repo_name repo_url chart_name chart_version` — scaffold a new app from `apps/templates/helm/`, set up HelmRepository or OCIRepository, register with flux-system
- `./encrypt_secrets.sh` — encrypt all `*.yaml.decrypted` files via sops (runs automatically during deploy_new_app)
- Decrypt/view secrets: `sops apps/<app>/helm_secrets.yaml` (opens in editor; never edit with vim/cat)
- Test helm values locally: `helm install <app> <repo>/<chart> --values values.yaml --values <(sops -d helm_secrets.yaml)`
- Render an app the way Flux will: `kubectl kustomize apps/<app>` (no decryption happens — encrypted secret bodies render verbatim)
- Diff your overrides against chart defaults: use the `dyff`/`vim` one-liners at the top of each `values.yaml` (see below)

## App structure (`apps/<name>/`)

Each app is a kustomize directory managed by a HelmRelease. Files:

| File                              | Purpose                                                                        |
| --------------------------------- | ------------------------------------------------------------------------------ |
| `kustomization.yaml`              | Generates ConfigMap from `values.yaml` and Secret from `helm_secrets.yaml`     |
| `values.yaml`                     | Non-secret helm overrides (trim defaults; only keep changed values)            |
| `helm_secrets.yaml`               | SOPS-encrypted secrets (passwords, tokens) — edit via `sops`, never plain text |
| `release.yaml`                    | HelmRelease referencing the generated ConfigMap and Secret                     |
| `helmrepo.yaml` or `ocirepo.yaml` | Source repository definition (only one active)                                 |
| `namespace.yaml`                  | Namespace manifest                                                             |
| `kustomizeconfig.yaml`            | ConfigMap/Secret generator config                                              |

Optional per-app files, all of which must be listed in `kustomization.yaml`'s `resources:`:

- `*.secrets.yaml` — a real Kubernetes Secret manifest, SOPS-encrypted (only `data`/`stringData`). Distinct from `helm_secrets.yaml`, which is helm values.
- `<app>-httproute.yaml` — Gateway API route for charts with no built-in HTTPRoute support
- `<app>-auth-policy.yaml` — Envoy Gateway `SecurityPolicy` (basic auth)
- `README.md` — app-specific notes; read it before touching that app

Not every app dir is a Helm app: the `*-custom-resources` dirs (`eg-`, `cert-manager-`, `metallb-`) and `cnpg-cluster-nextcloud` are plain kustomize dirs with no `values.yaml` or `release.yaml`, scaffolded from `apps/templates/kustomize/`.

Registration: adding an app creates `flux/flux-system/<name>.yaml` (a Kustomization pointing to the app dir), referenced from `flux/flux-system/kustomization.yaml`.

## Enabling and disabling apps

`flux/flux-system/kustomization.yaml` is the single source of truth for what is actually deployed. Apps are toggled by **commenting/uncommenting** their line in `resources:`, usually with a trailing comment saying why. An app directory existing under `apps/` does **not** mean it is running — well over a third of them are currently commented out. Always check this file before assuming something is live or debugging why a change "did nothing".

Currently disabled but still described as active in older notes: `external-dns` and `ingress-nginx`. See the Ingress section.

## Secrets

- SOPS age encryption. Key file: `~/.config/sops/age/keys.txt` (itself age-encrypted with a password; `variables.sh` decrypts it into `SOPS_AGE_KEY`).
- `.sops.yaml` has two rules: `*secrets.yaml` files encrypt only `data`/`stringData` (so Kubernetes can still read `kind`/`apiVersion`); `*helm_secrets.yaml` files encrypt everything.
- `bin/*` and `*.decrypted` are gitignored. Never commit decrypted secrets.

## Adding a new app

1. Run `./deploy_new_app.sh <app_name> <repo_name> <repo_url> <chart_name> <chart_version>`
1. Edit `apps/<app_name>/values.yaml` — remove all defaults, keep only overrides; keep the generated `dyff`/`vim` header comments
1. If secrets needed: `sops apps/<app_name>/helm_secrets.yaml.decrypted`, move secrets from values.yaml into it
1. If it needs a hostname: add an HTTPRoute **and** a matching HTTPS listener in `apps/eg-custom-resources/gateway.yaml`
1. Uncomment the app in `flux/flux-system/kustomization.yaml` (the script adds the line; it is not enabled until it's uncommented)
1. Commit and push; Flux will reconcile automatically

## values.yaml conventions

- Every `values.yaml` starts with two helper comments naming the exact chart and version, e.g.
  ```
  # dyff between <(yq . <(helm show values oci://.../app --version 0.9.0)) <(yq eval '. * load("values.yaml")' <(helm show values oci://.../app --version 0.9.0))
  # vim -O <(helm show values oci://.../app --version 0.9.0) values.yaml
  ```
  Keep these in sync when bumping a chart version — they are how anyone re-derives which values are overrides vs. defaults.
- Prefer digest-pinned images with the human-readable version as a trailing comment:
  `repository: ghcr.io/kozea/radicale@sha256` + `tag: "<digest>" # 3.7.2`
- **Exception — lines with `# {"$imagepolicy": ...}`:** those tags are rewritten and pushed to `main` by Flux's ImageUpdateAutomation (`update.path: apps`, `strategy: Setters`). Only the in-house apps (`timetracker`, `youcandoithealth`, `chorechart`) use this. Editing those tag values by hand will be overwritten; change the ImagePolicy instead.

## In-house chart

Seven apps (`timetracker`, `chorechart`, `copyparty`, `oxicloud`, `radicale`, `hatsmith`, `youcandoithealth`) share the generic chart `oci://registry.gitlab.com/devopscoop/charts/app`, via an OCIRepository named `devopscoop-app` (naming scheme `${org_name}-${chart_name}`). Its `workloadType` value switches between Deployment and StatefulSet. When changing behavior for one of these apps, check whether the knob exists in that chart before adding raw manifests.

## Ingress / Gateway API

- **Envoy Gateway is the only enabled ingress path.** `apps/eg/` + `apps/eg-custom-resources/`. `ingress-nginx` is commented out in `flux/flux-system/kustomization.yaml`; leftover nginx `Ingress` annotations in app values are inert.
- There is a single `Gateway` named `eg` in `envoy-gateway-system` with **one explicit HTTPS listener per hostname** (`longhorn.6j0.org`, `immich.6j0.org`, `grafana.6j0.org`, …). There is **no** `*.6j0.org` wildcard listener — the only wildcards are `*.s3.garage.6j0.org` and `*.web.garage.6j0.org`. Adding a new subdomain therefore requires editing `apps/eg-custom-resources/gateway.yaml`, not just adding an HTTPRoute.
- Listener convention: `name` is the hostname with dots as dashes (`hatsmith-6j0-org`), TLS secret is `<name>-tls`, `allowedRoutes.namespaces.from: All`. HTTPRoutes attach with `parentRefs: [{name: eg, namespace: envoy-gateway-system}]` and no `sectionName` — Envoy matches on `hostnames`.
- TLS certs come from cert-manager via the `cert-manager.io/cluster-issuer: letsencrypt` annotation on the Gateway, using the ACME **HTTP-01** solver bound to Gateway API (`gatewayHTTPRoute: {}`) in `apps/cert-manager-custom-resources/clusterissuer.yaml`. Adding a listener with a fresh `certificateRefs` secret name is enough to get a cert; the DNS-01 (Cloudflare) solver is commented out.
- **DNS is currently manual.** `external-dns` is disabled, so a new HTTPRoute will *not* create the Porkbun record. When re-enabled it runs with `--source=gateway-httproute --domain-filter=6j0.org` and reads `PORKBUN_API_KEY` / `PORKBUN_SECRET_API_KEY` from a secret in the `external-dns` namespace.
- Charts without HTTPRoute support (longhorn, grafana, garage, immich, seafile, peertube, nextcloud-aio) get a standalone `<app>-httproute.yaml` in their app dir.
- **Basic auth has been migrated** off ingress-nginx annotations to Envoy Gateway `SecurityPolicy` (`longhorn`, `timetracker`, `chorechart`): a policy with `targetRefs` → the HTTPRoute and `basicAuth.users.name: basic-auth`, where `basic-auth` is a htpasswd Secret from the app's `auth.secrets.yaml`. Copy that pattern for new protected routes.

## Networking notes

`ipv6-problems.txt` is a dated (2026-06-06) layer-by-layer diagnosis of why IPv6 dual-stack doesn't work end to end. Short version: the cluster's service/pod CIDRs are IPv4-only and can't be changed on a running cluster, so the MetalLB IPv6 pool and the `ipFamily: DualStack` EnvoyProxy config have no IPv6 backends. Read it before spending time on IPv6.

## Common pitfalls

- **Volume permissions**: pods running as non-root need `podSecurityContext.fsGroup` set to the container's gid so PVCs are writable. Example: radicale uses `fsGroup: 1000`.
- **OCI vs Helm repo**: `deploy_new_app.sh` auto-configures based on whether `repo_url` starts with `oci:`. If switching later, swap `helmrepo.yaml` ↔ `ocirepo.yaml` references in `kustomization.yaml` and update `release.yaml` `.spec.chartRef` or `.spec.chart`.
- **Image automation**: `deploy_new_app.sh` adds an ImageRepository + ImagePolicy for `ghcr.io/devopscoop/<app_name>` to `flux/flux-system/imagerepositories.yaml` and `imagepolicies.yaml`. For third-party charts this is wrong — fix the image path or delete both blocks.
- **`deploy.sh` rewrites the string `project1-dev`** to `${cluster_name}` across every file in the repo (except itself) and commits the result. Don't introduce that literal.

## Working in this repo

- Always run `git pull` before making any edits or creating files — Flux's image automation pushes commits to `main` on its own.
- CI: `.github/workflows/claude.yml` (@claude mentions) and `claude-code-review.yml` (auto review on PRs). Both pin `claude-opus-5` and action SHAs; the review workflow's `--allowed-tools` list is load-bearing — see the comments in the file before editing.
