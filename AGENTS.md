# worclustershire-deploy

Kubernetes cluster managed by Flux CD (GitOps). K8s platform: Talos.

## Commands

- `./deploy.sh` — bootstrap Flux, install managed binaries (kubectl, flux, sops, yq) into `bin/`, reconcile
- `./deploy_new_app.sh app_name repo_name repo_url chart_name chart_version` — scaffold a new app from `apps/templates/helm/`, set up HelmRepository or OCIRepository, register with flux-system
- `./encrypt_secrets.sh` — encrypt all `*.yaml.decrypted` files via sops (runs automatically during deploy_new_app)
- Decrypt/view secrets: `sops apps/<app>/helm_secrets.yaml` (opens in editor; never edit with vim/cat)
- Test helm values locally: `helm install <app> <repo>/<chart> --values values.yaml --values <(sops -d helm_secrets.yaml)`

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

Registration: adding an app creates `flux/flux-system/<name>.yaml` (a Kustomization pointing to the app dir), referenced from `flux/flux-system/kustomization.yaml`.

## Secrets

- SOPS age encryption. Key file: `~/.config/sops/age/keys.txt` (decrypt with age password).
- `.sops.yaml` has two rules: `*secrets.yaml` files encrypt only `data`/`stringData`; `*helm_secrets.yaml` files encrypt everything.
- `bin/*` and `*.decrypted` are gitignored. Never commit decrypted secrets.

## Adding a new app

1. Run `./deploy_new_app.sh <app_name> <repo_name> <repo_url> <chart_name> <chart_version>`
1. Edit `apps/<app_name>/values.yaml` — remove all defaults, keep only overrides
1. If secrets needed: `sops apps/<app_name>/helm_secrets.yaml.decrypted`, move secrets from values.yaml into it
1. Commit and push; Flux will reconcile automatically

## Common pitfalls

- **Volume permissions**: pods running as non-root need `podSecurityContext.fsGroup` set to the container's gid so PVCs are writable. Example: radicale uses `fsGroup: 1000`.
- **OCI vs Helm repo**: `deploy_new_app.sh` auto-configures based on whether `repo_url` starts with `oci:`. If switching later, swap `helmrepo.yaml` ↔ `ocirepo.yaml` references in `kustomization.yaml` and update `release.yaml` `.spec.chartRef` or `.spec.chart`.
- **Image automation**: `deploy_new_app.sh` adds an ImageRepository + ImagePolicy for `ghcr.io/dfinity-ops/<app_name>` to `flux/flux-system/imagerepositories.yaml` and `imagepolicies.yaml`. Update the image org/path if different.
