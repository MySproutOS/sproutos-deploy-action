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

released=$(curl -sSf -X POST "${API_URL}/v1/deploy/release" \
  -H "Authorization: Bearer ${SPROUTOS_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "{\"project\":\"${PROJECT}\",\"key\":\"${key}\",\"digest\":\"${DIGEST}\",\"preset\":\"${PRESET}\",\"environment\":\"${ENVIRONMENT}\",\"commit\":\"${COMMIT}\",\"ref\":\"${REF}\"${static_field}}")

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
