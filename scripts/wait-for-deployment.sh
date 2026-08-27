#!/usr/bin/env bash
set -euo pipefail

: "${API_URL:?API_URL is required}"
: "${SPROUTOS_TOKEN:?SPROUTOS_TOKEN is required}"
: "${DEPLOYMENT_ID:?DEPLOYMENT_ID is required}"

poll_interval=${POLL_INTERVAL_SECONDS:-5}
timeout=${DEPLOY_TIMEOUT_SECONDS:-1200}
deadline=$((SECONDS + timeout))
previous_status=""

while true; do
  if ! out=$(curl -sS -X GET "${API_URL}/v1/deploy/deployments/${DEPLOYMENT_ID}" \
    -H "Authorization: Bearer ${SPROUTOS_TOKEN}" \
    -w '\n%{http_code}'); then
    echo "::error::Could not read SproutOS deployment ${DEPLOYMENT_ID}." >&2
    exit 1
  fi

  http_status=$(printf '%s' "$out" | tail -n1)
  response=$(printf '%s' "$out" | sed '$d')
  if [ "$http_status" -lt 200 ] || [ "$http_status" -ge 300 ]; then
    echo "::error::GET ${API_URL}/v1/deploy/deployments/${DEPLOYMENT_ID} returned ${http_status}" >&2
    echo "::error::${response}" >&2
    exit 1
  fi

  status=$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')
  if [ "$status" != "$previous_status" ]; then
    echo "SproutOS deployment ${DEPLOYMENT_ID}: ${status}" >&2
    previous_status=$status
  fi

  case "$status" in
    ready)
      printf '%s' "$response"
      exit 0
      ;;
    error|torn_down)
      printf '%s' "$response" | python3 -c '
import json, sys

deployment = json.load(sys.stdin)
reason = deployment.get("failure_reason") or "Deployment ended as {}.".format(deployment["status"])

def command_value(value):
    return str(value).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")

print(f"::error title=SproutOS deployment failed::{command_value(reason)}", file=sys.stderr)
output = deployment.get("migration_output")
if output:
    print("::group::Migration output", file=sys.stderr)
    print(output, file=sys.stderr)
    print("::endgroup::", file=sys.stderr)
'
      exit 1
      ;;
    queued|building|deploying)
      ;;
    *)
      echo "::error::SproutOS returned unknown deployment status '${status}'." >&2
      exit 1
      ;;
  esac

  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "::error::Timed out after ${timeout}s waiting for SproutOS deployment ${DEPLOYMENT_ID}. Last status: ${status}." >&2
    exit 1
  fi
  sleep "$poll_interval"
done
