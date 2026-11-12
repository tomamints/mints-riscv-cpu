#!/usr/bin/env python3
"""Reject entries in Quartus Standard's Ignored Assignments report panels."""
import argparse
from pathlib import Path


def ignored_rows(report):
    in_panel = False
    for line in report.splitlines():
        if not line.lstrip().startswith(";"):
            continue
        cells = [cell.strip() for cell in line.strip().split(";")[1:-1]]
        if cells == ["Ignored Assignments"]:
            in_panel = True
        elif in_panel and len(cells) == 1:
            in_panel = False
        elif in_panel and len(cells) >= 6 and cells[0] not in ("", "Name"):
            yield cells


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", type=Path)
    parser.add_argument("--count", action="store_true", help="print only the row count")
    parser.add_argument("--allow-missing", action="store_true", help="for partial-build summaries")
    args = parser.parse_args()
    rows = []
    for path in args.reports:
        if args.allow_missing and not path.exists():
            continue
        try:
            report = path.read_text(encoding="latin1")
        except OSError as error:
            parser.error(str(error))
        rows.extend((path, row) for row in ignored_rows(report))
    if args.count:
        print(len(rows))
        return 0
    for path, row in rows:
        print(f"IGNORED ASSIGNMENT {path}: {' | '.join(row)}")
    print(f"QUARTUS_IGNORED_ASSIGNMENTS count={len(rows)}")
    return 1 if rows else 0


if __name__ == "__main__":
    raise SystemExit(main())
