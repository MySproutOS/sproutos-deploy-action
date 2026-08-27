#!/usr/bin/env bash
set -euo pipefail

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/sproutos-auth-test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

cat > "$test_dir/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
if [ -f "$MOCK_COUNT" ]; then count=$(cat "$MOCK_COUNT"); fi
count=$((count + 1))
printf '%s' "$count" > "$MOCK_COUNT"

if [ "$count" -eq 1 ]; then
  printf '%s' '{"value":"github-oidc-token"}'
  exit 0
fi

while [ "$#" -gt 0 ]; do
  if [ "$1" = "-d" ]; then
    shift
    printf '%s' "$1" > "$MOCK_PAYLOAD"
    break
  fi
  shift
done
printf '%s\n200\n' '{"token":"sproutos-deploy-token"}'
EOF
chmod +x "$test_dir/curl"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

authenticate() {
  : > "$test_dir/output"
  rm -f "$test_dir/count" "$test_dir/payload"
  MOCK_COUNT="$test_dir/count" \
  MOCK_PAYLOAD="$test_dir/payload" \
  PATH="$test_dir:$PATH" \
  GITHUB_OUTPUT="$test_dir/output" \
  API_URL="https://api.example.test" \
  ACTIONS_ID_TOKEN_REQUEST_URL="https://github.example.test/oidc?x=1" \
  ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
  PROJECT="$1" \
  "$script_dir/authenticate.sh" >/dev/null
}

authenticate ""
python3 -c 'import json,sys; assert "project" not in json.load(open(sys.argv[1]))' "$test_dir/payload"

authenticate "web-app"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["project"] == "web-app"' "$test_dir/payload"

grep -Fq "PROJECT: \${{ inputs.project }}" "$script_dir/../action.yml"
echo "authenticate tests passed"
