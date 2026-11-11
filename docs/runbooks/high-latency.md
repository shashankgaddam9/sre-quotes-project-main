# Runbook: HighLatencyP99

**Severity:** ticket (page if it persists > 30 min or pairs with errors)

## Diagnose
1. Grafana latency panel — sudden step (likely a change) or gradual climb (likely load/saturation)?
2. Is traffic higher than usual? Traffic panel.
3. Saturation:
   ```bash
   kubectl top pods -n quotes
   kubectl -n quotes get hpa          # stuck at maxReplicas?
   kubectl -n quotes describe pod <pod> | grep -i throttl   # CPU throttling from limits?
   ```
4. Recent change? `kubectl -n quotes rollout history deployment/quotes-api`, config map values
   (`FAULT_LATENCY_MS`).
5. Redis slow? `kubectl -n quotes exec redis-0 -- redis-cli --latency -i 1` (Ctrl-C to stop).

## Mitigate
- Recent change → `make rollback`.
- Saturation → scale out: `kubectl -n quotes scale deployment/quotes-api --replicas=6`
  (raise HPA `maxReplicas` in git afterwards), or raise CPU limits.
