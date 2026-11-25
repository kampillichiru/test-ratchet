#!/usr/bin/env bash
# Authoritative enforcement. Runs on a CI runner, where the agent cannot edit
# this script, cannot write the files it reads, and cannot push a tag.
#
# What makes it authoritative, and the local guard only advisory:
#   - the mutation baseline is RECOMPUTED by building BASE_REF in a clean
#     worktree, instead of being read from .testing/baseline.json, which the
#     agent can write
#   - plan approval is read from the REMOTE's tags, and the agent has no push
#   - every check runs again from the diff, so a tampered local run proves nothing
#
# Usage: bash scripts/ci-check.sh
# Env:
#   BASE_REF=origin/main          base of the comparison (CI sets the PR base)
#   BUILD_CMD="mvn -q verify"
#   MUTATION_CMD="mvn -q org.pitest:pitest-maven:mutationCoverage"
#   APPROVAL_REMOTE=origin
#   REQUIRE_APPROVAL=1            set 0 only for a repo not yet using the gate
set -uo pipefail

BASE_REF=${BASE_REF:-origin/main}
BUILD_CMD=${BUILD_CMD:-mvn -q verify}
MUTATION_CMD=${MUTATION_CMD:-mvn -q org.pitest:pitest-maven:mutationCoverage}
APPROVAL_REMOTE=${APPROVAL_REMOTE:-origin}
REQUIRE_APPROVAL=${REQUIRE_APPROVAL:-1}
PIT_REPORTS=${PIT_REPORTS:-target/pit-reports}

HERE=$(cd "$(dirname "$0")" && pwd)
PY=$(command -v python3 || command -v python)
mkdir -p .testing/logs
fail=0
say() { echo "[ci-check] $*"; }

say "base=$BASE_REF head=$(git rev-parse --short HEAD)"

# ---------------------------------------------------- recompute the baseline
# Build BASE_REF in a detached worktree. Nothing here reads a file the agent
# can write, so the baseline cannot be moved by editing the repo.
BASE_SCORE=""
WT=$(mktemp -d)
if git worktree add -q --detach "$WT" "$BASE_REF" 2>/dev/null; then
  say "recomputing the baseline mutation score at $BASE_REF"
  (
    cd "$WT" || exit 1
    eval "$BUILD_CMD"  > /dev/null 2>&1
    eval "$MUTATION_CMD" > /dev/null 2>&1
  )
  if out=$("$PY" "$HERE/pit_score.py" --reports-dir "$WT/$PIT_REPORTS" \
             --write-scope-file .testing/ci-base-scope.txt --json 2>/dev/null); then
    BASE_SCORE=$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['score'])" "$out")
    say "recomputed baseline: $BASE_SCORE (from $BASE_REF, not from baseline.json)"
    echo "$out" > .testing/logs/ci-base-score.json
  else
    say "WARN: could not score $BASE_REF; the mutation comparison will be skipped"
  fi
  git worktree remove --force "$WT" >/dev/null 2>&1
else
  say "WARN: could not create a worktree for $BASE_REF; is the history shallow? (fetch-depth: 0)"
fi
rm -rf "$WT" 2>/dev/null

# ------------------------------------- committed baseline must not disagree
if [ -n "$BASE_SCORE" ] && [ -f .testing/baseline.json ]; then
  claimed=$("$PY" -c 'import json;print(json.load(open(".testing/baseline.json")).get("mutation_score",""))' 2>/dev/null)
  if [ -n "$claimed" ] && "$PY" -c "import sys;sys.exit(0 if abs(float('$claimed')-float('$BASE_SCORE'))>0.051 else 1)"; then
    say "FAIL: .testing/baseline.json claims $claimed but $BASE_REF actually scores $BASE_SCORE."
    say "      A baseline that disagrees with the base commit has been edited. Refusing to use it."
    fail=1
  else
    say "PASS: committed baseline agrees with the recomputed score"
  fi
fi

# ------------------------------------------------------ approval from the remote
if [ "$REQUIRE_APPROVAL" = "1" ]; then
  git fetch -q --tags "$APPROVAL_REMOTE" 2>/dev/null
  if out=$("$PY" "$HERE/approval.py" --plan .testing/plan.md --verify --require-remote --remote "$APPROVAL_REMOTE" 2>&1); then
    say "PASS: $out"
  else
    say "FAIL: $(echo "$out" | head -1)"
    fail=1
  fi
fi

# -------------------------------------------------------------- run the guard
say "running the guard with the recomputed baseline"
BASELINE_SCORE="$BASE_SCORE" \
BASE_REF="$BASE_REF" \
BUILD_CMD="$BUILD_CMD" \
MUTATION_CMD="$MUTATION_CMD" \
REQUIRE_APPROVAL=0 \
bash "$HERE/test-guard.sh" || fail=1

if [ "$fail" -eq 0 ]; then
  say "ALL CHECKS PASSED"
else
  say "CHECKS FAILED"
fi
exit $fail
