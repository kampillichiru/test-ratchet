---
name: test-hardening
description: Runs the phased workflow that strengthens an existing Java/Spring service's JUnit and integration tests without changing production code. Use when asked to assess, plan, implement, or report on test quality or test coverage for a service in this repository.
---

# Test hardening workflow

Four phases, in order. Each writes its output to `.testing/`.

| Phase | Agent | Writes | Gate to continue |
|---|---|---|---|
| 1. Assess | `assessor` | `.testing/assessment.md`, `baseline.json`, `pit-scope.txt` | none |
| 2. Propose | you (read-only for code) | `.testing/plan.md` | a person creates the approval tag |
| 3. Implement | `implementer` | `src/test/` changes, one commit per item | `scripts/test-guard.sh` per item |
| 4. Report | `reporter` | `.testing/final-report.md` | a person reviews |

## What enforces what

Read this before trusting any local result.

- `scripts/test-guard.sh` is **fast feedback, not a control**. It runs in the same
  tree the agent writes.
- `scripts/ci-check.sh` on a CI runner is **authoritative**. It rebuilds the
  baseline from the base commit, reads the approval tag from the remote, and
  re-runs every check from the diff. It also fails a PR that edits the harness.
- The PreToolUse hook is defense in depth. Shell quoting is open-ended, so it
  will not catch every bypass. It is not a sandbox.

## Rules

- Read `CLAUDE.md` before every phase.
- Production code under `src/main/` is never changed.
- Phase 3 needs `python scripts/approval.py --verify` to pass. Never create the
  tag yourself; print its name with `--name` and ask the person for it.
- Never edit `.testing/baseline.json`, `scripts/`, or `CLAUDE.md` during hardening work.
- Tests and assertions must not decrease. A justified removal carries
  `Ratchet-Decrease: <reason>` in the commit message.
- Every number in an assessment or report cites a log. A skipped check is reported
  as skipped, never as a pass.

## Starting

1. Confirm the project builds: `mvn -v` and `mvn -q verify`. If Maven is missing,
   stop and say so. Never estimate a result.
2. Confirm the pom is configured: `python scripts/setup_pom.py --check`. If it
   reports INCOMPLETE, run `python scripts/setup_pom.py` and show the user the diff.
   The guard refuses a PIT report it cannot parse or that predates the last `src/`
   commit, so XML output is required. The pom change is setup, not hardening work:
   commit it on its own.
3. Run `bash scripts/tests/selftest.sh`. All cases must pass before you rely on the guard.
4. Start Phase 1 by delegating to the `assessor` agent.

## Phase 2: plan

Use `templates/plan.md`. Rank items by risk: escaped defects, money or data
changes, then external calls. Write the plan, print the approval tag name, and stop.

## Phase 3: per item

After each item: `bash scripts/test-guard.sh`, then re-run PIT for that class and
confirm the expected mutants died. One commit per item.
