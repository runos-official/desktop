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
