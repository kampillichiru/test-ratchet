# Test hardening guardrails

These rules apply to every agent session in this repository.

Most of them are enforced mechanically, and the enforcement that matters runs in
CI (scripts/ci-check.sh), not here. Nothing in this file is a control on its own:
a rule an agent can edit is a checklist, not a guardrail.

## Scope
- Write only under src/test/, .testing/, and test-only build configuration.
- Never modify src/main/. If a test needs a production change, record it in
  .testing/blockers.md and continue with other items.
- Never edit scripts/, .github/workflows/, or this file during test-hardening work.
  Harness changes belong in their own pull request. CI fails a hardening PR that
  touches them.

## Evidence
- Every claim in an assessment or report must cite a log in .testing/logs/ or a command output.
- Never state that tests pass unless the log from that run shows it.
- A check reported as SKIP is never written up as a pass. If the build or the
  mutation run was skipped, the report says so.

## Phase rules
- Phases 1 and 2 are read-only for code. Write only to .testing/.
- Phase 3 starts only when the plan is approved by a tag a person created:
  `python scripts/approval.py --verify`. A `Status: APPROVED` line in plan.md is
  not approval; editing the plan invalidates an existing tag.
- Never create a plan-approved-* tag. That is the person's action, not yours.
  Print the tag name they need with `python scripts/approval.py --name` and ask.
- Implement one plan item at a time. Run `bash scripts/test-guard.sh` after each.

## Test standards
- Assert outputs and side effects, not only status codes or absence of exceptions.
- Integration tests use real infrastructure (Testcontainers, pinned versions) where behavior depends on it.
- Each test sets up its own data. No Thread.sleep. No ordering dependencies.
- Test names describe behavior: method_condition_expectedResult.
- Tests and assertions must not decrease. If a removal is correct, put
  `Ratchet-Decrease: <reason>` in that commit message so it is reviewable.

## Stop conditions
- The guard fails and the fix is not obvious: stop and report.
- A mutant cannot be killed without changing production code: stop that item and record it.
- Mutation score falls below baseline: stop and report. Never adjust the baseline.
- Expected behavior is unclear: add to .testing/SUSPECTED_ISSUES.md. Do not assert it.
