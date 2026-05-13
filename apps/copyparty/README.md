# Copyparty

## Users

Each user has their own directory and can only access their own files:

| User   | WebDAV URL                                |
| ------ | ----------------------------------------- |
| alice  | `https://copyparty.6j0.org/alice/`  |
| bob | `https://copyparty.6j0.org/bob/` |
| charlie | `https://copyparty.6j0.org/charlie/` |
| dave   | `https://copyparty.6j0.org/dave/`   |

Initial passwords are the same as the username. Change on first login:

1. Log in at `https://copyparty.6j0.org/`
2. Navigate to your directory.
3. Click the control panel (gear icon) → **Change password**

To regenerate a hash (e.g. after changing a password):

```
docker run --rm copyparty/ac --ah-alg argon2 --ah-gen alice:newpassword
# Output: +<hash>
```

Edit `copyparty.secrets.yaml.decrypted` with the new hash, then run `./encrypt_secrets.sh` and commit.

## Adding a new user

1. Generate an argon2 hash:
   ```
   docker run --rm copyparty/ac --ah-alg argon2 --ah-gen username:password
   ```
2. Add the hash to the `[accounts]` section in `copyparty.secrets.yaml.decrypted`.
3. Add a volume to the config:
   ```
   [username]
     /data/username:rw:username
   ```
4. Add `mkdir -p /data/username` to the `init-dirs` initContainer command in `values.yaml`.
5. Run `./encrypt_secrets.sh` and commit.

## WebDAV access

All methods use the per-user URLs above with your copyparty username and password.

---

### Android

**Option A — DAVx5 (recommended for file browsing)**

1. Install [DAVx5](https://www.davx5.com/download) from Play Store or F-Droid.
2. Open DAVx5, tap **+** (add account).
3. Choose **Login with URL and username**.
4. Enter:
   - **URL**: `https://copyparty.6j0.org/`
   - **Username**: your copyparty username
   - **Password**: your copyparty password
5. Tap **Login**, grant the **Storage Access Framework** permission.
6. Browse copyparty files from any SAF-compatible app via the DAVx5 provider.

**Option B — File manager with native WebDAV**

Solid Explorer, CX File Explorer, X-plore — add a WebDAV connection. Use the URL for your user (e.g. `https://copyparty.6j0.org/alice/`) and your credentials.

---

### iOS

1. Install **FE File Explorer** or **Documents by Readdle** from the App Store.
2. Add a **WebDAV** connection:
   - **URL**: `https://copyparty.6j0.org/` (or your per-user URL)
   - **Username**: your copyparty username
   - **Password**: your copyparty password
3. Files appear in the app for browsing, uploading, and downloading.

---

### Windows

**Option A — Map as network drive**

```
net use Z: https://copyparty.6j0.org/alice/ /user:alice hunter2 /persistent:yes
```

Or via File Explorer: right-click **This PC** → **Add a network location** → enter `https://copyparty.6j0.org/` and supply credentials.

**Option B — WinSCP / Cyberduck**

Add a WebDAV site with the same URL and credentials.

---

### Linux

**Option A — davfs2 (mount as filesystem)**

```bash
sudo apt install davfs2
sudo mount -t davfs https://copyparty.6j0.org/alice/ /mnt/copyparty
```

For passwordless mount, add to `/etc/davfs2/secrets`:
```
https://copyparty.6j0.org/alice/ alice hunter2
```

**Option B — rclone (mount or sync)**

```bash
rclone config  # choose WebDAV, URL, vendor "other", username, password
rclone mount copyparty: /mnt/copyparty
```

Set the `url` to your per-user URL (e.g. `https://copyparty.6j0.org/alice/`) to scope the remote to your directory.

---

### macOS

1. Open **Finder**.
2. Press **⌘K** (Connect to Server).
3. Enter `https://copyparty.6j0.org/alice/` (use your own user).
4. Click **Connect**, enter your username and password.
5. The share mounts as a volume in Finder and on the desktop.
