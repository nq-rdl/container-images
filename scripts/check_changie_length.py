#!/usr/bin/env python3
"""Lint changie fragment bodies against a hard length limit.

Changie has no built-in ``lint``/``validate`` subcommand. It *does* validate
``body`` length at ``changie new`` time when ``.changie.yaml`` sets
``body.maxLength`` — but that only guards the interactive/``--body`` creation
path. A fragment written directly (an agent editing the YAML, a hand-authored
file, a copy-paste) sails past it. This checker closes that gap: it re-reads the
fragment files on disk and fails if any ``body`` exceeds the cap.

The cap is a *per-fragment* limit, not a per-change one. A changelog change that
does not fit is split into multiple fragments (``changie new`` again) — there is
no limit on how many fragments a branch may add, only on the length of each one.

CLI:
    python3 scripts/check_changie_length.py [FILE ...]
    python3 scripts/check_changie_length.py --max 200 [FILE ...]

With no FILE args, every ``.changes/unreleased/*.yaml`` is scanned. The limit
defaults to 200 and is overridable with ``--max`` or the
``CHANGIE_MAX_BODY_LENGTH`` environment variable (``--max`` wins). Exits
non-zero (with ``::error::`` annotations) when any body is over the cap.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import yaml

DEFAULT_MAX = 200
UNRELEASED_GLOB = ".changes/unreleased/*.yaml"

REMINDER = (
    "reminder: the cap is per *fragment*, not per change. A changelog entry too "
    "long for one fragment is split into several — there is NO limit on how many "
    "fragments a branch adds, only on each one's length. Run `changie new` once "
    "per idea:\n"
    "    changie new   # kind: Added, body: thing 1\n"
    "    changie new   # kind: Added, body: thing 2\n"
    "instead of packing every idea into a single over-long body."
)


def _resolve_max(cli_max: int | None) -> int:
    if cli_max is not None:
        return cli_max
    raw = os.environ.get("CHANGIE_MAX_BODY_LENGTH", "").strip()
    if raw:
        try:
            return int(raw)
        except ValueError:
            print(
                f"::warning::ignoring non-integer CHANGIE_MAX_BODY_LENGTH={raw!r}; "
                f"using default {DEFAULT_MAX}",
                file=sys.stderr,
            )
    return DEFAULT_MAX


def _fragment_files(paths: list[str]) -> list[Path]:
    if paths:
        return [Path(p) for p in paths]
    return sorted(Path(".").glob(UNRELEASED_GLOB))


def _is_unreleased_fragment(path: Path) -> bool:
    """Only current-unreleased fragment YAMLs are in scope.

    Released versions live in ``.changes/<version>.md`` (and the GitHub release
    body) — immutable, out of scope. Anything not under ``.changes/unreleased/``
    with a ``.yaml`` suffix is skipped, so passing a released ``.md`` (or any
    other file) is a silent no-op rather than a spurious parse error.
    """
    parent = path.parent
    return (
        path.suffix == ".yaml"
        and parent.name == "unreleased"
        and parent.parent.name == ".changes"
    )


def find_length_issues(paths: list[str], max_len: int) -> list[str]:
    """Return one message per fragment whose body exceeds ``max_len``."""
    issues: list[str] = []
    for path in _fragment_files(paths):
        if not _is_unreleased_fragment(path):
            continue  # released versions / non-fragments are out of scope
        if not path.is_file():
            continue
        try:
            data = yaml.safe_load(path.read_text(encoding="utf-8"))
        except yaml.YAMLError as exc:
            issues.append(f"{path}: could not parse YAML ({exc})")
            continue
        if not isinstance(data, dict):
            continue  # .gitkeep / empty / non-fragment
        body = data.get("body")
        if not isinstance(body, str):
            continue  # body presence is enforced by the fragment gate, not here
        length = len(body)
        if length > max_len:
            preview = body[:60].replace("\n", " ")
            issues.append(
                f"{path}: body is {length} chars (limit {max_len}, "
                f"over by {length - max_len}): \"{preview}…\""
            )
    return issues


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)

    cli_max: int | None = None
    paths: list[str] = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--max":
            i += 1
            if i >= len(argv):
                print("::error::--max requires a value", file=sys.stderr)
                return 2
            try:
                cli_max = int(argv[i])
            except ValueError:
                print(f"::error::--max value {argv[i]!r} is not an integer", file=sys.stderr)
                return 2
        elif arg.startswith("--max="):
            try:
                cli_max = int(arg.split("=", 1)[1])
            except ValueError:
                print(f"::error::--max value {arg!r} is not an integer", file=sys.stderr)
                return 2
        else:
            paths.append(arg)
        i += 1

    max_len = _resolve_max(cli_max)
    issues = find_length_issues(paths, max_len)
    for msg in issues:
        print(f"::error::{msg}", file=sys.stderr)
    if issues:
        n = len(issues)
        print(
            f"{n} changie fragment{'s' if n != 1 else ''} over the {max_len}-char limit",
            file=sys.stderr,
        )
        print(f"\n{REMINDER}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
