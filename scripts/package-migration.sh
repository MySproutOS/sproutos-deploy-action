#!/usr/bin/env bash
#
# Package the database migrator, if this project has one.
#
# Separate from the application archive because a migrator is a different program: a different entry
# point and usually a different dependency set. Bundling it into the function that serves requests
# would ship migration tooling into every cold start, forever.
#
# Silent and successful when there is nothing to package. A project with no migrations is the normal
# case for a static site, and an action that failed on it would make "no migrations" indistinguishable
# from "misconfigured".
set -euo pipefail

if [ -z "${MIGRATION_DIRECTORY:-}" ]; then
  echo "migration-archive=" >> "$GITHUB_OUTPUT"
  echo "migration-digest=" >> "$GITHUB_OUTPUT"
  echo "no migration-directory set; this deploy has no migration step"
  exit 0
fi

if [ ! -d "$MIGRATION_DIRECTORY" ]; then
  echo "::error::migration-directory '$MIGRATION_DIRECTORY' does not exist." >&2
  echo "::error::It must point at a *built* migrator, not at source." >&2
  exit 1
fi

archive="$RUNNER_TEMP/sproutos-migration.zip"
rm -f "$archive"

# `-r` from inside the directory, so paths in the archive are relative to it — Lambda resolves a
# handler against the archive root, and a directory prefix makes `index.handler` unfindable in a way
# whose only symptom is `Cannot find module 'index'`.
(cd "$MIGRATION_DIRECTORY" && zip -q -r "$archive" .)

digest=$(shasum -a 256 "$archive" | cut -d' ' -f1)

echo "migration-archive=$archive" >> "$GITHUB_OUTPUT"
echo "migration-digest=$digest" >> "$GITHUB_OUTPUT"
echo "packaged migrator from $MIGRATION_DIRECTORY ($digest)"
