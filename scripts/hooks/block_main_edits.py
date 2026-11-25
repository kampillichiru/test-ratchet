#!/usr/bin/env python3
"""PreToolUse hook: refuse writes to production code and to the approval gate.

Claude Code passes the tool call as JSON on stdin. Exit 2 blocks the call and
returns stderr to the agent; exit 0 allows it.

Blocked:
  - Edit/Write/MultiEdit targeting src/main/ (production code)
  - Edit/Write targeting .testing/plan.md or baseline files (the agent must not
    approve its own plan or move its own baseline)
  - Bash commands that look like a write to src/main, or like self-approval
    (git tag plan-approved-*)

IMPORTANT: this hook is defense in depth, not the control. Shell quoting is
open-ended, so a determined bypass exists (base64, a variable, a script it
writes elsewhere). The authoritative check is CI recomputing from the diff:
scripts/ci-check.sh, which the agent cannot run or edit on the CI runner.
"""
import json
import re
import sys
from pathlib import PurePosixPath

PROTECTED_PATH_RE = re.compile(r"(^|/)src/main/")
# Files that define the gate or the bar. The agent writes the plan's CONTENT in
# phase 2, so plan.md itself stays writable; approval is the git tag, not a file.
GATE_FILES = ("baseline.json", "pit-scope.txt")

# Shell constructs that write a file. Matched against the whole command, then
# checked for a src/main target. Deliberately broad: a false positive is a
# message the agent can work around by using the Write tool on src/test.
WRITE_VERB_RE = re.compile(
    r"(\bsed\b[^|;]*-i|\btee\b|\bcp\b|\bmv\b|\binstall\b|\btruncate\b|"
    r"\bdd\b|>>?\s*\S*src/main|\bpatch\b|\bgit\s+(checkout|restore|apply|am)\b|"
    r"\bperl\b[^|;]*-i|\bpython3?\b[^|;]*-c)")
SELF_APPROVE_RE = re.compile(r"\bgit\s+tag\b[^|;]*plan-approved")


def norm(path: str) -> str:
    return str(PurePosixPath(path.replace("\\", "/")))


def check_path(target: str):
    p = norm(target)
    if PROTECTED_PATH_RE.search("/" + p.lstrip("/")):
        return (f"BLOCKED: {target} is production code (src/main/). Test hardening may only "
                "change src/test/ and .testing/. Record the need in .testing/blockers.md.")
    if any(p.endswith(g) for g in GATE_FILES):
        return (f"BLOCKED: {target} records the baseline this work is measured against. "
                "It is set in phase 1 and recomputed by CI; the agent must not rewrite it.")
    return None


def check_bash(command: str):
    if SELF_APPROVE_RE.search(command):
        return ("BLOCKED: creating a plan-approved-* tag is how a person approves the plan. "
                "The agent must not approve its own plan. Ask the user to create and push it.")
    if "src/main" in command and WRITE_VERB_RE.search(command):
        return (f"BLOCKED: this command looks like a write to production code (src/main/): "
                f"{command[:160]}. Test hardening may only change src/test/ and .testing/.")
    return None


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError):
        # Fail closed: an unreadable payload must not allow a write.
        print("BLOCKED: hook could not parse tool input", file=sys.stderr)
        return 2

    tool = (payload.get("tool_name") or "").strip()
    ti = payload.get("tool_input") or {}

    if tool == "Bash" or "command" in ti:
        reason = check_bash(str(ti.get("command", "")))
        if reason:
            print(reason, file=sys.stderr)
            return 2

    targets = [ti.get("file_path"), ti.get("path"), ti.get("notebook_path")]
    for edit in ti.get("edits") or []:
        if isinstance(edit, dict):
            targets.append(edit.get("file_path"))
    for t in [t for t in targets if t]:
        reason = check_path(str(t))
        if reason:
            print(reason, file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
