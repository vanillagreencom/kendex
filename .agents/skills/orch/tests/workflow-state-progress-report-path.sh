#!/usr/bin/env bash
# `workflow-state progress-report-path [--succession]`: the owner progress
# report is named MM-DD-HH-MM.md in UTC, with -succession before the extension
# for the one a succession writes, under ORCH_PROGRESS_REPORT_DIR joined to the
# project root, and the directory exists once the path is printed.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"

WS="$REPO_ROOT/skills/orch/scripts/workflow-state"

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# mutant_scripts and mutate_file, the two halves of the control below.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

echo
echo "--- workflow-state progress-report-path ---"

# Rows: the setting (- for unset), the flag (- for none), the directory the
# path must sit in, and the suffix before .md.
while IFS='|' read -r setting flag dir suffix; do
  project="$TMP_ROOT/p-$RANDOM"
  mkdir -p "$project"
  [[ "$setting" == - ]] && setting_env=(env -u ORCH_PROGRESS_REPORT_DIR) \
    || setting_env=(env ORCH_PROGRESS_REPORT_DIR="${setting//@/$TMP_ROOT}")
  [[ "$flag" == - ]] && flags=() || flags=("$flag")
  got="$(cd "$project" && "${setting_env[@]}" "$WS" progress-report-path ${flags[@]+"${flags[@]}"})"
  want_dir="${dir//@/$TMP_ROOT}"
  want_dir="${want_dir//%/$project}"
  label="setting=$setting flag=$flag"
  [[ "$got" =~ ^"$want_dir"/[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}"$suffix"\.md$ && -d "$want_dir" ]] \
    && pass "$label names MM-DD-HH-MM$suffix.md in an existing $dir" \
    || fail "$label names MM-DD-HH-MM$suffix.md in an existing $dir" "got=$got"
done <<'ROWS'
-|-|%/tmp/progress-reports|
-|--succession|%/tmp/progress-reports|-succession
reports|-|%/reports|
@/abs|--succession|@/abs|-succession
ROWS

# The stamp is UTC: a TZ far from it still names the UTC hour.
before="$(date -u +%m-%d-%H)"
got="$(cd "$TMP_ROOT" && TZ=XXX-14 "$WS" progress-report-path)"
after="$(date -u +%m-%d-%H)"
[[ "${got##*/}" == "$before"-* || "${got##*/}" == "$after"-* ]] && pass "the stamp is UTC whatever TZ says" \
  || fail "the stamp is UTC whatever TZ says" "got=${got##*/} want=$before-* or $after-*"

# A directory setting naming a file cannot be created, and is refused with
# mkdir's own words after the key.
printf 'x\n' > "$TMP_ROOT/a-file"
rc=0
(cd "$TMP_ROOT" && ORCH_PROGRESS_REPORT_DIR="$TMP_ROOT/a-file" "$WS" progress-report-path) \
  >/dev/null 2>"$TMP_ROOT/dir.err" || rc=$?
key="$(head -n 1 "$TMP_ROOT/dir.err")"
[[ "$rc" -eq 1 && "$key" == "workflow-state: progress-dir-failed path=$TMP_ROOT/a-file" ]] \
  && pass "a directory that cannot be created is refused as progress-dir-failed" \
  || fail "a directory that cannot be created is refused as progress-dir-failed" "rc=$rc key=$key"

rc=0
(cd "$TMP_ROOT" && "$WS" progress-report-path --later) >/dev/null 2>"$TMP_ROOT/opt.err" || rc=$?
key="$(head -n 1 "$TMP_ROOT/opt.err")"
[[ "$rc" -eq 2 && "$key" == "workflow-state: unknown-option arg1=--later" ]] \
  && pass "another option is refused as unknown-option" \
  || fail "another option is refused as unknown-option" "rc=$rc key=$key"

# Planted: the succession suffix dropped. The succession report then takes
# the name of the summary report written in the same minute.
NO_SUFFIX="$(mutant_scripts no-suffix workflow-state)/workflow-state" || exit 1
mutate_file "$NO_SUFFIX" '1:--succession) suffix=$PROGRESS_REPORT_SUFFIX ;;' '1:--succession) ;;'
got="$(cd "$TMP_ROOT" && "$NO_SUFFIX" progress-report-path --succession)"
[[ "$got" =~ /[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}\.md$ ]] && pass "control: without the suffix the succession report loses its name" \
  || fail "control: without the suffix the succession report loses its name" "got=$got"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
