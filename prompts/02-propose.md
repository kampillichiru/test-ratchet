Phase 2: Propose. Read-only for code.

Read CLAUDE.md and .testing/assessment.md.

Write .testing/plan.md using templates/plan.md. Rank work items by risk:
escaped defects, money or data changes, and external calls first.

For each item include:
- Target class and the behaviors to verify
- Tests to add or fix
- Mutants expected to be killed (cite the assessment)
- Blockers that need production changes (list them; do not work around them)
- Effort estimate

Then print the approval tag name with `python scripts/approval.py --name` and ask
the person to create and push it. Do not start implementation, and never create
the tag yourself.
