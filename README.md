# SRE Hands-On Project: Quotes API, End to End

You will take a small web service from "code on my laptop" to "running on Kubernetes,
deployed automatically by CI/CD, monitored with SLOs, with alerts and runbooks", then
break it on purpose and fix it like an on-call SRE.

Work through the phases in order. Each one ends with a checkpoint. Don't skip the
"Try this" sections — that's where the learning happens.

> **New: live website on AWS.** The app now has a web page at http://localhost:8080, and
> `docs/04-aws-live-website.md` walks you through putting it live on AWS with Terraform,
> CloudWatch logs, email alarms and a budget guard. Do it after Phase 2 (or any time after).

---

## What the project is

```
              developer pushes code
                       │
                       ▼
 ┌─────────────────────────── GitHub Actions (CI) ───────────────────────────┐
 │ lint → unit tests → build image → Trivy scan → validate k8s → e2e on kind │
 │                                        │ (main branch only)                │
 │                    push image to GHCR ─┴─ commit new tag to k8s/overlays/  │
 └────────────────────────────────────────────────────────────────────────────┘
                       │  (git is the source of truth)
                       ▼
            Argo CD (in your cluster) notices the commit and syncs
                       │
 ┌──────────────────── Kubernetes (kind, 3 nodes) ──────────────────────────┐
 │  Ingress (nginx) ──► Service ──► Deployment: quotes-api (2–10 pods, HPA)  │
 │                                        │                                  │
 │                                        ▼                                  │
 │                              StatefulSet: Redis (+ PVC)                    │
 │                                                                            │
 │  Prometheus scrapes /metrics ─► alert rules (SLO burn) ─► Alertmanager     │
 │  Grafana dashboard: traffic, errors, latency, saturation                   │
 └────────────────────────────────────────────────────────────────────────────┘
```

**The app** (`app/main.py`) is a tiny REST API that stores quotes in Redis. It's
deliberately simple so you can focus on *operating* it. It already has what a
production service needs:

| Endpoint | Purpose |
|---|---|
| `GET /api/quotes`, `POST /api/quotes`, `GET /api/quotes/random`, `DELETE /api/quotes/<id>` | The business logic |
| `GET /healthz` | **Liveness** — is the process alive? |
| `GET /readyz` | **Readiness** — can it reach Redis and take traffic? |
| `GET /metrics` | Prometheus metrics: request count, latency histogram, `redis_up` |

Plus JSON logs with request IDs, and **fault injection** (`FAULT_ERROR_RATE`,
`FAULT_LATENCY_MS`) so you can simulate incidents.

### Project layout

```
app/                    Python service, tests, Dockerfile
docker-compose.yml      Phase 1: run everything locally
k8s/base/               Kubernetes manifests (Deployment, Service, HPA, PDB, Redis, Ingress…)
k8s/overlays/           staging and production variations (Kustomize)
k8s/monitoring/         ServiceMonitor + PrometheusRule for the in-cluster Prometheus
monitoring/             Alert rules, Grafana dashboard, local Prometheus config
.github/workflows/      ci.yml (build/test/deploy) and promote.yml (prod release)
argocd/                 GitOps Application definitions
kind/                   Local 3-node cluster config
scripts/                Cluster setup, smoke test, load test
docs/                   SLOs, incident drills, runbooks, postmortem template
Makefile                Shortcuts for everything (run `make help`)
```

---

## Prerequisites

Install these (all free):

- **Docker Desktop** (or Docker Engine on Linux)
- **kubectl** — https://kubernetes.io/docs/tasks/tools/
- **kind** — https://kind.sigs.k8s.io/docs/user/quick-start/#installation
- **helm** — https://helm.sh/docs/intro/install/
- **Python 3.12**, **git**, a **GitHub account**
- Optional: `hey` load generator (`go install github.com/rakyll/hey@latest`)

Give Docker at least **4 CPUs and 8 GB RAM** (the monitoring stack is hungry).

---

## Phase 1 — Run it locally (Day 1)

**Goal:** understand the app before putting it in Kubernetes.

```bash
cd app
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
pytest -v                 # 8 tests should pass
cd ..
make compose-up           # API + Redis + Prometheus + Grafana in Docker
```

Try it:

```bash
curl -X POST localhost:8080/api/quotes -H 'Content-Type: application/json' \
     -d '{"text":"Hope is not a strategy","author":"Google SRE"}'
curl localhost:8080/api/quotes/random
curl localhost:8080/metrics | grep http_requests_total
docker compose logs api | tail      # see the JSON logs
```

Open Grafana at http://localhost:3000 (admin/admin) → Dashboards → SRE → *Quotes API*.
Run `./scripts/load-test.sh http://localhost:8080 60 10` and watch the graphs move.

**Try this**
1. `docker compose stop redis`. What do `/healthz` and `/readyz` return now? Why is it
   important that liveness does *not* check Redis? (Hint: what would Kubernetes do?)
2. In Prometheus (http://localhost:9090) run:
   `histogram_quantile(0.99, sum by (le)(rate(http_request_duration_seconds_bucket[1m])))`

✅ **Checkpoint:** you can explain the difference between liveness and readiness, and
you've seen a metric go from `/metrics` → Prometheus → Grafana.

`make compose-down` when done.

---

## Phase 2 — Containers properly (Day 1)

Read `app/Dockerfile`. Things to understand:

- **Multi-stage build** — dependencies are installed in one stage, only the result is
  copied to the final image → smaller image, smaller attack surface.
- **Non-root user** (UID 10001).
- **gunicorn** instead of Flask's dev server, with `--graceful-timeout` so in-flight
  requests finish when Kubernetes sends SIGTERM.

```bash
docker build -t quotes-api:local app
docker images quotes-api                 # check the size
docker run --rm quotes-api:local id      # should NOT be root
```

✅ **Checkpoint:** you can explain why each line of the Dockerfile exists.

---

## Phase 3 — Kubernetes (Days 2–3)

**Goal:** run the service on a real (local) multi-node cluster.

```bash
make cluster          # ~5–10 min: kind cluster, ingress, metrics-server, Prometheus stack
make deploy-local     # builds image, loads it into kind, applies k8s/overlays/production
make status
```

Add this line to your hosts file (`/etc/hosts` on Mac/Linux,
`C:\Windows\System32\drivers\etc\hosts` on Windows) if `quotes.localhost` doesn't resolve:

```
127.0.0.1 quotes.localhost staging.quotes.localhost
```

```bash
make smoke            # runs scripts/smoke-test.sh against http://quotes.localhost
```

Now read every file in `k8s/base/` — each has comments. Key concepts:

| File | Concept | Why an SRE cares |
|---|---|---|
| `deployment.yaml` | replicas, rolling update (`maxUnavailable: 0`), probes, resource requests/limits, `preStop` | Zero-downtime deploys; self-healing; capacity planning |
| `service.yaml` | Stable virtual IP that load-balances to *ready* pods | Readiness probe failures remove pods from here |
| `hpa.yaml` | Autoscaling on CPU | Handles traffic spikes |
| `pdb.yaml` | PodDisruptionBudget | Node drains/upgrades can't take all pods down |
| `redis.yaml` | StatefulSet + PersistentVolumeClaim | State that survives pod restarts |
| `ingress.yaml` | HTTP routing from outside the cluster | The front door |
| `networkpolicy.yaml` | Only API pods can reach Redis | Least privilege |
| `configmap.yaml` | Config outside the image | Change behaviour without rebuilding |
| `overlays/*` | Kustomize: same base, different env settings | One set of manifests, many environments |

**Try this (these are classic interview questions — do them, don't just read them)**

```bash
# 1. Self-healing: kill a pod and watch it come back
kubectl -n quotes delete pod -l app=quotes-api --wait=false; kubectl -n quotes get pods -w

# 2. Zero-downtime rollout: run load in one terminal, deploy in another
make load
kubectl -n quotes rollout restart deployment/quotes-api && kubectl -n quotes rollout status deployment/quotes-api
#    Did any requests fail? (check the Grafana error panel)

# 3. Rollback
kubectl -n quotes rollout history deployment/quotes-api
make rollback

# 4. Autoscaling: generate heavy load and watch replicas climb
./scripts/load-test.sh http://quotes.localhost 300 50 &
kubectl -n quotes get hpa -w

# 5. Node failure: drain a worker. PDB + topology spread should keep you serving.
kubectl get nodes
kubectl drain sre-lab-worker --ignore-daemonsets --delete-emptydir-data
kubectl -n quotes get pods -o wide
kubectl uncordon sre-lab-worker

# 6. Persistence: add quotes, delete the Redis pod, check the quotes are still there
kubectl -n quotes delete pod redis-0
```

✅ **Checkpoint:** you can explain what happens, step by step, from `kubectl apply` to a
pod receiving traffic, and you've done every exercise above.

---

## Phase 4 — CI pipeline (Day 4)

**Goal:** every change is automatically tested, built, scanned, and deployed to a
throwaway cluster before it's allowed anywhere near production.

1. Create an empty GitHub repo called `sre-quotes-project`.
2. Push this project:
   ```bash
   git init && git add . && git commit -m "initial commit"
   git branch -M main
   git remote add origin https://github.com/YOUR_GITHUB_USER/sre-quotes-project.git
   git push -u origin main
   ```
3. Watch **Actions** in GitHub. Read `.github/workflows/ci.yml` while it runs.

What each CI job does:

| Job | What it proves |
|---|---|
| `test` | Code passes lint (`ruff`) and unit tests (`pytest`) |
| `validate-k8s` | Both overlays render and are valid Kubernetes (`kubeconform`) |
| `build-and-scan` | Image builds; **Trivy** finds no CRITICAL vulnerabilities |
| `e2e` | Spins up kind *inside the CI runner*, deploys, runs the smoke test |
| `publish` | (main only) Pushes the image to GHCR and commits the new tag to `k8s/overlays/staging` |

4. After the first successful run on `main`, go to your GitHub profile → **Packages** →
   `quotes-api` → Package settings → **Change visibility to Public** (so your kind
   cluster can pull it without credentials).

**Try this**
- Open a pull request that breaks a test (e.g. change a status code in `main.py`).
  Watch CI block it. That's a quality gate.
- Notice the `publish` job commits with `[skip ci]` — why? (Infinite loop otherwise.)

✅ **Checkpoint:** a push to `main` results in a new image in GHCR and a bot commit
changing `newTag` in `k8s/overlays/staging/kustomization.yaml`.

---

## Phase 5 — CD with GitOps / Argo CD (Day 5)

**Goal:** the cluster deploys itself from git. Nobody runs `kubectl apply` by hand.

```bash
make argocd                                    # installs Argo CD, prints admin password
# edit argocd/applications.yaml: replace YOUR_GITHUB_USER (2 places)
kubectl apply -f argocd/applications.yaml
kubectl -n argocd port-forward svc/argocd-server 8443:443   # https://localhost:8443, user: admin
```

Now the full loop works:

1. Change something visible — e.g. add a field to the `/healthz` response.
2. `git commit && git push`
3. CI tests, builds, pushes the image, bumps the staging tag.
4. Argo CD sees the commit and rolls staging out. Check `curl http://staging.quotes.localhost/healthz`.
5. Promote: GitHub → Actions → **Promote to production** → Run workflow, give a reason.
6. Argo CD rolls out production.

**Set up an approval gate:** GitHub repo → Settings → Environments → New environment
`production` → add yourself as a *Required reviewer*. Now prod deploys need a human
click — this is change management.

**Try this**
- `kubectl -n quotes scale deployment quotes-api --replicas=1`. Watch Argo CD undo it
  (`selfHeal`). This is *drift correction*.
- Roll back the GitOps way: `git revert` the bad deploy commit and push.

✅ **Checkpoint:** you shipped a code change to production without touching kubectl.

> Note: the first time Argo CD takes over, the production overlay will switch from the
> locally-built `quotes-api:<tag>` to your GHCR image. That's expected.

---

## Phase 6 — Observability, SLOs, alerting (Days 6–7)

Read **`docs/01-slos.md`** first. Then:

```bash
make grafana        # http://localhost:3000  (admin/admin) → Dashboards → "Quotes API - Golden Signals"
make prometheus     # http://localhost:9090  → Status → Rules / Alerts
make alertmanager   # http://localhost:9093
make load           # give the graphs something to show
```

Things to understand in `monitoring/alerts/alert-rules.yml`:
- **Recording rules** precompute the SLI (error ratio, p99 latency).
- **Burn-rate alerting**: `HighErrorBudgetBurn` pages only when the error budget is
  being consumed ~14× faster than sustainable — not on every blip. This is how
  Google-style SRE teams avoid alert fatigue.
- Every alert links to a **runbook** in `docs/runbooks/`.

**Try this**
- In Prometheus, query `sli:error_ratio:rate5m` and `sli:latency_p99:5m`.
- Calculate: with a 99.5% SLO over 30 days, how many minutes of full outage is your
  error budget? (Answer in `docs/01-slos.md`.)
- Bonus: configure Alertmanager to send to a Slack webhook or email.

✅ **Checkpoint:** you can explain SLI vs SLO vs SLA, and what an error budget is used for.

---

## Phase 7 — Incident drills (Days 8–10)

This is the most valuable part. Follow **`docs/02-incident-drills.md`** — six realistic
incidents (bad deploy, latency regression, Redis outage, OOMKills, crash loop, node
failure). For each one:

1. Break it using the instructions.
2. Notice it **from the dashboards/alerts only** (pretend you didn't break it).
3. Follow the runbook to diagnose and mitigate.
4. Write a short postmortem using **`docs/03-postmortem-template.md`**.

✅ **Checkpoint:** you have at least 3 written postmortems. These are great material
for interviews ("tell me about an incident you handled").

---

## Phase 8 — Level up (pick any)

- **Terraform**: provision a real cluster (AWS EKS / GCP GKE / Azure AKS free tier) and
  point Argo CD at it. Destroy it when done to avoid charges.
- **Helm**: convert `k8s/base` into a Helm chart.
- **Canary deploys** with Argo Rollouts: shift 10% → 50% → 100% based on error rate.
- **Secrets**: add a Redis password with Sealed Secrets or External Secrets Operator.
- **Logging**: add Loki + Promtail so you can search logs in Grafana by `request_id`.
- **Tracing**: add OpenTelemetry and Tempo/Jaeger.
- **Chaos engineering**: install Chaos Mesh and schedule random pod kills.
- **Policy**: Kyverno policy that rejects pods without resource limits.

---

## Putting it on your résumé

> Built and operated a containerized Python service on Kubernetes with GitOps (Argo CD)
> and GitHub Actions CI/CD (unit/e2e tests, Trivy image scanning, staged promotion with
> approval gates). Defined SLOs with multi-window burn-rate alerting in Prometheus,
> built Grafana golden-signal dashboards, wrote runbooks, and ran incident simulations
> with blameless postmortems. Configured HPA, PDBs, probes, and topology spread for
> zero-downtime deploys and node-failure tolerance.

Be ready to demo it and explain *why* each piece exists — that matters more than the
list of tools.

## Cleanup

```bash
make destroy        # deletes the kind cluster
make compose-down   # stops the Docker Compose stack
```
