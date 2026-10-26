# ipfs

A [Kubo](https://github.com/ipfs/kubo) node that pins one static website and
serves it at <https://site.6j0.org>. The node also joins the public IPFS
network, so the same site can be fetched by CID from any IPFS node or
gateway.

## How it fits together

- `site.env`: the site's CID. This is the only place it is written.
- `pin-site.sh`: a sidecar that pins that CID under the pin name `site`
  and unpins the previous one. `--enable-gc` then reclaims the old blocks.
- `httproute.yaml`: Envoy rewrites `site.6j0.org/<path>` to
  `/ipfs/<CID>/<path>` on Kubo's gateway. Kustomize `replacements` copy
  the CID in from `site.env`.
- `tcproute.yaml`: inbound libp2p connections on TCP 4001, through the
  `ipfs` listener on the eg-public Gateway.
- `kubo-init.sh`: Kubo config, re-applied on every start. Settings worth
  knowing:
  - The RPC API is on loopback only.
  - `Gateway.NoFetch` is on, so the gateway serves only the pinned site.
  - Only pinned content is announced to the DHT.

## Publishing the site

Run these on any machine with Kubo (`ipfs daemon` running):

```shell
ipfs add -r --cid-version=1 -Q ./public    # prints the CID
```

Put that CID in `site.env`, commit, and push to the remote Flux watches. The
pod restarts, and `pin-site` fetches the DAG from the network and pins it.

**Keep the publishing node online until the pin finishes.** Until then it is
the only provider of the content. Watch the pin's progress here:

```shell
kubectl -n ipfs logs deploy/kubo -c pin-site -f
```

Until the pin completes, the site returns 404s, because `NoFetch` stops the
gateway from fetching the content on demand.

## Limitations of serving over a path rewrite

Kubo only sees the rewritten `/ipfs/<CID>/...` path, which has two effects:

- A directory URL without a trailing slash (`/blog`) gets a 301 to
  `/ipfs/<CID>/blog/`, which works but exposes the CID in the address
  bar. Links that end in `/` (most static site generators produce these)
  never hit this.
- `_redirects` files and custom `404.html` pages are ignored. Kubo
  applies them only on DNSLink and subdomain gateways.

If either one matters, switch to DNSLink. Add a TXT record
`_dnslink.site.6j0.org` → `dnslink=/ipfs/<CID>`, set `Gateway.NoDNSLink` to
false, and drop the rewrites. The cost is that the CID then lives in DNS as
well as in `site.env`.

## Outside the cluster

- `site.6j0.org` is already covered by the `*.6j0.org` wildcard DNS record,
  like every other single-label app.
- For the swarm to be reachable from the internet, TCP 4001 has to be
  forwarded to the eg-public LoadBalancer IP, the same as 8776 for radicle.
  Check it from outside with
  `ipfs routing findprovs <CID>` and `ipfs swarm connect /dns4/site.6j0.org/tcp/4001/p2p/<PeerID>`.
  Get the PeerID from `kubectl -n ipfs exec deploy/kubo -c kubo -- ipfs id -f '<id>'`.
