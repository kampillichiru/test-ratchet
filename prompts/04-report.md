Phase 4: Verify and report.

Read CLAUDE.md, .testing/plan.md, and .testing/baseline.json.

1. Run `scripts/test-guard.sh`.
2. Run the suite twice more to recheck flakiness.
3. Run the PIT goal for the same packages as Phase 1.
4. Write .testing/final-report.md using templates/report.md.
   Every number must cite its log. Compare each number with baseline.json.
5. List completed items, stopped items with reasons, open suspected issues, and open blockers.

Do not describe anything as passing unless a log in .testing/logs/ shows it.
