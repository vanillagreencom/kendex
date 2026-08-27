#!/usr/bin/env bash
# A wiring error is not a verdict. A bad call exits 2 with nothing on stdout,
# so the caller's step goes red instead of quietly running every lane forever.
# And the verdict reaches the file the caller named, beside stdout.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

repo="$(new_repo wiring)"
commit_paths "$repo" "baseline" README.md
base="$(git -C "$repo" rev-parse HEAD)"
commit_paths "$repo" "render only" .agents/skills/orch/SKILL.md

# Bounded: an argument loop that fails to consume its input hangs rather than
# exits, and a hung CI step is the failure this catches. macOS ships no
# timeout, and the suite still runs there without the bound.
bounded() { # ARGS...
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 "$@"
  else
    "$@"
  fi
}

wiring() { # LABEL ARGS...
  local label="$1" out status
  shift
  set +e
  out="$(bounded "$HARNESS_ONLY" "$@" 2>/dev/null)"
  status=$?
  set -e
  assert_eq "$label" "exit 2 stdout=''" "exit $status stdout='$out'"
}

wiring "an unknown flag" --repo "$repo" --event push --base "$base" --nope
wiring "a positional argument" --repo "$repo" --event push "$base"
wiring "no --event at all" --repo "$repo" --base "$base"
wiring "an empty --event" --repo "$repo" --event "" --base "$base"
wiring "--event with no value" --repo "$repo" --base "$base" --event
wiring "--base with no value" --repo "$repo" --event push --base
wiring "--head with no value" --repo "$repo" --event push --base "$base" --head
wiring "--repo with no value" --event push --base "$base" --repo
wiring "--output with no value" --repo "$repo" --event push --base "$base" --output
wiring "an empty --head" --repo "$repo" --event push --base "$base" --head ""

# A flag where a value belongs. Consuming it would classify '--base' as an
# unrecognised event and hand back a verdict for a call that named no event.
wiring "--event followed by another flag" --repo "$repo" --event --base "$base"
wiring "--base followed by another flag" --repo "$repo" --event push --base --head
wiring "--head followed by another flag" \
  --repo "$repo" --event push --base "$base" --head --output
wiring "--repo followed by another flag" --repo --event push --base "$base"
wiring "--output followed by another flag" \
  --repo "$repo" --event push --base "$base" --output --head

# A lone dash and a dash-led path are values, not flags: only a flag shape
# (a dash with something after it) is refused.
verdict_dash="$(classify --repo "$repo" --event push --base "$base" --head "-" || true)"
assert_eq "a lone dash is taken as a value" "harness_only=false" "$verdict_dash"

# An --output the process cannot append to is wiring, not data: the caller
# asked for a file and would otherwise get silence.
unwritable="$SANDBOX/no-such-dir/out.txt"
wiring "an unwritable --output" \
  --repo "$repo" --event push --base "$base" --output "$unwritable"

# --output appends beside stdout and keeps what the file already held.
out_file="$SANDBOX/github_output"
printf 'other_key=kept\n' >"$out_file"
verdict="$("$HARNESS_ONLY" --repo "$repo" --event push --base "$base" --output "$out_file" 2>/dev/null)"
assert_eq "--output leaves the verdict on stdout too" "harness_only=true" "$verdict"
assert_eq "--output appends without clobbering" \
  "other_key=kept harness_only=true" "$(tr '\n' ' ' <"$out_file" | sed -e 's/ $//')"

# With no --output, the file is $GITHUB_OUTPUT — what a workflow step sets.
env_file="$SANDBOX/env_output"
: >"$env_file"
GITHUB_OUTPUT="$env_file" "$HARNESS_ONLY" --repo "$repo" --event push --base "$base" >/dev/null 2>&1
assert_eq "GITHUB_OUTPUT receives the verdict" "harness_only=true" "$(cat "$env_file")"

override="$SANDBOX/override_output"
: >"$override"
: >"$env_file"
GITHUB_OUTPUT="$env_file" "$HARNESS_ONLY" --repo "$repo" --event push --base "$base" \
  --output "$override" >/dev/null 2>&1
assert_eq "--output wins over GITHUB_OUTPUT" "harness_only=true" "$(cat "$override")"
assert_eq "--output leaves GITHUB_OUTPUT untouched" "" "$(cat "$env_file")"

# With neither, stdout is the whole contract and nothing is written anywhere.
lone="$(env -u GITHUB_OUTPUT "$HARNESS_ONLY" --repo "$repo" --event push --base "$base" 2>/dev/null)"
assert_eq "no output file is required" "harness_only=true" "$lone"

# stdout carries the verdict line and nothing else; the changed paths are
# stderr's, so `$(harness-only …)` is safe to read directly.
assert_eq "stdout is the verdict line alone" "1" \
  "$(printf '%s\n' "$lone" | wc -l | tr -d ' ')"
paths="$("$HARNESS_ONLY" --repo "$repo" --event push --base "$base" 2>&1 >/dev/null)"
case "$paths" in
  *"changed: .agents/skills/orch/SKILL.md"*)
    assert_eq "the changed paths reach stderr" pass pass ;;
  *) assert_eq "the changed paths reach stderr" pass "$paths" ;;
esac

help_out="$("$HARNESS_ONLY" --help)"
case "$help_out" in
  "Usage: harness-only"*) assert_eq "--help prints the usage" pass pass ;;
  *) assert_eq "--help prints the usage" pass "$help_out" ;;
esac

report wiring-errors
