#!/usr/bin/env python3
"""Read a PIT mutation report: real XML parsing, freshness, and scope.

Replaces a grep over the XML, which misread double-quoted and single-line reports
and happily read a stale report from an earlier run.

Usage:
  pit_score.py --reports-dir target/pit-reports [--min-mtime EPOCH]
                [--expect-scope-file .testing/pit-scope.txt] [--write-scope-file PATH]
                [--json]

Exit codes: 0 ok, 3 no report, 4 report older than --min-mtime, 5 scope mismatch.
"""
import argparse
import json
import os
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

KILLED = {"KILLED", "TIMED_OUT"}  # PIT counts a timeout as detected


def newest_report(reports_dir: Path):
    found = sorted(reports_dir.glob("**/mutations.xml"), key=lambda p: p.stat().st_mtime, reverse=True)
    return found[0] if found else None


def read(path: Path):
    root = ET.parse(path).getroot()
    total = killed = 0
    scope = set()
    for m in root.iter("mutation"):
        status = (m.get("status") or "").strip().upper()
        if not status:
            continue
        total += 1
        if status in KILLED:
            killed += 1
        cls = m.findtext("mutatedClass")
        if cls:
            scope.add(cls.strip())
    return total, killed, scope


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--reports-dir", default="target/pit-reports")
    ap.add_argument("--min-mtime", type=float, default=None,
                    help="reject a report older than this epoch time (freshness)")
    ap.add_argument("--expect-scope-file", default=None,
                    help="file of mutated class names the baseline covered; mismatch is an error")
    ap.add_argument("--write-scope-file", default=None)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    reports = Path(a.reports_dir)
    report = newest_report(reports) if reports.is_dir() else None
    if report is None:
        print(f"NO_REPORT: no mutations.xml under {reports}", file=sys.stderr)
        return 3

    if a.min_mtime is not None and report.stat().st_mtime < a.min_mtime:
        age = a.min_mtime - report.stat().st_mtime
        print(f"STALE_REPORT: {report} predates this run by {age:.0f}s. "
              "PIT did not produce a fresh report; refusing to score it.", file=sys.stderr)
        return 4

    total, killed, scope = read(report)
    score = round(100.0 * killed / total, 1) if total else 0.0

    if a.expect_scope_file and os.path.exists(a.expect_scope_file):
        expected = {l.strip() for l in open(a.expect_scope_file, encoding="utf-8") if l.strip()}
        if expected and expected != scope:
            only_expected = sorted(expected - scope)
            only_now = sorted(scope - expected)
            print("SCOPE_MISMATCH: this report does not cover the same classes as the baseline. "
                  f"missing={only_expected} extra={only_now}. Scores are not comparable.", file=sys.stderr)
            return 5

    if a.write_scope_file:
        Path(a.write_scope_file).parent.mkdir(parents=True, exist_ok=True)
        Path(a.write_scope_file).write_text("\n".join(sorted(scope)) + "\n", encoding="utf-8")

    if a.json:
        print(json.dumps({"score": score, "killed": killed, "total": total,
                          "report": str(report), "scope": sorted(scope)}))
    else:
        print(score)
    return 0


if __name__ == "__main__":
    sys.exit(main())
