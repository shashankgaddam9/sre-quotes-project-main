# Runbook: RedisUnreachable

**Severity:** page **Impact:** API pods go NotReady; all /api requests fail.

## Diagnose
```bash
kubectl -n quotes get sts redis
kubectl -n quotes get pods -l app=redis
kubectl -n quotes describe pod redis-0
kubectl -n quotes logs redis-0 --tail=50
kubectl -n quotes get pvc                       # volume bound?
kubectl -n quotes get endpoints redis           # does the Service have a backend?
kubectl -n quotes exec deploy/quotes-api -- python -c "import socket; socket.create_connection(('redis',6379),2); print('ok')"
```

## Common causes
| Symptom | Cause | Fix |
|---|---|---|
| 0/0 replicas | scaled down | `kubectl -n quotes scale sts redis --replicas=1` |
| Pending | PVC can't bind / node down | check `describe pod`, node status |
| OOMKilled | memory limit | raise limit in `k8s/base/redis.yaml` |
| Pod fine, API can't connect | NetworkPolicy / DNS | check `networkpolicy.yaml`, `kubectl -n quotes get svc redis` |

## After
Once Redis is Ready, API pods become Ready within ~10s automatically (readiness probe). Verify with `make smoke`.
