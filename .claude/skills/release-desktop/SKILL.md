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
5. Confirm that `git config core.hooksPath` prints `.githooks`.
6. Read the release payload with `git diff deployed..dev`, then remove each sensitive item.

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

## Leak gate

This repository is public.
`scripts/leakcheck.py` blocks a credential and a new internal identifier.
The checker has two severities.
A credential fails the gate always, and a credential can never be baselined.
An internal identifier ratchets against `scripts/leakcheck.baseline`.
A finding already recorded in the baseline passes.
A new finding fails.

Run `make hooks` once in each fresh clone.
The command sets `core.hooksPath` to `.githooks`.
Git never installs a repository hook for you, so a fresh clone has no gate until you run it.

The gate runs at three points.

| Where | Command | Skippable |
|---|---|---|
| Pre-commit, staged diff only | `.githooks/pre-commit`, or `make leakcheck-staged` by hand | Yes, with `git commit --no-verify` |
| On demand, whole tracked tree | `make leakcheck` | Not applicable |
| `scripts/release.sh`, whole tracked tree | Runs automatically, in `CHECK=1` too | **No.** No flag and no variable skips it. |

Fix the text when the gate fires.
Rewrite the comment, the fixture or the test name until the identifier is gone.
Do not run `make leakcheck-update` to clear a new finding.
That command ratchets the baseline down after you REMOVE an identifier from the source.
Baseline a finding only when the identifier is already published.
Never edit `scripts/leakcheck.baseline` by hand.
Prove a suspected false positive in `make leakcheck-test`, then fix the checker.

## Read the payload yourself

The leak gate is a floor.
The leak gate does not replace your own reading of the payload.
The checker knows the tokens in `scripts/leakcheck.config` and the shape of an address.
The checker cannot recognise a customer name it has never seen.
The checker cannot recognise a screenshot path, an internal URL or a project codename.
The checker cannot recognise prose that describes internal infrastructure without naming it.
Read the payload before each candidate.
Remove each sensitive item on `dev`, then run the gates again.

## Write about hardware without naming it

Name the role, not the machine.
Write "the lab box", "one host" or "a two-node cluster".
Do not write a machine name, an internal hostname, or an org or customer name.
Do not paste raw command output that carries a real address or a real id.
Replace each address with an RFC 5737 documentation address: `192.0.2.0/24`, `198.51.100.0/24` or `203.0.113.0/24`.
The measurement is the part the reader needs, and the machine name adds nothing.

This rule comes from a real incident on 2026-08-24.
A code comment in the public node agent repository named the operator's lab box and its disk layout.
The comment sat on `dev`, one push away from a release.
A human found the comment by reading the payload by hand.
Six earlier cases had already shipped.
One shipped test comment holds pasted terminal output with a real LAN address and a real host address.
That comment is public and nobody can unpublish it.

This skill file also ships in the public repository.
This skill file therefore describes the leaked identifiers and does not repeat them.
`scripts/leakcheck.config` holds the machine names, as bare tokens with no context.

## Failure handling

Create a new candidate after a code or workflow failure.
Fix the text when the leak gate fails, then create a new candidate.
Do not baseline an identifier that has never shipped.
Do not delete a published tag.
Do not move `deployed` after a failed verification.
