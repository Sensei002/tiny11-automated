#!/usr/bin/env python3
"""Static validation for the Tiny11 Core-Gaming GitHub Actions workflow.

Pester covers the workflow structurally (are the inputs declared, is the builder
invoked), but it cannot parse YAML. A workflow that fails to parse does not load at
all, so this checks the file is valid YAML, that every input referenced in an
expression is declared, and that the Core-Gaming workflow stays a superset of the
Core workflow's inputs.

Author: kelexine (https://github.com/kelexine)
License: MIT

Usage:
    python tests/validate_workflow.py

Requires: pyyaml
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = REPO_ROOT / ".github" / "workflows"
GAMING_WF = WORKFLOWS / "build-tiny11-core-gaming.yml"
CORE_WF = WORKFLOWS / "build-tiny11-core.yml"
EXPECTED_NAME = "Build and Release Tiny11 Core-Gaming"
EXPECTED_JOB = "build-tiny11-core-gaming"

problems: list[str] = []


def load_yaml(path: Path):
    try:
        import yaml  # noqa: PLC0415
    except ImportError:
        print("pyyaml is required:  pip install pyyaml")
        sys.exit(2)
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def inputs_of(doc) -> set[str]:
    # PyYAML maps the bare key `on` to the boolean True under YAML 1.1.
    on_block = doc.get("on") or doc.get(True) or {}
    dispatch = on_block.get("workflow_dispatch") or {}
    return set(dispatch.get("inputs") or {})


def main() -> int:
    print("=" * 68)
    print("Workflow validation")
    print("=" * 68)

    if not GAMING_WF.exists():
        print(f"[FAIL] missing {GAMING_WF.relative_to(REPO_ROOT)}")
        return 1

    try:
        doc = load_yaml(GAMING_WF)
    except Exception as exc:  # noqa: BLE001
        print(f"[FAIL] {GAMING_WF.name} is not valid YAML: {exc}")
        return 1

    print(f"[ok]   {GAMING_WF.name} parses as valid YAML")

    if doc.get("name") != EXPECTED_NAME:
        problems.append(f"unexpected workflow name: {doc.get('name')!r}")
        print(f"[FAIL] name is {doc.get('name')!r}, expected {EXPECTED_NAME!r}")
    else:
        print(f"[ok]   name: {EXPECTED_NAME!r}")

    jobs = doc.get("jobs") or {}
    if EXPECTED_JOB not in jobs:
        problems.append(f"expected job id {EXPECTED_JOB!r}")
        print(f"[FAIL] job id {EXPECTED_JOB!r} not found (have: {', '.join(jobs)})")
    else:
        print(f"[ok]   job id: {EXPECTED_JOB}")

    declared = inputs_of(doc)
    print(f"[ok]   {len(declared)} declared workflow_dispatch input(s)")

    raw = GAMING_WF.read_text(encoding="utf-8")

    referenced = set(re.findall(r"github\.event\.inputs\.([A-Za-z0-9_-]+)", raw))
    referenced |= set(re.findall(r"\binputs\.([A-Za-z0-9_-]+)", raw))

    print()
    print("Input cross-check")
    undeclared = sorted(referenced - declared)
    unused = sorted(declared - referenced)
    if undeclared:
        for name in undeclared:
            problems.append(f"referenced but not declared: {name}")
            print(f"[FAIL] referenced but NOT declared: {name}")
    else:
        print(f"[ok]   all {len(referenced)} referenced input(s) are declared")
    for name in unused:
        print(f"[warn] declared but never referenced: {name}")

    print()
    print("Core workflow compatibility")
    try:
        core_inputs = inputs_of(load_yaml(CORE_WF))
        missing = sorted(core_inputs - declared)
        if missing:
            for name in missing:
                problems.append(f"Core input not preserved: {name}")
                print(f"[FAIL] Core input missing: {name}")
        else:
            print(f"[ok]   all {len(core_inputs)} Core input(s) preserved")
        added = sorted(declared - core_inputs)
        print(f"[ok]   {len(added)} added gaming input(s): {', '.join(added)}")
    except Exception as exc:  # noqa: BLE001
        problems.append(f"could not compare against the Core workflow: {exc}")
        print(f"[FAIL] comparison failed: {exc}")

    print()
    print("Builder wiring")
    for flag in ("-GamingProfile", "-GamingGroups", "-HagsMode"):
        if flag in raw:
            print(f"[ok]   {flag} passed to the builder")
        else:
            problems.append(f"{flag} not passed to the builder")
            print(f"[FAIL] {flag} missing")

    if "tiny11coremaker-headless.ps1" in raw:
        print("[ok]   invokes tiny11coremaker-headless.ps1")
    else:
        problems.append("does not invoke the Core builder")
        print("[FAIL] does not invoke tiny11coremaker-headless.ps1")

    # The profile must be validated before the ISO download, otherwise a typo costs
    # an hour of build time.
    validate_at = raw.find("Validate gaming profile")
    download_at = raw.find("Download Windows 11 ISO")
    if validate_at > 0 and download_at > 0 and validate_at < download_at:
        print("[ok]   profile is validated before the ISO download")
    else:
        problems.append("profile validation does not precede the ISO download")
        print("[FAIL] profile validation should precede the ISO download")

    print()
    print("=" * 68)
    if problems:
        print(f"RESULT: {len(problems)} problem(s)")
        for item in problems:
            print(f"  - {item}")
        return 1

    print("RESULT: all workflow checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
