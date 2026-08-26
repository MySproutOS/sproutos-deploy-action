#!/usr/bin/env bash
#
# Upload the archive and ask SproutOS to release it.
#
# Two steps rather than one multipart POST: the upload goes straight to object storage through a
# pre-signed URL, so a 200 MB artifact never passes through the API. The release call is small and
# carries the digest, which is what lets the platform refuse an upload that did not arrive intact.
set -euo pipefail

upload=$(curl -sSf -X POST "${API_URL}/v1/deploy/upload-url" \
  -H "Authorization: Bearer ${SPROUTOS_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "{\"project\":\"${PROJECT}\",\"digest\":\"${DIGEST}\",\"preset\":\"${PRESET}\"}")

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
  static_upload=$(curl -sSf -X POST "${API_URL}/v1/deploy/static-upload-url" \
    -H "Authorization: Bearer ${SPROUTOS_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "{\"digest\":\"${STATIC_DIGEST}\"}")

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
  migration_upload=$(curl -sSf -X POST "${API_URL}/v1/deploy/upload-url" \
    -H "Authorization: Bearer ${SPROUTOS_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "{\"project\":\"${PROJECT}\",\"digest\":\"${MIGRATION_DIGEST}\",\"preset\":\"${PRESET}\"}")

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

released=$(curl -sSf -X POST "${API_URL}/v1/deploy/release" \
  -H "Authorization: Bearer ${SPROUTOS_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "$body")

deployment_id=$(echo "$released" | python3 -c 'import sys,json;print(json.load(sys.stdin)["deployment_id"])')
deploy_url=$(echo "$released" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("url",""))')

{
  echo "deployment-id=$deployment_id"
  echo "url=$deploy_url"
} >> "$GITHUB_OUTPUT"

echo "### Deployed to SproutOS" >> "$GITHUB_STEP_SUMMARY"
echo "" >> "$GITHUB_STEP_SUMMARY"
echo "| | |" >> "$GITHUB_STEP_SUMMARY"
echo "| --- | --- |" >> "$GITHUB_STEP_SUMMARY"
echo "| Project | \`${PROJECT}\` |" >> "$GITHUB_STEP_SUMMARY"
echo "| Environment | ${ENVIRONMENT} |" >> "$GITHUB_STEP_SUMMARY"
echo "| Deployment | \`${deployment_id}\` |" >> "$GITHUB_STEP_SUMMARY"
[ -n "$deploy_url" ] && echo "| URL | ${deploy_url} |" >> "$GITHUB_STEP_SUMMARY"

echo "released $deployment_id"
