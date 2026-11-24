#!/usr/bin/env bash
# Probe the options in the published workflow examples with the real CLI parsers.
set -euo pipefail
# shellcheck source=../../change-scope/tests/lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../change-scope/tests/lib/sandbox.sh"
WIRING="$TEST_DIR/../references/wiring.md"
AGGREGATE_NEEDS="$TEST_DIR/../scripts/aggregate-needs"
[ -f "$WIRING" ] || { echo "missing $WIRING" >&2; exit 1; }

# Only the fenced yaml blocks, with the fences dropped.
yaml_lines() {
  awk '/^```yaml$/ { inblock = 1; next } /^```$/ { inblock = 0; next } inblock' "$WIRING"
}

blocks="$(yaml_lines)"
[ -n "$blocks" ] || { echo "no yaml blocks found in $WIRING" >&2; exit 1; }

# Pass each extracted option to the real parser. A documented unknown option
# must produce the wiring-error status instead of being accepted by a copy of
# the parser's option list here.
parser_repo="$(new_repo wiring-shapes-parser)"
commit_paths "$parser_repo" baseline README.md
parser_base="$(git -C "$parser_repo" rev-parse HEAD)"
commit_paths "$parser_repo" render .agents/skills/orch/SKILL.md
parser_head="$(git -C "$parser_repo" rev-parse HEAD)"
probe_value="$SANDBOX/probe-value"
extract_options() { # COMMAND
  printf '%s\n' "$blocks" | awk -v command="$1" '
  index($0, command) > 0 { in_call = 1; next }
  in_call && /^[[:space:]]+--/ { print; next }
  in_call { in_call = 0 }
' | grep -oE '(^|[[:space:]])--[a-z-]+' | tr -d ' ' | sort -u
}

harness_parser_rejections=""
harness_flag_probe() { # FLAG VALUE
  if "$HARNESS_ONLY" --repo "$parser_repo" --event push \
    --base "$parser_base" --head "$parser_head" "$1" "$2" \
    >/dev/null 2>&1; then
    parser_status=0
  else
    parser_status=$?
  fi
  if [ "$parser_status" != 0 ]; then
    harness_parser_rejections="$harness_parser_rejections $1:$parser_status"
  fi
}
harness_option_row_count=0
for flag in $(extract_options scripts/harness-only); do
  harness_option_row_count=$((harness_option_row_count + 1))
  if [ "$flag" = --mode ]; then
    mode_rows=0
    while IFS= read -r mode; do
      [ -n "$mode" ] || continue
      mode_rows=$((mode_rows + 1))
      harness_flag_probe "$flag" "$mode"
    done < <(printf '%s\n' "$blocks" | awk '{ for (i=1; i<NF; i++) if ($i == "--mode") print $(i+1) }' | sort -u)
    require_rows documented-harness-mode "$mode_rows"
  else
    harness_flag_probe "$flag" "$probe_value"
  fi
done
require_rows documented-harness-option "$harness_option_row_count"
assert_eq "the shapes pass only harness-only flags its parser accepts" "" \
  "$harness_parser_rejections"

aggregate_parser_rejections=""
aggregate_option_row_count=0
for flag in $(extract_options scripts/aggregate-needs); do
  aggregate_option_row_count=$((aggregate_option_row_count + 1))
  if "$AGGREGATE_NEEDS" "$flag" "$probe_value" --help >/dev/null 2>&1; then
    parser_status=0
  else
    parser_status=$?
  fi
  if [ "$parser_status" != 0 ]; then
    aggregate_parser_rejections="$aggregate_parser_rejections $flag:$parser_status"
  fi
done
require_rows documented-aggregate-option "$aggregate_option_row_count"
assert_eq "the shapes pass only aggregate-needs flags its parser accepts" "" \
  "$aggregate_parser_rejections"

report wiring-shapes
