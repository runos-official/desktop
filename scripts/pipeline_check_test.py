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
# A branch that no longer records anything. Spelled in two halves so that this file does not trip its own scan.
RETIRED_BRANCH = "deployed/" + "prod"


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
    """A bare origin and a working clone, with dev, the prod record main, a record branch named deployed, and tags."""

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
        # The prod record starts at the first commit, an ancestor of every later dev commit.
        git(self.work, "push", "-q", "origin", "dev:refs/heads/main")

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
    def gate(self, version: str, env: str, branch: str = "dev") -> subprocess.CompletedProcess:
        run = fill("Version and target agree", version=version, target__env=env, target__branch=branch)
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

    def test_a_target_that_integrates_elsewhere_is_refused(self) -> None:
        result = self.gate("v0.4.8", "prod", branch="main")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("releases only from dev", result.stdout)

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
            run = fill("Check out the integration branch", target__branch="dev")
            result = sh(repo.work, run)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(git(repo.work, "branch", "--show-current"), "dev")
            self.assertEqual(git(repo.work, "rev-parse", "HEAD"), tip)
            repo.commit("unpushed")
            result = sh(repo.work, run)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("has commits origin/dev does not", result.stdout)


class FinalFromCandidate(unittest.TestCase):
    """The step calls scripts/record-release.sh. The prod target records on main, the dev target on deployed."""

    def run_step(self, repo: Repo, version: str, env: str = "", record: str = "") -> subprocess.CompletedProcess:
        env = env or ("dev" if "-" in version else "prod")
        record = record or ("deployed" if env == "dev" else "main")
        run = fill(
            "Final comes from the validated candidate",
            version=version,
            target__env=env,
            target__branch="dev",
            target__deployed_branch=record,
        )
        # The pipeline runs from the repo root. The throwaway clone has no scripts, so point at this repo's.
        run = run.replace("scripts/record-release.sh", str(REPO / "scripts" / "record-release.sh"))
        return sh(repo.work, run)

    def test_a_candidate_passes_straight_through(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Repo(Path(tmp))
            result = self.run_step(repo, "v0.4.8-rc.1")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("leaves main alone", result.stdout)

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
            self.assertIn("Cut a new candidate", result.stderr)

    def test_a_final_with_no_candidate_tag_on_the_tip_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Repo(Path(tmp))
            repo.tag("v0.4.7-rc.2")
            repo.record()
            result = self.run_step(repo, "v0.4.8")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("no release candidate tag v0.4.8-rc.N", result.stderr)

    def test_a_final_with_no_record_branch_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Repo(Path(tmp))
            repo.tag("v0.4.8-rc.1")
            result = self.run_step(repo, "v0.4.8")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("no release candidate has shipped", result.stderr)

    def test_a_prod_target_must_record_on_main_and_a_candidate_must_not(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Repo(Path(tmp))
            repo.tag("v0.4.8-rc.1")
            repo.record()
            result = self.run_step(repo, "v0.4.8", env="prod", record="deployed")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("a final on a prod target records on main", result.stderr)
            result = self.run_step(repo, "v0.4.8-rc.1", env="dev", record="main")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must not record on main", result.stderr)

    def test_a_final_is_refused_before_the_tag_when_main_has_diverged(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Repo(Path(tmp))
            git(repo.work, "checkout", "-q", "-b", "side", "origin/main")
            repo.commit("on main only")
            git(repo.work, "push", "-q", "-f", "origin", "side:refs/heads/main")
            git(repo.work, "checkout", "-q", "dev")
            repo.tag("v0.4.8-rc.1")
            repo.record()
            result = self.run_step(repo, "v0.4.8")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("could not fast-forward main", result.stderr)

    def test_a_final_on_a_good_main_passes_and_says_it_will_fast_forward(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Repo(Path(tmp))
            repo.commit("the candidate")
            git(repo.work, "push", "-q", "origin", "dev")
            repo.tag("v0.4.8-rc.1")
            repo.record()
            result = self.run_step(repo, "v0.4.8")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("will fast-forward it", result.stdout)


class Record(unittest.TestCase):
    def test_the_record_script_passes_its_own_test(self) -> None:
        result = subprocess.run(["bash", str(REPO / "scripts" / "record-release-test.sh")], text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_the_release_step_expects_the_main_facts(self) -> None:
        self.assertEqual(set(STEPS["Release"]["expect"]), {"main_before", "main_after", "main_equals_final"})

    def test_the_gate_and_release_steps_name_no_record_branch(self) -> None:
        for name in ("Gate chain", "Release"):
            self.assertNotIn("deployed", STEPS[name]["run"], name)
            self.assertNotRegex(STEPS[name]["run"], r"(^|[^\w-])main([^\w/-]|$)", name)

    def test_no_pipeline_script_or_test_names_the_retired_branch(self) -> None:
        here = Path(__file__).resolve()
        for root in (REPO / ".foreman" / "pipelines", REPO / "scripts"):
            for path in sorted(root.rglob("*")):
                if not path.is_file() or path.resolve() in (here, REPO / "scripts" / "pipeline_check.py"):
                    continue
                self.assertNotIn(RETIRED_BRANCH, path.read_text(errors="replace"), str(path.relative_to(REPO)))


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
