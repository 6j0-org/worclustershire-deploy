// Mints a GitHub App installation token for one account, just before that
// account's Renovate step runs, and writes it to /run/renovate/token in the
// account's own in-memory volume. Only these steps mount the app's private
// key; the Renovate steps, which run package-manager commands from the repos
// they update, never see it.
//
// Usage: node mint-token.mjs <account>
//
// The installation is looked up by the account's login, so only accounts
// that have a step in cronjob.yaml get a token. An account that installed
// the app without one is never touched.
//
// Always exits 0, so a failure here doesn't stop the accounts after this one.
// The Renovate step finds no token and records the failure, and report.sh
// fails the Job.

import { sign } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const account = process.argv[2];

function appJwt() {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const unsigned = b64({ alg: "RS256", typ: "JWT" }) + "." +
    b64({ iat: now - 60, exp: now + 540, iss: process.env.GITHUB_APP_ID });
  const signature = sign("sha256", Buffer.from(unsigned), readFileSync("/github-app/private-key"));
  return `${unsigned}.${signature.toString("base64url")}`;
}

async function github(jwt, method, path) {
  const res = await fetch(`https://api.github.com${path}`, {
    method,
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${jwt}`,
      "X-GitHub-Api-Version": "2022-11-28",
    },
    signal: AbortSignal.timeout(30_000),
  });
  if (!res.ok) {
    throw new Error(`${method} ${path}: GitHub returned ${res.status}: ${await res.text()}`);
  }
  return res.json();
}

try {
  if (!account) throw new Error("No account given.");
  const jwt = appJwt();
  let installation;
  for (let page = 1; !installation; page++) {
    const batch = await github(jwt, "GET", `/app/installations?per_page=100&page=${page}`);
    installation = batch.find((i) => i.account.login.toLowerCase() === account.toLowerCase());
    if (batch.length < 100) break;
  }
  if (!installation) {
    throw new Error(`The app has no installation on ${account}. Install it there, or remove the account's steps from cronjob.yaml.`);
  }
  const { token } = await github(jwt, "POST", `/app/installations/${installation.id}/access_tokens`);
  writeFileSync("/run/renovate/token", token, { mode: 0o600 });
  console.log(`Minted a token for ${account} (installation ${installation.id}).`);
} catch (err) {
  console.error(`Couldn't mint a token for ${account}: ${err.message}`);
}
