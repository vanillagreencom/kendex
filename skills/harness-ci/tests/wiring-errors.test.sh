#!/usr/bin/env bash
# Wiring errors exit with no verdict. Successful classifications write the
# same verdict to stdout and to the selected output file.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

repo="$(new_repo wiring)"
commit_paths "$repo" baseline README.md
base="$(git -C "$repo" rev-parse HEAD)"
commit_paths "$repo" "render only" .agents/skills/orch/SKILL.md

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
  if out="$(bounded "$HARNESS_ONLY" "$@" 2>/dev/null)"; then
    status=0
  else
    status=$?
  fi
  assert_eq "$label" "exit 2 stdout=''" "exit $status stdout='$out'"
}

run_argument_case() { # LABEL KIND OPTION VALUE
  local label="$1" kind="$2" option="$3" value="$4"
  local args=(--repo "$repo" --event push --base "$base")
  case "$kind" in
    unknown) args+=(--nope) ;;
    positional) args+=("$base") ;;
    missing-event) args=(--repo "$repo" --base "$base") ;;
    empty-value) args+=("$option" "") ;;
    missing-value) args+=("$option") ;;
    flag-value) args+=("$option" "$value") ;;
    *) echo "FAIL: unknown argument case '$kind'" >&2; exit 1 ;;
  esac
  wiring "$label" "${args[@]}"
}

# label | shape | option under test | value
while IFS='|' read -r label kind option value; do
  run_argument_case "$label" "$kind" "$option" "$value"
done <<'CASES'
unknown-flag|unknown|<none>|<none>
positional-argument|positional|<none>|<none>
missing-event|missing-event|--event|<none>
empty-event|empty-value|--event|<empty>
missing-event-value|missing-value|--event|<none>
missing-base-value|missing-value|--base|<none>
missing-head-value|missing-value|--head|<none>
missing-repo-value|missing-value|--repo|<none>
missing-output-value|missing-value|--output|<none>
empty-head|empty-value|--head|<empty>
flag-value-event|flag-value|--event|--head
flag-value-base|flag-value|--base|--head
flag-value-head|flag-value|--head|--output
flag-value-repo|flag-value|--repo|--head
flag-value-output|flag-value|--output|--head
CASES

if verdict_dash="$(classify --repo "$repo" --event push --base "$base" --head -)"; then
  dash_status=0
else
  dash_status=$?
fi
assert_eq lone-dash-value "harness_only=false exit 0" \
  "$verdict_dash exit $dash_status"

unwritable="$SANDBOX/no-such-dir/out.txt"
wiring output-parent-absent \
  --repo "$repo" --event push --base "$base" --output "$unwritable"

if [ -c /dev/full ]; then
  wiring output-write-fails \
    --repo "$repo" --event push --base "$base" --output /dev/full
else
  echo "  SKIP: no /dev/full, the full-device case did not run"
fi

file_bytes() { # FILE
  od -An -tx1 "$1" | tr -d ' \n'
}

run_output_case() { # LABEL MODE EXPECTED_STDOUT EXPECTED_EXPLICIT EXPECTED_ENV
  local label="$1" mode="$2" expected_stdout="$3"
  local expected_explicit="$4" expected_env="$5"
  local case_dir="$SANDBOX/output-$label" stdout_file explicit_file env_file status actual
  mkdir -p "$case_dir"
  stdout_file="$case_dir/stdout"
  explicit_file="$case_dir/explicit"
  env_file="$case_dir/env"
  : >"$explicit_file"
  : >"$env_file"

  case "$mode" in
    explicit-append)
      printf 'other_key=kept\n' >"$explicit_file"
      if env -u GITHUB_OUTPUT "$HARNESS_ONLY" \
        --repo "$repo" --event push --base "$base" --output "$explicit_file" \
        >"$stdout_file" 2>/dev/null; then status=0; else status=$?; fi
      ;;
    environment)
      if GITHUB_OUTPUT="$env_file" "$HARNESS_ONLY" \
        --repo "$repo" --event push --base "$base" \
        >"$stdout_file" 2>/dev/null; then status=0; else status=$?; fi
      ;;
    explicit-precedence)
      if GITHUB_OUTPUT="$env_file" "$HARNESS_ONLY" \
        --repo "$repo" --event push --base "$base" --output "$explicit_file" \
        >"$stdout_file" 2>/dev/null; then status=0; else status=$?; fi
      ;;
    stdout-only)
      if env -u GITHUB_OUTPUT "$HARNESS_ONLY" \
        --repo "$repo" --event push --base "$base" \
        >"$stdout_file" 2>/dev/null; then status=0; else status=$?; fi
      ;;
    *) echo "FAIL: unknown output case '$mode'" >&2; exit 1 ;;
  esac

  actual="exit=$status stdout=$(file_bytes "$stdout_file") explicit=$(file_bytes "$explicit_file") env=$(file_bytes "$env_file")"
  assert_eq "$label" \
    "exit=0 stdout=$expected_stdout explicit=$expected_explicit env=$expected_env" \
    "$actual"
}

verdict_bytes=6861726e6573735f6f6e6c793d747275650a
append_bytes=6f746865725f6b65793d6b6570740a6861726e6573735f6f6e6c793d747275650a

# label | mode | stdout bytes | explicit-output bytes | environment-output bytes
while IFS='|' read -r label mode expected_stdout expected_explicit expected_env; do
  run_output_case "$label" "$mode" "$expected_stdout" "$expected_explicit" "$expected_env"
done <<CASES
explicit-output-append|explicit-append|$verdict_bytes|$append_bytes|
environment-output|environment|$verdict_bytes||$verdict_bytes
explicit-output-precedence|explicit-precedence|$verdict_bytes|$verdict_bytes|
stdout-only|stdout-only|$verdict_bytes||
CASES

if paths="$("$HARNESS_ONLY" --repo "$repo" --event push --base "$base" 2>&1 >/dev/null)"; then
  paths_status=0
else
  paths_status=$?
fi
case "$paths" in
  *"changed: .agents/skills/orch/SKILL.md"*) paths_contract=present ;;
  *) paths_contract="$paths" ;;
esac
assert_eq changed-path-stderr "present exit 0" \
  "$paths_contract exit $paths_status"

if help_out="$("$HARNESS_ONLY" --help)"; then
  help_status=0
else
  help_status=$?
fi
case "$help_out" in
  "Usage: harness-only"*) help_contract=usage ;;
  *) help_contract="$help_out" ;;
esac
assert_eq help "usage exit 0" "$help_contract exit $help_status"

report wiring-errors
