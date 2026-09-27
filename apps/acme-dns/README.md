# acme-dns

Authoritative DNS for `auth.6j0.org`, serving only the `_acme-challenge` TXT
records that Let's Encrypt reads during DNS-01 validation. It exists so the
`letsencrypt` ClusterIssuer can issue certificates for hostnames HTTP-01 cannot
reach — everything on the `eg-private` Gateway resolves to an RFC1918 MetalLB
address, and wildcards are DNS-01 only.

**Status: working since 2026-09-27.** `*.6j0.org` issues through this server, and
`longhorn`, `grafana`, `prometheus` and `alertmanager` all serve TLS on
`eg-private`. See "Remaining work" for the part that is not finished.

## Why it is in-cluster

acme-dns is a nameserver, so it needs inbound UDP/53 from the internet. The
concern was that a residential Comcast line would block that. It does not —
measured 2026-09-26 with a throwaway delegation, where Google's
(`172.253.223.214`) and Cloudflare's (`104.22.106.113`) resolvers both reached a
probe in this cluster over UDP/53 through the NAT. TCP/53 verified too.

Running it here costs one thing: a cluster outage stops certificate issuance.
That is bounded — cert-manager renews at 1/3 of remaining lifetime and these
certificates are 45 days (the issuer sets `profile: tlsserver`), so roughly 15
days of slack. The real risk is the dynamic IP; see "Known fragility".

## How it is wired

```text
_acme-challenge.6j0.org.  CNAME  <subdomain>.auth.6j0.org.   <- one per validated domain
auth.6j0.org.             NS     acme-ns.6j0.org.            <- delegation
acme-ns.6j0.org.          A      76.88.105.61                <- router forwards :53 to 192.168.8.13
```

The NS target sits deliberately *outside* the delegated zone, so it resolves from
the parent normally and no glue record is needed. This differs from upstream's
`ns1.auth.example.org` example, and was chosen because it is the shape that was
actually verified working.

cert-manager reaches the registration API in-cluster at
`http://acme-dns-api.acme-dns.svc:8080`. Plain HTTP is deliberate: it keeps the
credential inside the pod network and avoids a bootstrap loop, since acme-dns
must not need a certificate that acme-dns is itself required to issue. The API is
`ClusterIP`-only, so nothing on the internet can reach `/register`.

## Initial setup runbook

This is the order it was done in, and the order to repeat it in if the cluster is
ever rebuilt. Each step has a gate — do not proceed past a failing gate, because
everything downstream depends on it.

### 1. Publish the delegation

In whatever DNS host holds `6j0.org`:

```dns
acme-ns.6j0.org.   A    76.88.105.61
auth.6j0.org.      NS   acme-ns.6j0.org.
```

Independent of the cluster, so do it first and let it propagate.

**Gate:**

```shell
curl -s 'https://dns.google/resolve?name=auth.6j0.org&type=NS' | jq '.Answer'
```

### 2. Deploy acme-dns

Merge the app. Flux reconciles within its 10m interval.

**Gate** — confirm it answers *from outside*, not merely that the pod runs:

```shell
kubectl -n acme-dns get pod,svc          # Running; EXTERNAL-IP 192.168.8.13
curl -s 'https://dns.google/resolve?name=auth.6j0.org&type=SOA' | jq '.Status, .Comment'
```

The `Comment` must read `Response from 76.88.105.61.` — that is the whole
delegation path proving itself. If it does not, nothing downstream can work.

### 3. Register

```shell
kubectl -n acme-dns port-forward svc/acme-dns-api 8080:8080
curl -s -X POST http://localhost:8080/register | jq .
```

Keep the JSON: `username`, `password`, `fulldomain`, `subdomain`.

### 4. Publish the CNAME

Only possible now, because it needs `subdomain` from step 3.

```dns
_acme-challenge.6j0.org.   CNAME   <subdomain>.auth.6j0.org.
```

A wildcard is validated at its base domain, so `*.6j0.org` uses
`_acme-challenge.6j0.org` — *not* `_acme-challenge.*.6j0.org`.

### 5. Install the account secret

Keyed by the domain being **validated**, not the certificate's name:

```shell
# edit apps/cert-manager-custom-resources/acme-dns-account.secrets.yaml.decrypted
./encrypt_secrets.sh
# uncomment "- acme-dns-account.secrets.yaml" in that directory's kustomization.yaml
```

Commit **both** in one commit — see "The two-commit deadlock" below.

**Gate:**

```shell
kubectl get clusterissuer letsencrypt \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
kubectl get certificate -n envoy-gateway-system wildcard-6j0-org
curl -sS -o /dev/null -w '%{http_code}\n' https://longhorn.6j0.org/   # expect 401
```

## Adding a certificate later

Every certificate needs its own account entry and its own CNAME, because
acme-dns keys accounts by validated domain. **Prefer the existing `*.6j0.org`
wildcard instead**: point the Gateway listener's `certificateRefs` at
`wildcard-6j0-org-tls` and no new registration is needed at all.

Only register separately when the wildcard genuinely cannot cover the name — it
matches exactly one label, so `s3.garage.6j0.org` and `*.web.garage.6j0.org` need
their own. When you must:

1. `curl -X POST .../register` again — a *fresh* registration, not a copy
2. Add the key to `acmedns.json`, re-run `./encrypt_secrets.sh`
3. Publish `_acme-challenge.<host>.6j0.org CNAME <new-subdomain>.auth.6j0.org.`

Do not alias several domain keys onto one credential. acme-dns stores at most 2
TXT values per credential, so three or more certificates renewing concurrently
through one credential will clobber each other's challenges.

## Remaining work

`eg-public` still carries eleven per-hostname Certificates (wiki, immich,
nextcloud, peertube, timetracker, radicle, radicale, copyparty, seafile,
hatsmith, gathio). All eleven are single-label and so are already covered by
`*.6j0.org`. Until their listeners are repointed at `wildcard-6j0-org-tls`, each
one needs its own registration and CNAME at its next renewal.

Repointing them retires eleven Certificates and leaves exactly one registration
to maintain, forever.

**This has a clock on it.** `gathio-6j0-org-tls` expires 2026-10-17, and
cert-manager begins attempting renewal around 2026-10-02.

## Known fragility

`acme-ns.6j0.org` points at `76.88.105.61`, a **dynamic** Comcast address. If it
changes, Let's Encrypt can no longer find this server, renewals fail, and nothing
visibly breaks for about 15 days. Either keep it current with a dynamic-DNS
updater, or rely on the alerts in
`apps/kube-prometheus-stack/cert-expiry-rules.yaml`.

Do not plan on noticing by hand. `longhorn-6j0-org-tls` failed renewal 29 times
across a month before anyone spotted it, and only then because the UI stopped
answering on `:443`.

## Troubleshooting

### The two-commit deadlock

Adding the secret file in one commit and uncommenting it in `kustomization.yaml`
in a *later* commit can wedge `cert-manager-custom-resources` permanently. This
happened on 2026-09-27.

The ClusterIssuer references a secret that the earlier revision does not create,
so it reports `Ready=False InvalidSolver: failed to get secret`. With
`wait: true`, Flux burns the full 5m health-check timeout, the reconcile never
completes, and it therefore never advances to the commit that would create the
secret. The fix is in a revision Flux cannot reach.

Symptom — `lastAttemptedRevision` stuck behind the GitRepository:

```shell
kubectl get kustomization -n flux-system cert-manager-custom-resources \
  -o jsonpath='{.status.lastAttemptedRevision}{"\n"}{.status.lastAppliedRevision}{"\n"}'
kubectl get gitrepository -n flux-system flux-system -o jsonpath='{.status.artifact.revision}{"\n"}'
```

Fix:

```shell
flux reconcile kustomization cert-manager-custom-resources -n flux-system --with-source
```

Avoid it by committing the secret and its `resources` entry together.

### encrypt_secrets.sh reaches into worktrees

`encrypt_secrets.sh` runs `find "${SCRIPT_DIR}"` from the repo root, and git
worktrees under `.claude/worktrees/` are inside that tree. A stale
`*.yaml.decrypted` left in a worktree therefore gets encrypted by a run launched
from the main checkout, producing a second `*.secrets.yaml` that looks legitimate
but may hold placeholder values. Delete stale `.decrypted` files in worktrees
before running it, and check `git status` afterwards.

### Challenge stuck pending

Verify the chain from the outside, in order — the first failing link is the
problem:

```shell
curl -s 'https://dns.google/resolve?name=auth.6j0.org&type=NS' | jq '.Answer'
curl -s 'https://dns.google/resolve?name=_acme-challenge.6j0.org&type=TXT' | jq '.Answer, .Comment'
kubectl describe challenge -n envoy-gateway-system <name>
kubectl logs -n acme-dns -l app=acme-dns --tail=50
```

A correct TXT answer returns two records — the CNAME, then the TXT from
`<subdomain>.auth.6j0.org` — with `Comment: Response from 76.88.105.61.`

### Listener serving nothing on :443

Envoy Gateway refuses to program an HTTPS listener whose certificate Secret is
missing or expired, so the symptom is connection-refused rather than a TLS
warning:

```shell
kubectl get gateway -n envoy-gateway-system eg-private \
  -o jsonpath='{range .status.listeners[*]}{.name}{" Programmed="}{.conditions[?(@.type=="Programmed")].status}{"\n"}{end}'
```

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
- **Config format.** acme-dns v2 uses `engine = "sqlite"` (not `sqlite3`) and
  `port` under `[api]` is a *string*. The v1 examples still in circulation are
  wrong on both.
- **Exposure.** This answers only its own small zone and does no recursion, so it
  is a poor amplification target — but it is a public DNS server on a home
  connection. Consider rate limiting if that ever matters.
