#!/usr/bin/env python3
"""Ratchet on test strength: test methods and assertions must not decrease.

A blocklist of forbidden strings (@Disabled, Thread.sleep) cannot catch an
open-ended problem: a test can also be deleted outright, or gutted until it
asserts nothing. This counts tests and assertions at two git refs and fails on
a decrease, unless a commit in the range carries a Ratchet-Decrease: trailer
explaining it (visible in history and reviewable).

Usage:
  test_census.py --count [PATH]              count the working tree
  test_census.py --compare BASE_REF HEAD_REF [--path src/test] [--json]

Exit codes: 0 no decrease, 1 decrease without an accepted justification.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Optional

# JUnit 4 and 5 test markers.
# Match the annotation anywhere, not only at line start: @Test on the same line as
# the method signature is legal Java and was previously counted as zero tests.
TEST_ANNOTATION = re.compile(r"@(Test|ParameterizedTest|RepeatedTest|TestFactory|TestTemplate)\b")
# Common assertion and verification calls across JUnit, AssertJ, Hamcrest, Mockito, REST Assured.
ASSERTION_CALL = re.compile(
    r"\b(assert[A-Z]\w*|assertThat|assertj|verify|verifyNoMoreInteractions|"
    r"expect|shouldBe|should\(\)|andExpect|hasSize|isEqualTo|containsExactly)\s*\(")
LINE_COMMENT = re.compile(r"//.*$")
BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)


def strip_comments(src: str) -> str:
    src = BLOCK_COMMENT.sub("", src)
    return "\n".join(LINE_COMMENT.sub("", l) for l in src.splitlines())


def census_text(src: str):
    src = strip_comments(src)
    tests = len(TEST_ANNOTATION.findall(src))
    assertions = len(ASSERTION_CALL.findall(src))
    return tests, assertions


def census_tree(path: str):
    tests = assertions = files = 0
    root = Path(path)
    if root.is_dir():
        for f in sorted(root.glob("**/*.java")):
            t, a = census_text(f.read_text(encoding="utf-8", errors="replace"))
            tests += t
            assertions += a
            files += 1
    return {"tests": tests, "assertions": assertions, "files": files}


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=False)


def census_ref(ref: str, path: str):
    listing = git("ls-tree", "-r", "--name-only", ref, "--", path)
    tests = assertions = files = 0
    for name in [l for l in listing.stdout.splitlines() if l.endswith(".java")]:
        blob = git("show", f"{ref}:{name}")
        if blob.returncode != 0:
            continue
        t, a = census_text(blob.stdout)
        tests += t
        assertions += a
        files += 1
    return {"tests": tests, "assertions": assertions, "files": files}


def justified(base: str, head: str) -> Optional[str]:
    log = git("log", "--format=%B", f"{base}..{head}")
    for line in log.stdout.splitlines():
        if line.strip().lower().startswith("ratchet-decrease:"):
            return line.strip()
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", nargs="?", const="src/test", default=None)
    ap.add_argument("--compare", nargs=2, metavar=("BASE_REF", "HEAD_REF"), default=None)
    ap.add_argument("--path", default="src/test")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    if a.count is not None:
        print(json.dumps(census_tree(a.count)))
        return 0

    if not a.compare:
        ap.error("pass --count or --compare")

    base_ref, head_ref = a.compare
    before = census_ref(base_ref, a.path)
    after = census_ref(head_ref, a.path)
    drops = [k for k in ("tests", "assertions") if after[k] < before[k]]

    if a.json:
        print(json.dumps({"before": before, "after": after, "drops": drops}))
    else:
        print(f"tests {before['tests']} -> {after['tests']}, "
              f"assertions {before['assertions']} -> {after['assertions']}")

    if not drops:
        return 0

    reason = justified(base_ref, head_ref)
    if reason:
        print(f"RATCHET_DECREASE_ACCEPTED: {', '.join(drops)} decreased; {reason}", file=sys.stderr)
        return 0
    print(f"RATCHET_FAIL: {', '.join(drops)} decreased "
          f"({before} -> {after}). Tests or assertions were removed. If intended, put a "
          "'Ratchet-Decrease: <reason>' line in the commit message.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
