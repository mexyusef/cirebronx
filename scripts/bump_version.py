from __future__ import annotations

import argparse
import re
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]


def replace_once(path: Path, pattern: str, replacement: str) -> None:
    text = path.read_text(encoding="utf-8")
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit(f"Failed to update version in {path}")
    path.write_text(updated, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Bump cirebronx version strings.")
    parser.add_argument("version", help="New semantic version, for example 0.2.0")
    args = parser.parse_args()

    zon = REPO / "build.zig.zon"
    replace_once(zon, r'(\.version\s*=\s*")([^"]+)(")', rf'\g<1>{args.version}\g<3>')

    print(f"Updated cirebronx version to {args.version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
