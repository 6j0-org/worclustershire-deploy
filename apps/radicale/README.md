# Authentication

Radicale uses htpasswd-based authentication. The `users` file is stored as a SOPS-encrypted Secret and mounted into the pod at `/etc/radicale/users`.

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
kubectl create secret generic basic-auth \
  --from-file=users \
  --dry-run=client \
  -o yaml > auth.secrets.yaml

sops --encrypt --in-place auth.secrets.yaml

rm users
```

## Updating the Radicale config

The config file at `/etc/radicale/config` must include the auth section:

```ini
[auth]
type = htpasswd
htpasswd_filename = /etc/radicale/users
htpasswd_encryption = autodetect
```

This is set via the chart's config mechanism (the `config` key in values.yaml, which populates the ConfigMap mounted as the `config` volume).
