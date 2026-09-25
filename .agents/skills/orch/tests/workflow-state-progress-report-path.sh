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

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

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
    && ok "$label names MM-DD-HH-MM$suffix.md in an existing $dir" \
    || bad "$label names MM-DD-HH-MM$suffix.md in an existing $dir" "got=$got"
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
[[ "${got##*/}" == "$before"-* || "${got##*/}" == "$after"-* ]] && ok "the stamp is UTC whatever TZ says" \
  || bad "the stamp is UTC whatever TZ says" "got=${got##*/} want=$before-* or $after-*"

# A directory setting naming a file cannot be created, and is refused with
# mkdir's own words after the key.
printf 'x\n' > "$TMP_ROOT/a-file"
rc=0
(cd "$TMP_ROOT" && ORCH_PROGRESS_REPORT_DIR="$TMP_ROOT/a-file" "$WS" progress-report-path) \
  >/dev/null 2>"$TMP_ROOT/dir.err" || rc=$?
key="$(head -n 1 "$TMP_ROOT/dir.err")"
[[ "$rc" -eq 1 && "$key" == "workflow-state: progress-dir-failed path=$TMP_ROOT/a-file" ]] \
  && ok "a directory that cannot be created is refused as progress-dir-failed" \
  || bad "a directory that cannot be created is refused as progress-dir-failed" "rc=$rc key=$key"

rc=0
(cd "$TMP_ROOT" && "$WS" progress-report-path --later) >/dev/null 2>"$TMP_ROOT/opt.err" || rc=$?
key="$(head -n 1 "$TMP_ROOT/opt.err")"
[[ "$rc" -eq 2 && "$key" == "workflow-state: unknown-option arg1=--later" ]] \
  && ok "another option is refused as unknown-option" \
  || bad "another option is refused as unknown-option" "rc=$rc key=$key"

# Planted: the succession suffix dropped. The succession report then takes
# the name of the summary report written in the same minute.
MUTANT_DIR="$TMP_ROOT/mutant"
mkdir -p "$MUTANT_DIR"
cp -R "$REPO_ROOT/skills/orch/scripts/lib" "$MUTANT_DIR/lib"
cp "$REPO_ROOT/skills/orch/scripts/orch-env" "$REPO_ROOT/skills/orch/scripts/git-context" "$MUTANT_DIR/"
[[ "$(grep -Fc '1:--succession) suffix=-succession ;;' "$WS")" == "1" ]] \
  && ok "the suffix control finds the succession arm" || bad "the suffix control finds the succession arm"
sed 's/1:--succession) suffix=-succession ;;/1:--succession) ;;/' "$WS" > "$MUTANT_DIR/workflow-state"
got="$(cd "$TMP_ROOT" && bash "$MUTANT_DIR/workflow-state" progress-report-path --succession)"
[[ "$got" =~ /[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}\.md$ ]] && ok "control: without the suffix the succession report loses its name" \
  || bad "control: without the suffix the succession report loses its name" "got=$got"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
