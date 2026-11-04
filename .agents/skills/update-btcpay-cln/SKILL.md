---
name: update-btcpay-cln
description: Update BTCPay's Core Lightning fork, publish its image, and validate downstream integration before deployment. Use when bumping Core Lightning, rewriting btcpaymaster, or publishing a basedon-* image.
---

# Update BTCPay Core Lightning

Keep `btcpaymaster` linear: the selected upstream release followed by BTCPay's
commits. This repository builds `btcpayserver/lightning`; pushing a `basedon-*`
tag triggers [docker.yml](../../../.github/workflows/docker.yml), which removes
`basedon-` to form the image tag.

## Prepare the source

1. Read `AGENTS.md`. Confirm `origin` is `btcpayserver/lightning`, `upstream` is
   `ElementsProject/lightning`, and the worktree is clean. Fetch the remote
   `btcpaymaster` and selected upstream release tag; verify the tag's peeled SHA
   against upstream and read the release notes.
2. Identify the previous upstream tag and published BTCPay tag. Inspect every
   BTCPay-only commit in oldest-first order:

   ```bash
   git log --reverse --oneline <old-upstream-tag>..<old-btcpay-tag>
   ```

3. On a dedicated update branch at the new upstream tag, cherry-pick those
   commits separately and in order. Preserve later BTCPay fixes too; do not
   assume a historical commit list is still complete. Resolve conflicts without
   dropping upstream changes, then review:

   ```bash
   git range-diff <old-upstream-tag>..<old-btcpay-tag> <new-upstream-tag>..HEAD
   git diff --check <new-upstream-tag>..HEAD
   bash -n tools/docker-entrypoint.sh
   ```

Review any range-diff changes caused by conflict resolution. A local build and
smoke test can catch packaging failures before publication; record its source
SHA and keep local-candidate evidence distinct from published-image evidence.

## Publish once

The update request must authorize rewriting `btcpaymaster` and publishing the
image. Existing authorization is sufficient; otherwise ask before those actions.

Use `basedon-v<version>` for the first image of an upstream release, with no `-1`.
Use `-1`, `-2`, etc. only for subsequent BTCPay revisions. Before publishing,
check both Git refs and Docker Hub for the intended version. Never move a
published tag or reuse its image version for changed source.

1. Record the fetched remote SHA and confirm no unreviewed remote change has
   appeared. Push the prepared tip with an explicit lease:

   ```bash
   expected_remote=$(git rev-parse origin/btcpaymaster)
   git push --force-with-lease=refs/heads/btcpaymaster:$expected_remote \
     origin HEAD:refs/heads/btcpaymaster
   git ls-remote origin refs/heads/btcpaymaster
   ```

2. Require the remote branch SHA to equal the prepared tip. Create an annotated
   `basedon-v<version>` tag there, verify its peeled target, and push that tag.
   If a local candidate tag already exists, verify its target instead of
   silently replacing it. A remote tag with unexpected provenance needs
   investigation, not a force push.
3. Watch the matching `docker.yml` run to completion and verify its source SHA.
   Do not open downstream test PRs until publication succeeds.

If publication fails, diagnose the failed jobs. Retry infrastructure failures
on the same source; changed source requires a new revision tag. For a wrong-tag
push, cancel the run and inspect Git refs and registry artifacts before cleanup:
partial publication is possible. Tag deletion/recreation requires explicit
approval if already published or publication is uncertain. Historical Actions
runs retain their original SHA; use current remote refs to check a live tag.

## Verify the artifact

```bash
docker buildx imagetools inspect btcpayserver/lightning:v<version>
docker buildx imagetools inspect btcpayserver/lightning:v<version> \
  --format '{{json .Provenance}}'
docker pull btcpayserver/lightning:v<version>
docker run --rm --network none --entrypoint lightningd \
  btcpayserver/lightning:v<version> --version
```

Require `linux/amd64`, `linux/arm64`, and `linux/arm/v7`. Record the index and
platform digests and verify each platform's source attestation against the
published Git commit. The executable version can include `basedon-` because
CLN derives it from the repository tag. A version command alone does not prove
BTCPay integration or upgrade compatibility.

## Require both downstream integration runs

Read each repository's current agent instructions and workflows. Update the
exact published image tag, including any revision suffix, in:

| Repository | Compose files | CLN services |
| --- | --- | --- |
| `BTCPayServer.Lightning` | `tests/docker-compose.yml` | `lightningd`, `lightningd_dest` |
| `btcpayserver` | `BTCPayServer.Tests/docker-compose.yml`, `docker-compose.altcoins.yml`, `docker-compose.mutinynet.yml`, `docker-compose.testnet.yml` | `merchant_lightningd`, `customer_lightningd` in each |

Open the library PR, then the core PR linking it and the published image.
Require successful integration jobs on both PRs' **current heads**, inspect logs
for image pulls and executed CLN tests, and record commits, image tag/digest and
run links. Old-image CI is not evidence for this update. Investigate failures;
do not disable CLN tests to make the bump pass.

Core CI currently exercises regtest through `docker-compose.altcoins.yml`;
updating the other three files does not test their separate environments.
Follow the core test instructions, including `PLAYWRIGHT_HEADLESS=true` locally.

The [LND update guide](https://github.com/btcpayserver/lnd/blob/master/UPDATING-LND-NOTES.md#7-downstream-repos---exact-files)
uses the same two-repository gate. Its wallet-unlock and macaroon startup suite
is specific to LND, not a CLN prerequisite.

## Update deployment

After both integration suites pass, change the CLN fragment in
`btcpayserver-docker`. Follow its [agent instructions](https://github.com/btcpayserver/btcpayserver-docker/blob/master/AGENTS.md)
for generated files and its PR skill for draft/review conventions; do not copy
or hand-edit generated image tables. Link both test PRs in the deployment PR
and their successful runs in the handoff. Require the Docker repository's CI.

Use a disposable CLN-backed upgrade check unless an operator has authorized
changes to an existing server. Check retained node identity/channel state,
startup, peer connectivity and invoice/payment flows. Record reconnect steps
and coverage gaps; distinguish a node-level check from a full BTCPay upgrade.
Release preparation does not itself authorize merging PRs or changing a live
server.
