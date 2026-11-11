# Postmortem: <short title>

**Date:** YYYY-MM-DD **Authors:** **Status:** Draft / Reviewed
**Severity:** SEV1 / SEV2 / SEV3 **Duration:** HH:MM (detect → resolve)

> Blameless: describe what the *system* allowed to happen, not who made a mistake.

## Summary
2–3 sentences: what broke, who was affected, how it was fixed.

## Impact
- Users affected / % of requests failed:
- Error budget consumed: X% of monthly budget
- SLO breached? yes / no

## Timeline (all times UTC)
| Time | Event |
|---|---|
| 00:00 | Change deployed / trigger occurred |
| 00:03 | Alert `HighErrorBudgetBurn` fired |
| 00:05 | On-call acknowledged, opened dashboard |
| 00:09 | Root cause identified |
| 00:10 | Mitigation applied (rollback) |
| 00:14 | Metrics back to normal; incident closed |

## Root cause
What actually caused it. Use "5 whys" to go past the first answer.

## Detection
How did we find out? Was the alert fast enough? Would users have noticed first?

## Resolution
What we did to stop the bleeding, and the permanent fix.

## What went well
## What went poorly
## Where we got lucky

## Action items
| Action | Type (prevent / detect / mitigate) | Owner | Ticket |
|---|---|---|---|
| | | | |
