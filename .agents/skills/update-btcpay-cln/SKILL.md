---
name: update-btcpay-cln
description: Update the BTCPay Core Lightning fork to an upstream CLN release and publish a btcpayserver/lightning image. Use when bumping Core Lightning, rewriting btcpaymaster, creating a basedon-* tag, or publishing the Lightning Docker image.
---

# Update BTCPay Core Lightning

Use this workflow to base `btcpaymaster` linearly on a new upstream Core
Lightning release, reapply BTCPay's commits, and publish the corresponding
multi-platform `btcpayserver/lightning` image.

This image is built from this repository, not `dockerfile-deps`. Pushing a
`basedon-*` tag runs `.github/workflows/docker.yml`; the workflow strips the
`basedon-` prefix to obtain the Docker image tag.

## Choose The Tag

For the first BTCPay image based on an upstream release, use exactly:

```text
basedon-v<version>
```

For example, upstream `v26.06.8` produces:

```text
Git tag:     basedon-v26.06.8
Docker tag:  btcpayserver/lightning:v26.06.8
```

Add `-1`, `-2`, and later revisions only when publishing another image from
the same upstream release. Do not add `-1` to its first BTCPay image.

## Prepare The Update

1. Read `AGENTS.md`, inspect the worktree, remotes, tracking branches, tags,
   and recent history. Start with a clean worktree.
2. Confirm `origin` is `btcpayserver/lightning` and `upstream` is
   `ElementsProject/lightning`.
3. Fetch `origin` and the new upstream release tag. Verify the upstream tag
   exists and inspect its peeled commit rather than assuming the release or
   tag name:

```bash
git fetch origin \
  refs/heads/btcpaymaster:refs/remotes/origin/btcpaymaster
git fetch upstream \
  refs/tags/v<new-version>:refs/tags/v<new-version>
git ls-remote upstream \
  refs/tags/v<new-version> \
  'refs/tags/v<new-version>^{}'
```

4. Identify the previous upstream and `basedon-*` tags. List the BTCPay-only
   commits in oldest-first order:

```bash
git log --reverse --oneline \
  v<old-version>..basedon-v<old-version>[-revision]
```

Inspect every commit and record its SHA before rewriting `btcpaymaster`.

## Rebuild `btcpaymaster`

This repository intentionally keeps `btcpaymaster` as the upstream release
plus the BTCPay-only commits. Do not merge the new release into the old
`btcpaymaster` tip.

Resetting and force-pushing are destructive. Ensure the update request
authorizes rewriting and publishing `btcpaymaster`; otherwise ask before doing
either operation.

```bash
git switch btcpaymaster
git reset --hard v<new-version>
git cherry-pick <oldest-btcpay-commit> [<next-btcpay-commit> ...]
```

Resolve conflicts without dropping upstream changes or BTCPay behavior. Keep
the BTCPay commits separate and in their original order.

Verify the resulting history and changes:

```bash
git status --short --branch
git log --graph --decorate --oneline -10
git diff --check v<new-version>..HEAD
git range-diff \
  v<old-version>..basedon-v<old-version>[-revision] \
  v<new-version>..HEAD
bash -n tools/docker-entrypoint.sh
```

The range diff should show that the BTCPay-only commits were reapplied. Review
any differences caused by conflict resolution.

## Push And Publish

1. Record the current remote `btcpaymaster` SHA and force-push with an explicit
   lease. Never use an unguarded force push:

```bash
expected_remote=$(git rev-parse origin/btcpaymaster)
git push \
  --force-with-lease=refs/heads/btcpaymaster:$expected_remote \
  origin btcpaymaster
```

2. Verify the remote branch before creating a tag:

```bash
git ls-remote origin refs/heads/btcpaymaster
```

3. Check that the intended tag does not already exist locally or remotely. If
   it exists, stop and determine whether an image was already published. Do
   not move or reuse a published tag without explicit approval.
4. Create an annotated tag at the verified `btcpaymaster` tip, verify its
   peeled target, then push it:

```bash
git tag -a basedon-v<new-version> -m basedon-v<new-version>
test "$(git rev-parse 'basedon-v<new-version>^{}')" = \
  "$(git rev-parse btcpaymaster)"
git push origin basedon-v<new-version>
```

5. Watch the Docker publication workflow through completion:

```bash
gh run list \
  --repo btcpayserver/lightning \
  --workflow docker.yml \
  --branch basedon-v<new-version> \
  --limit 1
gh run watch <run-id> --repo btcpayserver/lightning --exit-status
```

Do not continue to downstream updates until the workflow succeeds.

## Verify The Published Image

Confirm the image index contains `linux/amd64`, `linux/arm64`, and
`linux/arm/v7`, then run the published executable:

```bash
docker buildx imagetools inspect \
  btcpayserver/lightning:v<new-version>
docker run --rm --entrypoint lightningd \
  btcpayserver/lightning:v<new-version> --version
```

The reported version can include the `basedon-` prefix because BTCPay's
`Makefile` derives it from the repository tag.

After publication, update `btcpayserver-docker` according to that repository's
own agent instructions and generated-image workflow.

## Recover From A Wrong Tag

If a tag is pushed from the wrong commit or with the wrong revision:

1. Cancel its Actions run immediately and wait until cancellation completes.
2. Delete the remote tag so it cannot be mistaken for the intended source.
3. Delete the local tag.
4. Rebuild and verify `btcpaymaster` using the workflow above.
5. Recreate the correct tag only after the remote branch is correct.
6. Inspect Docker Hub because a canceled multi-platform build may have
   partially published artifacts.

Example cleanup commands:

```bash
gh run cancel <run-id> --repo btcpayserver/lightning
gh run watch <run-id> --repo btcpayserver/lightning --exit-status
git push origin :refs/tags/<wrong-tag>
git tag -d <wrong-tag>
```

Deleting and recreating a remote tag does not update matching tags in other
local checkouts. A normal fetch does not overwrite an existing local tag. To
repair a stale checkout, compare the local and remote peeled targets, then
replace only the stale local tag:

```bash
git ls-remote origin \
  refs/tags/basedon-v<version> \
  'refs/tags/basedon-v<version>^{}'
git tag -d basedon-v<version>
git fetch origin tag basedon-v<version>
```

Historical Actions runs retain the tag SHA from their original push event even
after the live tag is deleted or recreated. Use `git ls-remote` or GitHub's Git
refs API to verify the current remote tag.
