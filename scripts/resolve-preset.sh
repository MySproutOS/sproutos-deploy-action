#!/usr/bin/env bash
#
# Turn a preset name into a directory, and refuse an unknown one.
set -euo pipefail

# Each preset resolves to a directory to run, and a list of directories to publish as assets.
#
# The static defaults are not a convenience. Next's standalone output **deliberately excludes**
# `.next/static` and `public/` — it assumes a CDN serves them — so a preset that collected only the
# standalone tree produced an application that returned 200 for every page and 404 for every
# stylesheet, script and font. The HTML was correct and the site was unstyled, which no health check
# and no `curl` of `/` will ever notice. It is the default precisely because a customer should never
# have to know that.
case "$PRESET" in
  # `.next/standalone` is what `output: "standalone"` produces: a self-contained server plus a
  # pruned `node_modules`. Without that setting the directory does not exist, which is the most
  # common way this action fails and why the error says so rather than "not found".
  next)
    default=".next/standalone"
    # `.next/static` is served at `/_next/static`, and `public/` at the root. Two sources, two
    # different URL prefixes — which is why this input is a list and not a path.
    static_default=$'.next/static:_next/static
public:'
    ;;
  hono)
    default="dist"
    static_default=""
    ;;
  # An APK, not a directory of files. The platform signs it — the customer's workflow does not hold
  # a signing key, which is the whole point of SproutOS being developer of record.
  android)
    default="app/build/outputs/apk/release"
    static_default=""
    ;;
  # Every file is an asset. There is no server, so publishing the tree to the CDN *is* the deploy.
  static)
    default="dist"
    static_default="dist:"
    ;;
  *)
    echo "::error::Unknown preset '$PRESET'. Supported: next, hono, android, static." >&2
    exit 1
    ;;
esac

directory="${DIRECTORY:-}"
[ -n "$directory" ] || directory="$default"

if [ ! -d "$directory" ]; then
  echo "::error::Nothing at '$directory'." >&2
  if [ "$PRESET" = "next" ] && [ "$directory" = ".next/standalone" ]; then
    echo "::error::Next.js writes this only with output: \"standalone\" in next.config. Add it, or set the 'directory' input." >&2
  else
    echo "::error::Build before this step, or set the 'directory' input." >&2
  fi
  exit 1
fi

# `none` publishes nothing, an explicit choice rather than an empty string that reads as "unset".
static_paths="${STATIC_PATHS:-}"
if [ "$static_paths" = "none" ]; then
  static_paths=""
elif [ -z "$static_paths" ]; then
  if [ "$PRESET" = "static" ]; then
    # For a static app the build directory is the asset tree. An explicit `directory` override
    # therefore has to move both; otherwise the package step looks for the preset's literal
    # `dist/`, silently publishes no archive, and the platform correctly refuses the release.
    static_paths="${directory}:"
  else
    static_paths="$static_default"
  fi
fi

# Warn rather than fail on a source that is not there. A `public/` directory is optional in a
# Next.js app and its absence is not an error — but a *misspelled* path is, and silence would make
# the two look identical.
kept=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  source="${line%%:*}"
  if [ -d "$source" ]; then
    kept="${kept}${line}"$'\n'
  else
    echo "::warning::No static assets at '$source'; skipping."
  fi
done <<< "$static_paths"

{
  echo "preset=$PRESET"
  echo "directory=$directory"
  echo "static-paths<<STATIC_EOF"
  printf '%s' "$kept"
  echo "STATIC_EOF"
} >> "$GITHUB_OUTPUT"

echo "preset $PRESET from $directory"
if [ -n "$kept" ]; then
  echo "publishing assets from: $(printf '%s' "$kept" | tr '\n' ' ')"
fi
