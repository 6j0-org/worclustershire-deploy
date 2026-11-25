# shellcheck shell=bash
#
# Runs Renovate for one account with the token its mint step left in the
# account's own volume, then records the exit code there for report.sh.
#
# Usage: bash run-renovate.sh <account>
#
# Always exits 0, so a failure doesn't stop the accounts after this one.
# report.sh fails the Job instead.

set -u

account=$1
dir=/run/renovate

if [[ ! -s ${dir}/token ]]; then
  echo "No token for ${account}; see the log of its token-* step." >&2
  echo no-token > "${dir}/result"
  exit 0
fi

RENOVATE_TOKEN=$(< "${dir}/token")
export RENOVATE_TOKEN
rm -f "${dir}/token"

# The token expires an hour after it was minted.
timeout 55m renovate
echo "$?" > "${dir}/result"
