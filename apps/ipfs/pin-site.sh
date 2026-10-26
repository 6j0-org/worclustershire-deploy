#!/bin/sh
# Sidecar: keep exactly one pin named "site", pointing at $CID from site.env.
#
# Runs in the kubo pod and talks to the daemon's RPC API over loopback (see
# kubo-init.sh). A new CID changes the generated ConfigMap's name, which rolls
# the pod, so this only ever needs to converge on one value -- the loop just
# re-asserts the pin in case someone removes it by hand.
set -eu

ipfs() { command ipfs --api=/ip4/127.0.0.1/tcp/5001 "$@"; }

until ipfs id >/dev/null 2>&1; do
  echo "waiting for the kubo API"
  sleep 5
done

# Compare in one canonical form, so a CIDv0 (Qm...) in site.env still matches
# what `pin ls` prints.
want=$(ipfs cid base32 "$CID")

while :; do
  echo "pinning $CID"
  # Blocks until the whole DAG is local. That needs at least one provider of
  # the site online (e.g. the machine that ran `ipfs add`) on the first pin.
  ipfs pin add --name=site --progress=false "$CID"

  # Drop the previous version's pin; --enable-gc then reclaims its blocks.
  ipfs pin ls --type=recursive --names | while read -r cid _type name; do
    [ "$name" = site ] || continue
    [ "$(ipfs cid base32 "$cid")" = "$want" ] && continue
    echo "unpinning old site $cid"
    ipfs pin rm "$cid"
  done

  sleep 3600
done
