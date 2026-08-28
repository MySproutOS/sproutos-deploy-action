#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
action="$root/action.yml"

section_keys() {
  local start=$1 end=$2
  awk -v start="$start" -v end="$end" '
    $0 == start ":" { inside=1; next }
    $0 == end ":" { inside=0 }
    inside && /^  [a-z0-9-]+:$/ { value=$0; sub(/^  /, "", value); sub(/:$/, "", value); print value }
  ' "$action"
}

inputs=$(section_keys inputs outputs)
for existing in preset directory project environment api-url runtime handler migration-directory \
  migration-handler static-paths token; do
  printf '%s\n' "$inputs" | grep -Fxq "$existing" || {
    echo "existing Action input '$existing' was removed" >&2
    exit 1
  }
done

outputs=$(section_keys outputs runs)
for existing in url deployment-id; do
  printf '%s\n' "$outputs" | grep -Fxq "$existing" || {
    echo "existing Action output '$existing' was removed" >&2
    exit 1
  }
done

# These strings are intentional contract assertions, not implementation-style checks: replacing an
# omitted project with a repository name or handing the token to the general credential variable
# would make an ambiguous monorepo silently deploy the wrong child.
# shellcheck disable=SC2016 # Literal GitHub expression is the value under test.
grep -Fq 'PROJECT: ${{ inputs.project }}' "$action"
# shellcheck disable=SC2016 # Literal GitHub expression is the value under test.
grep -Fq 'SPROUTOS_DEPLOY_TOKEN: ${{ steps.auth.outputs.token }}' "$action"
if grep -Fq 'inputs.project || github.event.repository.name' "$action"; then
  echo "project omission was replaced with a guessed repository name" >&2
  exit 1
fi

echo "Action input/output and OIDC ambiguity contract tests passed"
