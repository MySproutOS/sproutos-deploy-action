#!/usr/bin/env bash
set -euo pipefail

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/sproutos-wait-test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

cat > "$test_dir/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
if [ -f "$MOCK_COUNT" ]; then count=$(cat "$MOCK_COUNT"); fi
count=$((count + 1))
printf '%s' "$count" > "$MOCK_COUNT"
response=$(sed -n "${count}p" "$MOCK_RESPONSES")
printf '%s\n200\n' "$response"
EOF

cat > "$test_dir/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$test_dir/curl" "$test_dir/sleep"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

run_wait() {
  MOCK_COUNT="$test_dir/count" \
  MOCK_RESPONSES="$test_dir/responses" \
  PATH="$test_dir:$PATH" \
  API_URL="https://api.example.test" \
  SPROUTOS_TOKEN="test-token" \
  DEPLOYMENT_ID="019d-test" \
  POLL_INTERVAL_SECONDS=0 \
  "$script_dir/wait-for-deployment.sh"
}

printf '%s\n' \
  '{"status":"queued"}' \
  '{"status":"deploying"}' \
  '{"status":"ready","url":"https://app.example.test"}' > "$test_dir/responses"
ready=$(run_wait 2>"$test_dir/ready.err")
printf '%s' "$ready" | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"] == "ready"'

rm -f "$test_dir/count"
printf '%s\n' \
  '{"status":"error","failure_reason":"The database migration failed","migration_output":"ImportModuleError: missing migrate.js"}' \
  > "$test_dir/responses"
if run_wait >"$test_dir/failure.out" 2>"$test_dir/failure.err"; then
  echo "expected a failed deployment to fail the waiter" >&2
  exit 1
fi
grep -q "The database migration failed" "$test_dir/failure.err"
grep -q "ImportModuleError: missing migrate.js" "$test_dir/failure.err"

rm -f "$test_dir/count"
printf '%s\n' '{"status":"queued"}' > "$test_dir/responses"
if DEPLOY_TIMEOUT_SECONDS=0 run_wait >"$test_dir/timeout.out" 2>"$test_dir/timeout.err"; then
  echo "expected a queued deployment to time out" >&2
  exit 1
fi
grep -q "Timed out after 0s" "$test_dir/timeout.err"

echo "wait-for-deployment tests passed"
