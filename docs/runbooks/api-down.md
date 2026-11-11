# Runbook: ApiDown (no healthy targets)

**Severity:** page

```bash
kubectl -n quotes get deploy,pods -l app=quotes-api
kubectl -n quotes describe pod <pod>              # look at Events + Last State
kubectl -n quotes logs <pod> --previous           # logs from the crashed container
kubectl -n quotes get events --sort-by=.lastTimestamp | tail -20
```

| Pod status | Meaning | Next step |
|---|---|---|
| `ImagePullBackOff` | bad image tag / registry auth / private package | `make rollback`; check GHCR visibility |
| `CrashLoopBackOff` | app crashes on start | `logs --previous`; rollback |
| `OOMKilled` | memory limit too low | raise limit, rollback |
| `Pending` | no node has capacity | `kubectl describe pod`, `kubectl get nodes`, `kubectl top nodes` |
| Running but not Ready | readiness failing | `runbooks/redis-down.md` |

If pods are fine, check Prometheus itself: Status → Targets. Is the ServiceMonitor picking them up?
