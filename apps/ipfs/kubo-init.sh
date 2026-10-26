#!/bin/sh
# Mounted into /container-init.d, which the Kubo image's start_ipfs runs on
# EVERY start: after `ipfs init` (first boot only) and before `ipfs daemon`.
# The repo's config file lives on the PVC, so this is what keeps it matching
# git -- edit here, not with `ipfs config` in a shell, or the change is undone
# on the next restart.
set -e

# The RPC API is full admin control of the node (add/pin/rm, keys, config).
# start_ipfs binds it to 0.0.0.0 on first init; pin it back to loopback, where
# only containers in this pod (pin-site) can reach it. The Service does not
# expose 5001 either, but the pod IP is reachable from the whole cluster.
ipfs config Addresses.API /ip4/127.0.0.1/tcp/5001
ipfs config Addresses.Gateway /ip4/0.0.0.0/tcp/8080

# Serve only what is already in the repo -- i.e. the pinned site. Without this
# the gateway would fetch any CID from the network on request, making it an
# open public gateway for arbitrary content behind our domain.
ipfs config --json Gateway.NoFetch true
# Every request arrives with Host: site.6j0.org. Skip the DNSLink TXT lookup
# Kubo would otherwise do for it on each request; the HTTPRoute maps the
# hostname to the CID instead.
ipfs config --json Gateway.NoDNSLink true

# Peers reach us through the eg-public Gateway's `ipfs` TCP listener, not the
# pod IP (which the server profile's NoAnnounce filters out anyway). Must match
# the hostname in httproute.yaml, whose DNS record points at that Gateway.
ipfs config --json Addresses.AppendAnnounce '["/dns4/site.6j0.org/tcp/4001"]'

# Advertise only pinned content to the DHT, not every cached block.
ipfs config Provide.Strategy pinned

# Kubo sizes these from the HOST's memory and a 10GB default, neither of which
# matches the pod. Keep the libp2p resource manager under the container limit
# (deployment.yaml), and StorageMax under the PVC size so --enable-gc kicks in
# before the volume fills.
ipfs config Swarm.ResourceMgr.MaxMemory 512MB
ipfs config Datastore.StorageMax 8GB
