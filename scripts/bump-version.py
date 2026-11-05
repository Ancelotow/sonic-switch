#!/usr/bin/env python3
"""Increment Info.plist from the highest committed version or release tag."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess


def parse_version(value):
    if not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise ValueError("Version must have the form major.minor.patch")
    return tuple(map(int, value.split(".")))


def next_version(current, tags, bump):
    versions = [parse_version(current)]
    versions.extend(parse_version(tag[1:]) for tag in tags
                    if re.fullmatch(r"v\d+\.\d+\.\d+", tag))
    major, minor, patch = max(versions)
    if bump == "major":
        return f"{major + 1}.0.0"
    if bump == "minor":
        return f"{major}.{minor + 1}.0"
    if bump == "patch":
        return f"{major}.{minor}.{patch + 1}"
    raise ValueError("Unknown increment")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bump", choices=["patch", "minor", "major"], nargs="?", default="patch")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    path = root / "scripts" / "Info.plist"
    with path.open("rb") as stream:
        info = plistlib.load(stream)
    tags = subprocess.check_output(["git", "tag", "--list"], cwd=root, text=True).splitlines()
    version = next_version(info["CFBundleShortVersionString"], tags, args.bump)
    build = int(info["CFBundleVersion"]) + 1
    if build <= 0:
        raise ValueError("Build number must be positive")
    if not args.dry_run:
        info["CFBundleShortVersionString"] = version
        info["CFBundleVersion"] = str(build)
        temporary = path.with_suffix(".plist.tmp")
        try:
            temporary.write_bytes(plistlib.dumps(info, sort_keys=False))
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
                stream.write(f"version={version}\nbuild={build}\ntag=v{version}\n")
    print(f"{version} (build {build})")


if __name__ == "__main__":
    main()
