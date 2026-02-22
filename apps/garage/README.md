TODO: Create a new longhorn storageclass that only has 1 replication?

After deploying garage, we have to create the cluster:

```
kubectl exec --stdin --tty -n garage garage-0 -- ./garage status
kubectl exec --stdin --tty -n garage garage-0 -- ./garage layout assign -z dc1 -c 10G 49e869189d9bb967
kubectl exec --stdin --tty -n garage garage-0 -- ./garage layout assign -z dc1 -c 10G 89e9aaafe5e3c090
kubectl exec --stdin --tty -n garage garage-0 -- ./garage layout apply --version 1
```

References:
- https://garagehq.deuxfleurs.fr/documentation/cookbook/kubernetes/
- https://garagehq.deuxfleurs.fr/documentation/quick-start/#creating-a-cluster-layout
