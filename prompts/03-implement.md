Phase 3: Implement. Edits under src/test/ only.

Precondition: `python scripts/approval.py --verify` exits 0 (a person created the
approval tag). If it does not, stop and report the tag name they must create.
Never create the tag yourself.

Read CLAUDE.md first. For each work item, in the order listed in plan.md:

1. Write or fix tests under src/test/ only.
2. Run `scripts/test-guard.sh`. If it fails and the fix is not obvious, stop and report.
3. Rerun the PIT goal for the item's class and confirm the expected mutants are killed.
   If a mutant survives, fix the assertion or stop that item and record it.
4. Commit with the message "test: <item id> <summary>".
5. Update the item's status in plan.md and reference the log file.

Do not reorder items. Do not expand scope. Record any expected-behavior uncertainty
in .testing/SUSPECTED_ISSUES.md.
