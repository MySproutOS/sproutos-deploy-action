#!/usr/bin/env bash
#
# Turn a preset name into a directory, and refuse an unknown one.
set -euo pipefail

case "$PRESET" in
  # `.next/standalone` is what `output: "standalone"` produces: a self-contained server plus a
  # pruned `node_modules`. Without that setting the directory does not exist, which is the most
  # common way this action fails and why the error says so rather than "not found".
  next)    default=".next/standalone" ;;
  hono)    default="dist" ;;
  # An APK, not a directory of files. The platform signs it — the customer's workflow does not hold
  # a signing key, which is the whole point of SproutOS being developer of record.
  android) default="app/build/outputs/apk/release" ;;
  static)  default="dist" ;;
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

{
  echo "preset=$PRESET"
  echo "directory=$directory"
} >> "$GITHUB_OUTPUT"

echo "preset $PRESET from $directory"
