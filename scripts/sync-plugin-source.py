#!/usr/bin/env python3
"""Check or export the product-owned plugin source to its distribution checkout."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


MIRRORS = ("plugins/codex-micro-keypad", ".agents/plugins/marketplace.json", "LICENSE")
REPOSITORY = "gantrol/codex-plugin-micro-keypad"


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.PIPE)


def tracked(root):
    return {os.fsdecode(name) for name in git(root, "ls-files", "-z", "--", *MIRRORS).split(b"\0") if name}


def safe_file(root, relative):
    path = root / relative
    if not path.resolve().is_relative_to(root):
        raise ValueError(f"Path escapes repository: {relative}")
    for part in (path, *path.parents):
        if part == root:
            break
        if part.is_symlink():
            raise ValueError(f"Symlinks are not exported: {relative}")
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="Compare only (default)")
    mode.add_argument("--apply", action="store_true", help="Copy source into a clean distribution checkout")
    parser.add_argument("--destination", type=Path, help="Default: sibling codex-plugin-micro-keypad")
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1]
    destination = (args.destination or source.parent / "codex-plugin-micro-keypad").resolve()
    if destination == source or destination.is_relative_to(source) or source.is_relative_to(destination):
        raise ValueError("Source and destination must be separate, non-nested checkouts")
    if Path(os.fsdecode(git(destination, "rev-parse", "--show-toplevel")).strip()).resolve() != destination:
        raise ValueError("Destination must be a Git repository root")
    remote = os.fsdecode(git(destination, "remote", "get-url", "origin")).strip().removesuffix(".git").rstrip("/")
    if remote not in (f"https://github.com/{REPOSITORY}", f"git@github.com:{REPOSITORY}", f"ssh://git@github.com/{REPOSITORY}"):
        raise ValueError("Destination origin must be gantrol/codex-plugin-micro-keypad")

    names = tracked(source)
    if "plugins/codex-micro-keypad/plugin.json" not in names:
        raise ValueError("Product plugin manifest is missing from Git")
    source_untracked = git(source, "ls-files", "--others", "--exclude-standard", "-z", "--", *MIRRORS)
    if source_untracked:
        raise ValueError("Untracked plugin source files exist; review and git add them before synchronizing")
    extra = tracked(destination) - names
    changed = []
    for name in sorted(names):
        src, dst = safe_file(source, name), safe_file(destination, name)
        if not src.is_file():
            raise ValueError(f"Tracked source is missing: {name}")
        if not dst.is_file() or src.read_bytes() != dst.read_bytes():
            changed.append(name)
    for name in sorted(extra):
        print(f"EXTRA   {name}")
    for name in changed:
        print(f"UPDATE  {name}")
    if extra:
        raise ValueError("Distribution contains extra tracked files; reconcile them explicitly (no automatic deletion)")
    if not changed:
        print(f"In sync: {len(names)} files; {destination}")
        return 0
    if not args.apply:
        print(f"{len(changed)} files differ; run with --apply after reviewing")
        return 1

    # Refuse all dirty mirrored paths, not just files about to be overwritten.
    if git(destination, "status", "--porcelain", "--untracked-files=all", "--", *MIRRORS).strip():
        raise ValueError("Distribution plugin files have local changes; preserve or commit them before applying")
    for name in changed:
        src, dst = safe_file(source, name), safe_file(destination, name)
        dst.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(prefix=".plugin-sync-", dir=dst.parent)
        os.close(descriptor)
        try:
            shutil.copyfile(src, temporary)
            shutil.copymode(src, temporary)
            os.replace(temporary, dst)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    print(f"Exported {len(changed)} files; review git diff in {destination}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Plugin sync failed: {error}", file=sys.stderr)
        sys.exit(2)
