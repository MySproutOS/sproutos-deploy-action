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

workspace=$(pwd)
cd "$DIRECTORY"

# The startup script, for presets that produce a web server rather than a Lambda handler.
#
# `next` and `hono` build a program that listens on a port. Lambda cannot invoke that directly, so
# the platform publishes those functions with the Lambda Web Adapter attached; the adapter starts
# the server and forwards each invocation to it as an ordinary HTTP request. The adapter's contract
# is that the function's handler is a script at the archive root, so it has to be written here —
# the platform never opens the archive.
#
# Written into the build output *before* packaging, so the digest covers it: an archive whose
# entrypoint is not part of what was checksummed is an archive that can change without the digest
# moving.
case "$PRESET" in
  next|hono)
    entry=""
    for candidate in server.js index.js index.mjs dist/index.js; do
      if [ -f "$candidate" ]; then entry="$candidate"; break; fi
    done
    # A monorepo's Next standalone tree nests the server under the app's path — `apps/web/server.js`
    # rather than `server.js` — because standalone mirrors the workspace layout. Searched only when
    # the root has nothing, and refused when it is ambiguous: picking one of two servers would
    # deploy the wrong application and look like a working deploy.
    if [ -z "$entry" ]; then
      matches=$(find . -name server.js -not -path '*/node_modules/*' | LC_ALL=C sort)
      count=$(printf '%s' "$matches" | grep -c . || true)
      if [ "$count" -eq 1 ]; then
        entry="${matches#./}"
      elif [ "$count" -gt 1 ]; then
        echo "::error::Found $count server.js files in '$DIRECTORY' and cannot tell which to run:" >&2
        echo "$matches" >&2
        echo "::error::Set the 'handler' input to the one to start, e.g. handler: apps/web/server.js" >&2
        exit 1
      fi
    fi
    if [ -z "$entry" ]; then
      echo "::error::No server entry point found in '$DIRECTORY' for the '$PRESET' preset." >&2
      echo "::error::Expected server.js, index.js or index.mjs. Set the 'directory' input if the build output is elsewhere." >&2
      exit 1
    fi
    # Next's standalone output **excludes** `.next/static` and `public/` — it assumes a CDN serves
    # them — so a function built from the standalone tree alone answers 200 for every page and 404
    # for every stylesheet, script and font. The HTML is correct and the site is unstyled, which no
    # health check and no `curl` of `/` will notice.
    #
    # The action already uploads them separately, and the platform accepts a `static_key` it never
    # reads: nothing unpacks that archive and nothing serves it. Until something does, copying them
    # in is Next's own documented instruction and needs no CDN at all.
    #
    # Into the *server's own directory*, not the tree root: a workspace build nests the server under
    # the app's path, and it resolves both of these relative to itself.
    if [ "$PRESET" = "next" ]; then
      app_source="$workspace/${DIRECTORY%/.next/standalone}"
      entry_dir=$(dirname "$entry")
      if [ -d "$app_source/.next/static" ]; then
        mkdir -p "$entry_dir/.next"
        cp -R "$app_source/.next/static" "$entry_dir/.next/static"
        echo "bundled .next/static"
      else
        echo "::warning::No .next/static at '$app_source'; the site will render unstyled." >&2
      fi
      if [ -d "$app_source/public" ]; then
        cp -R "$app_source/public" "$entry_dir/public"
        echo "bundled public/"
      fi
    fi

    # `exec` so the server replaces the shell and receives Lambda's signals directly.
    printf '#!/bin/sh\nset -e\nexec node %s\n' "$entry" > run.sh
    chmod +x run.sh
    echo "entrypoint: node $entry"
    ;;
esac

# Reproducible: the same tree produces the same bytes and the same digest, so a redeploy of an
# unchanged build is visibly a no-op rather than looking like a new artifact every time.
#
# Zip has no `--sort`, so the file list is sorted and fed in explicitly — zip otherwise stores
# entries in readdir order, which differs between filesystems. And every entry's mtime is pinned,
# because zip records timestamps with no option to omit them; without this the digest changes on
# every checkout even when nothing in the tree did.
# `-L`, and this is the difference between a working deploy and a 234 KB archive.
#
# A pnpm workspace links dependencies rather than copying them, so Next's standalone tree contains
# `node_modules/next` as a **symlink to a directory**. `find . -type f` does not descend into one,
# and `find . -type l` lists the link itself — which zip stores as a single entry with nothing
# inside. The archive builds, uploads and publishes, and the function dies on
# `Cannot find module 'next'` from a tree that visibly contains it.
#
# `-L` follows symlinks while descending, so the files inside a linked package are enumerated at the
# paths the application will look for them.
find -L . -exec touch -t 202001010000.00 {} + 2>/dev/null || true
# A broken symlink is not `-type f` under `-L`, so it is excluded here without a second test —
# `-xtype` would have done it explicitly and does not exist in BSD find, which is how a check like
# that ends up passing in CI and failing for anyone testing on a Mac.
find -L . -type f | LC_ALL=C sort | zip -X -q -@ "$archive"

# Compiled native modules built for the wrong machine.
#
# SproutOS publishes customer functions on arm64 — Graviton is cheaper for identical work, and it is
# the architecture the platform's own Lambda extension is built for. A GitHub `ubuntu-latest` runner
# is x86-64, so a project with a compiled dependency (`sharp`, `better-sqlite3`, a native `swc`)
# packages the wrong `.node` file here and fails at runtime with a module-not-found naming a file
# and not an architecture.
#
# Refused with the list, before the upload. `file` is on every GitHub runner; where it is not, this
# says so rather than passing silently — a check that quietly does nothing is worse than no check.
if command -v file >/dev/null 2>&1; then
  wrong=$(find . -name '*.node' -not -path '*/node_modules/.cache/*' -exec file {} + 2>/dev/null \
    | grep -E 'x86-64|80386' | cut -d: -f1 || true)
  if [ -n "$wrong" ]; then
    echo "::error::This build contains native modules compiled for x86-64. SproutOS runs functions on arm64." >&2
    echo "$wrong" | head -20 >&2
    echo "::error::Build on an arm64 runner (runs-on: ubuntu-24.04-arm) so the compiled dependencies match." >&2
    exit 1
  fi
else
  echo "::warning::'file' is not available, so native modules were not checked against the arm64 runtime." >&2
fi

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
