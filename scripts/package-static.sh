#!/usr/bin/env bash
#
# Collect the static assets into their own archive, keyed by the URL prefix each set is served at.
#
# Separate from the application archive on purpose. These bytes are served by the CDN and never by
# the function, so shipping them inside it would pay twice: once against the 200 MB limit, and again
# on every cold start, to deliver files a browser could have fetched from an edge.
set -euo pipefail

archive="${RUNNER_TEMP}/sproutos-static.zip"
staging="${RUNNER_TEMP}/sproutos-static"

rm -rf "$staging" "$archive"
mkdir -p "$staging"

if [ -z "${STATIC_PATHS:-}" ]; then
  # Nothing to publish is a normal outcome — an API has no assets — so this is an empty output and
  # not a failure. `release.sh` omits the field entirely when this is unset.
  echo "no static assets to publish"
  exit 0
fi

count=0
while IFS= read -r line; do
  [ -n "$line" ] || continue

  # `source:prefix`, where a missing prefix means the root. The prefix is a URL path, not a file
  # path, which is why `public:` and `.next/static:_next/static` both make sense: the same kind of
  # directory served at two different places.
  source="${line%%:*}"
  prefix=""
  case "$line" in
    *:*) prefix="${line#*:}" ;;
  esac

  # A prefix that escapes its own directory would write outside the project's namespace in a shared
  # bucket. Refused here rather than trusted to the platform, because an action that produces a
  # malformed archive should say so in the customer's own logs.
  case "$prefix" in
    /*|*..*)
      echo "::error::Static prefix '$prefix' must be relative and must not contain '..'." >&2
      exit 1
      ;;
  esac

  destination="$staging"
  [ -z "$prefix" ] || destination="$staging/$prefix"
  mkdir -p "$destination"
  cp -R "$source/." "$destination/"
  count=$((count + 1))
done <<< "$STATIC_PATHS"

if [ "$count" -eq 0 ]; then
  echo "no static assets to publish"
  exit 0
fi

cd "$staging"

# Reproducible, for the same reason the application archive is: an unchanged build should produce an
# unchanged digest, so a redeploy is visibly a no-op rather than a new artifact every time.
find . -exec touch -t 202001010000.00 {} +
find . -type f -o -type l | LC_ALL=C sort | zip -X -q -@ "$archive"

digest=$(shasum -a 256 "$archive" | cut -d' ' -f1)
size=$(wc -c < "$archive" | tr -d ' ')

if [ -z "$digest" ] || [ "$size" -eq 0 ]; then
  echo "::error::Static packaging produced nothing from $count path(s)." >&2
  exit 1
fi

{
  echo "static-archive=$archive"
  echo "static-digest=$digest"
} >> "$GITHUB_OUTPUT"

echo "packaged $((size / 1024)) KB of assets from $count path(s), sha256:${digest:0:16}…"
