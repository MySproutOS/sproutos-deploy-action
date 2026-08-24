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

curl -sSf -X PUT "$url" --upload-file "$ARCHIVE" -H 'Content-Type: application/gzip' > /dev/null
echo "uploaded"

released=$(curl -sSf -X POST "${API_URL}/v1/deploy/release" \
  -H "Authorization: Bearer ${SPROUTOS_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "{\"project\":\"${PROJECT}\",\"key\":\"${key}\",\"digest\":\"${DIGEST}\",\"preset\":\"${PRESET}\",\"environment\":\"${ENVIRONMENT}\",\"commit\":\"${COMMIT}\",\"ref\":\"${REF}\"}")

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
