#!/usr/bin/env bash
# Surface: scripts/change-class, the CI wrapper over change-scope's classifier.
# Inputs: scripts/change-class, scripts/lib/change-class.sh,
# change-scope/scripts/change-scope.
#
# The wrapper carries the classifier's answer as it stands: the one class line
# on stdout, every stderr line the classifier printed in order, and its
# `class:` line last, after the queue-only, per-push and unread-paths records
# this package adds. A wiring error of the classifier is the wrapper's, with the same
# status. The verdict reaches the GitHub output file with the queue and lane
# answers beside it. No flag of the wrapper carries a class, and the
# classifier's own --paths-output is not one of the wrapper's.
set -euo pipefail
# shellcheck source=../../change-scope/tests/lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../change-scope/tests/lib/sandbox.sh"
PLANT_ENTRY=change-class

repo="$(new_repo change-class)"
commit_paths "$repo" baseline seed.txt
base="$(git -C "$repo" rev-parse HEAD)"

# LINES lines of content under PATH.
write_lines() { # PATH LINES
  local n=0
  mkdir -p "$repo/$(dirname "$1")"
  while [ "$n" -lt "$2" ]; do
    n=$((n + 1))
    printf 'line %d\n' "$n" >>"$repo/$1"
  done
}
case_diff() { # MESSAGE PATH=LINES...
  local message="$1" spec
  shift
  git -C "$repo" checkout -q -B case "$base"
  git -C "$repo" clean -qfd
  for spec in "$@"; do write_lines "${spec%=*}" "${spec##*=}"; done
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$message"
}

# No kendex reaches these rows: every class here is earned by size or rule.
no_kendex_path=""
while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  [ ! -x "$dir/kendex" ] || continue
  no_kendex_path="${no_kendex_path:+$no_kendex_path:}$dir"
done <<<"$(printf '%s' "$PATH" | tr ':' '\n')"

# The wrapper's stdout and stderr beside the classifier's, over the same
# range: WRAPPER names the command under test, so a control runs a planted
# copy through the same rows.
forward_rows() { # WRAPPER
  local wrapper="$1" label edits core_out core_status wrap_out wrap_status
  local core_err wrap_err core_lines
  while IFS='|' read -r label edits; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086
    case_diff "$label" $edits
    core_status=0
    core_out="$(PATH="$no_kendex_path" "$CHANGE_SCOPE" --event pull_request --repo "$repo" \
      --base "$base" --head HEAD 2>"$SANDBOX/core.err")" || core_status=$?
    wrap_status=0
    wrap_out="$(PATH="$no_kendex_path" "$wrapper" --event pull_request --repo "$repo" \
      --base "$base" --head HEAD 2>"$SANDBOX/wrap.err")" || wrap_status=$?
    assert_eq "$label: the wrapper's stdout and status are the classifier's" \
      "$core_out exit $core_status" "$wrap_out exit $wrap_status"
    # Every classifier line, in order, with the three records ahead of the
    # last one: the wrapper's log without its queue-only, per-push and
    # unread-paths lines is the classifier's log.
    core_err="$(cat "$SANDBOX/core.err")"
    wrap_err="$(grep -v '^queue-only: \|^per-push: \|^unread-paths:' "$SANDBOX/wrap.err")"
    assert_eq "$label: the wrapper carries every classifier line in order" "$core_err" "$wrap_err"
    core_lines="$(grep -c '' "$SANDBOX/core.err")"
    assert_eq "$label: the wrapper adds the three records and nothing else" \
      "$((core_lines + 3))" "$(grep -c '' "$SANDBOX/wrap.err")"
    assert_eq "$label: the class line closes the wrapper's log" \
      "$(sed -n '$p' "$SANDBOX/core.err")" "$(sed -n '$p' "$SANDBOX/wrap.err")"
    assert_eq "$label: the queue-only, per-push and unread-paths records precede the class line" \
      "queue-only per-push unread-paths class" \
      "$(tail -n 4 "$SANDBOX/wrap.err" | sed 's/^\([a-z-]*\):.*/\1/' | tr '\n' ' ' | sed 's/ $//')"
  done <<'ROWS'
a micro diff|runtime/product.ts=2
a small diff|runtime/product.ts=40
a diff past small|runtime/product.ts=200
a documentation diff|docs/guide.md=2
an excluded path|.github/workflows/ci.yml=2
an instruction file|AGENTS.md=3
a render refused without a verifier|.agents/skills/orch/SKILL.md=4
ROWS
}
forward_rows "$CHANGE_CLASS"

# The classifier's wiring error is the wrapper's, status and first line.
case_diff "a diff under a malformed ceiling" docs/guide.md=2
status=0
out="$(PATH="$no_kendex_path" HARNESS_CI_TRIVIAL_MAX_LINES=abc "$CHANGE_CLASS" --event pull_request \
  --repo "$repo" --base "$base" --head HEAD 2>"$SANDBOX/wiring.err")" || status=$?
assert_eq "a classifier wiring error keeps its status and line" \
  "wiring-error: cause=invalid-setting setting=HARNESS_CI_TRIVIAL_MAX_LINES exit 2 stdout=''" \
  "$(grep '^wiring-error: ' "$SANDBOX/wiring.err") exit $status stdout='$out'"

# A wiring error raised after the paths were read still carries the base
# settings' records: a base whose settings set the per-push reason blank
# prints the `setting-refused:` record and its `::warning` annotation, which
# GitHub Actions reads as a workflow command, ahead of the error and without
# a `queue-only:` line. WRAPPER names the command under test so a control
# runs a planted copy through the same row.
setting_records_on_wiring_error() { # WRAPPER
  local wrapper="$1" settings_base status=0 out
  git -C "$repo" checkout -q -B settings-base "$base"
  git -C "$repo" clean -qfd
  printf '[env]\nHARNESS_CI_PER_PUSH_REASON = " "\n' >"$repo/kendex.settings.toml"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "a blank per-push reason"
  settings_base="$(git -C "$repo" rev-parse HEAD)"
  write_lines docs/guide.md 2
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "a diff under a malformed ceiling, over a blank reason"
  out="$(PATH="$no_kendex_path" HARNESS_CI_TRIVIAL_MAX_LINES=abc "$wrapper" --event pull_request \
    --repo "$repo" --base "$settings_base" --head HEAD 2>"$SANDBOX/records.err")" || status=$?
  # The three keyed lines in the order they came out, the annotation cut at
  # its title; the human text after it is not read here.
  assert_eq "a wiring error over a blank per-push reason prints the setting record and its annotation" \
    "setting-refused: setting=HARNESS_CI_PER_PUSH_REASON cause=empty-reason
::warning title=per-push opt-back refused
wiring-error: cause=invalid-setting setting=HARNESS_CI_TRIVIAL_MAX_LINES
queue-only lines: 0 exit 2 stdout=''" \
    "$(grep '^setting-refused: \|^::warning title=per-push opt-back refused::\|^wiring-error: ' "$SANDBOX/records.err" |
      sed 's/^\(::warning title=per-push opt-back refused\)::.*/\1/')
queue-only lines: $(grep -c '^queue-only: ' "$SANDBOX/records.err" || true) exit $status stdout='$out'"
}
setting_records_on_wiring_error "$CHANGE_CLASS"

# The verdict reaches the GitHub output file, with the queue and lane answers.
case_diff "wiring outputs" docs/guide.md=2
output_file="$SANDBOX/change-class-output"
out="$(PATH="$no_kendex_path" "$CHANGE_CLASS" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD \
  --output "$output_file" 2>/dev/null)"
assert_eq "the verdict reaches the output file" \
  "change_class=trivial queue_only=true lanes=false lanes_cause=trivial stdout=change_class=trivial" \
  "$(tr '\n' ' ' <"$output_file")stdout=$out"

# No flag asserts a class, and the flags the readers take are not this
# script's.
flag_rows=0
while IFS= read -r flag; do
  flag_rows=$((flag_rows + 1))
  out="$("$CHANGE_CLASS" "$flag" render --event pull_request --repo "$repo" \
    --base "$base" 2>&1)" && status=0 || status=$?
  assert_eq "no $flag flag reaches this script" \
    "wiring-error: cause=unknown-argument argument=$flag exit 2" \
    "${out%%$'\n'*} exit $status"
done <<'FLAGS'
--class
--mode
--paths-output
FLAGS
require_rows change-class-refused-flags "$flag_rows"

# Must-fail control: a wrapper that prints the class line ahead of its own
# records answers the same class, so the stdout row stays green, and the
# order rows turn red on every forwarded diff.
early_class="$(mutant early-class change-class \
  "printf '%s\\n' \"\$class_record\" >&2" - \
  "printf '%s\\n%s\\n' \"\$queue_line\" \"\$per_push_line\" >&2" \
  "printf '%s\\n' \"\$class_record\" >&2; printf '%s\\n%s\\n' \"\$queue_line\" \"\$per_push_line\" >&2")"
control_status=0
(PASS=0; FAIL=0; forward_rows "$early_class" >/dev/null 2>"$SANDBOX/control.err"; [ "$FAIL" -eq 0 ]) || control_status=$?
assert_eq "must-fail: a wrapper printing the class line early fails the forwarding rows" 1 "$control_status"
assert_eq "and the control reddened the order row, not the stdout row" "0" \
  "$(grep -c "stdout and status are the classifier's" "$SANDBOX/control.err" || true)"
assert_eq "and the control reddened the closing-line row on every diff" "7" \
  "$(grep -c 'FAIL: .*the class line closes the wrapper' "$SANDBOX/control.err" || true)"

report change-class
