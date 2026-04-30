# Nextcloud AppAPI HaRP

This deploys HaRP (HaProxy Reversed Proxy) for Nextcloud AppAPI ExApps support with Kubernetes backend.

## Deployed Resources

- **Deployment**: `harp-nextcloud` - HaRP proxy with K8s backend enabled
- **Service**: `harp-nextcloud` - ClusterIP on ports 8780 (HTTP) and 8782 (FRP)
- **ServiceAccount**: `harp-nextcloud` - namespace-scoped permissions for managing ExApps
- **Role/RoleBinding**: Permissions for Services, Deployments, StatefulSets, Secrets, etc.

## Registering the K8s Deploy Daemon

After HaRP is deployed and running, register the K8s daemon by running the following command inside the Nextcloud pod:

```bash
kubectl exec -n nextcloud deploy/nextcloud -- \
  php occ app_api:daemon:register \
    k8s_harp "K8s HaRP" "kubernetes-install" "http" \
    "harp-nextcloud.nextcloud.svc.cluster.local:8780" \
    "https://nextcloud.6j0.org" \
    --harp \
    --harp_shared_key "$(kubectl get secret -n nextcloud harp-nextcloud-secret -o jsonpath='{.data.shared-key}' | base64 -d)" \
    --harp_frp_address "harp-nextcloud.nextcloud.svc.cluster.local:8782" \
    --set-default
```

This registers the daemon with:
- `kubernetes-install` deploy method (native K8s, not Docker)
- ClusterIP service type for ExApps
- HaRP for proxying communication
- Sets it as the default daemon for ExApp installations

## Verifying the Daemon

```bash
kubectl exec -n nextcloud deploy/nextcloud -- php occ app_api:daemon:list
```

## Ingress Configuration

The Nextcloud ingress has been updated with a `/exapps/` route that proxies to HaRP with a 1800s timeout (required for long-running ExApp operations like document indexing).
