#!/usr/bin/env python3
"""Plan approval that the agent cannot grant itself.

A 'Status: APPROVED' line inside .testing/plan.md is worthless as a gate: the
plan lives in the tree the agent is allowed to write. Instead, approval is a git
tag whose NAME contains a hash of the plan's content:

    plan-approved-<first 12 hex of sha256(.testing/plan.md)>

Properties this gives:
  - Editing the plan changes the hash, so an existing tag stops matching. An
    agent cannot approve a plan by writing to it.
  - A human creates the tag after reading the plan, and pushes it.
  - CI checks the tag on ORIGIN (--require-remote). The agent cannot push
    (git push is denied), so the remote tag is the authoritative signal. A local
    tag only gives fast feedback and is explicitly advisory.

Usage:
  approval.py --plan .testing/plan.md --name           print the tag a human should create
  approval.py --plan .testing/plan.md --verify         local tags (advisory)
  approval.py --plan .testing/plan.md --verify --require-remote [--remote origin]

Exit codes: 0 approved, 1 not approved, 3 plan missing.
"""
import argparse
import hashlib
import subprocess
import sys
from pathlib import Path

PREFIX = "plan-approved-"


def plan_hash(path: Path) -> str:
    # Hash bytes with newlines normalized, so a CRLF checkout on Windows and an
    # LF checkout in CI produce the same tag name.
    data = path.read_bytes().replace(b"\r\n", b"\n")
    return hashlib.sha256(data).hexdigest()[:12]


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=False)


def local_tags():
    return set(git("tag", "--list", f"{PREFIX}*").stdout.split())


def remote_tags(remote: str):
    out = git("ls-remote", "--tags", remote)
    if out.returncode != 0:
        return None, out.stderr.strip()
    names = set()
    for line in out.stdout.splitlines():
        parts = line.split("refs/tags/")
        if len(parts) == 2:
            name = parts[1].strip()
            if name.endswith("^{}"):
                name = name[:-3]
            names.add(name)
    return {n for n in names if n.startswith(PREFIX)}, None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", default=".testing/plan.md")
    ap.add_argument("--name", action="store_true")
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--require-remote", action="store_true")
    ap.add_argument("--remote", default="origin")
    a = ap.parse_args()

    plan = Path(a.plan)
    if not plan.exists():
        print(f"NO_PLAN: {plan} does not exist. Phase 2 must write it first.", file=sys.stderr)
        return 3

    expected = PREFIX + plan_hash(plan)

    if a.name:
        print(expected)
        return 0

    if not a.verify:
        ap.error("pass --name or --verify")

    if a.require_remote:
        tags, err = remote_tags(a.remote)
        if tags is None:
            print(f"NOT_APPROVED: cannot read tags from '{a.remote}': {err}", file=sys.stderr)
            return 1
        where = f"remote '{a.remote}'"
    else:
        tags = local_tags()
        where = "local tags (advisory; CI must re-check against the remote)"

    if expected in tags:
        print(f"APPROVED: {expected} found in {where}")
        return 0

    stale = sorted(t for t in tags if t != expected)
    msg = [f"NOT_APPROVED: no tag {expected} in {where}."]
    if stale:
        msg.append(f"Found {stale}, which approved a different version of the plan "
                   "(the plan changed after approval, or the hash is from another plan).")
    msg.append("A person must read .testing/plan.md and then run: "
               f"git tag {expected} && git push {a.remote} {expected}")
    print(" ".join(msg), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
