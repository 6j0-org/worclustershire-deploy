#!/usr/bin/env bash
set -euo pipefail

# Mirrors Radicle repos out to other forges, so the code is reachable to people
# who are not on the Radicle network. Run daily by the radicle-mirror CronJob;
# see README.md -> "Mirroring repos out to other forges".
#
# The repo list is seeded-repos.txt, the same file the node's seeding policy
# comes from. A line there is mirrored only if it carries a mirror name in its
# second column:
#
#   rad:z4KE6B3D7hDborYdrRoehccephmnh myproject   <- seeded and mirrored
#   rad:z3gqcJUoA1n9HaHKufZs5FCSGazv5             <- seeded only
#
# Seeding a repo and republishing it under your own forge account are separate
# decisions, so the second one is opt-in per repo rather than implied by the
# first.

SEED="${SEED:-https://seed.radicle.dev}"
CACHE="${CACHE:-$HOME/.cache/rad-mirror}"
# Mounted from the radicle-config ConfigMap, the same one the node reads.
REPO_LIST="${REPO_LIST:-/etc/radicle/seeded-repos.txt}"

# Where each repo is pushed. "%s" becomes the mirror name from seeded-repos.txt.
# Delete the forges you do not use; the repos must already exist on them, since
# git push will not create them.
MIRRORS=(
  "git@github.com:USER/%s.git"
  "git@gitlab.com:USER/%s.git"
  "git@codeberg.org:USER/%s.git"
)

# Strip comments, then keep only lines that are a Radicle ID plus a name.
# Anything without a name is a seed-only entry and is skipped here.
mapfile -t entries < <(sed 's/#.*//' "$REPO_LIST" | awk '$1 ~ /^rad:/ && NF >= 2 { print $1, $2 }')

if [ "${#entries[@]}" -eq 0 ]; then
  echo "Nothing to mirror: no entry in $REPO_LIST has a mirror name." >&2
  exit 0
fi

for entry in "${entries[@]}"; do
  read -r rid name <<< "$entry"
  rid="${rid#rad:}" # the seed serves the bare ID, seeded-repos.txt prefixes it
  dir="$CACHE/$name.git"

  echo "==> $name ($rid)"

  if [ -d "$dir" ]; then
    # Explicitly origin, not `remote update`: that walks every remote, and in a
    # mirror clone fetching the forges drags their refs into refs/remotes/
    # mirrors/*, which origin's own +refs/*:refs/* --prune then deletes again
    # on the next run. Pure churn, and a forge being unreachable would abort
    # the run before it ever got to the push.
    git -C "$dir" fetch --prune origin
  else
    # Clones over HTTPS from the public seed rather than from the node next
    # door: serving git over HTTPS is radicle-httpd's job and this image has
    # no such thing.
    git clone --mirror "$SEED/$rid.git" "$dir"
  fi

  # Pushed to each URL directly rather than through a named remote holding
  # several pushurls. A named remote would need rebuilding every run to pick
  # up edits to MIRRORS, and `git push` updates its remote-tracking refs on
  # success -- which, in a mirror clone, origin's +refs/*:refs/* --prune then
  # deletes again on the next run. A URL has neither problem, and a failure
  # names the forge it happened on.
  #
  # Only the canonical refs travel. Radicle's per-peer namespaces and its
  # collaborative objects (issues, patches) match neither refspec and stay on
  # Radicle -- a mirror is a copy of the code, not of the project around it.
  #
  # Note there is no --prune here: a branch deleted upstream is left standing
  # on the forges rather than deleted from them. Add --prune if you want the
  # mirrors to track deletions too.
  for url in "${MIRRORS[@]}"; do
    git -C "$dir" push "${url//%s/$name}" \
      "+refs/heads/*:refs/heads/*" "+refs/tags/*:refs/tags/*"
  done
done
