#!/usr/bin/env bash
set -euo pipefail

package_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)

if [[ "${PI_CODEX_BRIDGE_LIVE:-0}" != "1" ]]; then
	printf '%s\n' "pi-codex-live skipped=PI_CODEX_BRIDGE_LIVE"
	exit 0
fi

if [[ -z "${PI_CODEX_BRIDGE_MODEL:-}" ]]; then
	printf '%s\n' "pi-codex-live model=missing"
	exit 1
fi

mkdir -p -- "$package_dir/tmp"
run_dir=$(mktemp -d "$package_dir/tmp/int-smoke.XXXXXX")
trap 'rm -rf -- "$run_dir"' EXIT

snapshot="$run_dir/credential-snapshot.json"
output="$run_dir/pi-output.jsonl"
fixture="$package_dir/tests/fixtures/live-read.txt"
pi_bin="$package_dir/node_modules/.bin/pi"

node "$package_dir/tests/credential-snapshot.mjs" write "$snapshot"

"$pi_bin" \
	--no-session \
	--no-extensions \
	--no-skills \
	--no-prompt-templates \
	--no-context-files \
	--mode json \
	--print \
	--extension "$package_dir/bundle/index.js" \
	--model "pi-codex/$PI_CODEX_BRIDGE_MODEL" \
	--tools read \
	"Use the read tool on $fixture. Reply with only the file contents." > "$output"

node "$package_dir/tests/assert-live-smoke.mjs" "$output"
node "$package_dir/tests/credential-snapshot.mjs" compare "$snapshot"
