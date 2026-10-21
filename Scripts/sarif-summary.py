#!/usr/bin/env python3
"""Prints the results of one or more SARIF files as `path:line: level [rule] message`, plus counts.

The analyzer GitHub Actions emit SARIF only, which is unreadable in a job log; CI runs this after them.
Usage: Scripts/sarif-summary.py FILE.sarif...   (always exits 0: the analyzer step is the gate)
"""

import json
import sys
from pathlib import Path


def location(result: dict) -> str:
    try:
        physical = result["locations"][0]["physicalLocation"]
        uri = physical["artifactLocation"]["uri"].removeprefix("file://")
        line = physical.get("region", {}).get("startLine", 1)
        return f"{uri}:{line}"
    except (KeyError, IndexError):
        return "<no location>"


def main(paths: list[str]) -> None:
    for name in paths:
        path = Path(name)
        if not path.is_file():
            print(f"{name}: no SARIF report (the analyzer failed before producing one)")
            continue
        report = json.loads(path.read_text(encoding="utf-8"))
        for run in report.get("runs", []):
            tool = run.get("tool", {}).get("driver", {}).get("name", path.stem)
            results = run.get("results", [])
            counts: dict[str, int] = {}
            for result in results:
                level = result.get("level", "warning")
                counts[level] = counts.get(level, 0) + 1
                message = " ".join(result.get("message", {}).get("text", "").split())
                print(f"{location(result)}: {level} [{result.get('ruleId', '?')}] {message}")
            summary = ", ".join(f"{count} {level}" for level, count in sorted(counts.items())) or "clean"
            print(f"{tool}: {len(results)} finding(s) ({summary})")


if __name__ == "__main__":
    main(sys.argv[1:])
