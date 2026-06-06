# external-snapshotter

Enables external-snapshotter (AKA CSI Snapshotter) support for clusters that don't have it built-in (like Talos) via the [external-snapshotter](https://github.com/kubernetes-csi/external-snapshotter/) project. AWS EKS clusters don't need this.

The GitRepository source and Kustomizations live in `flux/flux-system/`:

- `external-snapshotter.yaml` — GitRepository + Kustomization `external-snapshotter-crds` (CRDs via `client/config/crd`) + Kustomization `external-snapshotter-snapshot-controller` (deployment via `deploy/kubernetes/snapshot-controller`)

See also:
- https://longhorn.io/docs/1.12.0/snapshots-and-backups/csi-snapshot-support/enable-csi-snapshot-support/#if-your-kubernetes-distribution-does-not-bundle-the-snapshot-controller
