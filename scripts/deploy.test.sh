#!/usr/bin/env bash
set -euo pipefail

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/sproutos-deploy-wrapper-test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

cat > "$test_dir/sprout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" > "$TRACE"
printf '%s' "${SPROUTOS_DEPLOY_TOKEN:-}" > "$TOKEN_TRACE"
cat <<'JSON'
{"schema_version":1,"ok":true,"command":"deploy","data":{"deployment_id":"019d-test-deployment","url":"https://app.example.test","status":{"status":"ready"},"primary_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","static_digest":null,"migration_digest":null}}
JSON
EOF
chmod +x "$test_dir/sprout"

run_deploy() {
  : > "$test_dir/output"
  : > "$test_dir/summary"
  TRACE="$test_dir/trace" TOKEN_TRACE="$test_dir/token" PATH="$test_dir:$PATH" \
    GITHUB_OUTPUT="$test_dir/output" GITHUB_STEP_SUMMARY="$test_dir/summary" \
    SPROUTOS_DEPLOY_TOKEN="short-lived-repository-token" \
    API_URL="https://api.example.test" PRESET="$1" DIRECTORY="$2" \
    PROJECT="${3:-}" ENVIRONMENT="preview" TIMEOUT_SECONDS=37 \
    COMMIT="0123456789abcdef" REF="feature/test" MESSAGE=$'subject "quoted"\nbody' \
    RUNTIME="nodejs22.x" HANDLER="run.sh" MIGRATION_DIRECTORY="${MIGRATION_DIRECTORY:-}" \
    MIGRATION_HANDLER="${MIGRATION_HANDLER:-}" STATIC_PATHS="${STATIC_PATHS:-}" \
    VERSION_CODE="${VERSION_CODE:-}" "$script_dir/deploy.sh" >/dev/null
}

mkdir -p "$test_dir/site" "$test_dir/migrate"
STATIC_PATHS=$'public:\n.next/static:_next/static' \
MIGRATION_DIRECTORY="$test_dir/migrate" MIGRATION_HANDLER="migrate.handler" \
  run_deploy next "$test_dir/site" "web-app"

python3 - "$test_dir/trace" "$test_dir/site" "$test_dir/migrate" <<'PY'
import pathlib, sys

args = pathlib.Path(sys.argv[1]).read_bytes().split(b"\0")[:-1]
expected = [
    b"--json", b"--api-url", b"https://api.example.test", b"deploy", b"web-app",
    b"--path", sys.argv[2].encode(), b"--preset", b"next", b"--environment", b"preview",
    b"--timeout-seconds", b"37", b"--git-sha", b"0123456789abcdef", b"--git-ref",
    b"feature/test", b"--message", b'subject "quoted"\nbody', b"--runtime", b"nodejs22.x",
    b"--handler", b"run.sh", b"--migration-path", sys.argv[3].encode(),
    b"--migration-handler", b"migrate.handler", b"--static-path", b"public:",
    b"--static-path", b".next/static:_next/static",
]
assert args == expected, (args, expected)
PY
grep -Fxq 'short-lived-repository-token' "$test_dir/token"
grep -Fxq 'deployment-id=019d-test-deployment' "$test_dir/output"
grep -Fxq 'url=https://app.example.test' "$test_dir/output"
grep -Fxq 'digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$test_dir/output"

# Omitted project stays omitted: the argument after `deploy` must be --path. This is the trace that
# guards the multi-project repository safety boundary.
unset STATIC_PATHS MIGRATION_DIRECTORY MIGRATION_HANDLER
run_deploy static "$test_dir/site" ""
python3 - "$test_dir/trace" <<'PY'
import pathlib, sys
args = pathlib.Path(sys.argv[1]).read_bytes().split(b"\0")[:-1]
assert args[args.index(b"deploy") + 1] == b"--path", args
PY

# Android is a raw APK path, not the zip the old Action produced, and Gradle metadata can provide
# the required versionCode without changing the existing `directory` input.
mkdir -p "$test_dir/android"
printf 'raw-apk-bytes' > "$test_dir/android/app-release.apk"
cat > "$test_dir/android/output-metadata.json" <<'JSON'
{"elements":[{"versionCode":42,"outputFile":"app-release.apk"}]}
JSON
run_deploy android "$test_dir/android" "android-app"
python3 - "$test_dir/trace" "$test_dir/android" <<'PY'
import pathlib, sys
args = pathlib.Path(sys.argv[1]).read_bytes().split(b"\0")[:-1]
path_index = args.index(b"--path")
assert args[path_index + 1] == sys.argv[2].encode(), args
version_index = args.index(b"--version-code")
assert args[version_index + 1] == b"42", args
assert not any(value.endswith(b".zip") for value in args), args
PY

VERSION_CODE=43 run_deploy android "$test_dir/android/app-release.apk" "android-app"
python3 - "$test_dir/trace" "$test_dir/android/app-release.apk" <<'PY'
import pathlib, sys
args = pathlib.Path(sys.argv[1]).read_bytes().split(b"\0")[:-1]
assert args[args.index(b"--path") + 1] == sys.argv[2].encode(), args
assert args[args.index(b"--version-code") + 1] == b"43", args
PY

# The exact same source/action inputs produce the exact same CLI request trace. Deterministic
# artifact bytes and digests are then owned by the pinned sprout-core implementation.
cp "$test_dir/trace" "$test_dir/android-first-trace"
VERSION_CODE=43 run_deploy android "$test_dir/android/app-release.apk" "android-app"
cmp "$test_dir/android-first-trace" "$test_dir/trace"

echo "deploy wrapper contract tests passed"
