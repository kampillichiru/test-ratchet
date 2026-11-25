Phase 1: Assess. Read-only for code.

Read CLAUDE.md first.

1. Inventory each target package: public behaviors, branches, covering test classes,
   test framework in use.
2. Run `mvn verify` and the PIT goal for the target packages. Save all output to
   .testing/logs/ with descriptive names (assess-verify.log, assess-pit-<pkg>.log).
3. Run the suite twice and record any test whose result changes (flaky).
4. Record:
   - Branch coverage per package (JaCoCo report)
   - Top 15 surviving mutants with file and line
   - @Disabled tests, Thread.sleep uses, and tests that only check status codes
5. Write:
   - .testing/assessment.md: findings, each with a log reference
   - .testing/baseline.json: {"mutation_score": <number>, "date": "<YYYY-MM-DD>"}

Do not change any file outside .testing/.
