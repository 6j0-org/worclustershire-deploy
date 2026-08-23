# PeerTube

All credentials for this app live in git, SOPS-encrypted. Nothing needs to be read out of the cluster.

## Web admin

<https://peertube.6j0.org>

| Field | Value |
| --- | --- |
| Username | `root` |
| Email | `gmail@evanstucker.com` |
| Password | `sops -d admin.secrets.yaml` |

The password comes from `admin.secrets.yaml`, which `values.yaml` passes to the container as `PT_INITIAL_ROOT_PASSWORD`.

**That variable only applies on first boot.** PeerTube's installer skips admin creation once any user exists, so editing `admin.secrets.yaml` on a running instance changes nothing — it only takes effect against a freshly-bootstrapped database. To actually change the password, use Account settings in the web UI, or:

```bash
kubectl exec -it -n peertube deploy/peertube -c peertube -- sh -c 'cd /app && npm run reset-password -- -u root'
```

If you do change it, update `admin.secrets.yaml` to match so a future rebuild lands on the same password:

```bash
sops apps/peertube/admin.secrets.yaml
```

## Database

PeerTube connects as the `peertube` owner role, whose password is pinned in `db-owner.secrets.yaml` and handed to CNPG at bootstrap. Read it with `sops -d db-owner.secrets.yaml`, or connect directly:

```bash
kubectl exec -it -n peertube peertube-database-1 -c postgres -- psql -U postgres peertube
```

That needs no credentials: `enableSuperuserAccess: false` leaves the `postgres` role with none at all, so superuser login is impossible over the network, while peer auth over the pod's local socket still gives you full access. This is deliberate — `pg_hba` ends with `host all all all scram-sha-256` and the namespace has no NetworkPolicy, so a superuser password would be reachable from anywhere in the cluster.

Like the admin password, `db-owner.secrets.yaml` is only read during `initdb`. Changing it does not rotate the password on an already-bootstrapped database.

## Valkey

Valkey has no separate admin account — the `default` ACL user holds `~* &* +@all`. Its password is in `valkey-auth.secrets.yaml` under the `default` key:

```bash
kubectl exec -it -n peertube deploy/valkey-peertube -- valkey-cli --no-auth-warning --user default --pass "$(sops -d apps/peertube/valkey-auth.secrets.yaml | yq '.stringData.default')"
```
