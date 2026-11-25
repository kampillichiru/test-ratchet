#!/usr/bin/env bash
# Guardrails for test-hardening work.
#
# Run it after every plan item for fast feedback. It is NOT the authoritative
# control: locally, the agent can edit this file and the files it reads.
# scripts/ci-check.sh running on a CI runner is authoritative, because it
# recomputes the baseline from git and reads the approval tag from the remote.
#
# Usage: bash scripts/test-guard.sh
# Env:
#   BASE_REF=origin/main       comparison base for the diff and ratchet checks
#   BUILD_CMD="mvn -q verify"  build and test command
#   MUTATION_CMD=""            command that produces the PIT report; empty means
#                              the caller already ran it
#   BASELINE_SCORE=            mutation baseline; CI passes a value recomputed
#                              from BASE_REF, which overrides .testing/baseline.json
#   REQUIRE_APPROVAL=0|1       check the plan-approval tag (CI sets 1)
#   APPROVAL_REMOTE=origin     with REQUIRE_APPROVAL=1, read tags from this remote
#   GUARD_SKIP_BUILD=1         skip build and mutation checks (self-test only)
set -uo pipefail

BASE_REF=${BASE_REF:-origin/main}
BUILD_CMD=${BUILD_CMD:-mvn -q verify}
MUTATION_CMD=${MUTATION_CMD:-}
BASELINE_SCORE=${BASELINE_SCORE:-}
REQUIRE_APPROVAL=${REQUIRE_APPROVAL:-0}
APPROVAL_REMOTE=${APPROVAL_REMOTE:-origin}
GUARD_SKIP_BUILD=${GUARD_SKIP_BUILD:-0}
PIT_REPORTS=${PIT_REPORTS:-target/pit-reports}

HERE=$(cd "$(dirname "$0")" && pwd)
PY=$(command -v python3 || command -v python)
mkdir -p .testing/logs
fail=0
log() { echo "$*" | tee -a .testing/logs/guard.log; }

# ---------------------------------------------------------------- 1. production
if git diff --name-only "$BASE_REF"...HEAD 2>/dev/null | grep -q '^src/main/'; then
  log "FAIL: src/main/ changed relative to $BASE_REF"
  fail=1
else
  log "PASS: src/main/ untouched"
fi

# ------------------------------------------------------- 2. ratchet (not a blocklist)
# Checked against BOTH the branch base and the previous commit. Base alone is not
# enough: on a multi-item branch, deleting a test still leaves the total above the
# branch base, so the drop would pass unnoticed. Per-commit is what catches it.
ratchet_check() { # label base head
  local out rc
  out=$("$PY" "$HERE/test_census.py" --compare "$2" "$3" --path src/test 2>&1); rc=$?
  if [ $rc -eq 0 ]; then
    log "PASS: test ratchet vs $1 ($(echo "$out" | head -1))"
  else
    log "FAIL: test ratchet vs $1 — $(echo "$out" | grep RATCHET_FAIL || echo "$out" | head -1)"
    fail=1
  fi
}
ratchet_check "$BASE_REF" "$BASE_REF" HEAD
if git rev-parse --verify -q HEAD~1 >/dev/null; then
  ratchet_check "the previous commit" HEAD~1 HEAD
else
  log "SKIP: test ratchet vs the previous commit (HEAD has no parent)"
fi

# --------------------------------------------- 3. fast signal on weakening patterns
if git diff "$BASE_REF"...HEAD -- src/test 2>/dev/null | grep '^+' | grep -qE '@Disabled|@Ignore|Thread\.sleep'; then
  log "FAIL: newly added @Disabled/@Ignore or Thread.sleep in src/test"
  fail=1
else
  log "PASS: no new @Disabled/@Ignore or Thread.sleep"
fi

# ------------------------------------------------------------------ 4. approval gate
if [ "$REQUIRE_APPROVAL" = "1" ]; then
  if [ -f .testing/plan.md ]; then
    out=$("$PY" "$HERE/approval.py" --plan .testing/plan.md --verify --require-remote --remote "$APPROVAL_REMOTE" 2>&1)
    if [ $? -eq 0 ]; then
      log "PASS: plan approval ($(echo "$out" | head -1))"
    else
      log "FAIL: plan approval — $(echo "$out" | head -1)"
      fail=1
    fi
  else
    log "FAIL: REQUIRE_APPROVAL=1 but .testing/plan.md does not exist"
    fail=1
  fi
else
  log "SKIP: plan approval (REQUIRE_APPROVAL=0; CI sets 1 and reads the tag from the remote)"
fi

# ------------------------------------------------------------------------ 5. build
if [ "$GUARD_SKIP_BUILD" = "1" ]; then
  log "SKIP: build check (GUARD_SKIP_BUILD=1 — a report must call this skipped, never passed)"
elif eval "$BUILD_CMD" > .testing/logs/verify.log 2>&1; then
  log "PASS: build and tests ($BUILD_CMD; log: .testing/logs/verify.log)"
else
  log "FAIL: build or tests failed ($BUILD_CMD; see .testing/logs/verify.log)"
  fail=1
fi

# ------------------------------------------------------------- 6. mutation score
if [ "$GUARD_SKIP_BUILD" = "1" ]; then
  log "SKIP: mutation check (GUARD_SKIP_BUILD=1)"
else
  if [ -n "$MUTATION_CMD" ]; then
    eval "$MUTATION_CMD" > .testing/logs/mutation.log 2>&1 \
      || log "WARN: mutation command exited non-zero (see .testing/logs/mutation.log)"
  fi
  # A report must be newer than the code it claims to describe, so a leftover
  # report from an earlier run can never be scored as if it were current.
  # Anchored to the last commit that touched src/, not to HEAD: a commit that
  # changes only docs or the harness does not invalidate a PIT run, and anchoring
  # to HEAD would train people to ignore the check.
  head_time=$(git log -1 --format=%ct -- src/ 2>/dev/null)
  [ -z "$head_time" ] && head_time=$(git log -1 --format=%ct 2>/dev/null || echo 0)
  baseline="$BASELINE_SCORE"
  scope_arg=()
  [ -f .testing/pit-scope.txt ] && scope_arg=(--expect-scope-file .testing/pit-scope.txt)
  if [ -z "$baseline" ] && [ -f .testing/baseline.json ]; then
    baseline=$("$PY" -c 'import json;print(json.load(open(".testing/baseline.json"))["mutation_score"])' 2>/dev/null)
  fi

  result=$("$PY" "$HERE/pit_score.py" --reports-dir "$PIT_REPORTS" \
             --min-mtime "$head_time" "${scope_arg[@]}" --json 2>&1)
  rc=$?
  case $rc in
    0)
      score=$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['score'])" "$result")
      if [ -z "$baseline" ]; then
        log "WARN: mutation score $score but no baseline to compare (set BASELINE_SCORE or .testing/baseline.json)"
      elif "$PY" -c "import sys;sys.exit(0 if float('$score') >= float('$baseline') else 1)"; then
        log "PASS: mutation score $score (baseline $baseline)"
      else
        log "FAIL: mutation score $score below baseline $baseline"
        fail=1
      fi ;;
    3) log "FAIL: no PIT report under $PIT_REPORTS. Run the PIT goal, or set MUTATION_CMD." ; fail=1 ;;
    4) log "FAIL: $(echo "$result" | head -1)" ; fail=1 ;;
    5) log "FAIL: $(echo "$result" | head -1)" ; fail=1 ;;
    *) log "FAIL: could not read the PIT report — $(echo "$result" | head -1)" ; fail=1 ;;
  esac
fi

if [ "$fail" -eq 0 ]; then log "GUARD: all checks passed"; else log "GUARD: FAILED"; fi
exit $fail
