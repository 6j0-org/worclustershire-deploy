#!/usr/bin/env bash

# Creates a GitHub App for Flux or Renovate through GitHub's App Manifest flow
# (https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest),
# so the app's settings come from this script instead of a hand-filled form.
#
# GitHub has no API that creates or installs an app without a person, so two
# clicks remain: "Create GitHub App" on a page this script fills in, and
# "Install" on the app's install page. Everything else is scripted:
#
#   1. A listener on 127.0.0.1 serves a form that posts the app manifest to
#      GitHub's "new app" page, and catches GitHub's redirect back with a
#      one-time code (valid for an hour).
#   2. POST /app-manifests/<code>/conversions trades the code for the App ID
#      and private key. The key goes straight into age (flux) or sops
#      (renovate) and never touches the disk in plaintext. The client secret
#      and webhook secret it also returns are dropped: neither app uses them.
#   3. flux only: after the install click, the script signs a JWT with the
#      key and reads the installation ID from GET /app/installations.
#
# Then it writes the IDs where they're read:
#
#   flux      variables.sh (GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, and the
#             .pem.age path), plus <app-slug>.<date>.private-key.pem.age at
#             the repo root, encrypted to the age recipients in .sops.yaml.
#   renovate  apps/hacky-renovate-cronjobs/github-app.env (GITHUB_APP_ID),
#             plus an encrypted
#             apps/hacky-renovate-cronjobs/github-app.secrets.yaml. The app is
#             public, so one app can be installed on several accounts.
#             Renovate finds each installation by the account's login when it
#             runs (apps/hacky-renovate-cronjobs/mint-token.mjs), so there's
#             no installation ID to record: each account just needs its block
#             in apps/hacky-renovate-cronjobs/cronjob.yaml.
#
# No git operations: review and commit the result yourself.

# No -x: the private key passes through shell variables.
set -Eeuo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

usage() {
  cat <<EOF >&2

Usage:

  $0 flux|renovate [--owner OWNER] [--name NAME]

Arguments:

  flux       The app Flux syncs this repo with (Contents read/write).
  renovate   The app apps/hacky-renovate-cronjobs runs as (see its README.md).

Options:

  --owner    GitHub organization or user that owns the app. Default:
             git_owner from variables.sh.
  --name     App name, unique across GitHub, at most 34 characters.
             Default: <org_name>-<cluster_name>-flux from variables.sh, or
             <owner>-renovate (one Renovate app serves every account it's
             installed on, so it's named after the account that owns it).

Needs a browser on this machine for the two clicks, and the age recipients
in .sops.yaml filled in (the placeholder key is refused before anything is
created).

EOF
  exit 1
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

[[ $# -ge 1 ]] || usage
kind=$1
shift
[[ $kind == flux || $kind == renovate ]] || usage

owner=""
name=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) [[ $# -ge 2 ]] || usage; owner=$2; shift 2 ;;
    --name)  [[ $# -ge 2 ]] || usage; name=$2; shift 2 ;;
    *) usage ;;
  esac
done

for cmd in age curl jq openssl python3 sops yq; do
  command -v "$cmd" > /dev/null || die "$cmd is not installed (see Brewfile or pkglist.txt)."
done

# Reads a literal `export NAME=value` from variables.sh. variables.sh isn't
# sourced: it decrypts the SOPS key ring and the Flux app's key, and the
# latter is what this script is about to create.
variables_file="${SCRIPT_DIR}/variables.sh"
var() {
  sed -n "s/^export $1=\"\{0,1\}\([^\" #]*\)\"\{0,1\}.*/\1/p" "$variables_file" | head -n 1
}

[[ -n $owner ]] || owner=$(var git_owner)
[[ -n $owner ]] || die "No --owner given and no git_owner in variables.sh."
git_repo=$(var git_repo)
if [[ -z $name ]]; then
  if [[ $kind == flux ]]; then
    name="$(var org_name)-$(var cluster_name)-flux"
  else
    name="${owner}-renovate"
  fi
fi
[[ ${#name} -le 34 ]] || die "App name '${name}' is longer than GitHub's 34 characters; pass a shorter --name."

# Fail before creating anything if the key can't be encrypted afterwards.
sops_file="${SCRIPT_DIR}/.sops.yaml"
recipients=$(yq '.creation_rules[0].age' "$sops_file")
if [[ -z $recipients || $recipients == null || $recipients == *YOUR_AGE_PUBLIC_KEY* ]]; then
  die "Put your age public key in .sops.yaml first (README.md, \"Deploying Flux\")."
fi

api() {
  curl -fsS -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' "$@"
}

owner_json=$(api "https://api.github.com/users/${owner}") || die "GitHub has no user or organization named '${owner}'."
owner_type=$(jq -r .type <<< "$owner_json")
owner_id=$(jq -r .id <<< "$owner_json")
if [[ $owner_type == Organization ]]; then
  create_url="https://github.com/organizations/${owner}/settings/apps/new"
else
  create_url="https://github.com/settings/apps/new"
fi

# Permissions use the manifest's names, which differ from the settings UI's:
# statuses is "Commit statuses", vulnerability_alerts is "Dependabot alerts".
case $kind in
  flux)
    homepage="https://github.com/${owner}/${git_repo}"
    # Flux reads the repo; image-automation-controller pushes commits to it.
    permissions='{"contents": "write", "metadata": "read"}'
    # Only installable on the owner's account.
    public=false
    ;;
  renovate)
    homepage="https://docs.renovatebot.com/"
    # A private app can only be installed on the account that owns it. Public
    # lets the other accounts install it too; it isn't listed anywhere, and
    # an account with no block in apps/hacky-renovate-cronjobs/cronjob.yaml
    # never gets a token, so a stranger's installation is ignored.
    public=true
    # From https://docs.renovatebot.com/modules/platform/github/#running-as-a-github-app
    permissions='{
      "checks": "write", "statuses": "write", "contents": "write",
      "issues": "write", "pull_requests": "write", "workflows": "write",
      "administration": "read", "vulnerability_alerts": "read",
      "metadata": "read"
    }'
    # Organization permission, so only on an organization.
    if [[ $owner_type == Organization ]]; then
      permissions=$(jq '. + {"members": "read"}' <<< "$permissions")
    fi
    ;;
esac

# redirect_url is filled in by the listener once it has a port.
manifest=$(jq -n \
  --arg name "$name" \
  --arg url "$homepage" \
  --argjson permissions "$permissions" \
  --argjson public "$public" \
  '{
    name: $name,
    url: $url,
    hook_attributes: {url: $url, active: false},
    public: $public,
    request_oauth_on_install: false,
    default_permissions: $permissions,
    default_events: []
  }')

state=$(openssl rand -hex 16)

# Serves the auto-submitting manifest form on / and waits for GitHub's
# redirect to /callback, then prints the code. Gives up after 15 minutes.
listener=$(cat <<'PY'
import html, http.server, json, sys, time, urllib.parse, webbrowser

manifest, create_url, state = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3]
code = None

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        global code
        url = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(url.query)
        if url.path == "/":
            action = create_url + "?" + urllib.parse.urlencode({"state": state})
            self.reply(200,
                '<!doctype html><title>Create GitHub App</title>'
                f'<form id="f" method="post" action="{html.escape(action)}">'
                f'<input type="hidden" name="manifest" value="{html.escape(json.dumps(manifest))}">'
                '<button>Continue to GitHub</button></form>'
                '<script>document.getElementById("f").submit()</script>')
        elif url.path == "/callback" and query.get("state") == [state] and "code" in query:
            code = query["code"][0]
            self.reply(200, "<!doctype html><title>Done</title>"
                "<p>GitHub App created. Close this tab and return to the terminal.</p>")
        else:
            self.reply(404, "Not found")

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
server.timeout = 5
start = f"http://127.0.0.1:{server.server_port}/"
manifest["redirect_url"] = start + "callback"
print(f"Opening {start} -- open it yourself if no browser appears.", file=sys.stderr)
webbrowser.open(start)
deadline = time.monotonic() + 900
while code is None and time.monotonic() < deadline:
    server.handle_request()
if code is None:
    sys.exit("Timed out waiting for GitHub to redirect back.")
print(code)
PY
)

printf 'Creating GitHub App "%s" owned by %s.\n' "$name" "$owner" >&2
printf 'Click "Create GitHub App" on the GitHub page that opens.\n' >&2
code=$(python3 -I -c "$listener" "$manifest" "$create_url" "$state")

# The response holds the private key: keep it in variables, never on disk.
conversion=$(api -X POST "https://api.github.com/app-manifests/${code}/conversions") \
  || die "GitHub refused the manifest code (they expire after an hour)."
app_id=$(jq -r .id <<< "$conversion")
slug=$(jq -r .slug <<< "$conversion")
html_url=$(jq -r .html_url <<< "$conversion")
pem=$(jq -r .pem <<< "$conversion")
unset conversion
printf 'Created %s (App ID %s).\n' "$html_url" "$app_id" >&2

# Store the key before anything else can fail: GitHub never shows it again.
case $kind in
  flux)
    key_name="${slug}.$(date +%F).private-key.pem.age"
    age_args=()
    IFS=',' read -ra recipient_list <<< "$recipients"
    for r in "${recipient_list[@]}"; do
      age_args+=(-r "${r//[[:space:]]/}")
    done
    printf '%s\n' "$pem" | age "${age_args[@]}" -o "${SCRIPT_DIR}/${key_name}"
    sed -i.bak \
      -e "s/^export GITHUB_APP_ID=.*/export GITHUB_APP_ID=${app_id}/" \
      -e "s|\"\${SCRIPT_DIR}/[^\"]*\.private-key\.pem\.age\"|\"\${SCRIPT_DIR}/${key_name}\"|" \
      "$variables_file"
    rm "${variables_file}.bak"
    printf 'Wrote %s and updated variables.sh.\n' "$key_name" >&2
    ;;
  renovate)
    secret_file="${SCRIPT_DIR}/apps/hacky-renovate-cronjobs/github-app.secrets.yaml"
    env_file="${SCRIPT_DIR}/apps/hacky-renovate-cronjobs/github-app.env"
    PEM=$pem yq -n '
      .apiVersion = "v1" |
      .kind = "Secret" |
      .metadata.name = "renovate-github-app" |
      .type = "Opaque" |
      .stringData."private-key" = strenv(PEM)' \
      | sops -e --filename-override "$secret_file" --input-type yaml --output-type yaml /dev/stdin \
      > "${secret_file}.new"
    mv "${secret_file}.new" "$secret_file"
    rm -f "${secret_file}.decrypted"
    sed -i.bak "s/^GITHUB_APP_ID=.*/GITHUB_APP_ID=${app_id}/" "$env_file"
    rm "${env_file}.bak"
    printf 'Wrote apps/hacky-renovate-cronjobs/github-app.secrets.yaml and the App ID in apps/hacky-renovate-cronjobs/github-app.env.\n' >&2
    ;;
esac

# Renovate needs no installation ID, so the script is done once the install
# page is open. Without target_id, GitHub asks which account to install on.
if [[ $kind == renovate ]]; then
  install_url="${html_url}/installations/new"
  printf '\nNow install it on each account Renovate should manage: pick the account\n' >&2
  printf 'and its repos, and click Install. Repeat from the same page for each\n' >&2
  printf 'account. An account without a block in\n' >&2
  printf 'apps/hacky-renovate-cronjobs/cronjob.yaml is never touched.\n' >&2
  printf 'Opening %s -- open it yourself if no browser appears.\n' "$install_url" >&2
  python3 -I -c 'import sys, webbrowser; webbrowser.open(sys.argv[1])' "$install_url" || true
  printf "\nReview with git status and git diff, then commit.\n" >&2
  exit 0
fi

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# A GitHub App JWT, valid for nine minutes.
jwt() {
  local now header payload signature
  now=$(date +%s)
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$app_id" | b64url)
  signature=$(printf '%s.%s' "$header" "$payload" \
    | openssl dgst -sha256 -binary -sign <(printf '%s\n' "$pem") | b64url)
  printf '%s.%s.%s' "$header" "$payload" "$signature"
}

# From here on, flux only: renovate exited above.
install_url="${html_url}/installations/new/permissions?target_id=${owner_id}"
printf '\nNow install it: choose "Only select repositories", pick %s, and click Install.\n' "$git_repo" >&2
printf 'Opening %s -- open it yourself if no browser appears.\n' "$install_url" >&2
python3 -I -c 'import sys, webbrowser; webbrowser.open(sys.argv[1])' "$install_url" || true

installation_id=""
deadline=$(( $(date +%s) + 900 ))
while [[ -z $installation_id && $(date +%s) -lt $deadline ]]; do
  sleep 5
  installation_id=$(api -H "Authorization: Bearer $(jwt)" "https://api.github.com/app/installations" \
    | jq -r --arg owner "$owner" '[.[] | select(.account.login | ascii_downcase == ($owner | ascii_downcase))][0].id // empty') \
    || installation_id=""
done
[[ -n $installation_id ]] || die "No installation after 15 minutes. Install the app from ${install_url}, then set the installation ID (the number at the end of the installation's settings URL) by hand."

sed -i.bak "s/^export GITHUB_APP_INSTALLATION_ID=.*/export GITHUB_APP_INSTALLATION_ID=${installation_id}/" "$variables_file"
rm "${variables_file}.bak"
printf 'Installed (installation ID %s); updated variables.sh.\n' "$installation_id" >&2

printf "\nReview with git status and git diff, then commit.\n" >&2
