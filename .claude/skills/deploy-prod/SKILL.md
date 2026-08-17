---
name: deploy-prod
description: Promote a verified RunOS Desktop release candidate to production.
---

# Promote RunOS Desktop to production

Production always follows a verified development release.
The final tag must reference the exact verified candidate commit.

## Preconditions

1. Confirm that a `vX.Y.Z-rc.N` release exists.
2. Confirm that live development verification passed.
3. Confirm that `deployed` references the candidate commit.
4. Confirm that `dev` has not advanced after the candidate.
5. Confirm that `CHANGELOG.md` accurately describes the release.

Stop when any precondition fails.
Create and verify a new candidate when `dev` has advanced.

## Procedure

1. Run `make release VERSION=vX.Y.Z CHECK=1`.
2. Run `make release VERSION=vX.Y.Z`.
3. Confirm that both archives pass checksum verification.
4. Confirm that both archives have valid build provenance.
5. Confirm that the release becomes the latest GitHub release.
6. Run `runos desktop update --json` on a clean test account.
7. Confirm that Desktop relaunches after replacement.
8. Confirm that the installed application reports version `X.Y.Z`.

The Desktop release needs no Foreman advertisement.
The CLI installer reads the latest GitHub release.
Do not change Conductor configuration.
Do not merge `main` automatically.

## Failure handling

Fix forward with a new release candidate.
Do not delete a published tag.
Do not advertise browser downloads as an installation method.
