#!/usr/bin/env bash
# Post-deploy smoke test. Exits non-zero if the service is not behaving.
# Usage: ./scripts/smoke-test.sh http://localhost:8080
set -euo pipefail
BASE="${1:-http://localhost:8080}"

check() {  # check <description> <expected status> <curl args...>
  local desc=$1 want=$2; shift 2
  local got
  got=$(curl -s -o /dev/null -w '%{http_code}' "$@")
  if [[ "$got" == "$want" ]]; then echo "PASS  $desc ($got)"; else echo "FAIL  $desc (want $want, got $got)"; exit 1; fi
}

# Retry readiness for up to 30s
for _ in $(seq 1 15); do
  [[ $(curl -s -o /dev/null -w '%{http_code}' "$BASE/readyz") == 200 ]] && break
  sleep 2
done

check "liveness"            200 "$BASE/healthz"
check "readiness"           200 "$BASE/readyz"
check "create quote"        201 -X POST -H 'Content-Type: application/json' \
                                -d '{"text":"Smoke test quote","author":"ci"}' "$BASE/api/quotes"
check "list quotes"         200 "$BASE/api/quotes"
check "random quote"        200 "$BASE/api/quotes/random"
check "validation works"    400 -X POST -H 'Content-Type: application/json' -d '{}' "$BASE/api/quotes"
check "metrics endpoint"    200 "$BASE/metrics"
echo "All smoke tests passed."
