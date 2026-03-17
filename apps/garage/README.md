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
