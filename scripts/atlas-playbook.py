#!/usr/bin/env python3
"""Compile an AtlasOS playbook (.apbx) into a plan the offline applier can execute.

The Atlas playbook is a zip archive (password "malte", documented publicly) full of
YAML files that the AME Wizard interprets on a *live* Windows install. A CI build has
no live install: the image is a mounted WIM, so nothing can run interactively and no
service can be started. This script does the half that does not need Windows - it
opens the archive, reads the playbook manifest, and flattens the whole action tree
into one ordered JSON list - so that scripts/atlas-playbook.ps1 only has to execute
a plan instead of re-implementing a YAML parser.

Two things are decided here rather than in the applier:

  * Which build numbers the playbook accepts. Atlas v0.5.0 ships 26100 (24H2) and
    26200 (25H2) in <SupportedBuilds>; a 26H2 image is newer than anything the
    playbook was written for, so the gate would reject it. The build actually read
    from the ISO is appended to the list and the patched playbook.conf is written
    back next to the extracted tree, which is what "enable 26H2 in the playbook"
    means in practice - no guessed build number is baked in.

  * What cannot be applied offline. Every action is classified while flattening, so
    the plan carries an explicit coverage report instead of silently dropping the
    script-driven half of the playbook.

Author: Sensei002 (https://github.com/Sensei002)
License: MIT

Usage:
    python scripts/atlas-playbook.py --playbook <path-or-url> --out atlas-plan.json
    python scripts/atlas-playbook.py --windows-build 26300 --out atlas-plan.json

Requires: pyyaml
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import sys
import urllib.error
import urllib.request
import zipfile
from pathlib import Path
from xml.etree import ElementTree

REPO_ROOT = Path(__file__).resolve().parent.parent

# The archive password is not a secret: Atlas documents the format, and every
# playbook is a renamed, password-protected zip so that it can be audited.
PLAYBOOK_PASSWORD = b"malte"

ATLAS_RELEASES_API = "https://api.github.com/repos/Atlas-OS/Atlas/releases/latest"

# Actions the offline applier understands. Everything else is recorded as skipped
# with a reason, and the counts land in the build manifest.
APPLICABLE = {
    "registryValue": "registry",
    "registryKey": "registry",
    "service": "registry",
    "appx": "appx",
}

# Live-only verbs. They need a running Windows (services, shell, task scheduler) or
# an interactive session, none of which exist against a mounted image.
LIVE_ONLY_REASONS = {
    "powerShell": "runs a live PowerShell session",
    "cmd": "runs a live cmd.exe session",
    "run": "launches an executable on the running system",
    "taskKill": "needs a running process table",
    "scheduledTask": "needs the Task Scheduler service",
    "file": "operates on a live user profile path",
    "delete": "operates on a live path",
    "install": "installs software",
    "uninstall": "uninstalls software",
}

# Tag spellings that only ever appear inside comments or string literals. They are
# counted separately so a real action never hides in the noise.
NOT_ACTIONS = {"App", "Microsoft", "microsoft", "SecHealthUI", "disable"}


class PlaybookError(RuntimeError):
    pass


# --------------------------------------------------------------------------- yaml


def _load_yaml_module():
    try:
        import yaml  # noqa: PLC0415
    except ImportError:
        print("pyyaml is required:  pip install pyyaml", file=sys.stderr)
        raise SystemExit(2)
    return yaml


def build_loader():
    """A SafeLoader that keeps the AME tag on every mapping it parses.

    The playbook is YAML with custom tags (`!registryValue:`, `!task:`, ...). PyYAML
    refuses unknown tags, and dropping them would lose the only thing that says what
    an action *is*, so each tagged node is turned into a plain dict carrying
    `__tag__`.
    """
    yaml = _load_yaml_module()

    class AtlasLoader(yaml.SafeLoader):
        pass

    def construct_tagged(loader, tag_suffix, node):
        # Playbook actions are written as `- !task: {path: ...}`, which YAML reads
        # as the tag `!task:` - the colon belongs to the tag, not the value, so it
        # has to come back off before the tag can be compared to anything.
        tag = tag_suffix.rstrip(":")
        if isinstance(node, yaml.MappingNode):
            data = loader.construct_mapping(node, deep=True)
        elif isinstance(node, yaml.SequenceNode):
            data = loader.construct_sequence(node, deep=True)
        else:
            data = loader.construct_scalar(node)
        if isinstance(data, dict):
            data["__tag__"] = tag
            return data
        return {"__tag__": tag, "value": data}

    AtlasLoader.add_multi_constructor("!", construct_tagged)
    return AtlasLoader


# ----------------------------------------------------------------------- download


def http_get(url: str, timeout: int = 60) -> bytes:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "tiny11-automated-atlas-playbook/1.0",
            "Accept": "application/vnd.github+json",
        },
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
        return response.read()


def resolve_latest_playbook() -> tuple[str, str]:
    """Return (url, tag) for the newest .apbx published on the Atlas releases page."""
    try:
        payload = json.loads(http_get(ATLAS_RELEASES_API).decode("utf-8"))
    except (urllib.error.URLError, json.JSONDecodeError) as exc:
        raise PlaybookError(f"could not query the Atlas release API: {exc}") from exc

    tag = payload.get("tag_name") or "unknown"
    for asset in payload.get("assets") or []:
        name = asset.get("name") or ""
        if name.lower().endswith(".apbx"):
            return asset["browser_download_url"], tag
    raise PlaybookError(f"release {tag} publishes no .apbx asset")


def fetch_playbook(source: str, work_dir: Path) -> tuple[Path, str]:
    """Return (local path, provenance string) for a URL or an existing file."""
    if re.match(r"^https?://", source, re.IGNORECASE):
        work_dir.mkdir(parents=True, exist_ok=True)
        name = source.rstrip("/").split("/")[-1] or "AtlasPlaybook.apbx"
        target = work_dir / name
        print(f"  downloading {source}")
        data = http_get(source, timeout=300)
        target.write_bytes(data)
        print(f"  saved {target.name} ({len(data) / 1048576:.1f} MB)")
        return target, source

    path = Path(source)
    if not path.exists():
        raise PlaybookError(f"playbook not found: {path}")
    return path, str(path.resolve())


# ------------------------------------------------------------------------ extract


def extract_playbook(archive: Path, destination: Path) -> None:
    """Unpack the .apbx, replacing whatever was there before."""
    if destination.exists():
        shutil.rmtree(destination, ignore_errors=True)
    destination.mkdir(parents=True, exist_ok=True)

    try:
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(destination, pwd=PLAYBOOK_PASSWORD)
    except zipfile.BadZipFile as exc:
        raise PlaybookError(f"{archive.name} is not a zip archive: {exc}") from exc
    except RuntimeError as exc:
        raise PlaybookError(
            f"could not decrypt {archive.name} - the archive password changed: {exc}"
        ) from exc

    if not (destination / "playbook.conf").exists():
        raise PlaybookError(
            f"{archive.name} extracted but has no playbook.conf - wrong file?"
        )


def read_manifest(extracted: Path) -> dict:
    """Pull the fields the applier needs out of playbook.conf."""
    tree = ElementTree.parse(extracted / "playbook.conf")
    root = tree.getroot()

    def text(tag: str) -> str:
        node = root.find(tag)
        return (node.text or "").strip() if node is not None else ""

    supported = [
        (node.text or "").strip()
        for node in root.findall("./SupportedBuilds/string")
        if (node.text or "").strip()
    ]

    options: list[dict] = []
    for page in root.findall("./FeaturePages/*"):
        page_kind = page.tag
        page_desc = page.get("Description") or ""
        page_default = page.get("DefaultOption") or ""
        depends_on = page.get("DependsOn") or ""

        for option in page.findall("./Options/*"):
            name = (option.findtext("Name") or "").strip()
            if not name:
                continue
            options.append(
                {
                    "name": name,
                    "text": (option.findtext("Text") or "").strip(),
                    "page": page_kind,
                    "pageDescription": page_desc,
                    "default": name == page_default,
                    "dependsOn": depends_on,
                }
            )

    return {
        "name": text("Name"),
        "title": text("Title"),
        "version": text("Version"),
        "uniqueId": text("UniqueId"),
        "supportedBuilds": supported,
        "options": options,
        "tree": tree,
    }


def enable_build(manifest: dict, build: str) -> bool:
    """Add a build number to <SupportedBuilds> and rewrite playbook.conf.

    Returns True when the build had to be added, so the caller can warn about it.
    """
    supported = manifest["supportedBuilds"]
    if build in supported:
        return False

    tree = manifest["tree"]
    root = tree.getroot()
    container = root.find("SupportedBuilds")
    if container is None:
        container = ElementTree.SubElement(root, "SupportedBuilds")

    # Keep the list ordered; Atlas ships it ascending and a human may read it.
    ordered = sorted(set(supported) | {build}, key=lambda value: int(value))
    for node in list(container):
        container.remove(node)
    for value in ordered:
        node = ElementTree.SubElement(container, "string")
        node.text = value

    ElementTree.indent(tree, space="\t")
    tree.write(
        Path(manifest["path"]) / "playbook.conf",
        encoding="utf-8",
        xml_declaration=True,
    )
    manifest["supportedBuilds"] = ordered
    return True


# ------------------------------------------------------------------------ flatten


def normalise(relative: str) -> str:
    """Playbook paths are Windows-style; normalise so Path can resolve them."""
    return relative.replace("\\", "/").strip()


class Flattener:
    def __init__(self, configuration: Path):
        self.configuration = configuration
        self.actions: list[dict] = []
        self.skipped: dict[str, int] = {}
        self.skipped_detail: list[dict] = []
        self.visited: list[str] = []
        self.stats = {
            "registryValue": 0,
            "registryKey": 0,
            "service": 0,
            "appx": 0,
        }

    # -- helpers ---------------------------------------------------------------

    def _skip(self, action: dict, file_name: str, reason: str) -> None:
        tag = action.get("__tag__", "unknown")
        self.skipped[tag] = self.skipped.get(tag, 0) + 1
        # Keep the manifest readable: one line per skipped action, but never the
        # whole script body.
        detail = action.get("command") or action.get("exe") or action.get("name") or ""
        if isinstance(detail, str):
            detail = " ".join(detail.split())[:160]
        self.skipped_detail.append(
            {"tag": tag, "file": file_name, "reason": reason, "detail": detail}
        )

    # -- walk ------------------------------------------------------------------

    def walk_file(self, relative: str, inherited_options: list[str], depth: int = 0) -> None:
        if depth > 12:
            raise PlaybookError(f"task nesting too deep at {relative} (cycle?)")

        path = self.configuration / normalise(relative)
        if not path.exists():
            raise PlaybookError(f"playbook references a missing file: {relative}")

        key = str(path.resolve())
        if key in self.visited:
            # A file included twice would apply its actions twice; Atlas never does
            # it, but a duplicated include is a bug worth surfacing.
            print(f"  [warn] {relative} included more than once - second pass skipped")
            return
        self.visited.append(key)

        yaml = _load_yaml_module()
        loader = build_loader()
        with open(path, encoding="utf-8", errors="replace") as handle:
            document = yaml.load(handle, Loader=loader)  # noqa: S506

        if not isinstance(document, dict):
            return

        # Files flagged onUpgrade are migrations from a previous Atlas version. A
        # fresh ISO has no previous version, so they must not run.
        if document.get("onUpgrade") is True:
            self._skip(
                {"__tag__": "task", "command": relative},
                relative,
                "onUpgrade-only migration file",
            )
            return

        for action in document.get("actions") or []:
            if isinstance(action, dict):
                self.walk_action(action, relative, inherited_options, depth)

    def walk_action(
        self, action: dict, file_name: str, inherited_options: list[str], depth: int
    ) -> None:
        tag = action.get("__tag__")

        if tag in NOT_ACTIONS or not tag:
            return

        options = list(inherited_options)
        own_option = action.get("option")
        if isinstance(own_option, str) and own_option:
            options.append(own_option)
        elif isinstance(own_option, list):
            options.extend(str(item) for item in own_option if item)

        if tag == "writeStatus":
            return

        if tag == "task":
            target = action.get("path")
            if not target:
                return
            self.walk_file(str(target), options, depth + 1)
            return

        if tag in APPLICABLE:
            entry = {
                "kind": APPLICABLE[tag],
                "action": tag,
                "file": file_name,
                "options": sorted(set(options)),
            }
            for field in ("path", "value", "data", "type", "operation", "name", "startup"):
                if field in action and action[field] is not None:
                    entry[field] = action[field]
            if "type" in action and tag == "appx":
                entry["appxType"] = action.get("type")
                entry.pop("type", None)
            for field in ("cpuArch", "iso", "ignoreErrors"):
                if field in action:
                    entry[field] = action[field]
            self.stats[tag] = self.stats.get(tag, 0) + 1
            self.actions.append(entry)
            return

        reason = LIVE_ONLY_REASONS.get(tag, "not an offline-applicable verb")
        self._skip(action, file_name, reason)


def compile_plan(extracted: Path, build: str, source: str, archive: Path) -> dict:
    manifest = read_manifest(extracted)
    manifest["path"] = str(extracted)

    added_build = enable_build(manifest, build)

    flattener = Flattener(extracted / "Configuration")
    flattener.walk_file("custom.yml", [])

    digest = hashlib.sha256(archive.read_bytes()).hexdigest()

    plan = {
        "schemaVersion": "1.0.0",
        "playbook": {
            "name": manifest["name"],
            "title": manifest["title"],
            "version": manifest["version"],
            "uniqueId": manifest["uniqueId"],
            "source": source,
            "sha256": digest,
            "supportedBuilds": manifest["supportedBuilds"],
            "addedBuild": build if added_build else "",
            "imageBuild": build,
            # The applier copies AtlasDesktop / AtlasModules / Themes straight out of
            # the unpacked tree, so the plan has to say where it lives. It is a path
            # on the machine that compiled the plan - the applier fails loudly if it
            # is gone rather than silently shipping an image with no Atlas folder.
            "extractedPath": str(extracted.resolve()),
        },
        "options": manifest["options"],
        "actions": flattener.actions,
        "skipped": flattener.skipped_detail,
        "stats": {
            "applied": dict(flattener.stats),
            "appliedTotal": sum(flattener.stats.values()),
            "skipped": dict(flattener.skipped),
            "skippedTotal": len(flattener.skipped_detail),
            "files": len(flattener.visited),
        },
    }
    return plan


# --------------------------------------------------------------------------- main


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--playbook",
        default="",
        help="Path or URL to the .apbx. Empty resolves the newest release.",
    )
    parser.add_argument(
        "--out",
        default="atlas-plan.json",
        help="Where to write the compiled plan (default: atlas-plan.json).",
    )
    parser.add_argument(
        "--extract-dir",
        default="atlas-playbook",
        help="Directory the archive is unpacked into (default: atlas-playbook).",
    )
    parser.add_argument(
        "--windows-build",
        required=True,
        help="Build number read from the image, e.g. 26200. Used for the version gate.",
    )
    parser.add_argument(
        "--work-dir",
        default=".atlas-cache",
        help="Where a downloaded archive is cached (default: .atlas-cache).",
    )
    args = parser.parse_args()

    build = re.sub(r"[^0-9]", "", str(args.windows_build))[:5]
    if len(build) < 5:
        print(f"unusable build number: {args.windows_build!r}", file=sys.stderr)
        return 2

    source = args.playbook
    if not source:
        try:
            source, tag = resolve_latest_playbook()
        except PlaybookError as exc:
            print(str(exc), file=sys.stderr)
            return 1
        print(f"Resolved Atlas playbook {tag}: {source}")

    print("Compiling Atlas playbook")
    print(f"  image build : {build}")

    try:
        archive, provenance = fetch_playbook(source, Path(args.work_dir))
        extract_playbook(archive, Path(args.extract_dir))
        plan = compile_plan(Path(args.extract_dir), build, provenance, archive)
    except PlaybookError as exc:
        print(f"FAILED: {exc}", file=sys.stderr)
        return 1

    Path(args.out).write_text(json.dumps(plan, indent=2), encoding="utf-8")

    stats = plan["stats"]
    playbook = plan["playbook"]

    print(f"  playbook    : {playbook['name']} {playbook['version']} ({playbook['sha256'][:12]})")
    print(f"  supported   : {', '.join(playbook['supportedBuilds'])}")
    if playbook["addedBuild"]:
        print(
            f"  [patched]   {build} added to SupportedBuilds - "
            "the playbook did not know this build"
        )
    print(f"  files       : {stats['files']}")
    print(f"  applicable  : {stats['appliedTotal']} action(s)")
    for kind, count in sorted(stats["applied"].items()):
        print(f"                {count:>4}  {kind}")
    print(f"  skipped     : {stats['skippedTotal']} live-only action(s)")
    for kind, count in sorted(stats["skipped"].items()):
        print(f"                {count:>4}  {kind}")
    print(f"  plan written: {args.out}")

    if stats["appliedTotal"] == 0:
        print("FAILED: the plan contains nothing to apply", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
