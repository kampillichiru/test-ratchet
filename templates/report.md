# Test hardening report: <service>

Date: <YYYY-MM-DD>

## Summary
| Metric | Baseline | Final | Evidence |
|---|---|---|---|
| Mutation score | <n> | <n> | <log path> |
| Mutation scope | <classes> | <classes> | `.testing/pit-scope.txt` |
| Test methods | <n> | <n> | `test_census.py` output |
| Assertions | <n> | <n> | `test_census.py` output |
| Branch coverage | <n> | <n> | <log path> |
| Flaky tests | <n> | <n> | <log path> |
| Production code changed | — | none | `git diff --stat <base>..HEAD -- src/main` |

## How these numbers were produced
- Build and test command: <cmd>
- Mutation tool: <PIT version, or state plainly that PIT did not run>
- Checks that were SKIPPED rather than passed: <list, or none>
- Confirmed by CI: <yes, with the run link | no — only the local guard ran>

## Completed items
| Item | Tests changed | Mutants killed | Commit |
|---|---|---|---|

## Stopped items and reasons

## Suspected issues (not asserted; need a requirement decision)
- See `.testing/SUSPECTED_ISSUES.md`

## Production blockers (need a separate approved change)
- See `.testing/blockers.md`

## Next recommended step
