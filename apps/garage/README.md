After deploying garage with FluxCD, we have to create the cluster:

```
kubectl exec --stdin --tty -n garage garage-0 -- ./garage status
```

Then we stage the roles. This has to be run once for each node, for example:

```
$ kubectl exec --stdin --tty -n garage garage-0 -- ./garage layout assign -z dc1 -c 10G 9510837cae21e2a2
$ kubectl exec --stdin --tty -n garage garage-0 -- ./garage layout assign -z dc1 -c 10G b53c4c9ac297d3c4
$ kubectl exec --stdin --tty -n garage garage-0 -- ./garage layout assign -z dc1 -c 10G d8cf697210823c78
```

Apply the staged changes:

```
kubectl exec --stdin --tty -n garage garage-0 -- ./garage layout apply --version 1
```

Create a bucket for Nextcloud:

```
kubectl exec --stdin --tty -n garage garage-0 -- ./garage bucket create nextcloud
```

Create an API key for Nextcloud:

```
kubectl exec --stdin --tty -n garage garage-0 -- ./garage key create nextcloud
```

Copy the "Key ID" and "Secret key" to put in the Nextcloud config.

Give the key access to the bucket:

```
kubectl exec --stdin --tty -n garage garage-0 -- ./garage bucket allow \
  --read \
  --write \
  --owner \
  nextcloud \
  --key nextcloud
```

Create buckets for Loki. Loki wants two: one for log chunks and one for the ruler (`loki.storage.bucketNames` in `apps/loki/values.yaml`).

```shell
kubectl exec --stdin --tty -n garage garage-0 -- ./garage bucket create loki-chunks
kubectl exec --stdin --tty -n garage garage-0 -- ./garage bucket create loki-ruler
```

Create one API key for Loki:

```shell
kubectl exec --stdin --tty -n garage garage-0 -- ./garage key create loki
```

Give the key access to both buckets. Unlike Nextcloud above, no `--owner`: Loki only gets, puts and deletes objects (the compactor deletes chunks past `retention_period`), it never touches bucket-level settings.

```shell
kubectl exec --stdin --tty -n garage garage-0 -- ./garage bucket allow \
  --read \
  --write \
  loki-chunks \
  --key loki
kubectl exec --stdin --tty -n garage garage-0 -- ./garage bucket allow \
  --read \
  --write \
  loki-ruler \
  --key loki
```

Check the result:

```shell
kubectl exec --stdin --tty -n garage garage-0 -- ./garage bucket info loki-chunks
```

Then wire Loki up. Garage is not AWS, so the IRSA path in `apps/loki` does not apply — leave the `serviceAccount.annotations` block in `apps/loki/values.yaml` commented out and use the static-key alternative instead. The non-secret half goes in `apps/loki/values.yaml`:

```yaml
loki:
  storage:
    type: s3
    bucketNames:
      chunks: loki-chunks
      ruler: loki-ruler
    s3:
      # Must match garage.s3.api.region in apps/garage/values.yaml, which is
      # unset there and so takes the chart default of "garage". Garage checks
      # the region in the SigV4 signature and rejects a mismatch.
      region: garage
      endpoint: garage.garage.svc.cluster.local:3900
      # Plain HTTP: this stays inside the cluster and never crosses the Gateway.
      insecure: true
      # The bucket-subdomain form (loki-chunks.s3.garage.6j0.org) only resolves
      # through the HTTPRoute, so address the service path-style.
      s3ForcePathStyle: true
```

The key from `garage key create` goes in `apps/loki/helm_secrets.yaml` — uncomment the static-key block in there and paste in the Key ID and Secret key:

```shell
sops apps/loki/helm_secrets.yaml
```

```yaml
loki:
  storage:
    s3:
      accessKeyId: GK...
      secretAccessKey: ...
```

Troubleshooting

```
kubectl run s3ls --image=amazon/aws-cli:2.15.0 --rm -it --restart=Never -- \
  --env="AWS_ACCESS_KEY_ID=GKe214ad1a729b32f06ba08766" \
  --env="AWS_SECRET_ACCESS_KEY=REDACTED" \
  -- aws --endpoint-url http://garage.garage.svc.cluster.local:3900 \
  --no-verify-ssl \
  s3 ls s3://nextcloud/ --recursive
```

References:
- https://garagehq.deuxfleurs.fr/documentation/cookbook/kubernetes/
- https://garagehq.deuxfleurs.fr/documentation/quick-start/#creating-a-cluster-layout
