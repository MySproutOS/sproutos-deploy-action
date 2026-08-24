#!/usr/bin/env bash
#
# Collect the build output into one archive, and record its digest.
set -euo pipefail

archive="${RUNNER_TEMP}/sproutos-deploy.tar.gz"

# GNU tar, explicitly checked.
#
# The reproducibility below needs `--sort` and `--mtime`, which BSD tar does not have — so on macOS
# this fails with "Option --sort=name is not supported", `set -e` aborts, and any check that reads
# the digest afterwards compares two empty strings and calls them equal. That happened. GitHub
# runners have GNU tar; a laptop may not, and being told which is the difference between a skipped
# test and a green one that tested nothing.
if tar --version 2>/dev/null | head -1 | grep -q 'GNU tar'; then
  TAR=tar
elif command -v gtar >/dev/null 2>&1; then
  TAR=gtar
else
  echo "::error::GNU tar is required (BSD tar has no --sort/--mtime, so archives would not be reproducible)." >&2
  echo "::error::On macOS: brew install gnu-tar" >&2
  exit 1
fi

# `--sort=name` and a fixed mtime make the archive reproducible: the same tree produces the same
# bytes and the same digest, so a redeploy of an unchanged build is visibly a no-op rather than
# looking like a new artifact every time.
"$TAR" --sort=name \
    --mtime='UTC 2020-01-01' \
    --owner=0 --group=0 --numeric-owner \
    -czf "$archive" -C "$DIRECTORY" .

digest=$(shasum -a 256 "$archive" | cut -d' ' -f1)
size=$(wc -c < "$archive" | tr -d ' ')

# Belt: an empty digest means something above failed quietly, and writing it would hand the platform
# a checksum it cannot verify anything against.
if [ -z "$digest" ] || [ "$size" -eq 0 ]; then
  echo "::error::Packaging produced nothing." >&2
  exit 1
fi

# Lambda's zip limit is 250 MB unzipped including layers, and a standalone Next.js tree with sharp
# gets close. Refused here with the number, rather than by AWS several minutes later with a message
# about a deployment package.
if [ "$size" -gt 209715200 ]; then
  echo "::error::Archive is $((size / 1048576)) MB, over the 200 MB limit." >&2
  echo "::error::Trim the build output, or ask SproutOS to switch this project to a container image." >&2
  exit 1
fi

{
  echo "archive=$archive"
  echo "digest=$digest"
} >> "$GITHUB_OUTPUT"

echo "packaged $((size / 1024)) KB, sha256:${digest:0:16}…"
