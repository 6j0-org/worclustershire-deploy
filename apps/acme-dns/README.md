# acme-dns

Authoritative DNS for `auth.6j0.org`, serving only the `_acme-challenge` TXT
records that Let's Encrypt reads during DNS-01 validation. It exists so the
`letsencrypt` ClusterIssuer can issue certificates for hostnames that HTTP-01
cannot reach — everything on the `eg-private` Gateway resolves to an RFC1918
MetalLB address, and wildcards are DNS-01 only.

## Why it is in-cluster

acme-dns is a nameserver, so it needs inbound UDP/53 from the internet. The
concern was that a residential Comcast line would block that. It does not —
measured on 2026-09-26 with a throwaway delegation, where Google's
(`172.253.223.214`) and Cloudflare's (`104.22.106.113`) resolvers both reached a
probe in this cluster over UDP/53 through the NAT.

Running it here costs one thing: a cluster outage stops certificate issuance.
That is bounded, because cert-manager renews at 1/3 of remaining lifetime and
these certificates are 45 days (the `letsencrypt` issuer sets
`profile: tlsserver`), leaving roughly 15 days of slack.

The real risk is the dynamic IP — see below.

## Delegation

Two records in the parent zone, wherever `6j0.org` is hosted:

```dns
acme-ns.6j0.org.   A    76.88.105.61
auth.6j0.org.      NS   acme-ns.6j0.org.
```

The NS target sits deliberately *outside* the delegated zone so it resolves from
the parent normally and no glue record is needed. This is the shape that was
verified working, rather than the in-bailiwick `ns1.auth.6j0.org` pattern from
upstream's example.

Then one CNAME per validated domain:

```dns
_acme-challenge.6j0.org.   CNAME   <subdomain>.auth.6j0.org.
```

A wildcard is validated at its base domain, so `*.6j0.org` needs the CNAME at
`_acme-challenge.6j0.org` — not at `_acme-challenge.*.6j0.org`.

**`acme-ns.6j0.org` is the fragile part.** `76.88.105.61` is a dynamic Comcast
address. If it changes, Let's Encrypt can no longer find this server, renewals
fail, and nothing visibly breaks for about 15 days. Either keep it current with
a dynamic-DNS updater or rely on the alerts in
`apps/kube-prometheus-stack/cert-expiry-rules.yaml` to catch it. Do not rely on
noticing by hand: `longhorn-6j0-org-tls` failed renewal 29 times across a month
before anyone spotted it.

## Registering a domain

The API is ClusterIP-only, so nothing on the internet can reach `/register`.

```shell
kubectl -n acme-dns port-forward svc/acme-dns-api 8080:8080
curl -s -X POST http://localhost:8080/register | jq .
```

Put the result into
`apps/cert-manager-custom-resources/acme-dns-account.secrets.yaml.decrypted`
keyed by the domain being *validated*, run `./encrypt_secrets.sh`, and publish
the matching CNAME. One registration per validated domain: acme-dns holds at
most 2 TXT values per credential, so three or more certificates renewing
concurrently through one credential will clobber each other's challenges.

## Operational notes

- **Pinned LoadBalancer IP.** `service-dns.yaml` pins `192.168.8.13` because a
  router rule forwards `76.88.105.61:53` (UDP *and* TCP) there. MetalLB would
  otherwise be free to pick another address from `first-pool` on recreate and
  silently break the forward.
- **TCP/53 matters.** Resolvers retry over TCP when a response is truncated.
- **Single replica, `Recreate` strategy.** SQLite on a ReadWriteOnce Longhorn
  volume; two pods cannot hold it at once, so a rolling update would deadlock.
- **Do not lose the PVC.** Each row ties a credential to the subdomain a CNAME
  points at. Losing it means re-registering and re-pointing every CNAME. The
  namespace carries `kustomize.toolkit.fluxcd.io/prune: disabled` for this
  reason.
- **Exposure.** This answers only its own small zone and does no recursion, so
  it is a poor amplification target — but it is a public DNS server on a home
  connection. Consider rate limiting if that ever matters.
