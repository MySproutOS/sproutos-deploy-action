#!/usr/bin/env bash
# Translate the stable Action inputs to the stable sprout CLI contract.
set -euo pipefail

: "${SPROUTOS_DEPLOY_TOKEN:?SPROUTOS_DEPLOY_TOKEN is required}"
: "${API_URL:?API_URL is required}"
: "${PRESET:?PRESET is required}"
: "${DIRECTORY:?DIRECTORY is required}"
: "${ENVIRONMENT:?ENVIRONMENT is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

command=(sprout --json --api-url "$API_URL" deploy)

# Omission is significant. A repository-bound token may select the only project associated with
# the repository, while an ambiguous repository must be refused by the platform. Substituting the
# repository name here would bypass that safety boundary.
if [ -n "${PROJECT:-}" ]; then
  command+=("$PROJECT")
fi

command+=(--path "$DIRECTORY" --preset "$PRESET" --environment "$ENVIRONMENT")
command+=(--timeout-seconds "${TIMEOUT_SECONDS:-1200}")

append_value() {
  local flag="$1" value="$2"
  [ -z "$value" ] || command+=("$flag" "$value")
}

append_value --git-sha "${COMMIT:-}"
append_value --git-ref "${REF:-}"
append_value --message "${MESSAGE:-}"
append_value --runtime "${RUNTIME:-}"
append_value --handler "${HANDLER:-}"
append_value --migration-path "${MIGRATION_DIRECTORY:-}"
append_value --migration-handler "${MIGRATION_HANDLER:-}"

while IFS= read -r mapping; do
  [ -z "$mapping" ] || command+=(--static-path "$mapping")
done <<< "${STATIC_PATHS:-}"

if [ "$PRESET" = "android" ]; then
  version_code="${VERSION_CODE:-}"
  if [ -z "$version_code" ] && [ -d "$DIRECTORY" ]; then
    metadata="$DIRECTORY/output-metadata.json"
    if [ -f "$metadata" ]; then
      if ! version_code=$(python3 - "$metadata" <<'PY'
import json, pathlib, sys

elements = json.loads(pathlib.Path(sys.argv[1]).read_text()).get("elements", [])
codes = {element.get("versionCode") for element in elements if element.get("outputFile", "").endswith(".apk")}
if len(codes) == 1 and next(iter(codes)) is not None:
    print(next(iter(codes)))
PY
      ); then
        echo "::error::Could not read Android versionCode from '$metadata'." >&2
        exit 1
      fi
    fi
  fi
  if ! [[ "$version_code" =~ ^[1-9][0-9]*$ ]]; then
    echo "::error::Android deploys need version-code, or one unambiguous Gradle output-metadata.json next to the APK." >&2
    exit 1
  fi
  command+=(--version-code "$version_code")
fi

# JSON stdout is captured exactly once. Progress stays on stderr by the CLI contract, and the
# repository deploy token is available only to this process through its dedicated environment
# variable; it is never accepted as a general SPROUTOS_TOKEN or written to disk.
result=$("${command[@]}")
deployment_id=$(python3 -c '
import json, sys
document = json.load(sys.stdin)
assert document.get("schema_version") == 1 and document.get("ok") is True and document.get("command") == "deploy", "unexpected sprout deploy output contract"
value = document.get("data", {}).get("deployment_id")
assert isinstance(value, str) and value, "sprout deploy returned no deployment id"
print(value)
' <<< "$result")
url=$(python3 -c '
import json, sys
document = json.load(sys.stdin)
value = document.get("data", {}).get("url") or ""
assert isinstance(value, str) and "\n" not in value and "\r" not in value, "invalid deployment URL"
print(value)
' <<< "$result")
digest=$(python3 -c '
import json, re, sys
value = json.load(sys.stdin).get("data", {}).get("primary_digest") or ""
assert re.fullmatch(r"sha256:[0-9a-f]{64}", value), "invalid primary artifact digest"
print(value)
' <<< "$result")

printf 'deployment-id=%s\nurl=%s\ndigest=%s\n' "$deployment_id" "$url" "$digest" >> "$GITHUB_OUTPUT"

{
  echo "### Deployed to SproutOS"
  echo
  echo "| | |"
  echo "| --- | --- |"
  [ -z "${PROJECT:-}" ] || echo "| Project | \`${PROJECT}\` |"
  echo "| Environment | ${ENVIRONMENT} |"
  echo "| Deployment | \`${deployment_id}\` |"
  [ -z "$url" ] || echo "| URL | ${url} |"
  [ -z "${MIGRATION_DIRECTORY:-}" ] || echo "| Migrations | ran before this release took traffic |"
  true
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

echo "deployed $deployment_id"
