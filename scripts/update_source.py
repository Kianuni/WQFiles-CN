#!/usr/bin/env python3
"""Add a release to source.json (the AltStore / SideStore source).

Usage: scripts/update_source.py <version> <build> <path/to/WQFiles.ipa> ["what's new"]

The new version goes first (AltStore treats the first entry as the latest).
An existing entry for the same version is replaced, so re-uploading an IPA to
a release just refreshes its size and date.
"""
import datetime
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "source.json")


def main() -> None:
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    version, build, ipa = sys.argv[1], sys.argv[2], sys.argv[3]
    notes = sys.argv[4] if len(sys.argv) > 4 else ""
    with open(SOURCE, encoding="utf-8") as f:
        source = json.load(f)
    app = source["apps"][0]
    entry = {
        "version": version,
        "buildVersion": build,
        "date": datetime.date.today().isoformat(),
        "size": os.path.getsize(ipa),
        "downloadURL": f"https://github.com/kolbicz/WQFiles/releases/download/v{version}/WQFiles.ipa",
        "localizedDescription": notes,
        "minOSVersion": app["versions"][0]["minOSVersion"] if app["versions"] else "27.0",
    }
    app["versions"] = [entry] + [v for v in app["versions"] if v["version"] != version]
    with open(SOURCE, "w", encoding="utf-8") as f:
        json.dump(source, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"source.json: {version} ({build}), {entry['size']} bytes")


if __name__ == "__main__":
    main()
