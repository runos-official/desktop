#!/usr/bin/env python3
"""Behaviour tests for .foreman/pipelines/release.yml.

Run with:  make pipelinecheck   (or: python3 scripts/pipeline_check_test.py)

pipeline_check.py holds the file to the schema. This file RUNS the three gate steps that
only read git (the version and target gate, the checkout, and "Final comes from the validated
candidate") in throwaway repositories with a throwaway origin. The two steps that call
scripts/release.sh are not run: they build and test the app and talk to GitHub.

This is a public repo. Every address, host and name below is a placeholder.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[1]
PIPELINE = yaml.safe_load((REPO / ".foreman" / "pipelines" / "release.yml").read_text())
STEPS = {step["name"]: step for step in PIPELINE["steps"]}
PLACEHOLDER_KEYS = ("version", "target.env", "target.branch", "target.deployed_branch")


def fill(step_name: str, **values: str) -> str:
    run = STEPS[step_name]["run"]
    for key, value in values.items():
        run = run.replace("${{ " + key.replace("__", ".") + " }}", value)
    assert "${{" not in run, f"unfilled placeholder in {step_name}"
    return run


def sh(cwd: Path, command: str) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", "-c", command], cwd=cwd, text=True, capture_output=True, check=False)


def git(cwd: Path, *args: str) -> str:
    result = subprocess.run(["git", *args], cwd=cwd, text=True, capture_output=True, check=False)
    assert result.returncode == 0, f"git {' '.join(args)}: {result.stderr}"
    return result.stdout.strip()


class Repo:
    """A bare origin and a working clone, with dev, a record branch named deployed, and tags."""

    def __init__(self, root: Path) -> None:
        self.origin = root / "origin.git"
        self.work = root / "work"
        subprocess.run(["git", "init", "-q", "--bare", str(self.origin)], check=True)
        subprocess.run(["git", "clone", "-q", str(self.origin), str(self.work)], check=True, capture_output=True)
        git(self.work, "config", "user.email", "tester@example.com")
        git(self.work, "config", "user.name", "tester")
        git(self.work, "checkout", "-q", "-b", "dev")
        self.commit("first")
        git(self.work, "push", "-q", "origin", "dev")

    def commit(self, name: str) -> str:
        (self.work / f"{name}.txt").write_text(name)
        git(self.work, "add", "-A")
        git(self.work, "commit", "-q", "-m", name)
        return git(self.work, "rev-parse", "HEAD")

    def record(self) -> None:
        """Put the record branch on the current dev commit, locally and on origin."""
        git(self.work, "branch", "-f", "deployed", "HEAD")
        git(self.work, "push", "-q", "-f", "origin", "deployed")

    def tag(self, name: str) -> None:
        git(self.work, "tag", name)
        git(self.work, "push", "-q", "origin", name)


class VersionAndTarget(unittest.TestCase):
    def gate(self, version: str, env: str, branch: str = "dev", deployed: str = "deployed") -> subprocess.CompletedProcess:
        run = fill(
            "Version and target agree",
            version=version,
            target__env=env,
            target__branch=branch,
            target__deployed_branch=deployed,
        )
        return sh(REPO, run)

    def test_a_dev_target_takes_only_a_candidate(self) -> None:
        for version in ("v0.4.8-rc.1", "v10.0.0-rc.12"):
            self.assertEqual(self.gate(version, "dev").returncode, 0, version)
        for version in ("v0.4.8", "v0.4.8-beta", "v0.4.8-rc", "0.4.8-rc.1", "", "v0.4", "latest"):
            result = self.gate(version, "dev")
            self.assertNotEqual(result.returncode, 0, f"'{version}'")

    def test_a_prod_target_takes_only_a_final(self) -> None:
        self.assertEqual(self.gate("v0.4.8", "prod").returncode, 0)
        for version in ("v0.4.8-rc.1", "0.4.8", "v0.4", "v0.4.8+b1", ""):
            self.assertNotEqual(self.gate(version, "prod").returncode, 0, f"'{version}'")

    def test_the_version_needs_the_leading_v_in_words(self) -> None:
        result = self.gate("0.4.8-rc.1", "dev")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("leading v", result.stdout)

    def test_a_target_that_integrates_or_records_elsewhere_is_refused(self) -> None:
        result = self.gate("v0.4.8", "prod", branch="main")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("releases only from dev", result.stdout)
        result = self.gate("v0.4.8", "prod", deployed="deployed/prod")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("advances only the record branch deployed", result.stdout)

    def test_an_unknown_env_is_refused(self) -> None:
        self.assertNotEqual(self.gate("v0.4.8", "staging").returncode, 0)


class Checkout(unittest.TestCase):
    def test_a_tree_behind_origin_catches_up_and_one_ahead_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Repo(Path(tmp))
            other = Path(tmp) / "other"
            subprocess.run(["git", "clone", "-q", str(repo.origin), str(other)], check=True, capture_output=True)
            git(other, "config", "user.email", "tester@example.com")
            git(other, "config", "user.name", "tester")
            git(other, "checkout", "-q", "dev")
            (other / "later.txt").write_text("later")
            git(other, "add", "-A")
            git(other, "commit", "-q", "-m", "later")
            git(other, "push", "-q", "origin", "dev")
            tip = git(other, "rev-parse", "HEAD")
            git(repo.work, "checkout", "-q", "-b", "elsewhere")
            run = fill("Check out the integration branch", target__branch="dev", target__deployed_branch="deployed")
            result = sh(repo.work, run)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(git(repo.work, "branch", "--show-current"), "dev")
            self.assertEqual(git(repo.work, "rev-parse", "HEAD"), tip)
            repo.commit("unpushed")
            result = sh(repo.work, run)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("has commits origin/dev does not", result.stdout)


class FinalFromCandidate(unittest.TestCase):
    def run_step(self, repo: Repo, version: str) -> subprocess.CompletedProcess:
        run = fill("Final comes from the validated candidate", version=version, target__branch="dev", target__deployed_branch="deployed")
        return sh(repo.work, run)

    def test_a_candidate_passes_straight_through(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Repo(Path(tmp))
            result = self.run_step(repo, "v0.4.8-rc.1")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("nothing to check", result.stdout)

    def test_a_final_from_the_exact_candidate_commit_passes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Repo(Path(tmp))
            repo.tag("v0.4.8-rc.1")
            repo.record()
            result = self.run_step(repo, "v0.4.8")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("will be cut from", result.stdout)

    def test_a_final_after_dev_moved_on_is_refused_in_words(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Repo(Path(tmp))
            repo.tag("v0.4.8-rc.1")
            repo.record()
            repo.commit("after the candidate")
            git(repo.work, "push", "-q", "origin", "dev")
            result = self.run_step(repo, "v0.4.8")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Cut a new candidate", result.stdout)

    def test_a_final_with_no_candidate_tag_on_the_tip_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Repo(Path(tmp))
            repo.tag("v0.4.7-rc.2")
            repo.record()
            result = self.run_step(repo, "v0.4.8")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("no release candidate tag v0.4.8-rc.N", result.stdout)

    def test_a_final_with_no_record_branch_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Repo(Path(tmp))
            repo.tag("v0.4.8-rc.1")
            result = self.run_step(repo, "v0.4.8")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("no release candidate has shipped", result.stdout)


class Files(unittest.TestCase):
    def test_no_step_names_a_credential_and_the_file_has_no_emdash(self) -> None:
        for step in PIPELINE["steps"]:
            self.assertEqual(step.get("needs", []), [], step["name"])
        self.assertNotIn(chr(0x2014), (REPO / ".foreman" / "pipelines" / "release.yml").read_text())

    def test_the_release_script_is_executable_and_takes_the_check_flag(self) -> None:
        script = REPO / "scripts" / "release.sh"
        self.assertTrue(os.access(script, os.X_OK))
        self.assertIn("--check", script.read_text())


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
