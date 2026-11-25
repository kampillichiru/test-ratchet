# Test hardening harness

A phased workflow for strengthening JUnit and integration tests in an existing
Java/Spring service without changing production code.

## Why the enforcement is split in two

The first version of this harness put every check inside the tree the agent was
allowed to write. Attacking it found six holes: the hook only saw Edit and Write,
so a shell `sed -i` walked past it; the agent could set `Status: APPROVED` in its
own plan; it could lower `baseline.json` to whatever it had just scored; a stale
PIT report scored as a pass; deleting a test or gutting its assertions passed;
and the grep over PIT's XML misread double-quoted reports as zero.

So enforcement now runs at two levels, and only one of them counts:

| | `scripts/test-guard.sh` | `scripts/ci-check.sh` (CI) |
|---|---|---|
| Where | the agent's own tree | a CI runner |
| Baseline | reads `.testing/baseline.json` | **rebuilds it from the base commit** |
| Approval | local tags, advisory | **tags fetched from the remote** |
| Harness edits | not checked | **fails the PR** |
| Status | fast feedback | **authoritative** |

Run the guard for feedback after every item. Believe CI.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how it works, the two-level
  enforcement model, what each check catches, and the trust boundaries.
- [docs/RUNBOOK.md](docs/RUNBOOK.md) — how to set it up on a service and run the
  four phases, including what to do when a check fails.

## Contents

| Path | Purpose |
|---|---|
| `CLAUDE.md` | Rules for every agent session |
| `.claude/settings.json` | Hook on Edit/Write/MultiEdit **and Bash**; denies push, tag, and writes to `scripts/`, `.github/`, `CLAUDE.md` |
| `.claude/agents/{assessor,implementer,reporter}.md` | Phase 1, 3 and 4 subagents |
| `.claude/skills/test-hardening/SKILL.md` | The workflow skill |
| `scripts/hooks/block_main_edits.py` | Refuses writes to `src/main`, to `baseline.json`, and self-approval tags; fails closed |
| `scripts/test-guard.sh` | Local checks: production untouched, ratchet, weakening patterns, build, mutation score |
| `scripts/ci-check.sh` | Authoritative: recomputes the baseline, verifies the remote tag, re-runs the guard |
| `scripts/pit_score.py` | Parses PIT XML properly; refuses a stale report or a mismatched class scope |
| `scripts/test_census.py` | Ratchet: test and assertion counts must not fall |
| `scripts/approval.py` | Approval as a git tag bound to a hash of the plan |
| `scripts/setup_pom.py` | Adds PIT (with XML) and JaCoCo to a service's `pom.xml`, idempotently |
| `scripts/tests/selftest.sh` | 55 cases, including one regression test per gap above |
| `.github/workflows/test-hardening.yml` | Wires `ci-check.sh` to pull requests |
| `prompts/`, `templates/` | Phase prompts and the plan and report formats |

## Phases

| Phase | Writes | Gate |
|---|---|---|
| 1. Assess | `assessment.md`, `baseline.json`, `pit-scope.txt` | none |
| 2. Propose | `plan.md` | a person creates the approval tag |
| 3. Implement | `src/test/`, one commit per item | guard per item; CI on the PR |
| 4. Report | `final-report.md` | a person reviews |

## How approval works

Phase 2 writes the plan, then prints the tag a person must create:

```bash
python scripts/approval.py --name          # plan-approved-<12 hex of sha256(plan.md)>
git tag plan-approved-<hash> && git push origin plan-approved-<hash>
```

Because the tag name contains a hash of the plan's content, editing the plan
invalidates it. The agent cannot push, and `git tag` is denied, so the remote tag
is a human signal. CI checks the remote; the local check says it is advisory.

## Setup

1. Copy these files into the root of the service repository.
2. Requirements: JDK 17, Maven, Git, Python 3.8+. On Windows use Git Bash; the
   hook calls `python`, so make sure that resolves to Python 3.
3. Add PIT and JaCoCo to the service's `pom.xml` with the setup script — it is
   idempotent, preserves formatting, and refuses to write anything that would not
   parse:

   ```bash
   python scripts/setup_pom.py --check     # what is missing?
   python scripts/setup_pom.py --dry-run   # show the diff
   python scripts/setup_pom.py             # patch in place
   ```

   XML output is required, not optional: `scripts/pit_score.py` parses it and the
   guard fails rather than guess without it. See
   [docs/RUNBOOK.md](docs/RUNBOOK.md) for the options and the version pins.

4. `bash scripts/tests/selftest.sh` — all 55 cases must pass.
5. Enable the workflow and make the `guard` job a required status check on `main`.
   Without that, CI is advice too.
6. Work on a branch, never on `main`.

### Not GitHub Actions

`ci-check.sh` is plain bash. In Jenkins or GitLab, call it with `BASE_REF` set to
the target branch and `REQUIRE_APPROVAL=1`, with full history fetched (the
baseline needs the base commit; a shallow clone breaks the worktree step).

## Known limits

- **The hook is not a sandbox.** It matches shell patterns, and shell quoting is
  open-ended: base64, a variable, or a helper script it writes elsewhere can get
  past it. CI recomputing from the diff is what actually holds.
- **Local checks are only as honest as the tree.** An agent that edits `scripts/`
  changes its own local verdict. CI fails any hardening PR that touches the harness.
- **`BUILD_CMD` is passed to `eval`.** Set it in the CI job, not from a repo file.
- **The ratchet counts patterns, not semantics.** Converting an assertion to
  `@Test(expected = ...)` reads as an assertion drop; that is what the
  `Ratchet-Decrease:` trailer is for.
- **Mutation score measures whether tests notice changes**, not whether they check
  the right behavior. Only a person reviewing each assertion against the
  requirement does that.
- **The self-test does not run Maven or PIT.** It covers the guard, hook, parser,
  ratchet and approval logic. The build and mutation paths need a real project.
