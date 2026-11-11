# Incident Drills

Do these on the kind cluster (Phase 3+), with `make grafana` open and `make load`
running in another terminal so there's traffic.

**Rules of the game:** after you break something, close this file. Diagnose using only
dashboards, alerts, `kubectl`, and logs. Time yourself from "break" to "mitigated".
Then write a postmortem (`03-postmortem-template.md`).

> If Argo CD is managing the namespace, it will revert manual changes (selfHeal).
> For drills, either pause it — `kubectl -n argocd patch application quotes-production
> --type merge -p '{"spec":{"syncPolicy":null}}'` — or make the "bad change" through a
> git commit, which is more realistic. Re-apply `argocd/applications.yaml` afterwards.

---

## Drill 1 — Bad deploy raises error rate

**Break it:**
```bash
kubectl -n quotes patch configmap quotes-api-config --type merge -p '{"data":{"FAULT_ERROR_RATE":"0.3"}}'
kubectl -n quotes rollout restart deployment/quotes-api
```
**Expect:** error-ratio panel jumps to ~30%; `HighErrorBudgetBurn` fires after a few minutes.
**Runbook:** `runbooks/high-error-rate.md`
**Lesson:** the fastest mitigation for a bad change is usually *rollback*, not debugging forward.
**Restore:** set it back to `"0"` and restart (or `make rollback`).

## Drill 2 — Latency regression

**Break it:**
```bash
kubectl -n quotes patch configmap quotes-api-config --type merge -p '{"data":{"FAULT_LATENCY_MS":"800"}}'
kubectl -n quotes rollout restart deployment/quotes-api
```
**Expect:** p99 jumps above 800 ms; `HighLatencyP99` fires. Notice: no errors — "up" isn't the same as "healthy".
Also watch what happens to throughput with gunicorn's fixed worker/thread count (saturation!).
**Runbook:** `runbooks/high-latency.md`

## Drill 3 — Dependency outage (Redis down)

**Break it:**
```bash
kubectl -n quotes scale statefulset redis --replicas=0
```
**Expect:** `/readyz` fails → pods become NotReady → removed from Service → requests return 503
from the ingress. `RedisUnreachable` fires. Liveness still passes, so pods are **not**
restart-looped — that's correct design.
**Runbook:** `runbooks/redis-down.md`
**Discuss:** is it better to fail readiness here, or stay ready and return 503 from the app? (There are tradeoffs — think about what happens when *every* pod is NotReady.)
**Restore:** `kubectl -n quotes scale statefulset redis --replicas=1`

## Drill 4 — OOMKilled pods

**Break it:** set the memory limit absurdly low.
```bash
kubectl -n quotes set resources deployment/quotes-api --limits=memory=40Mi --requests=memory=40Mi
```
**Expect:** pods restart repeatedly; `kubectl describe pod` shows `Last State: Terminated, Reason: OOMKilled`.
**Find it:** `kubectl -n quotes get pods`, `kubectl -n quotes describe pod <pod>`, `kubectl top pods -n quotes`.
**Restore:** `make rollback` or re-apply the overlay.

## Drill 5 — Crash loop from a bad image

**Break it:**
```bash
kubectl -n quotes set image deployment/quotes-api api=quotes-api:does-not-exist
```
**Expect:** new pods stuck in `ImagePullBackOff`/`ErrImagePull`. Because `maxUnavailable: 0`,
**old pods keep serving** — users see nothing. That's the rolling update protecting you.
**Find it:** `kubectl -n quotes rollout status deployment/quotes-api` (hangs), `kubectl -n quotes get events --sort-by=.lastTimestamp`.
**Restore:** `make rollback`

## Drill 6 — Node failure

**Break it:**
```bash
docker stop sre-lab-worker      # kind nodes are docker containers — this is a hard node failure
```
**Expect:** node goes `NotReady` after ~40s; pods on it are rescheduled after the
toleration timeout (~5 min by default). Did you lose availability? Did Redis move?
(Its PVC is node-local in kind, so it can't — a real lesson about storage.)
**Restore:** `docker start sre-lab-worker`

---

## Bonus drills
- Fill the Redis disk. Delete the namespace by "accident" and restore it from git (GitOps recovery).
- Push a commit that breaks YAML — does CI catch it before Argo CD sees it?
- Expire your error budget and enforce the policy in `01-slos.md`.
