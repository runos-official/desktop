#!/usr/bin/env bash

# This script is the only release entry point for RunOS Desktop.
set -euo pipefail

INTEGRATION_BRANCH="dev"
DEPLOYED_BRANCH="deployed"
EXPECTED_REPO="runos-official/desktop"
RELEASE_WORKFLOW="release.yml"
POLL_SECONDS=10
MAX_WAIT_SECONDS=900

fail() {
  printf 'FAIL %s\n' "$1" >&2
  exit 1
}

step() {
  printf '==> %s\n' "$1"
}

VERSION="${1:-}"
CHECK_ONLY="false"
if [[ "${2:-}" == "--check" || "$VERSION" == "--check" ]]; then
  CHECK_ONLY="true"
fi
if [[ "$VERSION" == "--check" ]]; then
  VERSION=""
fi

[[ -n "$VERSION" ]] || fail "usage: scripts/release.sh vX.Y.Z[-rc.N] [--check]"
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] || fail "invalid version: $VERSION"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

step "Preflight for $VERSION"
for tool in git gh make python3 shasum; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated"

NWO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
[[ "$NWO" == "$EXPECTED_REPO" ]] || fail "release repository must be $EXPECTED_REPO"
[[ "$(git branch --show-current)" == "$INTEGRATION_BRANCH" ]] || fail "release from the dev branch"
[[ -z "$(git status --porcelain)" ]] || fail "working tree is dirty"

git fetch --quiet --tags origin
git fetch --quiet origin "$INTEGRATION_BRANCH"
[[ "$(git rev-parse "$INTEGRATION_BRANCH")" == "$(git rev-parse "origin/$INTEGRATION_BRANCH")" ]] || fail "dev does not match origin/dev"

if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
  fail "tag already exists: $VERSION"
fi
if git ls-remote --exit-code --tags origin "refs/tags/$VERSION" >/dev/null 2>&1; then
  fail "remote tag already exists: $VERSION"
fi

CHANGELOG_VERSION="${VERSION%%-*}"
grep -qE "^## ${CHANGELOG_VERSION//./\\.}([[:space:]]|$)" CHANGELOG.md || fail "CHANGELOG.md has no $CHANGELOG_VERSION section"

DEPLOYED_EXISTS="false"
DEPLOYED_REF=""
git fetch --quiet origin "$DEPLOYED_BRANCH" >/dev/null 2>&1 || true
if git show-ref --verify --quiet "refs/heads/$DEPLOYED_BRANCH"; then
  DEPLOYED_EXISTS="true"
  DEPLOYED_REF="$DEPLOYED_BRANCH"
  if git show-ref --verify --quiet "refs/remotes/origin/$DEPLOYED_BRANCH"; then
    [[ "$(git rev-parse "$DEPLOYED_BRANCH")" == "$(git rev-parse "origin/$DEPLOYED_BRANCH")" ]] || fail "deployed does not match origin/deployed"
  fi
elif git show-ref --verify --quiet "refs/remotes/origin/$DEPLOYED_BRANCH"; then
  DEPLOYED_EXISTS="true"
  DEPLOYED_REF="origin/$DEPLOYED_BRANCH"
fi
if [[ "$DEPLOYED_EXISTS" == "true" ]]; then
  git merge-base --is-ancestor "$DEPLOYED_REF" "$INTEGRATION_BRANCH" || fail "deployed cannot advance to dev"
fi

if [[ "$DEPLOYED_EXISTS" == "true" ]]; then
  PAYLOAD_BASE="$DEPLOYED_REF"
elif PAYLOAD_BASE="$(git describe --tags --abbrev=0 "$INTEGRATION_BRANCH" 2>/dev/null)"; then
  :
else
  PAYLOAD_BASE="$(git rev-list --max-parents=0 "$INTEGRATION_BRANCH" | tail -1)"
fi

if [[ "$VERSION" != *-* ]]; then
  [[ "$DEPLOYED_EXISTS" == "true" ]] || fail "production requires a deployed release candidate"
  [[ "$(git rev-parse "$DEPLOYED_REF")" == "$(git rev-parse "$INTEGRATION_BRANCH")" ]] || fail "dev advanced after the release candidate"
  CANDIDATE_TAG=""
  while IFS= read -r tag; do
    case "$tag" in
      "$VERSION"-*) CANDIDATE_TAG="$tag" ;;
    esac
  done < <(git tag --points-at "$INTEGRATION_BRANCH")
  [[ -n "$CANDIDATE_TAG" ]] || fail "production requires a matching release candidate tag"
fi

step "Scan the public release payload"
ADDED_LINES="$(git diff "$PAYLOAD_BASE..$INTEGRATION_BRANCH" -- . | grep '^+' | grep -v '^+++' || true)"
SECRET_RE='(gh[pousr]_[A-Za-z0-9]{20,})|(github_pat_[A-Za-z0-9_]{20,})|(runos_pat_[A-Za-z0-9]{6,}\.[A-Za-z0-9]{20,})|(xox[baprs]-[A-Za-z0-9-]{10,})|(AKIA[0-9A-Z]{16})|(-----BEGIN [A-Z ]*PRIVATE KEY-----)'
if printf '%s\n' "$ADDED_LINES" | grep -nE "$SECRET_RE"; then
  fail "secret-shaped content exists in the release payload"
fi

# ---- Leak gate: internal identifiers (PUBLIC repo) -------------------------
# The floor above covers CREDENTIAL shapes in the payload diff. This gate covers
# the other half of the rule, INTERNAL IDENTIFIERS (lab machine names, account
# ids, IP address literals), and it reads the WHOLE TRACKED TREE, not the diff,
# because a public repo publishes the tree and not just the newest commits.
#
# The preflight above already proved the working tree is the dev tree and is
# clean, so scanning the working tree scans exactly what is about to ship.
#
# It is a ratchet, not a blanket ban: findings already recorded in
# scripts/leakcheck.baseline pass, anything NEW fails. That is deliberate. A
# blanket ban on a repo that already carries published violations would block
# every commit and get the gate switched off within a day.
#
# This gate CANNOT be skipped. The pre-commit hook in .githooks/ runs the same
# checker over the staged diff and CAN be skipped with --no-verify, which is why
# this one exists.
step "Leak gate (public repo, whole tree)"
command -v python3 >/dev/null 2>&1 || fail "python3 is required for the leak gate"
if ! LEAK_OUTPUT="$(python3 "$REPO_ROOT/scripts/leakcheck.py" 2>&1)"; then
  printf '%s\n' "$LEAK_OUTPUT" >&2
  fail "leak gate failed (public repo): remove the identifiers above before releasing. Do not hand-edit scripts/leakcheck.baseline."
fi
printf ' ok %s\n' "$(printf '%s' "$LEAK_OUTPUT" | tail -1)"

step "Run the release gates"
make verify

if [[ "$CHECK_ONLY" == "true" ]]; then
  printf 'All release gates passed. No tag was created.\n'
  exit 0
fi

step "Create and push $VERSION"
RELEASE_COMMIT="$(git rev-parse "$INTEGRATION_BRANCH")"
git tag "$VERSION" "$RELEASE_COMMIT"
git push origin "$INTEGRATION_BRANCH"
git push origin "$VERSION"

step "Wait for the release workflow"
RUN_ID=""
WAITED=0
while [[ -z "$RUN_ID" && "$WAITED" -lt 60 ]]; do
  RUN_ID="$(gh run list --workflow="$RELEASE_WORKFLOW" --limit 20 --json databaseId,headBranch,event -q "[.[] | select(.headBranch==\"$VERSION\" and .event==\"push\")][0].databaseId" 2>/dev/null || true)"
  [[ -n "$RUN_ID" ]] && break
  sleep "$POLL_SECONDS"
  WAITED=$((WAITED + POLL_SECONDS))
done
[[ -n "$RUN_ID" ]] || fail "release workflow did not start"

WAITED=0
while [[ "$WAITED" -lt "$MAX_WAIT_SECONDS" ]]; do
  RUN_STATE="$(gh run view "$RUN_ID" --json status,conclusion -q '.status + " " + (.conclusion // "")')"
  RUN_STATUS="${RUN_STATE%% *}"
  RUN_CONCLUSION="${RUN_STATE#* }"
  if [[ "$RUN_STATUS" == "completed" ]]; then
    [[ "$RUN_CONCLUSION" == "success" ]] || fail "release workflow failed: $RUN_ID"
    break
  fi
  sleep "$POLL_SECONDS"
  WAITED=$((WAITED + POLL_SECONDS))
done
[[ "$RUN_STATUS" == "completed" ]] || fail "release workflow timed out: $RUN_ID"

step "Verify the published artifacts"
RELEASE_TMP="$(mktemp -d)"
trap 'rm -rf "$RELEASE_TMP"' EXIT
gh release download "$VERSION" --repo "$NWO" --pattern 'runos-desktop-macos-*.zip' --pattern checksums.txt --dir "$RELEASE_TMP"
(
  cd "$RELEASE_TMP"
  shasum -a 256 -c checksums.txt
)

EXPECTED_SAN="https://github.com/$NWO/.github/workflows/$RELEASE_WORKFLOW@refs/tags/$VERSION"
for asset in runos-desktop-macos-arm64.zip runos-desktop-macos-amd64.zip; do
  VERIFY_JSON="$(gh attestation verify "$RELEASE_TMP/$asset" --repo "$NWO" --format json)"
  ACTUAL_SAN="$(printf '%s' "$VERIFY_JSON" | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data[0]["verificationResult"]["signature"]["certificate"].get("subjectAlternativeName", ""))')"
  [[ "$ACTUAL_SAN" == "$EXPECTED_SAN" ]] || fail "unexpected attestation signer for $asset"
done

step "Advance the deployed branch"
git branch -f "$DEPLOYED_BRANCH" "$RELEASE_COMMIT"
git push origin "$DEPLOYED_BRANCH"

RELEASE_URL="$(gh release view "$VERSION" --repo "$NWO" --json url -q .url)"
printf 'Released %s from %s.\n' "$VERSION" "$RELEASE_COMMIT"
printf 'Release: %s\n' "$RELEASE_URL"
printf 'The main branch remains under human control.\n'
