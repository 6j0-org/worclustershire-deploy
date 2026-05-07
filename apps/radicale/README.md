# Authentication

Radicale uses htpasswd-based authentication. The `users` file is stored as a SOPS-encrypted Secret and mounted into the pod at `/etc/radicale/users`. A ConfigMap provides the `[auth]` config section at `/etc/radicale/config`.

## Creating the users file

Install `apache2-utils` (Debian) or `httpd-tools` (Fedora) to get `htpasswd`, then create a file with bcrypt-hashed passwords:

```bash
htpasswd -B -c users <username>
```

Add more users:

```bash
htpasswd -B users <another-user>
```

## Encrypting with SOPS

Generate a Secret manifest from the `users` file and encrypt it:

```bash
kubectl create secret generic users \
  --namespace radicale \
  --from-file=users \
  --dry-run=client \
  -o yaml > users.secrets.yaml

sops --encrypt --in-place users.secrets.yaml

rm users
```
