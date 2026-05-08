# Radicale

## Initial setup

1. Use htpasswd with maximum security settings to create a file named `users` like this:
   ```bash
   # First user (needs -c to create the file)
   htpasswd -B -C 17 -c users alice

   # Subsequent users
   htpasswd -B -C 17 users bob
   htpasswd -B -C 17 users charlie
   ```
1. Generate a Kubernetes Secret from the `users` file, encrypt it, and clean up:
   ```bash
   kubectl create secret generic users \
     --dry-run=client \
     --from-file=users \
     -o yaml > users.secrets.yaml && \
   sops --encrypt --in-place users.secrets.yaml && \
   rm users
   ```
