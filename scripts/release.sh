#!/usr/bin/env bash
#
# Upload the archive and ask SproutOS to release it.
#
# Two steps rather than one multipart POST: the upload goes straight to object storage through a
# pre-signed URL, so a 200 MB artifact never passes through the API. The release call is small and
# carries the digest, which is what lets the platform refuse an upload that did not arrive intact.
set -euo pipefail

# One place that calls the API and says what happened when it goes wrong.
#
# Every call here was `curl -sSf`, which on a failure prints `curl: (22) The requested URL returned
# error: 404` and discards the body. The body is where the platform explains itself — "no project
# named X in this repository", "that project is a group" — and `-f` threw it away, leaving a customer
# with a bare status code and no route to the cause. That is the same failure this repository keeps
# writing findings about: a check that fires and says nothing.
api() {
  local url="$1" payload="$2"
  local out status response
  # `-d` is always passed, never built into a conditional expansion: an unquoted `${x:+-d "$x"}`
  # word-splits on the spaces `json.dumps` puts after every comma, which would send a fragment of
  # the payload and produce a validation error about a field the caller did send.
  out=$(curl -sS -X POST "$url" \
    -H "Authorization: Bearer ${SPROUTOS_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    -w '\n%{http_code}')
  status=$(printf '%s' "$out" | tail -n1)
  response=$(printf '%s' "$out" | sed '$d')
  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    echo "::error::POST ${url} returned ${status}" >&2
    echo "::error::${response}" >&2
    return 1
  fi
  printf '%s' "$response"
}

upload=$(api "${API_URL}/v1/deploy/upload-url" \
  "{\"project\":\"${PROJECT}\",\"digest\":\"${DIGEST}\",\"preset\":\"${PRESET}\"}")

url=$(echo "$upload" | python3 -c 'import sys,json;print(json.load(sys.stdin)["url"])')
key=$(echo "$upload" | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])')

curl -sSf -X PUT "$url" --upload-file "$ARCHIVE" -H 'Content-Type: application/zip' > /dev/null
echo "uploaded"

# The assets, if the build produced any, on their own pre-signed URL into the shared tenant bucket.
#
# Uploaded *before* the release call and named in it, the same order and for the same reason as the
# application archive: a release that referenced assets not yet uploaded would publish a version
# whose stylesheets 404 for as long as the upload took.
static_field=""
if [ -n "${STATIC_ARCHIVE:-}" ] && [ -f "${STATIC_ARCHIVE}" ]; then
  static_upload=$(api "${API_URL}/v1/deploy/static-upload-url" \
    "{\"digest\":\"${STATIC_DIGEST}\"}")

  static_url=$(echo "$static_upload" | python3 -c 'import sys,json;print(json.load(sys.stdin)["url"])')
  static_key=$(echo "$static_upload" | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])')

  curl -sSf -X PUT "$static_url" --upload-file "$STATIC_ARCHIVE" \
    -H 'Content-Type: application/zip' > /dev/null

  static_field=",\"static_key\":\"${static_key}\",\"static_digest\":\"${STATIC_DIGEST}\""
  echo "uploaded assets"
fi

# The migrator, on the same pre-signed path as the application archive.
#
# Uploaded before the release names it, for the same reason as the assets: a release referencing a
# migration key that has not landed would queue a job whose first act is to fail.
migration_field=""
if [ -n "${MIGRATION_ARCHIVE:-}" ] && [ -f "${MIGRATION_ARCHIVE}" ]; then
  migration_upload=$(api "${API_URL}/v1/deploy/upload-url" \
    "{\"project\":\"${PROJECT}\",\"digest\":\"${MIGRATION_DIGEST}\",\"preset\":\"${PRESET}\"}")

  migration_url=$(echo "$migration_upload" | python3 -c 'import sys,json;print(json.load(sys.stdin)["url"])')
  migration_key=$(echo "$migration_upload" | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])')

  curl -sSf -X PUT "$migration_url" --upload-file "$MIGRATION_ARCHIVE" \
    -H 'Content-Type: application/zip' > /dev/null

  migration_field=",\"migration_key\":\"${migration_key}\""
  if [ -n "${MIGRATION_HANDLER:-}" ]; then
    migration_field="${migration_field},\"migration_handler\":\"${MIGRATION_HANDLER}\""
  fi
  echo "uploaded migrator"
fi

# Built with `json.dumps` rather than string interpolation.
#
# The commit message is the reason: it is arbitrary text containing quotes, backslashes and
# newlines, and interpolating it into a hand-written JSON string produces a body the API rejects as
# malformed — for the commits most worth reading.
body=$(
  PROJECT="$PROJECT" KEY="$key" DIGEST="$DIGEST" PRESET="$PRESET" ENVIRONMENT="$ENVIRONMENT" \
  COMMIT="$COMMIT" REF="$REF" MESSAGE="${MESSAGE:-}" RUNTIME="${RUNTIME:-}" HANDLER="${HANDLER:-}" \
  STATIC_FIELD="$static_field" MIGRATION_FIELD="$migration_field" python3 -c '
import json, os

body = {
    "project": os.environ["PROJECT"],
    "key": os.environ["KEY"],
    "digest": os.environ["DIGEST"],
    "preset": os.environ["PRESET"],
    "environment": os.environ["ENVIRONMENT"],
    "commit": os.environ["COMMIT"],
    "ref": os.environ["REF"],
}

# The subject only. A body would be the rest of the commit, which is not what a one-line deployment
# list is for, and the column is bounded anyway.
message = os.environ.get("MESSAGE", "").strip().splitlines()
if message:
    body["message"] = message[0][:500]

for key, value in (("runtime", "RUNTIME"), ("handler", "HANDLER")):
    if os.environ.get(value, "").strip():
        body[key] = os.environ[value].strip()

# The two fields the shell already assembled, folded in rather than re-derived.
for fragment in (os.environ.get("STATIC_FIELD", ""), os.environ.get("MIGRATION_FIELD", "")):
    if fragment:
        body.update(json.loads("{" + fragment.lstrip(",") + "}"))

print(json.dumps(body))
'
)

released=$(api "${API_URL}/v1/deploy/release" "$body")

deployment_id=$(echo "$released" | python3 -c 'import sys,json;print(json.load(sys.stdin)["deployment_id"])')
deploy_url=$(echo "$released" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("url",""))')

{
  echo "deployment-id=$deployment_id"
  echo "url=$deploy_url"
} >> "$GITHUB_OUTPUT"

# One redirect for the whole summary rather than eight (SC2129), which also means a partial write
# cannot leave half a table in the job summary.
{
  echo "### Deployed to SproutOS"
  echo ""
  echo "| | |"
  echo "| --- | --- |"
  echo "| Project | \`${PROJECT}\` |"
  echo "| Environment | ${ENVIRONMENT} |"
  echo "| Deployment | \`${deployment_id}\` |"
  [ -n "$deploy_url" ] && echo "| URL | ${deploy_url} |"
  [ -n "${MIGRATION_ARCHIVE:-}" ] && echo "| Migrations | ran before this release took traffic |"
  # `true` so the block's exit status is the redirect's, not the last conditional's — a deploy with
  # no URL yet would otherwise fail the step under `set -e`.
  true
} >> "$GITHUB_STEP_SUMMARY"

echo "released $deployment_id"
