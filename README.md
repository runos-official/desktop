# RunOS Desktop

RunOS Desktop is the macOS menu-bar facade for the RunOS CLI.

Install the application with `runos desktop install`.
Browser downloads are not a supported installation method.

The application requires macOS 15 or newer.
The application has separate Apple Silicon and Intel release archives.
Public builds use an ad hoc Apple signature.
Public builds are not signed with an Apple Developer ID.

Run `make verify` to build and test the application.

## Releases

Run `make release VERSION=vX.Y.Z-rc.N CHECK=1` to check a release candidate.
Use the repository release skills for development and production releases.
The release script keeps `main` under human control.

A release has two stages and one entry point, `scripts/release.sh`. A person runs it
through `make release`. Foreman runs the same script through
`.foreman/pipelines/release.yml`, on the `github-release` target for a candidate and
on the `github-release-prod` target for a final. Both targets integrate on `dev` and
record on the branch `deployed`, because the script advances only that branch.

1. **Candidate.** `vX.Y.Z-rc.N` is tagged on `dev`. GitHub Actions builds both archives
   and publishes a prerelease. The script then advances `deployed` to that commit. Install
   and test it with `runos desktop install --version X.Y.Z-rc.N`.
2. **Final.** `vX.Y.Z` is tagged on the same commit. The script refuses unless `dev` has
   not moved since the candidate, `deployed` is at that commit and a `vX.Y.Z-rc.N` tag
   points at it. The release becomes the latest GitHub release, which is what
   `runos desktop update` installs. Desktop advertises nothing to Conductor.

Before a candidate, `CHANGELOG.md` on `dev` needs a section headed `## vX.Y.Z`, with the
leading `v` and a body. A heading alone passes the script but not the release workflow,
which turns the section into the release notes and fails on an empty one. A candidate and
its final share the section of the base version. Because `dev` cannot move between the
candidate and the final, a correction to the notes means a new candidate.

A version given to the script or to Foreman always carries the leading `v`.

`make pipelinecheck` holds the Foreman pipeline file to the schema Foreman validates it
with and runs its git-only gate steps in throwaway repositories. It needs python3 with
PyYAML and touches no network, no GitHub and no tag.

## Working in this repository

Install the tracked git hooks once per clone, right after you clone.

```bash
make hooks        # sets core.hooksPath to the tracked .githooks/ directory
```

`.git/hooks` is not tracked, so a hook that is not installed is a hook nobody
has. The `pre-commit` hook runs the leak gate over your staged diff and blocks a
commit that would publish a credential or a new internal identifier.

Run `make help` to list every target.

## Public repository: no secrets, no real identifiers

This repository is public. Never commit:

- Credentials, tokens, API keys, or private keys.
- Real account, cluster or node identifiers.
- Org or customer names, internal hostnames or IP addresses, or private URLs.
- Named lab or rented test machines, and pasted terminal output that carries a
  real address.

Use placeholders in examples and fixtures. For addresses, use the ranges that
exist for exactly that purpose: `192.0.2.0/24`, `198.51.100.0/24` and
`203.0.113.0/24` (RFC 5737), and `2001:db8::/32` (RFC 3849).

### The leak gate

`scripts/leakcheck.py` enforces the rule. This checker is identical in every
public RunOS repository and carries a version marker, so drift is visible in a
diff. It runs in three places: the `pre-commit` hook (staged diff only, fast),
`make leakcheck` (on demand), and `scripts/release.sh` (whole tree, and it
cannot be skipped).

```bash
make leakcheck          # scan every tracked file
make leakcheck-staged   # scan only what is staged
make leakcheck-test     # test the checker itself
make leakcheck-update   # ratchet the baseline down after removing an identifier
```

It has two severities.

- **Credentials** hard fail, always. They can never be baselined.
- **Internal identifiers** are ratcheted against a committed baseline.
  `scripts/leakcheck.baseline` records what this repository has already
  published, so existing work is not blocked. A NEW identifier fails the gate.

What counts as an internal identifier: the machine names and account ids listed
in `scripts/leakcheck.config`, and any IP address literal outside the
documentation, loopback, link-local, unspecified, broadcast and well-known
multicast ranges. Addresses are allow-listed rather than deny-listed because you
cannot tell a real address from an invented one by reading it. A project
constant such as a service CIDR is absorbed into the baseline once and never
asked about again.

**Do not hand-add a line to `scripts/leakcheck.baseline` to get a commit
through.** A line in that file is a record of a leak that already shipped, not a
licence to add another. Remove the identifier from the source instead, then run
`make leakcheck-update` so the baseline shrinks.

The pre-commit hook can be skipped in a genuine emergency with
`git commit --no-verify`, and it says so when it fires. That does not get the
change released: the release gate runs the same checker over the whole tree.
