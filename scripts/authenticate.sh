#!/usr/bin/env bash
#
# Exchange a GitHub OIDC token for a short-lived SproutOS token.
#
# The point of OIDC here is that **nothing is stored**. A long-lived deploy secret in a customer's
# repository is a credential that outlives the person who added it, leaks through a fork's pull
# request workflow, and has to be rotated by hand. An OIDC token is minted per run, expires in
# minutes, and carries claims SproutOS verifies — repository, ref, and workflow — so a token from
# somebody else's repository cannot deploy this project.
set -euo pipefail

if [ -n "${SUPPLIED_TOKEN:-}" ]; then
  echo "::warning::Using a supplied token. GitHub OIDC needs no stored secret and is preferred."
  echo "token=$SUPPLIED_TOKEN" >> "$GITHUB_OUTPUT"
  exit 0
fi

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  echo "::error::No OIDC token available. Add this to the job:" >&2
  echo "::error::  permissions:" >&2
  echo "::error::    id-token: write" >&2
  echo "::error::    contents: read" >&2
  echo "::error::A workflow grants its own permissions; an action cannot request them for it." >&2
  exit 1
fi

# The audience binds the token to SproutOS. Without it GitHub issues one for the repository owner's
# default audience, which any service could accept — the claim we rely on is that this token was
# minted *for us*.
oidc=$(curl -sSf -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sproutos" | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')

# The project travels with the exchange, not just with the release.
#
# The token is scoped to one project and every later call reads the project *from the token*, so a
# repository holding more than one has to say which at this point or not at all. The platform
# refuses to guess rather than picking one: a wrong pick is a successful deploy onto the wrong
# service, and nothing downstream could notice.
payload=$(PROJECT="${PROJECT:-}" OIDC="$oidc" python3 -c '
import json, os
body = {"oidc_token": os.environ["OIDC"]}
project = os.environ.get("PROJECT", "").strip()
if project:
    body["project"] = project
print(json.dumps(body))
')

# No `-f`, deliberately.
#
# `curl -f` throws the response body away on an error status, which is exactly the body worth
# reading here: an ambiguous repository lists its candidate projects, and naming a group says so by
# name. With `-f` the customer gets `exit 22` and nothing to act on.
response=$(curl -sS -w '\n%{http_code}' -X POST "${API_URL}/v1/deploy/token" \
  -H 'Content-Type: application/json' -d "$payload")
status=$(printf '%s' "$response" | tail -n1)
body=$(printf '%s' "$response" | sed '$d')

if [ "$status" != "200" ]; then
  echo "::error::SproutOS refused the deploy token (HTTP $status)." >&2
  printf '%s\n' "$body" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    print(json.loads(raw).get("message", raw))
except Exception:
    print(raw)
' | sed 's/^/::error::/' >&2
  exit 1
fi

exchanged=$(printf '%s' "$body" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

# Masked so it cannot appear in a log, including one printed by a later step's `set -x`.
echo "::add-mask::$exchanged"
echo "token=$exchanged" >> "$GITHUB_OUTPUT"
echo "authenticated with GitHub OIDC"
