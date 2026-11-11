# Service Level Objectives — Quotes API

## Vocabulary

- **SLI (indicator)** — a measurement of user experience. e.g. "fraction of requests that succeeded".
- **SLO (objective)** — the target for an SLI over a window. e.g. "99.5% over 30 days".
- **SLA (agreement)** — a contract with consequences (refunds) if you miss it. Always looser than the SLO.
- **Error budget** — `1 − SLO`. The amount of unreliability you're *allowed*. When it's
  healthy, ship features fast. When it's exhausted, freeze risky changes and fix reliability.

## Our SLOs

| SLI | Definition (PromQL) | SLO | Window |
|---|---|---|---|
| **Availability** | non-5xx `/api/*` requests ÷ all `/api/*` requests | **99.5%** | 30 days |
| **Latency** | `/api/*` requests served in < 500 ms | **99%** | 30 days |

We measure at the application (`/metrics`). A more user-centric measurement would be at
the ingress / load balancer — a good Phase 8 improvement.

## Error budget math

99.5% availability over 30 days:

- 30 days × 24 h × 60 min = 43,200 minutes
- Budget = 0.5% × 43,200 = **216 minutes (3.6 hours)** of total outage per month
- Or, at 1M requests/month: **5,000 failed requests**

## Why burn-rate alerts?

Alerting on "error rate > 1% for 5 minutes" either pages too often (noise) or too late.
Instead we ask: *how fast are we spending the budget?*

- Burn rate **1** = spending exactly the budget over 30 days.
- Burn rate **14.4** = 2% of the monthly budget gone in 1 hour → at this pace the whole
  budget is gone in ~2 days. **Page.**
- We require *both* the 5-minute and 1-hour windows to be over threshold so short spikes
  don't page and the alert clears quickly once fixed.

See: *The Site Reliability Workbook*, chapter 5 "Alerting on SLOs" (free online at sre.google).

## Error budget policy (example)

1. Budget > 50% remaining: normal release cadence.
2. Budget 0–50%: releases need a rollback plan reviewed by a second engineer.
3. Budget exhausted: feature freeze. Only reliability fixes ship until the 30-day window recovers.
4. Any single incident consuming > 20% of budget requires a postmortem.
