#!/usr/bin/env bash
# Generates traffic so your dashboards have data and the HPA has a reason to scale.
# Usage: ./scripts/load-test.sh [base_url] [seconds] [concurrency]
# Uses 'hey' if installed (go install github.com/rakyll/hey@latest), else a curl loop.
set -uo pipefail
BASE="${1:-http://quotes.localhost}"
DURATION="${2:-120}"
CONCURRENCY="${3:-20}"

# Seed a few quotes
for q in "Hope is not a strategy" "Measure everything" "Automate the toil" "Blameless postmortems"; do
  curl -s -X POST -H 'Content-Type: application/json' -d "{\"text\":\"$q\",\"author\":\"SRE\"}" "$BASE/api/quotes" >/dev/null
done

if command -v hey >/dev/null; then
  hey -z "${DURATION}s" -c "$CONCURRENCY" "$BASE/api/quotes/random"
else
  echo "hey not found; using curl loop with $CONCURRENCY workers for ${DURATION}s"
  end=$((SECONDS + DURATION))
  for _ in $(seq 1 "$CONCURRENCY"); do
    ( while (( SECONDS < end )); do curl -s -o /dev/null "$BASE/api/quotes/random"; done ) &
  done
  wait
fi
