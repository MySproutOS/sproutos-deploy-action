#!/usr/bin/env bash
#
# Collect the build output into one archive, and record its digest.
set -euo pipefail

archive="${RUNNER_TEMP}/sproutos-deploy.zip"

# Zip, not tar.gz.
#
# Lambda reads a zip and nothing else — `S3Key` pointing at a tarball fails with
# "Unzipped size must be smaller than…", which says nothing about the format being wrong. The
# android preset uses the same format because one archive format is simpler than two and `unzip` is
# as available as `tar` on any machine that can sign an APK.
if ! command -v zip >/dev/null 2>&1; then
  echo "::error::zip is required. On Debian/Ubuntu: apt-get install zip" >&2
  exit 1
fi

cd "$DIRECTORY"

# Reproducible: the same tree produces the same bytes and the same digest, so a redeploy of an
# unchanged build is visibly a no-op rather than looking like a new artifact every time.
#
# Zip has no `--sort`, so the file list is sorted and fed in explicitly — zip otherwise stores
# entries in readdir order, which differs between filesystems. And every entry's mtime is pinned,
# because zip records timestamps with no option to omit them; without this the digest changes on
# every checkout even when nothing in the tree did.
find . -exec touch -t 202001010000.00 {} +
find . -type f -o -type l | LC_ALL=C sort | zip -X -q -@ "$archive"

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
