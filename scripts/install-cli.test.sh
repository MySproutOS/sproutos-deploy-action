#!/usr/bin/env bash
set -euo pipefail

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/sproutos-cli-install-test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fixture="$test_dir/fixture"
mkdir -p "$fixture/sprout-v0.1.0-x86_64-unknown-linux-gnu"

cat > "$fixture/sprout-v0.1.0-x86_64-unknown-linux-gnu/sprout" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'sprout 0.1.0'
EOF
chmod +x "$fixture/sprout-v0.1.0-x86_64-unknown-linux-gnu/sprout"
tar -C "$fixture" -czf "$fixture/sprout-v0.1.0-x86_64-unknown-linux-gnu.tar.gz" \
  sprout-v0.1.0-x86_64-unknown-linux-gnu
digest=$(sha256sum "$fixture/sprout-v0.1.0-x86_64-unknown-linux-gnu.tar.gz" | cut -d' ' -f1)
size=$(wc -c < "$fixture/sprout-v0.1.0-x86_64-unknown-linux-gnu.tar.gz" | tr -d ' ')
printf '%s  %s\n' "$digest" 'sprout-v0.1.0-x86_64-unknown-linux-gnu.tar.gz' > "$fixture/SHA256SUMS"
python3 - "$fixture/sprout-v0.1.0-manifest.json" "$digest" "$size" <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "schemaVersion": 1,
    "version": "0.1.0",
    "tag": "cli-v0.1.0",
    "assets": [{
        "target": "x86_64-unknown-linux-gnu",
        "os": "linux",
        "arch": "x86_64",
        "url": "https://github.com/MySproutOS/SproutOS/releases/download/cli-v0.1.0/sprout-v0.1.0-x86_64-unknown-linux-gnu.tar.gz",
        "sha256": sys.argv[2],
        "sizeBytes": int(sys.argv[3]),
    }],
}))
PY

mkdir -p "$test_dir/bin"
cat > "$test_dir/bin/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in -s) echo Linux;; -m) echo x86_64;; *) echo Linux;; esac
EOF
cat > "$test_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in --output) output="$2"; shift 2;; *) url="$1"; shift;; esac
done
name=${url##*/}
cp "$FIXTURE/$name" "$output"
if [ "${TAMPER_ASSET:-0}" = 1 ] && [[ "$name" == *.tar.gz ]]; then printf x >> "$output"; fi
EOF
cat > "$test_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_TRACE"
[ "$1" = attestation ] && [ "$2" = verify ]
contains() {
  local expected=$1 value
  shift
  for value in "$@"; do [ "$value" != "$expected" ] || return 0; done
  return 1
}
contains --repo "$@"
contains MySproutOS/SproutOS "$@"
contains --signer-workflow "$@"
contains MySproutOS/SproutOS/.github/workflows/cli-release.yml "$@"
contains --source-ref "$@"
contains refs/tags/cli-v0.1.0 "$@"
contains --source-digest "$@"
contains 293f8cf60f3780a87b2f9bc216677e575829c20f "$@"
contains --deny-self-hosted-runners "$@"
EOF
chmod +x "$test_dir/bin/"*

run_install() {
  local runner=$1
  mkdir -p "$runner"
  : > "$runner/path"
  FIXTURE="$fixture" GH_TRACE="$runner/gh-trace" PATH="$test_dir/bin:$PATH" \
    RUNNER_TEMP="$runner" GITHUB_PATH="$runner/path" "$script_dir/install-cli.sh" >/dev/null
}

run_install "$test_dir/good"
first_install=$(tail -n1 "$test_dir/good/path")
"$first_install/sprout" --version | grep -Fxq 'sprout 0.1.0'
test "$(wc -l < "$test_dir/good/gh-trace" | tr -d ' ')" -eq 3
grep -Fq 'sprout-v0.1.0-x86_64-unknown-linux-gnu.tar.gz' "$test_dir/good/gh-trace"
grep -Fq '/SHA256SUMS ' "$test_dir/good/gh-trace"
grep -Fq '/sprout-v0.1.0-manifest.json ' "$test_dir/good/gh-trace"

# A monorepo may invoke the composite Action more than once in one job. Each installer owns a
# unique extraction tree, so Windows unzip never prompts to overwrite the first invocation.
run_install "$test_dir/good"
second_install=$(tail -n1 "$test_dir/good/path")
[ "$first_install" != "$second_install" ]
"$second_install/sprout" --version | grep -Fxq 'sprout 0.1.0'

if TAMPER_ASSET=1 run_install "$test_dir/tampered" 2>"$test_dir/tampered.err"; then
  echo "tampered CLI archive was accepted" >&2
  exit 1
fi
grep -Eq 'size does not match|checksum did not match' "$test_dir/tampered.err"

echo "CLI installer checksum and provenance tests passed"
