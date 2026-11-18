#!/usr/bin/env python3
"""Compare SwiftLint Xcode-reporter logs using per-file, per-rule counts."""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from pathlib import Path


VIOLATION_PATTERN = re.compile(
    r"^(?P<path>.+?):\d+:\d+:\s+(?:error|warning):\s+.*\((?P<rule>[A-Za-z0-9_]+)\)\s*$"
)
SUMMARY_PATTERN = re.compile(r"Done linting! Found (?P<count>\d+) violations?,")


def normalize_path(raw_path: str) -> str:
    """Use the repository-relative Sources/Tests path regardless of checkout location."""

    path = raw_path.replace("\\", "/")
    for root in ("Sources", "Tests"):
        marker = f"/{root}/"
        marker_index = path.rfind(marker)
        if marker_index >= 0:
            return path[marker_index + 1 :]
        if path.startswith(f"{root}/"):
            return path
    return str(Path(path))


def read_violations(path: Path) -> Counter[tuple[str, str]]:
    counts: Counter[tuple[str, str]] = Counter()
    reported_total: int | None = None
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = VIOLATION_PATTERN.match(line)
        if match:
            counts[(normalize_path(match.group("path")), match.group("rule"))] += 1
            continue
        summary = SUMMARY_PATTERN.search(line)
        if summary:
            reported_total = int(summary.group("count"))

    if reported_total is not None and reported_total != sum(counts.values()):
        raise ValueError(
            f"{path}: summary reports {reported_total} violations, "
            f"but {sum(counts.values())} violation lines were parsed"
        )
    return counts


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare SwiftLint logs by (relative file, rule) counts."
    )
    parser.add_argument("baseline", type=Path, help="SwiftLint log from the parent/baseline revision")
    parser.add_argument("current", type=Path, help="SwiftLint log from the revision under review")
    return parser.parse_args()


def print_comparison(baseline: Counter[tuple[str, str]], current: Counter[tuple[str, str]]) -> int:
    keys = sorted(set(baseline) | set(current))
    increased = [
        (key, baseline.get(key, 0), current.get(key, 0))
        for key in keys
        if current.get(key, 0) > baseline.get(key, 0)
    ]
    decreased = [
        (key, baseline.get(key, 0), current.get(key, 0))
        for key in keys
        if baseline.get(key, 0) > current.get(key, 0)
    ]
    new_count = sum(current_count - baseline_count for _, baseline_count, current_count in increased)
    resolved_count = sum(baseline_count - current_count for _, baseline_count, current_count in decreased)

    print("SwiftLint baseline comparison:")
    print(f"- baseline violations: {sum(baseline.values())}")
    print(f"- current violations: {sum(current.values())}")
    print(f"- new violations: {new_count}")
    print(f"- resolved violations: {resolved_count}")
    print(f"- changed file|rule keys: {len(increased) + len(decreased)}")

    if increased:
        print("Increased file|rule counts:")
        for (relative_path, rule), baseline_count, current_count in increased:
            delta = current_count - baseline_count
            print(
                f"- {relative_path}|{rule}: baseline={baseline_count} "
                f"current={current_count} delta=+{delta}"
            )
    if decreased:
        print("Decreased file|rule counts:")
        for (relative_path, rule), baseline_count, current_count in decreased:
            delta = current_count - baseline_count
            print(
                f"- {relative_path}|{rule}: baseline={baseline_count} "
                f"current={current_count} delta={delta}"
            )

    return 1 if increased else 0


def main() -> int:
    args = parse_args()
    try:
        baseline = read_violations(args.baseline)
        current = read_violations(args.current)
        return print_comparison(baseline, current)
    except (OSError, ValueError) as error:
        print(f"SwiftLint baseline comparison failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
