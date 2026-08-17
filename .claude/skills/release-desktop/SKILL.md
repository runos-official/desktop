---
name: release-desktop
description: Release and verify a RunOS Desktop candidate from the dev branch.
---

# Release RunOS Desktop to development

Use a release candidate before each production release.
The candidate must use a `vX.Y.Z-rc.N` tag.

## Preconditions

1. Confirm that the current branch is `dev`.
2. Confirm that `dev` matches `origin/dev`.
3. Add the base `vX.Y.Z` section to `CHANGELOG.md`.
4. Confirm that no tag exists for the candidate.

## Procedure

1. Run `make release VERSION=vX.Y.Z-rc.N CHECK=1`.
2. Fix each failed gate before continuing.
3. Run `make release VERSION=vX.Y.Z-rc.N`.
4. Confirm that the GitHub workflow succeeds.
5. Install the exact candidate with `runos desktop install --version X.Y.Z-rc.N --json`.
6. Open the application and exercise each menu action.
7. Verify account switching with two development accounts.
8. Verify VPN synchronization with a development daemon.
9. Verify a partial VPN synchronization failure.
10. Record how the candidate passed live verification.

The release script advances `deployed` only after artifact verification.
Do not promote an unverified candidate.
Do not merge `main` automatically.

## Failure handling

Create a new candidate after a code or workflow failure.
Do not delete a published tag.
Do not move `deployed` after a failed verification.
