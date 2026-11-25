# Runbook

How to run the workflow on a real service. Read `docs/ARCHITECTURE.md` first if
you want to know *why* it is shaped this way.

## 0. Prerequisites

| Need | Why |
|---|---|
| JDK 17, Maven | build and PIT |
| Git 2.x | the ratchet and approval checks read refs |
| Python 3.8+ | the four check scripts; on Windows `python` must be Python 3 |
| A CI runner | the only authoritative enforcement |

Git Bash on Windows is fine. The scripts avoid 3.9+ syntax on purpose.

## 1. One-time setup per service

```bash
# from the service repo root
git checkout -b chore/test-ratchet-setup
# copy this repo's contents in (scripts/, .claude/, .github/, CLAUDE.md, templates/, prompts/)
chmod +x scripts/*.sh scripts/*.py scripts/hooks/*.py scripts/tests/*.sh
```

Add PIT and JaCoCo to the service's `pom.xml`. Do not paste the XML by hand —
the setup script does it in place and is safe to re-run:

```bash
python scripts/setup_pom.py --check        # what is missing? exit 1 if incomplete
python scripts/setup_pom.py --dry-run      # show the diff, write nothing
python scripts/setup_pom.py                # patch in place (backup at pom.xml.bak)
```

What it does:

- adds `pitest-maven` with `<outputFormat>XML</outputFormat>`. **XML is required** —
  `scripts/pit_score.py` parses it, and the guard fails rather than guess without it.
- sets `<timestampedReports>false</timestampedReports>`, so the report lands at a
  stable path instead of a new timestamped directory per run.
- adds `pitest-junit5-plugin` **only** if the project uses JUnit 5 (it looks for
  `junit-jupiter`, `spring-boot-starter-test` or `junit-platform`). PIT needs it
  on its own classpath for JUnit 5, and must not have it for JUnit 4.
- adds `jacoco-maven-plugin` with `report` bound to `verify`. Pass `--no-jacoco`
  to skip.

What it will not do:

- It never reserialises the file. Detection uses a real XML parser; writing is a
  text insertion at a known offset, so comments, formatting and ordering survive.
- If `pitest-maven` is already there, it adds the XML format and leaves the
  version and any `targetClasses` alone.
- It refuses an aggregator pom (one with `<modules>`), because PIT belongs on the
  modules that hold the code. Run it per module, or pass `--force`.
- It validates the result as XML before writing. If the patch would not parse,
  nothing is written.

Pin the versions deliberately:

```bash
python scripts/setup_pom.py \
  --pitest-version 1.30.2 \
  --junit5-plugin-version 1.2.3 \
  --jacoco-version 0.8.12
```

Those are the defaults. **Check them against Maven Central before committing** —
they were current when this was written, not necessarily when you run it.

Verify the harness itself before trusting it:

```bash
bash scripts/tests/selftest.sh      # expect: Passed: 55   Failed: 0
```

**Then make CI a required status check.** Settings → Branches → rule for `main` →
require the `guard` check. Skip this and CI is advice too, which defeats the
entire design.

Merge the setup branch on its own. Harness changes never ride along with test work.

## 2. Phase 1 — Assess

```bash
# in the service repo, on a new branch
git checkout -b test/hardening-<area>
```

Ask the agent to use the `test-hardening` skill, or delegate to the `assessor`
subagent directly. It will:

- inventory the target packages and their covering tests
- run `mvn verify` and PIT, saving logs under `.testing/logs/`
- run the suite twice to spot flaky tests
- write `.testing/assessment.md`, `baseline.json` and `pit-scope.txt`

**Your job here:** skim the assessment. If Maven or PIT could not run, it must say
so and record no number. An assessment with numbers but no logs is wrong.

## 3. Phase 2 — Propose, then approve

The agent writes `.testing/plan.md`, ranked by risk, and prints:

```bash
python scripts/approval.py --name
# plan-approved-3250b8ecbdd8
```

**Your job here, and this is the one step that cannot be delegated:** read the
plan. Then:

```bash
git tag plan-approved-3250b8ecbdd8
git push origin plan-approved-3250b8ecbdd8
```

If the plan changes afterwards, the hash changes and the tag stops matching. That
is intended — re-read and re-tag.

Check it took:

```bash
python scripts/approval.py --verify --require-remote
```

## 4. Phase 3 — Implement

One plan item at a time. After each, the agent runs:

```bash
bash scripts/test-guard.sh
```

Expected output:

```
PASS: src/main/ untouched
PASS: test ratchet vs origin/main (tests 4 -> 13, assertions 3 -> 13)
PASS: test ratchet vs the previous commit (tests 13 -> 13, assertions 13 -> 13)
PASS: no new @Disabled/@Ignore or Thread.sleep
SKIP: plan approval (REQUIRE_APPROVAL=0; CI sets 1 and reads the tag from the remote)
PASS: build and tests (mvn -q verify; log: .testing/logs/verify.log)
PASS: mutation score 71.4 (baseline 14.3)
GUARD: all checks passed
```

Useful overrides:

```bash
BASE_REF=origin/main \
BUILD_CMD="mvn -q verify" \
MUTATION_CMD="mvn -q org.pitest:pitest-maven:mutationCoverage" \
bash scripts/test-guard.sh
```

**Your job here:** review each commit. The guard checks mechanics. Whether an
assertion matches the requirement is yours, and no script substitutes for it.

## 5. Phase 4 — Report, then PR

The agent writes `.testing/final-report.md` from `templates/report.md`. Then open
the PR. CI runs `ci-check.sh`, which rebuilds the baseline from the base commit,
reads the tag from origin, refuses any harness edit, and re-runs everything.

**Believe CI, not the local guard.**

## When a check fails

| Message | Meaning | Do this |
|---|---|---|
| `src/main/ changed` | production code was modified | revert it; if the test genuinely needs a production change, it belongs in `.testing/blockers.md` and a separate PR |
| `RATCHET_FAIL` | tests or assertions decreased | restore them; if the removal is correct, add `Ratchet-Decrease: <reason>` to the commit message |
| `STALE_REPORT` | PIT report predates the last `src/` commit | re-run the PIT goal, then the guard |
| `SCOPE_MISMATCH` | the report covers different classes than the baseline | run PIT against the same target as Phase 1, or redo the baseline deliberately |
| `NOT_APPROVED` | no tag matches the current plan | the plan changed after approval; a person re-reads and re-tags |
| `mutation score N below baseline` | the change weakened the suite | fix the tests. **Never adjust the baseline** — CI recomputes it and will catch the edit |
| `baseline.json claims X but base scores Y` | the committed baseline was edited | restore it to the recomputed value |
| `INCOMPLETE: ... pitest-maven` | the service's pom has no PIT, or PIT without XML | run `python scripts/setup_pom.py` |
| `This PR edits the guard` | harness and test work are mixed | split them into two PRs |

## Scaling to many services

Put `scripts/`, `.claude/` and the workflow in a shared location — a template
repo, or a parent POM plus a reusable workflow. Per service, the only things that
differ are `baseline.json`, `pit-scope.txt` and the plan.

Start with one tier-1 service. Run the four phases, measure the manual regression
hours it removed, and use that number to decide whether to roll on.

## What this does not do

- It does not run your tests in place of Maven. It governs how they change.
- It does not tell you a test is *correct*, only that it notices a change.
- It does not replace exploratory or UX testing.
