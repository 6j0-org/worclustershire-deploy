#!/usr/bin/env bash

export KUBECONFIG="${HOME}/.kube/worclustershire"
export cluster_name=worclustershire
export flux_path=flux
export git_owner=6j0-org
export git_repo=worclustershire-deploy
export k8s_platform=talos # eks, k0s, talos
export region=us-east-2 # replace_placeholders.sh rewrites this placeholder repo-wide (e.g. tempo's S3 config)
# Parent domain of the cluster's ingress hostnames (grafana.<cluster_domain>,
# ...) and the org prefix of its S3 bucket names (<org_name>-<cluster_name>-*,
# matching aws-eks-template's org_name). replace_placeholders.sh rewrites the
# template's hostname and bucket-name placeholders to these.
export cluster_domain=6j0.org
export org_name=6j0-org
# The 12-digit AWS account the cluster runs in. replace_placeholders.sh puts
# it into the IRSA role ARNs; leave it empty on non-EKS platforms.
export aws_account_id=""
# true to have Alertmanager send alert notifications to Slack. Also set your
# webhook URL and channel first -- see apps/victoria-metrics/README.md.
export slack_alerts=false

# GitHub App config for `flux-operator create secret githubapp` (see deploy.sh).
# None of these are secret: the App ID appears in the JWTs the app signs, and
# both IDs are visible in your GitHub App's settings UI. Find the App ID on the
# app's General page and the Installation ID in the "Install App" URL
# (https://github.com/settings/installations/<INSTALLATION_ID>).
export GITHUB_APP_ID=000000
export GITHUB_APP_INSTALLATION_ID=00000000
# The GitHub App private key (the actual secret) is decrypted further down,
# once the age identity ($SOPS_AGE_KEY) is loaded -- see GITHUB_APP_PRIVATE_KEY.

# Have to decrypt our encrypted keys.txt like this because of this bug:
# https://github.com/getsops/sops/issues/933
if [[ "$OSTYPE" == "darwin"* ]]; then
 export sops_dir="${HOME}/Library/Application Support/sops/age"
elif [[ "$OSTYPE" == "linux"* ]]; then
 export sops_dir="${HOME}/.config/sops/age"
fi
# shellcheck disable=SC2155
export SOPS_AGE_KEY=$(age -d "${sops_dir}/keys.txt")

# GitHub App private key -- this IS the secret. It's stored age-encrypted in
# this directory (github-app.private-key.pem.age), encrypted to the same age
# recipient as our sops secrets, so it can live in the repo safely. Encrypt
# yours with (your public key is the one in .sops.yaml):
#   age -r <your-age-recipient> -o github-app.private-key.pem.age /path/to/app.private-key.pem
# Decrypted non-interactively with the identity in $SOPS_AGE_KEY into a shell
# variable; deploy.sh hands it to `flux-operator create secret githubapp` via
# process substitution at the call site (same pattern as --age-key-file), so
# the key never touches the filesystem. Don't assign a process substitution
# here instead -- bash closes its /dev/fd/<n> as soon as the assignment
# completes, so the path would be dead before deploy.sh could use it.
# Not exported: deploy.sh sources this file, and keeping it out of the
# environment means child processes can't read it from their env.
# SCRIPT_DIR is set by deploy.sh before it sources this file.
# This cluster syncs over SSH (see deploy.sh), so no App key is committed yet;
# decrypt only when the file exists, or sourcing this aborts deploy.sh (set -e).
github_app_key_file="${SCRIPT_DIR}/github-app.private-key.pem.age"
# shellcheck disable=SC2034 # consumed by deploy.sh, which sources this file
GITHUB_APP_PRIVATE_KEY=""
# shellcheck disable=SC2034 # consumed by deploy.sh, which sources this file
if [[ -f "$github_app_key_file" ]]; then
  GITHUB_APP_PRIVATE_KEY=$(age -d -i <(printf '%s\n' "$SOPS_AGE_KEY") "$github_app_key_file")
fi
