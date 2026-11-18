#!/usr/bin/env python3
"""Produce one machine-readable, fail-closed quality-gate summary.

The command intentionally keeps test execution, baseline comparison, and lint comparison in one
place.  It also accepts captured logs so the parser can be tested without touching a checkout or
starting a Swift build.
"""

from __future__ import annotations

import argparse
import collections
import importlib.util
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path
from typing import Iterable, Sequence


TEST_STAT_PATTERNS = {
    "selected_groups": re.compile(r"(?:-\s*)?Selected groups:\s*(\d+)", re.IGNORECASE),
    "first_pass_successful_groups": re.compile(
        r"(?:-\s*)?First-pass successful groups:\s*(\d+)", re.IGNORECASE
    ),
    "first_pass_failed_groups": re.compile(
        r"(?:-\s*)?First-pass failed groups:\s*(\d+)", re.IGNORECASE
    ),
    "full_group_retries": re.compile(r"(?:-\s*)?Full-group retries:\s*(\d+)", re.IGNORECASE),
    "recovered_groups": re.compile(r"(?:-\s*)?Recovered groups:\s*(\d+)", re.IGNORECASE),
    "timed_out_groups": re.compile(r"(?:-\s*)?Timed out groups:\s*(\d+)", re.IGNORECASE),
    "isolated_selection_retries": re.compile(
        r"(?:-\s*)?Isolated selection retries:\s*(\d+)", re.IGNORECASE
    ),
}

FAILURE_PATTERNS = (
    re.compile(r"✘\s+Test\s+(?P<name>.+?)(?:\s+recorded an issue|\s+failed)\s*$"),
    re.compile(r"Test Case '-\[(?P<name>[^]]+)\]' failed", re.IGNORECASE),
    re.compile(r"Test ['\"](?P<name>.+?)['\"] failed", re.IGNORECASE),
)

SWIFTFORMAT_COLON_PATTERN = re.compile(
    r"^(?P<path>.+?\.swift):(?P<line>\d+):(?P<column>\d+):\s*(?P<message>.+?)\s*$"
)
SWIFTFORMAT_WORD_PATTERN = re.compile(
    r"^(?P<path>.+?\.swift):\s*line\s+(?P<line>\d+),\s*col(?:umn)?\s+(?P<column>\d+):\s*(?P<message>.+?)\s*$",
    re.IGNORECASE,
)


def normalize_source_path(raw_path: str) -> str:
    path = raw_path.replace("\\", "/")
    for root in ("Sources", "Tests"):
        marker = f"/{root}/"
        index = path.rfind(marker)
        if index >= 0:
            return path[index + 1 :]
        if path.startswith(f"{root}/"):
            return path
    return path


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def collect_platform_info() -> dict[str, str]:
    """Return reproducibility metadata without including hostnames or user paths."""

    system = platform.system() or "unknown"
    if system == "Darwin":
        os_name = "macOS"
        os_version = platform.mac_ver()[0] or platform.release() or "unknown"
    else:
        os_name = system
        os_version = platform.release() or "unknown"

    swift_version = "unavailable"
    swift_binary = shutil.which("swift")
    if swift_binary:
        try:
            result = subprocess.run(
                [swift_binary, "--version"],
                capture_output=True,
                check=False,
                text=True,
                timeout=5,
            )
            for line in (result.stdout + result.stderr).splitlines():
                if line.strip():
                    swift_version = " ".join(line.split())
                    break
        except (OSError, subprocess.SubprocessError):
            pass

    return {
        "os": os_name,
        "os_version": os_version,
        "architecture": platform.machine() or "unknown",
        "swift_version": swift_version,
    }


def read_baseline_names(path: Path) -> collections.Counter[str]:
    if not path.exists():
        return collections.Counter()
    names: collections.Counter[str] = collections.Counter()
    for line in read_text(path).splitlines():
        value = line.strip()
        if value and not value.startswith("#"):
            names[value] += 1
    return names


def parse_test_log(text: str, command_result: int | None) -> dict[str, object]:
    stats: dict[str, int] = {key: 0 for key in TEST_STAT_PATTERNS}
    for key, pattern in TEST_STAT_PATTERNS.items():
        matches = pattern.findall(text)
        if matches:
            stats[key] = int(matches[-1])

    failures: collections.Counter[str] = collections.Counter()
    for line in text.splitlines():
        for pattern in FAILURE_PATTERNS:
            match = pattern.search(line.strip())
            if match:
                name = " ".join(match.group("name").split())
                if name:
                    failures[name] += 1
                break

    if command_result not in (None, 0) and not failures:
        # A non-zero runner without a named test is still a failure.  The synthetic name prevents
        # a parser miss from silently turning a broken runner into a baseline pass.
        marker = "<test-runner-timeout>" if command_result == 124 else f"<test-runner-exit-{command_result}>"
        failures[marker] = 1

    selected = stats["selected_groups"]
    completed = min(selected, stats["first_pass_successful_groups"] + stats["first_pass_failed_groups"])
    if selected and command_result == 0:
        completed = selected
    stats["completed_groups"] = completed
    stats["total_groups"] = selected
    stats["test_failures"] = sum(failures.values())
    return {**stats, "failures": failures}


def compare_counters(
    baseline: collections.Counter[str], current: collections.Counter[str]
) -> tuple[int, int, list[str], list[str]]:
    new = baseline.copy()
    new.subtract(current)
    increased = current.copy()
    increased.subtract(baseline)
    new_count = sum(max(0, value) for value in increased.values())
    resolved_count = sum(max(0, value) for value in new.values())
    new_names = sorted(name for name, value in increased.items() if value > 0)
    resolved_names = sorted(name for name, value in new.items() if value > 0)
    return new_count, resolved_count, new_names, resolved_names


def swiftlint_status_messages(results: Sequence[int]) -> list[str]:
    """Describe every distinct SwiftLint process status using the gate's stable vocabulary."""

    messages: list[str] = []
    for result in sorted(set(results)):
        if result == 0:
            messages.append("clean (exit 0)")
        elif result == 1:
            # Keep this distinct from an invocation/runtime failure. Some SwiftLint wrappers and
            # older integrations use 1 for error-level findings, even though the pinned 0.65.0
            # binary exits 2 for serious violations.
            messages.append("error-level violations (exit 1)")
        elif result == 2:
            messages.append("violations reported (exit 2; baseline comparison applied)")
        else:
            messages.append(f"tool error or abnormal termination (exit {result})")
    return messages


def parse_swiftformat_log(text: str) -> collections.Counter[tuple[str, str, str, str]]:
    violations: collections.Counter[tuple[str, str, str, str]] = collections.Counter()
    for line in text.splitlines():
        match = SWIFTFORMAT_COLON_PATTERN.match(line.strip()) or SWIFTFORMAT_WORD_PATTERN.match(line.strip())
        if not match:
            continue
        key = (
            normalize_source_path(match.group("path")),
            match.group("line"),
            match.group("column"),
            " ".join(match.group("message").split()),
        )
        violations[key] += 1
    return violations


def load_swiftlint_reader(root: Path):
    module_path = root / "Scripts" / "compare_swiftlint_baseline.py"
    spec = importlib.util.spec_from_file_location("codexbar_swiftlint_baseline", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.read_violations


def parse_swiftlint_log(root: Path, path: Path):
    return load_swiftlint_reader(root)(path)


def run_and_capture(command: Sequence[str], cwd: Path, output_path: Path) -> int:
    print("$ " + " ".join(command), flush=True)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    process = subprocess.Popen(
        list(command),
        cwd=str(cwd),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    with output_path.open("w", encoding="utf-8") as output:
        assert process.stdout is not None
        for line in process.stdout:
            print(line, end="", flush=True)
            output.write(line)
    return process.wait()


def extract_archive(root: Path, revision: str, destination: Path) -> None:
    archive = subprocess.run(
        ["git", "-C", str(root), "archive", "--format=tar", revision],
        check=True,
        stdout=subprocess.PIPE,
    )
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=__import__("io").BytesIO(archive.stdout), mode="r:") as tar:
        # `git archive` produces paths rooted at the repository and is trusted input.  Keep an
        # explicit traversal guard nevertheless because this script is also used in CI wrappers.
        for member in tar.getmembers():
            target = (destination / member.name).resolve()
            if destination.resolve() not in target.parents and target != destination.resolve():
                raise RuntimeError(f"unsafe archive member: {member.name}")
        tar.extractall(destination)


def resolve_binary(name: str, environment_key: str, root: Path) -> str | None:
    configured = os.environ.get(environment_key)
    if configured:
        return configured
    bundled = root / ".build" / "lint-tools" / "bin" / name
    if bundled.is_file() and os.access(bundled, os.X_OK):
        return str(bundled)
    return shutil.which(name)


def lint_logs_from_checkout(
    root: Path,
    parent_ref: str,
    temp_root: Path,
    format_path: Path,
    lint_path: Path,
) -> tuple[Path, Path, Path, Path, list[int]]:
    parent_root = temp_root / "parent"
    extract_archive(root, parent_ref, parent_root)
    format_parent = temp_root / "swiftformat.parent.log"
    format_current = temp_root / "swiftformat.current.log"
    lint_parent = temp_root / "swiftlint.parent.log"
    lint_current = temp_root / "swiftlint.current.log"
    format_current_result = run_and_capture(
        [str(format_path), "Sources", "Tests", "--lint"], root, format_current
    )
    format_parent_result = run_and_capture(
        [str(format_path), "Sources", "Tests", "--lint"], parent_root, format_parent
    )
    lint_current_result = run_and_capture([str(lint_path), "--strict"], root, lint_current)
    lint_parent_result = run_and_capture([str(lint_path), "--strict"], parent_root, lint_parent)
    return format_parent, format_current, lint_parent, lint_current, [
        format_parent_result,
        format_current_result,
        lint_parent_result,
        lint_current_result,
    ]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run and summarize the CodexBar quality gate.")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--parent-ref", default="HEAD^", help="revision used for lint baselines")
    parser.add_argument("--test-command", nargs="+", help="test command; defaults to Scripts/test.sh")
    parser.add_argument("--test-arg", action="append", default=[])
    parser.add_argument("--test-log", type=Path)
    parser.add_argument("--test-baseline", type=Path)
    parser.add_argument("--format-baseline-log", type=Path)
    parser.add_argument("--format-current-log", type=Path)
    parser.add_argument("--lint-baseline-log", type=Path)
    parser.add_argument("--lint-current-log", type=Path)
    parser.add_argument("--summary-json", type=Path)
    parser.add_argument("--no-run", action="store_true", help="parse supplied logs only")
    parser.add_argument("--skip-tests", action="store_true")
    parser.add_argument("--skip-lint", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.root.resolve()
    platform_info = collect_platform_info()
    baseline_path = (args.test_baseline or root / "docs" / "baseline" / "test-baseline.txt").resolve()
    temporary = tempfile.TemporaryDirectory(prefix="codexbar-quality-gate-")
    temp_root = Path(temporary.name)
    command_results: list[int] = []
    format_command_results: list[int] = []
    swiftlint_command_results: list[int] = []
    try:
        if args.skip_tests:
            test_info: dict[str, object] = {
                "selected_groups": 0,
                "completed_groups": 0,
                "total_groups": 0,
                "first_pass_failed_groups": 0,
                "full_group_retries": 0,
                "isolated_selection_retries": 0,
                "timed_out_groups": 0,
                "recovered_groups": 0,
                "test_failures": 0,
                "failures": collections.Counter(),
                "skipped": True,
            }
        else:
            test_log = (args.test_log or temp_root / "make-test.log").resolve()
            if args.no_run:
                if not test_log.exists():
                    raise RuntimeError(f"--no-run requires an existing --test-log: {test_log}")
                test_result = None
            else:
                command = list(args.test_command or [str(root / "Scripts" / "test.sh")])
                command.extend(args.test_arg)
                test_result = run_and_capture(command, root, test_log)
                command_results.append(test_result)
            test_info = parse_test_log(read_text(test_log), test_result)

        baseline_failures = read_baseline_names(baseline_path)
        current_failures = test_info["failures"]
        test_new, test_resolved, test_new_names, test_resolved_names = compare_counters(
            baseline_failures, current_failures
        )

        lint_info: dict[str, object]
        if args.skip_lint:
            lint_info = {"skipped": True, "format_new": 0, "lint_new": 0}
        else:
            if args.no_run:
                required = [
                    args.format_baseline_log,
                    args.format_current_log,
                    args.lint_baseline_log,
                    args.lint_current_log,
                ]
                if any(path is None or not path.exists() for path in required):
                    raise RuntimeError("--no-run requires all four lint log arguments")
                format_parent, format_current = args.format_baseline_log, args.format_current_log
                lint_parent, lint_current = args.lint_baseline_log, args.lint_current_log
            else:
                format_binary = resolve_binary("swiftformat", "CODEXBAR_SWIFTFORMAT_BIN", root)
                lint_binary = resolve_binary("swiftlint", "CODEXBAR_SWIFTLINT_BIN", root)
                if not format_binary or not lint_binary:
                    raise RuntimeError(
                        "SwiftFormat and SwiftLint binaries are required; run Scripts/install_lint_tools.sh first"
                    )
                format_parent, format_current, lint_parent, lint_current, lint_results = lint_logs_from_checkout(
                    root, args.parent_ref, temp_root, Path(format_binary), Path(lint_binary)
                )
                command_results.extend(lint_results)
                format_command_results.extend(lint_results[:2])
                swiftlint_command_results.extend(lint_results[2:])

            format_baseline = parse_swiftformat_log(read_text(format_parent))
            format_now = parse_swiftformat_log(read_text(format_current))
            format_new, format_resolved, format_new_keys, format_resolved_keys = compare_counters(
                format_baseline, format_now
            )
            lint_baseline = parse_swiftlint_log(root, lint_parent)
            lint_now = parse_swiftlint_log(root, lint_current)
            lint_new, lint_resolved, lint_new_keys, lint_resolved_keys = compare_counters(
                lint_baseline, lint_now
            )
            lint_info = {
                "skipped": False,
                "format_baseline": sum(format_baseline.values()),
                "format_current": sum(format_now.values()),
                "format_new": format_new,
                "format_resolved": format_resolved,
                "format_new_keys": format_new_keys,
                "format_resolved_keys": format_resolved_keys,
                "lint_baseline": sum(lint_baseline.values()),
                "lint_current": sum(lint_now.values()),
                "lint_new": lint_new,
                "lint_resolved": lint_resolved,
                "lint_new_keys": lint_new_keys,
                "lint_resolved_keys": lint_resolved_keys,
            }

        test_ok = test_new == 0 and (not command_results or command_results[0] == 0 or not current_failures)
        if current_failures and command_results and command_results[0] != 0:
            # An expected baseline failure is acceptable; a newly named failure is not.
            test_ok = test_new == 0 and all(
                current_failures[name] <= baseline_failures.get(name, 0) for name in current_failures
            )
        lint_ok = bool(lint_info.get("skipped")) or (
            lint_info.get("format_new", 0) == 0 and lint_info.get("lint_new", 0) == 0
        )
        # SwiftFormat uses 1 for findings. SwiftLint 0 means clean, 1 is a known error-level
        # findings status used by some wrappers/integrations, and the pinned 0.65.0 binary uses 2
        # when --strict reports serious violations. Exit 2 may represent baseline debt, so the
        # parsed Counter delta remains authoritative. Exit 1 always fails closed; all other
        # non-zero statuses are invocation/runtime failures rather than lint results.
        lint_status_ok = all(result in (0, 1) for result in format_command_results) and all(
            result in (0, 2) for result in swiftlint_command_results
        )
        overall_ok = test_ok and lint_ok and lint_status_ok

        print("Quality gate summary:")
        print(
            f"- platform: {platform_info['os']} {platform_info['os_version']} "
            f"({platform_info['architecture']})"
        )
        print(f"- Swift version: {platform_info['swift_version']}")
        print(
            f"- make test groups: completed groups: {test_info['completed_groups']}/"
            f"{test_info['total_groups']}"
        )
        print(f"- failed groups: {test_info['first_pass_failed_groups']}")
        print(f"- retries: full={test_info['full_group_retries']} isolated={test_info['isolated_selection_retries']}")
        print(f"- timed out groups: {test_info['timed_out_groups']}")
        print(f"- recovered groups: {test_info['recovered_groups']}")
        print(f"- test failures: {test_info['test_failures']}")
        print(f"- test baseline new: {test_new}")
        print(f"- test baseline resolved: {test_resolved}")
        if test_new_names:
            print("- new test failures: " + ", ".join(test_new_names))
        if test_resolved_names:
            print("- resolved test failures: " + ", ".join(test_resolved_names))
        if lint_info.get("skipped"):
            print("- SwiftFormat/SwiftLint: skipped")
        else:
            print(f"- SwiftFormat baseline/current: {lint_info['format_baseline']}/{lint_info['format_current']}")
            print(f"- SwiftFormat strict new: {lint_info['format_new']}")
            print(f"- SwiftFormat strict resolved: {lint_info['format_resolved']}")
            print(f"- SwiftLint baseline/current: {lint_info['lint_baseline']}/{lint_info['lint_current']}")
            print(f"- SwiftLint strict new: {lint_info['lint_new']}")
            print(f"- SwiftLint strict resolved: {lint_info['lint_resolved']}")
            for status_message in swiftlint_status_messages(swiftlint_command_results):
                print(f"- SwiftLint status: {status_message}")
        print("RESULT: PASS" if overall_ok else "RESULT: FAIL")

        if args.summary_json:
            args.summary_json.parent.mkdir(parents=True, exist_ok=True)
            serializable_test = dict(test_info)
            serializable_test["failures"] = dict(current_failures)
            payload = {
                "platform": platform_info,
                "test": serializable_test,
                "test_baseline": {
                    "new": test_new,
                    "resolved": test_resolved,
                    "new_names": test_new_names,
                    "resolved_names": test_resolved_names,
                },
                "lint": lint_info,
                "pass": overall_ok,
            }
            args.summary_json.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
        return 0 if overall_ok else 1
    except (OSError, RuntimeError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Quality gate failed to run: {error}", file=sys.stderr)
        print("RESULT: FAIL")
        return 2
    finally:
        temporary.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
