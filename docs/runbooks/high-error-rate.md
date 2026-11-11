# Runbook: HighErrorBudgetBurn (5xx error rate high)

**Severity:** page **Impact:** users are getting errors from /api.

## 1. Confirm (1 min)
- Grafana → *Quotes API - Golden Signals* → "Error ratio". Is it real and ongoing?
- Prometheus: `sum by (endpoint, status) (rate(http_requests_total{status=~"5.."}[5m]))` — which endpoints?

## 2. What changed? (most incidents are caused by a change)
```bash
kubectl -n quotes rollout history deployment/quotes-api
kubectl -n quotes get events --sort-by=.lastTimestamp | tail -20
kubectl -n quotes get configmap quotes-api-config -o yaml
git log --oneline -10 -- k8s/ app/          # recent deploys / config commits
```
Argo CD UI → quotes-production → History.

## 3. Mitigate first, debug later
If a deploy or config change happened in the last ~hour, **roll it back**:
```bash
make rollback                                  # kubectl rollout undo
# GitOps: git revert <commit> && git push
```

## 4. If no recent change
- Is Redis healthy? → `runbooks/redis-down.md`
- Logs: `kubectl -n quotes logs -l app=quotes-api --tail=200 | grep '"status": 5'`
- Are pods restarting? `kubectl -n quotes get pods` (RESTARTS column)
- Saturation? `kubectl top pods -n quotes`, HPA at max? `kubectl -n quotes get hpa`

## 5. Close out
Confirm the error ratio is back to baseline for 10+ minutes. Write a postmortem if > 20% budget was used.
