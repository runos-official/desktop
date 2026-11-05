#!/usr/bin/env python3
"""Load every Foreman pipeline file in this repo against the schema Foreman validates it with.

Usage:  python3 scripts/pipeline_check.py        (needs python3 and PyYAML, exit 0 = pass)

Mirrors, by hand, the keys and limits of `pipelineFile` and `pipelineStep` in the Foreman repo
(packages/contracts/src/deployments.ts) and the placeholder rules of `interpolate` and
`sharedRecordBranchLeaks` (apps/api/src/services/deployments/pipeline.ts). It is a copy, so a
change to the Foreman schema needs the same change here; the check that matters is Foreman's own
loader, and this script exists to catch a typo before a deploy is triggered.

Then it holds each file to the rules this repo wants of it (see EXPECT below).
"""
import re
import subprocess
import sys
from pathlib import Path

import yaml

PIPELINE_DIR = Path(__file__).resolve().parents[1] / ".foreman" / "pipelines"

# pipelineFile keys, strict: an unknown key is a failure.
FILE_KEYS = {"name", "description", "kind", "operation", "install", "requires_files", "advertises", "steps"}
# pipelineStep keys, strict.
STEP_KEYS = {"name", "description", "run", "needs", "timeout", "workdir", "slow"}
KINDS = {"runos_cluster", "github_release"}
OPERATIONS = {"deploy", "cohort", "rollback"}
SLUG = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
PLACEHOLDER = re.compile(r"\$\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}")
BARE = {"version", "repo", "ref", "branch", "fast", "rollback_to"}
# The target config keys these pipelines are allowed to read. The target row must define each.
TARGET_KEYS = {"env", "branch", "deployed_branch"}
# The shared record branches. A command that names one literally defeats the objective-scoped
# rewrite of ${{ target.deployed_branch }}, which Foreman refuses.
RECORD_BRANCHES = ("deployed/dev", "deployed/prod")

# Per file: the exact step names in order and the credential slugs each step may name. A file not
# listed here fails, so a new pipeline must be added to this table on purpose.
#
# Desktop is a PUBLIC repo whose artefacts GitHub Actions builds. gh authenticates from the host
# keyring, so NO step names a credential, and the file has no `install` and no `advertises`.
EXPECT = {
    "release.yml": {
        "install": False,
        "kind": "github_release",
        "steps": [
            ("Version and target agree", []),
            ("Check out the integration branch", []),
            ("Final comes from the validated candidate", []),
            ("Gate chain", []),
            ("Release", []),
        ],
        "timeouts": {"Gate chain": 3600, "Release": 3600},
        "slugs": set(),
        "forbid_slug_fragment": None,
        "script": "scripts/release.sh",
        "runs": {
            "Gate chain": 'scripts/release.sh "${{ version }}" --check',
            "Release": 'scripts/release.sh "${{ version }}"',
        },
    },
}


def check_step(where: str, step: object, errors: list[str]) -> None:
    if not isinstance(step, dict):
        errors.append(f"{where}: a step must be a mapping")
        return
    for key in step:
        if key not in STEP_KEYS:
            errors.append(f"{where}: unknown step key '{key}'")
    name = step.get("name")
    if not isinstance(name, str) or not 1 <= len(name.strip()) <= 120:
        errors.append(f"{where}: name must be a string of 1 to 120 characters")
    desc = step.get("description", "")
    if not isinstance(desc, str) or len(desc.strip()) > 500:
        errors.append(f"{where}: description must be a string of at most 500 characters")
    run = step.get("run")
    if not isinstance(run, str) or not 1 <= len(run.strip()) <= 4000:
        errors.append(f"{where}: run must be a string of 1 to 4000 characters")
    needs = step.get("needs", [])
    if not isinstance(needs, list) or len(needs) > 10:
        errors.append(f"{where}: needs must be a list of at most 10 slugs")
    else:
        for slug in needs:
            if not isinstance(slug, str) or not SLUG.match(slug):
                errors.append(f"{where}: credential slug {slug!r} must be kebab-case")
    timeout = step.get("timeout")
    if timeout is not None and (
        isinstance(timeout, bool) or not isinstance(timeout, int) or not 0 < timeout <= 21600
    ):
        errors.append(f"{where}: timeout must be a positive integer of at most 21600")
    workdir = step.get("workdir")
    if workdir is not None and (not isinstance(workdir, str) or len(workdir.strip()) > 200):
        errors.append(f"{where}: workdir must be a string of at most 200 characters")
    if "slow" in step and not isinstance(step["slow"], bool):
        errors.append(f"{where}: slow must be a boolean")
    if isinstance(run, str):
        for expr in PLACEHOLDER.findall(run):
            if "." in expr:
                if not expr.startswith("target.") or expr[len("target."):] not in TARGET_KEYS:
                    errors.append(f"{where}: placeholder ${{{{ {expr} }}}} is not a target key this repo expects")
            elif expr not in BARE:
                errors.append(f"{where}: placeholder ${{{{ {expr} }}}} is not one foreman resolves")
        for line in run.split("\n"):
            if line.lstrip().startswith("#"):
                continue
            for branch in RECORD_BRANCHES:
                if re.search(rf"(^|[^\w-]){re.escape(branch)}([^\w/-]|$)", line):
                    errors.append(f"{where}: the command names the shared record branch {branch} literally; use ${{{{ target.deployed_branch }}}}")
        # The shell must at least parse. Placeholders become a plain word, as foreman fills them in.
        parsed = subprocess.run(
            ["bash", "-n"], input=PLACEHOLDER.sub("x1.2.3", run), text=True, capture_output=True, check=False
        )
        if parsed.returncode != 0:
            errors.append(f"{where}: the command is not valid shell: {parsed.stderr.strip()}")
        if "git add -A" in run or "git add ." in run:
            errors.append(f"{where}: a blanket git add can sweep unreviewed work into a release; stage named files")


def check_file(path: Path) -> list[str]:
    errors: list[str] = []
    label = path.name
    try:
        doc = yaml.safe_load(path.read_text())
    except yaml.YAMLError as err:
        return [f"{label}: not valid YAML: {err}"]
    if not isinstance(doc, dict):
        return [f"{label}: the file must be a mapping"]
    for key in doc:
        if key not in FILE_KEYS:
            errors.append(f"{label}: unknown key '{key}'")
    name = doc.get("name")
    if not isinstance(name, str) or not 1 <= len(name.strip()) <= 120:
        errors.append(f"{label}: name must be a string of 1 to 120 characters")
    description = doc.get("description", "")
    if not isinstance(description, str) or len(description.strip()) > 1000:
        errors.append(f"{label}: description must be a string of at most 1000 characters")
    if doc.get("kind") not in KINDS:
        errors.append(f"{label}: kind must be one of {sorted(KINDS)}")
    if doc.get("operation", "deploy") not in OPERATIONS:
        errors.append(f"{label}: operation must be one of {sorted(OPERATIONS)}")
    steps = doc.get("steps")
    if not isinstance(steps, list) or not 1 <= len(steps) <= 100:
        errors.append(f"{label}: steps must be a list of 1 to 100 steps")
        steps = []
    install = doc.get("install")
    if install is not None:
        check_step(f"{label} install", install, errors)
    for index, step in enumerate(steps):
        check_step(f"{label} step {index + 1}", step, errors)

    expect = EXPECT.get(path.name)
    if expect is None:
        errors.append(f"{label}: no expectations in EXPECT; add this file to the table on purpose")
        return errors
    if doc.get("operation", "deploy") != expect.get("operation", "deploy"):
        errors.append(f"{label}: operation must be {expect.get('operation', 'deploy')}")
    if bool(install) != expect["install"]:
        errors.append(f"{label}: install step {'missing' if expect['install'] else 'not expected'}")

    named = [(s.get("name"), s.get("needs", [])) for s in steps if isinstance(s, dict)]
    if "steps" in expect and named != expect["steps"]:
        errors.append(f"{label}: steps are {named}, expected {expect['steps']}")
    for step in steps:
        if not isinstance(step, dict):
            continue
        want = expect.get("timeouts", {}).get(step.get("name"))
        if want is not None and step.get("timeout") != want:
            errors.append(f"{label}: step {step.get('name')!r} timeout must be {want}")
    used = {slug for s in steps if isinstance(s, dict) for slug in s.get("needs", [])}
    extra = used - expect["slugs"]
    if extra:
        errors.append(f"{label}: credential slugs {sorted(extra)} are not allowed in this file")
    fragment = expect["forbid_slug_fragment"]
    if fragment and any(fragment in slug.replace("ghcr-push-token", "") for slug in used):
        errors.append(f"{label}: a credential slug naming '{fragment}' does not belong in this file")
    script = expect.get("script")
    if script:
        if not (PIPELINE_DIR.parents[1] / script).is_file():
            errors.append(f"{label}: the script {script} does not exist")
        if not any(isinstance(s, dict) and script in s.get("run", "") for s in steps):
            errors.append(f"{label}: no step runs {script}")
    if expect.get("operation") == "rollback" and any(
        isinstance(s, dict) and "deploy-prod.sh" in s.get("run", "") for s in steps
    ):
        errors.append(f"{label}: a rollback must not run the promote script deploy-prod.sh")
    if doc.get("kind") != expect.get("kind", doc.get("kind")):
        errors.append(f"{label}: kind must be {expect['kind']}")
    if "advertises" in doc:
        errors.append(f"{label}: Desktop advertises nothing; the CLI installer reads the latest GitHub release")
    for name, want_run in expect.get("runs", {}).items():
        for step in steps:
            if isinstance(step, dict) and step.get("name") == name and step.get("run", "").strip() != want_run:
                errors.append(f"{label}: step {name!r} must run exactly {want_run}")
    promote_env = expect.get("promote_env")
    if promote_env:
        for step in steps:
            if isinstance(step, dict) and step.get("name") == "Promote" and promote_env not in step.get("run", ""):
                errors.append(f"{label}: the Promote step must set {promote_env}")
    return errors


def main() -> int:
    files = sorted(PIPELINE_DIR.glob("*.y*ml"))
    if not files:
        print(f"no pipeline files in {PIPELINE_DIR}")
        return 1
    failures = 0
    for path in files:
        errors = check_file(path)
        if errors:
            failures += len(errors)
            for message in errors:
                print(f"FAIL {message}")
        else:
            print(f"ok   {path.name}")
    missing = set(EXPECT) - {p.name for p in files}
    for name in sorted(missing):
        failures += 1
        print(f"FAIL {name}: expected pipeline file is missing")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
