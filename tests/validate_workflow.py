#!/usr/bin/env python3
"""Static validation for the Tiny11 GitHub Actions workflows.

Pester covers the workflows structurally (are the inputs declared, is the builder
invoked), but it cannot parse YAML. A workflow that fails to parse does not load at
all, so this checks the file is valid YAML, that every input referenced in an
expression is declared, and that the Core-Gaming workflow stays a superset of the
Core workflow's inputs.

It also covers the two LTSC workflows, where the risk is different: the image index
is not a constant. It has to agree with the catalogue, has to be derived rather than
typed, and has to be verified against the mounted ISO before the builder runs.

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

CATALOG = REPO_ROOT / "scripts" / "ltsc-edition-catalog.ps1"
BACKFILL_WF = WORKFLOWS / "upload-iso-to-sourceforge.yml"
BUILD_WORKFLOWS = [
    "build-tiny11.yml",
    "build-tiny11-core.yml",
    "build-tiny11-core-gaming.yml",
    "build-nano11.yml",
    "build-tiny11-ltsc.yml",
    "build-tiny11-core-ltsc.yml",
]
LTSC_WORKFLOWS = {
    "build-tiny11-ltsc.yml": {
        "name": "Build and Release Tiny11 LTSC",
        "builder": "tiny11maker-headless.ps1",
    },
    "build-tiny11-core-ltsc.yml": {
        "name": "Build and Release Tiny11 Core LTSC",
        "builder": "tiny11coremaker-headless.ps1",
    },
}

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


def catalog_entries() -> list[dict[str, str]]:
    """Read the edition catalogue out of the PowerShell file.

    The catalogue is the single source of truth for the LTSC indexes, so the
    workflows are checked against it rather than against a second copy of the list
    kept here. Parsing is deliberately line-based: the entries are flat
    [pscustomobject] literals and a regex over the whole file would be more
    fragile than reading them one block at a time.
    """
    entries: list[dict[str, str]] = []
    current: dict[str, str] | None = None

    for line in CATALOG.read_text(encoding="utf-8").splitlines():
        if "[pscustomobject]@{" in line:
            current = {}
            continue
        if current is not None and line.strip() == "}":
            entries.append(current)
            current = None
            continue
        if current is not None:
            match = re.match(r"\s*(\w+)\s*=\s*(.+?)\s*$", line)
            if match:
                current[match.group(1)] = match.group(2).strip().strip("'")

    return entries


def validate_ltsc_workflows() -> None:
    print()
    print("LTSC workflows")

    if not CATALOG.exists():
        problems.append("missing scripts/ltsc-edition-catalog.ps1")
        print("[FAIL] scripts/ltsc-edition-catalog.ps1 is missing")
        return

    entries = catalog_entries()
    if len(entries) != 5:
        problems.append(f"catalogue has {len(entries)} entries, expected 5")
        print(f"[FAIL] catalogue has {len(entries)} entries, expected 5")
        return

    expected_names = [entry.get("Name", "") for entry in entries]
    print(f"[ok]   catalogue lists {len(entries)} editions")

    # The index layout the workflows assume, asserted here so a catalogue edit that
    # silently reshuffles the media is caught in CI rather than in a build.
    by_family: dict[str, list[tuple[int, str]]] = {}
    for entry in entries:
        by_family.setdefault(entry.get("Family", ""), []).append(
            (int(entry.get("Index", "0")), entry.get("Name", ""))
        )

    expected_layout = {
        "Windows 11": [
            (1, "Windows 11 Enterprise LTSC"),
            (2, "Windows 11 IoT Enterprise LTSC"),
            (3, "Windows 11 IoT Enterprise Subscription LTSC"),
        ],
        "Windows 10": [
            (1, "Windows 10 Enterprise LTSC"),
            (2, "Windows 10 IoT Enterprise LTSC"),
        ],
    }

    for family, layout in expected_layout.items():
        actual = sorted(by_family.get(family, []))
        if actual == layout:
            print(f"[ok]   {family} LTSC layout: {len(layout)} images at index "
                  f"{', '.join(str(i) for i, _ in layout)}")
        else:
            problems.append(f"{family} LTSC index layout does not match the media")
            print(f"[FAIL] {family} layout is {actual}, expected {layout}")

    for filename, spec in LTSC_WORKFLOWS.items():
        path = WORKFLOWS / filename
        print(f"\n  {filename}")

        if not path.exists():
            problems.append(f"missing {filename}")
            print("[FAIL] file is missing")
            continue

        try:
            doc = load_yaml(path)
        except Exception as exc:  # noqa: BLE001
            problems.append(f"{filename} is not valid YAML: {exc}")
            print(f"[FAIL] not valid YAML: {exc}")
            continue

        print("[ok]   parses as valid YAML")

        if doc.get("name") != spec["name"]:
            problems.append(f"{filename} name is {doc.get('name')!r}")
            print(f"[FAIL] name is {doc.get('name')!r}, expected {spec['name']!r}")
        else:
            print(f"[ok]   name: {spec['name']!r}")

        raw = path.read_text(encoding="utf-8")
        declared = inputs_of(doc)

        referenced = set(re.findall(r"github\.event\.inputs\.([A-Za-z0-9_-]+)", raw))
        referenced |= set(re.findall(r"\binputs\.([A-Za-z0-9_-]+)", raw))
        undeclared = sorted(referenced - declared)
        if undeclared:
            for name in undeclared:
                problems.append(f"{filename}: input {name} referenced but not declared")
                print(f"[FAIL] referenced but NOT declared: {name}")
        else:
            print(f"[ok]   all {len(referenced)} referenced input(s) are declared")

        # The index must be derived, not chosen: a dropdown of raw numbers is
        # exactly what puts the wrong SKU on someone's machine.
        if "image_index" in declared:
            problems.append(f"{filename} still exposes an image_index input")
            print("[FAIL] image_index is still a workflow input")
        else:
            print("[ok]   no image_index input - the index is derived")

        if "windows_iso_url" not in declared:
            problems.append(f"{filename} has no windows_iso_url input")
            print("[FAIL] windows_iso_url is missing")
        else:
            print("[ok]   windows_iso_url is the paste box")

        dispatch = (doc.get("on") or doc.get(True) or {}).get("workflow_dispatch") or {}
        options = ((dispatch.get("inputs") or {}).get("ltsc_edition") or {}).get("options") or []
        if options == expected_names:
            print(f"[ok]   edition menu matches the catalogue ({len(options)} options)")
        else:
            problems.append(f"{filename} edition menu does not match the catalogue")
            print(f"[FAIL] edition menu is {options}, expected {expected_names}")

        if "ltsc-edition-catalog.ps1" in raw and "Resolve-LTSCEdition" in raw:
            print("[ok]   resolves the edition through the catalogue")
        else:
            problems.append(f"{filename} does not use the catalogue")
            print("[FAIL] does not use scripts/ltsc-edition-catalog.ps1")

        verify_at = raw.find("Verify the LTSC edition is on the ISO")
        builder_at = raw.find(spec["builder"])
        if verify_at < 0:
            problems.append(f"{filename} does not verify the ISO edition")
            print("[FAIL] no ISO edition verification step")
        elif builder_at < 0:
            problems.append(f"{filename} does not invoke {spec['builder']}")
            print(f"[FAIL] does not invoke {spec['builder']}")
        elif verify_at > builder_at:
            problems.append(f"{filename} verifies the ISO after the builder runs")
            print("[FAIL] ISO verification must precede the builder")
        else:
            print("[ok]   ISO verified before the builder runs")

        if "ExpectedEdition = $env:LTSC_EDITION_NAME" in raw:
            print("[ok]   -ExpectedEdition is passed to the builder")
        else:
            problems.append(f"{filename} does not pass -ExpectedEdition")
            print("[FAIL] -ExpectedEdition is not passed")


def validate_sourceforge_folders() -> None:
    """One folder per variant, and the backfill must not invent a different one.

    A release lands in a folder named after the variant, edition and version -
    Tiny11-Pro-26H2, Tiny11Core-Pro-26H2, Tiny11CoreGaming-Pro-26H2. The backfill
    workflow has no way to derive that from an ISO filename, so each build records
    it in the verification file and the backfill reads it back.
    """
    print()
    print("SourceForge folder placement")

    expected_folders = {
        "build-tiny11.yml": '"Tiny11-$edition-$version"',
        "build-tiny11-core.yml": '"Tiny11Core-$edition-$version"',
        "build-tiny11-core-gaming.yml": '"Tiny11CoreGaming-$edition-$version"',
        "build-nano11.yml": '"Nano11-$edition-$version"',
    }

    for name in BUILD_WORKFLOWS:
        path = WORKFLOWS / name
        if not path.exists():
            problems.append(f"missing {name}")
            print(f"[FAIL] missing {name}")
            continue

        raw = path.read_text(encoding="utf-8")

        if "Folder: $env:FOLDER_NAME" not in raw:
            problems.append(f"{name} does not record its SourceForge folder")
            print(f"[FAIL] {name} does not write 'Folder: $env:FOLDER_NAME'")
        else:
            print(f"[ok]   {name} records its folder")

        if name in expected_folders:
            pattern = expected_folders[name]
            if pattern in raw:
                print(f"[ok]   {name} folder is {pattern.strip(chr(34))}")
            else:
                problems.append(f"{name} no longer uses the {pattern} folder")
                print(f"[FAIL] {name} does not use {pattern}")

        # A release folder should read as a plain list of ISOs. The checksums and
        # the verification file belong in the GitHub release and the artifact.
        leaked = [
            suffix
            for suffix in (".sha256", ".md5", ".txt")
            if f'Copy-Item "$env:ISO_NAME{suffix}" $env:FOLDER_NAME' in raw
        ]
        if leaked:
            problems.append(f"{name} still publishes {', '.join(leaked)} to SourceForge")
            print(f"[FAIL] {name} still copies {', '.join(leaked)} into the release folder")
        else:
            print(f"[ok]   {name} publishes only the ISO")

    if not BACKFILL_WF.exists():
        problems.append("missing upload-iso-to-sourceforge.yml")
        print("[FAIL] missing upload-iso-to-sourceforge.yml")
        return

    raw = BACKFILL_WF.read_text(encoding="utf-8")

    if "*.iso.txt" in raw and "Folder:" in raw:
        print("[ok]   backfill reads the folder the build recorded")
    else:
        problems.append("backfill does not read the recorded folder")
        print("[FAIL] backfill does not read 'Folder:' from the artifact")

    if "A-Za-z0-9._-" in raw:
        print("[ok]   backfill validates the folder name")
    else:
        problems.append("backfill does not validate the folder name")
        print("[FAIL] backfill does not validate the folder name")

    if 'mv -v "$iso" "$folder"/' in raw:
        print("[ok]   backfill publishes only the ISO")
    else:
        problems.append("backfill copies more than the ISO into the release folder")
        print("[FAIL] backfill should move only the ISO")

    # The regression that produced a stray folder per backfilled release: falling
    # back to the ISO stem silently. The fallback may exist, but must warn.
    if 'folder="${iso_name%.iso}"' in raw and "::warning" in raw:
        print("[ok]   ISO-stem fallback warns instead of guessing quietly")
    else:
        problems.append("ISO-stem fallback is silent or missing")
        print("[FAIL] ISO-stem fallback must warn")


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

    validate_ltsc_workflows()
    validate_sourceforge_folders()

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
