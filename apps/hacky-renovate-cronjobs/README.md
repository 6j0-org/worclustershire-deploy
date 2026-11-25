# hacky-renovate-cronjobs

[Renovate](https://docs.renovatebot.com/) for several GitHub accounts from one GitHub App: devopscoop, 6j0-org, and 3uzbcqje. A CronJob runs the official Renovate image for each account in turn, each walled off from the others (see "Isolation"). It lives only in this repo, not in the fluxcd template; `apps/renovate` is the template's single-account version, synced from upstream and not deployed here. Every hour on weekdays, at 33 minutes past in UTC, a Job starts one pod, which works through each account's repos and exits. Nothing runs between runs.

New repos default to dashboard-only mode. Renovate opens a PR for an update only after someone ticks its box on the repo's Dependency Dashboard issue, and assigns it to the code owners of the files it changes, from the repo's `CODEOWNERS` file. Lock file maintenance is on too: every Monday before 04:00 UTC the dashboard offers one PR that refreshes every lock file in the repo. Renovate holds back an update until its release is 7 days old, and offers to pin container images and GitHub Actions to digests, so a moved tag can't change what runs.

Security fixes skip both the wait and the dashboard: Renovate opens them on its own as soon as it finds them, from GitHub's vulnerability alerts and from [osv.dev](https://osv.dev/)'s database.

The global config is `config.json5`. It's shared by every account; repo-level options belong in each repo's `renovate.json`.

## Setup

1. Create the GitHub App. From the repo root:

   ```shell
   ./create_github_app.sh renovate --owner devopscoop
   ```

   The script opens a pre-filled "new app" page (click **Create GitHub App**) and then the install page. It writes the App ID into `github-app.env`, and the private key, sops-encrypted, to `github-app.secrets.yaml`. The app is named `<owner>-renovate` (here `devopscoop-renovate`) unless you pass `--name`. It's public, so accounts other than its owner can install it, but it isn't listed anywhere. It has no webhook and these repository permissions, from [Renovate's GitHub docs](https://docs.renovatebot.com/modules/platform/github/#running-as-a-github-app):

   | Permission        | Access         |
   | ----------------- | -------------- |
   | Checks            | Read and write |
   | Commit statuses   | Read and write |
   | Contents          | Read and write |
   | Issues            | Read and write |
   | Pull requests     | Read and write |
   | Workflows         | Read and write |
   | Administration    | Read           |
   | Dependabot alerts | Read           |
   | Metadata          | Read           |

   When the owner is an organization, the app also gets the organization permission Members: Read. Installations on user accounts (3uzbcqje) don't get it.

2. On the install page, install the app on each of the three accounts: pick the account and its repos, and click **Install**. Renovate discovers repos through each installation, so the installation's repo list is the only list to maintain. Installing on an organization takes an owner of that organization; for anyone else, GitHub sends the owners a request. To install on an account later, use the app's public page, `https://github.com/apps/<app-name>`.

Until step 1 has run, `github-app.env` holds the placeholder App ID `000000` and `github-app.secrets.yaml` is a copy of `apps/renovate`'s, most likely the template's placeholder key, so every token step fails and the Job pages. Don't push before running it.

To start a run without waiting for the schedule, for example right after ticking a box on a dashboard:

```shell
kubectl -n hacky-renovate-cronjobs create job --from=cronjob/renovate "renovate-manual-$(date +%s)"
```

The first run opens a "Configure Renovate" PR in each repo. Merging it adds the repo's `renovate.json` and creates the dashboard issue. To let Renovate open PRs on its own in a repo, remove `dependencyDashboardApproval` from that repo's `renovate.json`.

## Adding or removing an account

Each account has a block in `cronjob.yaml` (its `token-<account>` and `renovate-<account>` init containers, its `run-<account>` and `cache-<account>` volumes, and its `/results/<account>` mount in the `report` container) and a PVC in `caches.yaml`. To add one, copy an existing account's pieces and replace the name. Names must be lowercase there (`some-org`); the argument to each script is the login as GitHub shows it (`Some-Org`). Each step finds its account's installation by the login, so there's no installation ID to record. An account that installed the app but has no block is never touched.

## How a run works

Each account gets two init containers, and Kubernetes runs init containers one at a time, in order:

1. `token-<account>` (`mint-token.mjs`) signs a JWT with the app's private key, finds the account's installation, and mints an installation token. It writes the token to the account's in-memory volume.
2. `renovate-<account>` (`run-renovate.sh`) runs Renovate with that token. It deletes the token file once it has read it, then records Renovate's exit code in the same volume.

After every account's steps, the `report` container (`report.sh`) prints each account's result and fails the Job if any failed. A failed step doesn't stop the accounts after it.

An installation token expires after one hour, and Renovate can't mint one from the app's private key. Each token is minted just before its account's run, and `run-renovate.sh` stops Renovate after 55 minutes, before the token expires. The Job's `activeDeadlineSeconds` (4 hours) is only a backstop for a stuck run.

## Isolation

Renovate runs package-manager commands from the repos it updates, and some of them run code from the repo: Gradle build scripts and wrappers, a `Gemfile`, and Python source packages built during lock-file updates. (npm, Yarn, and pnpm install scripts are skipped by default.) The chain keeps that code from reaching another account:

- **Tokens.** While one account's Renovate step runs, the later accounts' tokens aren't minted yet. Each step mounts only its own account's token volume.
- **Nothing outlives a step.** Every process in an init container is gone before the next one starts, so nothing can wait for a later account's token.
- **Caches.** Each account has its own cache volume, so one account's run can't plant code that another's runs.
- **The private key** is mounted only in the `token-*` steps, which run no code from repos.
- **No Kubernetes credentials.** The pod has no service account token.

What it can't prevent: code run during an account's step can read that account's own token, which has the permissions above, until it expires. That's true of any Renovate setup. An egress NetworkPolicy that limits the pod to GitHub and your registries would make sending a stolen token out harder.

## Monitoring

Renovate has no metrics endpoint, so this app adds no scrape. A failed run fires `KubeJobFailed`, a warning from the bundled `kubernetes-apps` rules in `apps/victoria-metrics`, which pages. The `report` container's log says which accounts failed, and each step's log says why:

```shell
kubectl -n hacky-renovate-cronjobs logs job/<job-name> -c report
kubectl -n hacky-renovate-cronjobs logs job/<job-name> -c renovate-<account>   # or token-<account>
```

The alert keeps firing until the failed Job is deleted:

```shell
kubectl -n hacky-renovate-cronjobs delete job <job-name>
```

The run's logs are in the cluster's log store under the `hacky-renovate-cronjobs` namespace.

## Upgrading

Bump `newTag` under `images` in `kustomization.yaml`; it sets the image for every container. Renovate offers that update itself, on this repo's dashboard.
