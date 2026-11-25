# shellcheck shell=bash
#
# Runs after every account's steps. Prints each account's result and fails
# the Job if any account failed, which fires KubeJobFailed. Each account's
# volume is mounted read-only at /results/<account>.

set -u
shopt -s nullglob

status=0
dirs=(/results/*/)
if [[ ${#dirs[@]} -eq 0 ]]; then
  echo "No account volumes are mounted at /results." >&2
  exit 1
fi

for dir in "${dirs[@]}"; do
  account=$(basename "$dir")
  result=$(cat "${dir}result" 2> /dev/null || echo missing)
  if [[ $result == 0 ]]; then
    echo "${account}: ok"
  elif [[ $result == no-token ]]; then
    echo "${account}: failed (no token); see the log of its token-* step." >&2
    status=1
  else
    echo "${account}: failed (${result}); see the log of its renovate-* step." >&2
    status=1
  fi
done

exit "$status"
