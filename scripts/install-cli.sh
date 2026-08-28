#!/usr/bin/env bash
# Install the one immutable SproutOS CLI release this Action was reviewed against.
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"

# Updating this version is a reviewable Action change. Never resolve "latest": an Action run must
# not execute different platform code because a release appeared between two otherwise identical
# workflow runs.
readonly version="0.1.0"
readonly tag="cli-v${version}"
readonly repository="MySproutOS/SproutOS"
readonly signer_workflow="MySproutOS/SproutOS/.github/workflows/cli-release.yml"
# Exact source revision whose CLI contract this Action wraps. Updated together with `version` after
# the release has been built and attested; a moved/recreated tag cannot silently change it.
readonly source_digest="ef758b51d85fff0ffec9dfdea233c65af7e8fdab"
readonly release_base="https://github.com/${repository}/releases/download/${tag}"

case "$(uname -s):$(uname -m)" in
  Linux:x86_64) target="x86_64-unknown-linux-gnu"; suffix="tar.gz" ;;
  Linux:aarch64|Linux:arm64) target="aarch64-unknown-linux-gnu"; suffix="tar.gz" ;;
  Darwin:x86_64) target="x86_64-apple-darwin"; suffix="tar.gz" ;;
  Darwin:arm64|Darwin:aarch64) target="aarch64-apple-darwin"; suffix="tar.gz" ;;
  MINGW*:*|MSYS*:*|CYGWIN*:*) target="x86_64-pc-windows-msvc"; suffix="zip" ;;
  *)
    echo "::error::The SproutOS CLI has no release for $(uname -s) $(uname -m)." >&2
    exit 1
    ;;
esac

asset="sprout-v${version}-${target}.${suffix}"
manifest="sprout-v${version}-manifest.json"
stage=$(mktemp -d "${RUNNER_TEMP%/}/sprout-cli-${version}.XXXXXX")

download() {
  curl --proto '=https' --tlsv1.2 --location --fail --silent --show-error \
    --retry 3 --retry-all-errors --output "$stage/$1" "$release_base/$1"
}

download "$asset"
download SHA256SUMS
download "$manifest"

# The manifest is part of the versioned release contract, not merely another checksum source. It
# must describe this exact target and agree byte-for-byte with SHA256SUMS before either is trusted.
expected=$(python3 - "$stage/$manifest" "$target" "$asset" "$stage/$asset" <<'PY'
import json, pathlib, sys

document = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert document.get("schemaVersion") == 1, "unsupported CLI manifest schema"
assert document.get("version") == "0.1.0", "CLI manifest version mismatch"
assert document.get("tag") == "cli-v0.1.0", "CLI manifest tag mismatch"
expected_url = "https://github.com/MySproutOS/SproutOS/releases/download/cli-v0.1.0/" + sys.argv[3]
matches = [entry for entry in document.get("assets", [])
           if entry.get("target") == sys.argv[2] and entry.get("url") == expected_url]
assert len(matches) == 1, "CLI manifest does not contain exactly one matching asset"
assert matches[0].get("sizeBytes") == pathlib.Path(sys.argv[4]).stat().st_size, \
    "CLI manifest size does not match the downloaded asset"
value = matches[0].get("sha256", "")
assert len(value) == 64 and all(character in "0123456789abcdef" for character in value), \
    "CLI manifest contains an invalid SHA-256"
print(value)
PY
)

listed=$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1 }' "$stage/SHA256SUMS")
if [ "$(printf '%s\n' "$listed" | grep -c . || true)" -ne 1 ] || [ "$listed" != "$expected" ]; then
  echo "::error::The CLI manifest and SHA256SUMS disagree for $asset." >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$stage/$asset" | cut -d' ' -f1)
else
  actual=$(shasum -a 256 "$stage/$asset" | cut -d' ' -f1)
fi
if [ "$actual" != "$expected" ]; then
  echo "::error::The downloaded SproutOS CLI checksum did not match its immutable manifest." >&2
  exit 1
fi

# A checksum only proves agreement with the release page. The GitHub artifact attestation binds the
# bytes to SproutOS's CLI release workflow and source repository. There is deliberately no
# fail-open path: an old runner without attestation support must be upgraded, not allowed to run
# unverifiable deployment code.
if ! command -v gh >/dev/null 2>&1; then
  echo "::error::GitHub CLI with artifact-attestation support is required." >&2
  exit 1
fi
for verified in "$asset" SHA256SUMS "$manifest"; do
  gh attestation verify "$stage/$verified" \
    --repo "$repository" \
    --signer-workflow "$signer_workflow" \
    --source-ref "refs/tags/$tag" \
    --source-digest "$source_digest" \
    --deny-self-hosted-runners >/dev/null
done

install_dir="$stage/bin"
mkdir -p "$install_dir"
binary="$install_dir/sprout"
if [ "$suffix" = "tar.gz" ]; then
  tar -xzf "$stage/$asset" -C "$stage"
  cp "$stage/sprout-v${version}-${target}/sprout" "$binary"
  chmod +x "$binary"
else
  unzip -q "$stage/$asset" -d "$stage/extracted"
  binary="$install_dir/sprout.exe"
  cp "$stage/extracted/sprout-v${version}-${target}/sprout.exe" "$binary"
fi

"$binary" --version | grep -Fx "sprout ${version}" >/dev/null
printf '%s\n' "$install_dir" >> "$GITHUB_PATH"
echo "installed attested SproutOS CLI ${version} for ${target}"
