#!/usr/bin/env bash
# Tests for the CI ci class job set proof contract.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which would resolve ROOT to the hook's
# repository instead of this one.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ci-job-set-world.sh
. "$TEST_DIR/lib/ci-job-set-world.sh"

source "$TEST_DIR/lib/ci-job-set-case.sh"

# --- 1b. The proof ------------------------------------------------------------
# A merge group handed the record of its pull request's passing run stands
# down what that run ran, and nothing else, the verify job aside: its
# changelog step reads the group's base, which no record names. Rows run in
# the fixture world, whose lists are whole, but the two the world library's
# rows hand tools/tests/ci-aggregate.test.sh, which run over this tree.
# A Pi package's source, whose one shard, node, the matrix never runs on macOS.
PRICE_SHARDS='["guards-scans","guards-hooks","guards-hooks-tail","guards-tools","guards-tools-tail","rest"]'
# The whole merge-group selection of the price-handling path; that
# selection less what a pull request run of the same diff ran, which is
# every lane but the verify job; and less what a pull request run of the
# skill's prose ran: the same shards' Linux legs, and every lane but the
# platform lanes and the verify job.
PRICE_QUEUE="$(macos_shards "$PRICE_SHARDS")"
PRICE_GROUP="$(measured both false true false "$PRICE_SHARDS" "$PRICE_QUEUE" true)"
PRICE_NONE="shell_shards=false shell_os=[] ui=false bot_instructions=true cargo_linux=false cargo_macos=false cargo_lint=false cargo_windows=false cargo_windows_check=false catalog=true smoke=true shards=$PRICE_SHARDS queue_macos_shards=$PRICE_QUEUE"
PRICE_PLATFORM="shell_shards=true shell_os=$MACOS ui=false bot_instructions=true cargo_linux=false cargo_macos=true cargo_lint=false cargo_windows=true cargo_windows_check=false catalog=true smoke=true shards=$PRICE_SHARDS queue_macos_shards=$PRICE_QUEUE"
proof_selection() { # RECORD CLASS DOCS PATHS — the pull-request selection under tree RECORD, in the fixture world
  SELECT_IN="$SEL_WORLD" SELECT_EVENT=pull_request SELECT_PROOF="$(printf '%s' "$1" | tr ',' '\n')" \
    selection "$2" "$3" "$(printf '%s\n' $4)"
}
# LABEL|RECORD|CLASS|DOCS|PATHS|EXPECTED
proof_table() {
  cat <<ROWS
the pull request's own diff stands every leg down but the verify job|$(record pull_request micro false "$PRICE")|micro|false|$PRICE|$PRICE_NONE
a run whose shards cover this diff's stands every leg down but the verify job|$(record pull_request micro false skills/github/scripts/lib/gh-auth.sh)|micro|false|$PRICE|$PRICE_NONE
a pull request run of the skill's prose leaves the platform lanes|$(record pull_request micro false skills/price-handling/SKILL.md)|micro|false|$PRICE|$PRICE_PLATFORM
a run whose shards do not cover this diff's keeps every leg|$(record pull_request micro false skills/preflight/scripts/preflight)|micro|false|$PRICE|shell_shards=true shell_os=$BOTH ui=false bot_instructions=true cargo_linux=false cargo_macos=false cargo_lint=false cargo_windows=false cargo_windows_check=false catalog=true smoke=true shards=$PRICE_SHARDS queue_macos_shards=$PRICE_QUEUE
a trivial run stands nothing down, the verify job reading the base|$(record pull_request trivial true README.md)|micro|false|$PRICE|$PRICE_GROUP
a pull request run of a diff no macOS leg runs leaves no leg|$(record pull_request micro false "$PI")|micro|false|$PI|shell_shards=false shell_os=[] ui=false bot_instructions=true cargo_linux=false cargo_macos=false cargo_lint=false cargo_windows=false cargo_windows_check=false catalog=true smoke=true shards=["node"] queue_macos_shards=[]
a merge-group run of a lane source stands down every leg but the verify job|$(record merge_group micro false .github/AGENTS.md "$PRICE")|micro|false|$PRICE|shell_shards=false shell_os=[] ui=false bot_instructions=true cargo_linux=false cargo_macos=false cargo_lint=false cargo_windows=false cargo_windows_check=false catalog=true smoke=true shards=$PRICE_SHARDS queue_macos_shards=$PRICE_QUEUE
a record of an event this script does not select for is ignored|$(record push micro false "$PRICE")|micro|false|$PRICE|$PRICE_GROUP
a record of a measured class with no path is ignored|$(record pull_request micro false)|micro|false|$PRICE|$PRICE_GROUP
a record of a class this script does not know is ignored|$(record pull_request enormous false "$PRICE")|micro|false|$PRICE|$PRICE_GROUP
ROWS
}
proof_rows=0
while IFS='|' read -r label rec class docs paths expected; do
  proof_rows=$((proof_rows + 1))
  check "proof: $label" "$expected" "$(proof_selection "$rec" "$class" "$docs" "$paths")"
done < <(proof_table)
[ "$proof_rows" -eq 10 ] || { echo "the proof table read $proof_rows rows" >&2; exit 1; }
proof_selection "$(record push micro false "$PRICE")" micro false "$PRICE" >/dev/null
check "an ignored record says why" "ci-job-set: proof=ignored cause=unsupported-event event=push" \
  "$(grep '^ci-job-set: proof=ignored' "$TMP/selection-err")"
proof_selection "$(record pull_request micro false "$PRICE")" micro false "$PRICE" >/dev/null
check "a stood-down lane is named" "linux macos cargo_linux cargo_macos cargo_windows" \
  "$(sed -n 's/^ci-job-set: proof=reused lane=//p' "$TMP/selection-err" | tr '\n' ' ' | sed 's/ $//')"
# EDIT@LABEL: a copy with that rule removed answers the row named LABEL other
# than the script does.
while IFS='@' read -r edit label; do
  sed "$edit" "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
  chmod +x "$TMP/rule/tools/ci-job-set"
  if cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set"; then
    bad "control: the edit changed nothing in a ci-job-set copy: $edit"
    continue
  fi
  line="$(proof_table | grep -m1 -F -- "$label|")" || { echo "no proof row named $label" >&2; exit 1; }
  IFS='|' read -r _ rec class docs paths expected <<<"$line"
  got="$(SELECT_WITH="$TMP/rule/tools/ci-job-set" proof_selection "$rec" "$class" "$docs" "$paths")"
  [ "$got" != "$expected" ] && ok "control: $edit reddens the proof row '$label'" ||
    bad "control: $edit reddens the proof row '$label' (still '$got')"
done <<'CONTROLS'
s/^  if \[ "\$value:\$ran" = true:true \]; then$/  if false; then/@the pull request's own diff stands every leg down but the verify job
s/^  case "\$lane" in linux | macos) \[ "\$covered" = true \] || ran=false ;; esac$/  :/@a run whose shards do not cover this diff's keeps every leg
s/^    case "\$was_shards" in \*"\\"\$shard\\""\*) ;; \*) covered=false ;; esac$/    :/@a run whose shards do not cover this diff's keeps every leg
s/^  \[ "\$known" = true \] || die "unsupported-event event=\$event"/  true || die "unsupported-event event=$event"/@a record of an event this script does not select for is ignored
s/^      \[ -n "\$paths" \] || die "class-without-paths class=\$class" \\$/      true || die "class-without-paths class=$class" \\/@a record of a measured class with no path is ignored
s/^  case "\$lane" in bot_instructions | catalog | smoke) ran=false ;; esac$/  :/@a trivial run stands nothing down, the verify job reading the base
CONTROLS

# The world library's two proof selections over this tree, which
# tools/tests/ci-aggregate.test.sh evaluates the workflow against: a merge
# group of an orch code diff whose proof is a pull request run over orch's
# prose, and one of a lane-source diff whose pull request ran the same paths.
ORCH_GROUP="$(SELECT_EVENT=merge_group selection micro false skills/orch/scripts/lanes)"
check "a group tree proof leaves the integrated orch selection running" "$ORCH_GROUP" "$ORCH_PROOF_ROW"
check "a group tree proof leaves its selected lanes running" "$(measured both false true false "$ROSTER" "$QUEUE_ALL" true)" "$SOURCE_PROOF_ROW"

# Patch proof waives portability only. The expected Linux and Windows
# values come from the unproven row, not from the record's selection.
patch_record="$(record pull_request micro false "$PRICE" | tr ',' '\n')
patch_id=p1
macos_patch=true
$(SELECT_IN="$SEL_WORLD" macos_record micro false "$PRICE")"
patch_expected="$(measured linux false true false "$PRICE_SHARDS" '[]' true)"
patch_expected="${patch_expected/cargo_macos=true/cargo_macos=false}"
check "PR selector records its actual macOS lanes and queue shards" "macos_selected=true
cargo_macos_selected=true
macos_shards=$PRICE_QUEUE" "$(SELECT_IN="$SEL_WORLD" macos_record micro false "$PRICE")"
for field in macos_selected cargo_macos_selected macos_shards; do
  needle='macos_selected=%s\ncargo_macos_selected=%s\nmacos_shards=[%s]'
  replacement="${needle/$field=/omitted_field=}"
  [ "$(grep -cF -- "$needle" "$JOB_SET")" -eq 1 ] || exit 1
  NEEDLE="$needle" REPLACEMENT="$replacement" awk '{ i=index($0,ENVIRON["NEEDLE"]); if(i) $0=substr($0,1,i-1) ENVIRON["REPLACEMENT"] substr($0,i+length(ENVIRON["NEEDLE"])); print }' "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
  ! cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set" || exit 1
  got="$(SELECT_WITH="$TMP/rule/tools/ci-job-set" SELECT_IN="$SEL_WORLD" macos_record micro false "$PRICE")"
  [ "$(printf '%s\n' "$got" | sed -n "s/^$field=//p")" = '' ] &&
    ok "must-fail: PR recorder omits $field" || bad "must-fail: PR recorder omits $field"
done
check "accepted macOS record waives covered portability" "$patch_expected" \
  "$(SELECT_IN="$SEL_WORLD" SELECT_EVENT=merge_group SELECT_MACOS_PROOF="$patch_record" selection micro false "$PRICE")"
check "no macOS record retains portability despite matching tree proof" "$PRICE_GROUP" \
  "$(SELECT_IN="$SEL_WORLD" SELECT_EVENT=merge_group SELECT_PROOF="$patch_record" selection micro false "$PRICE")"
check "missing macOS shell shard retains its legs beside covered cargo" "${PRICE_GROUP/cargo_macos=true/cargo_macos=false}" \
  "$(SELECT_IN="$SEL_WORLD" SELECT_EVENT=merge_group SELECT_MACOS_PROOF="$(record pull_request micro false skills/preflight/scripts/preflight | tr ',' '\n')
patch_id=p1
macos_patch=true
$(SELECT_IN="$SEL_WORLD" macos_record micro false skills/preflight/scripts/preflight)" selection micro false "$PRICE")"

# The PR record includes every macOS leg, but never the selected node leg.
# Removing one selected macOS shard must retain portability for the group.
wide_paths="$(printf '%s\n' "$PRICE" "$PI")"
wide_shards="$(jq -c '. + ["node"]' <<<"$PRICE_SHARDS")"
wide_covered="$(measured linux false true false "$wide_shards" '[]' true)"
wide_covered="${wide_covered/cargo_macos=true/cargo_macos=false}"
wide_uncovered="$(measured both false true false "$wide_shards" "$PRICE_QUEUE" true)"
wide_uncovered="${wide_uncovered/cargo_macos=true/cargo_macos=false}"
missing_record="$(printf '%s\n' "$patch_record" | sed '/^macos_shards=/d')
macos_shards=$(jq -c 'map(select(. != "rest"))' <<<"$PRICE_QUEUE")"
for coverage in full missing; do
  rec="$patch_record" expected="$wide_covered"
  [ "$coverage" != missing ] || { rec="$missing_record"; expected="$wide_uncovered"; }
  check "$coverage wider patch coverage with a selected Linux-only shard" "$expected" \
    "$(SELECT_IN="$SEL_WORLD" SELECT_EVENT=merge_group SELECT_MACOS_PROOF="$rec" selection micro false "$wide_paths")"
done
while IFS='@' read -r needle replacement coverage; do
  [ "$(grep -cxF -- "$needle" "$JOB_SET")" -eq 1 ] || exit 1
  NEEDLE="$needle" REPLACEMENT="$replacement" awk '$0 == ENVIRON["NEEDLE"] { print ENVIRON["REPLACEMENT"]; next } { print }' "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
  ! cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set" || exit 1
  rec="$patch_record" expected="$wide_covered"
  [ "$coverage" != missing ] || { rec="$missing_record"; expected="$wide_uncovered"; }
  got="$(SELECT_WITH="$TMP/rule/tools/ci-job-set" SELECT_IN="$SEL_WORLD" SELECT_EVENT=merge_group SELECT_MACOS_PROOF="$rec" selection micro false "$wide_paths")"
  case "$got" in
    exit=*) bad "must-fail: wider coverage control broke the selector ($got)" ;;
    *) [ "$got" != "$expected" ] && ok "must-fail: wider $coverage coverage rule" || bad "must-fail: wider $coverage coverage rule" ;;
  esac
done <<'ROWS'
    case "$now_shards" in *"\"$shard\""*) ;; *) continue ;; esac@    case " orch-terminal orch-oversee-succeed guards-tools " in *" $shard "*) ;; *) continue ;; esac; case "$now_shards" in *"\"$shard\""*) ;; *) continue ;; esac@missing
      case " $LINUX_ONLY_SHARDS " in *" $shard "*) continue ;; esac@      :@full
ROWS

# sed can print the complete coverage field before it reports a read failure.
# Each field must retain portability on that status, even with usable text.
mkdir -p "$TMP/field-reader"
REAL_SED="$(command -v sed)" || exit 1
cat >"$TMP/field-reader/sed" <<'SH'
#!/usr/bin/env bash
"$REAL_SED" "$@" || exit "$?"
[ "${2:-}" != "s/^$FAILED_FIELD=//p" ] || exit 23
SH
chmod +x "$TMP/field-reader/sed"
while IFS='@' read -r field needle replacement; do
  got="$(REAL_SED="$REAL_SED" FAILED_FIELD="$field" PATH="$TMP/field-reader:$PATH" SELECT_IN="$SEL_WORLD" SELECT_EVENT=merge_group SELECT_MACOS_PROOF="$patch_record" selection micro false "$PRICE")"
  check "failed $field read retains macOS coverage" "$PRICE_GROUP" "$got"
  check "failed $field read reports ignored proof" "macos-coverage-read-failed" \
    "$(sed -n 's/^ci-job-set: proof=ignored cause=//p' "$TMP/selection-err")"
  [ "$(grep -cF -- "$needle" "$JOB_SET")" -eq 1 ] || exit 1
  NEEDLE="$needle" REPLACEMENT="$replacement" awk '{ i=index($0,ENVIRON["NEEDLE"]); if(i) $0=substr($0,1,i-1) ENVIRON["REPLACEMENT"] substr($0,i+length(ENVIRON["NEEDLE"])); print }' "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
  ! cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set" || exit 1
  got="$(REAL_SED="$REAL_SED" FAILED_FIELD="$field" PATH="$TMP/field-reader:$PATH" SELECT_WITH="$TMP/rule/tools/ci-job-set" SELECT_IN="$SEL_WORLD" SELECT_EVENT=merge_group SELECT_MACOS_PROOF="$patch_record" selection micro false "$PRICE")"
  [ "$got" = "$patch_expected" ] && ok "must-fail: unchecked $field read waives macOS" || bad "must-fail: unchecked $field read control"
done <<'ROWS'
macos_selected@! r_macos="$(patch_line macos_selected)"@{ r_macos="$(patch_line macos_selected)"; false; }
cargo_macos_selected@! r_cargo="$(patch_line cargo_macos_selected)"@{ r_cargo="$(patch_line cargo_macos_selected)"; false; }
macos_shards@! r_shards="$(patch_line macos_shards)"@{ r_shards="$(patch_line macos_shards)"; false; }
ROWS

check "old patch records with no selection retain portability" "$PRICE_GROUP" \
  "$(SELECT_IN="$SEL_WORLD" SELECT_EVENT=merge_group SELECT_MACOS_PROOF="$(record pull_request micro false "$PRICE" | tr ',' '\n')" selection micro false "$PRICE")"

# The base adds a reader after a PR ran no shell shard. Recorded coverage
# must retain that new macOS shard even though the patch stays unchanged.
ADVANCED_WORLD="$TMP/advanced-world"
cp -R "$SEL_WORLD" "$ADVANCED_WORLD"
advanced_path=ui/src/proof-fixture.ts
prior_record="$(record pull_request micro false "$advanced_path" | tr ',' '\n')
$(SELECT_IN="$ADVANCED_WORLD" macos_record micro false "$advanced_path")"
check "the PR actually selected no macOS shell shard" 'macos_shards=[]' \
  "$(printf '%s\n' "$prior_record" | grep '^macos_shards=')"
printf 'read ui/src/proof-fixture.ts\n' >"$ADVANCED_WORLD/tools/tests/base-reader.test.sh"
git -C "$ADVANCED_WORLD" add tools/tests/base-reader.test.sh
advanced_expected="$(measured both true true false '["guards-tools","guards-tools-tail"]' '["guards-tools","guards-tools-tail"]')"
advanced_expected="${advanced_expected/cargo_macos=true/cargo_macos=false}"
check "new base reader retains its untested macOS shard" "$advanced_expected" \
  "$(SELECT_IN="$ADVANCED_WORLD" SELECT_EVENT=merge_group SELECT_MACOS_PROOF="$prior_record" selection micro false "$advanced_path")"
needle='          patch_was="linux=false macos=$r_macos ui=false bot_instructions=false cargo_linux=false cargo_macos=$r_cargo cargo_lint=false cargo_windows=false cargo_windows_check=false catalog=false smoke=false shards=$r_shards"'
[ "$(grep -cxF -- "$needle" "$JOB_SET")" -eq 1 ] || exit 1
replacement='          patch_was="$(select_row "$(patch_line change_class)" "$(patch_line docs_only)" "$(patch_line changed_path)" pull_request)"'
NEEDLE="$needle" REPLACEMENT="$replacement" awk '$0 == ENVIRON["NEEDLE"] { print ENVIRON["REPLACEMENT"]; next } { print }' "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
! cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set" || exit 1
got="$(SELECT_WITH="$TMP/rule/tools/ci-job-set" SELECT_IN="$ADVANCED_WORLD" SELECT_EVENT=merge_group SELECT_MACOS_PROOF="$prior_record" selection micro false "$advanced_path")"
[ "$got" != "$advanced_expected" ] && ok "must-fail: rebuilding prior coverage invents macOS proof" || bad "must-fail: rebuilt prior coverage control"

# Reintroduce tree-only reuse in a disposable copy. The same-tree queue
# case must then lose its integrated Linux lanes, which fails the row above.
sed '/^\[ "\$EVENT" != merge_group \] || record=""$/d; /^  if \[ "\$EVENT" = merge_group \]; then$/,/^  fi$/d' "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
! cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set" || { echo "tree reuse control changed nothing" >&2; exit 1; }
chmod +x "$TMP/rule/tools/ci-job-set"
got="$(SELECT_WITH="$TMP/rule/tools/ci-job-set" SELECT_IN="$SEL_WORLD" SELECT_EVENT=merge_group SELECT_PROOF="$patch_record" selection micro false "$PRICE")"
[ "$got" != "$PRICE_GROUP" ] && ok "must-fail: tree-only reuse skips queue integration" || bad "must-fail: tree-only reuse still retains queue integration"
# Coverage controls plant Linux reuse and retain an already proven macOS queue.
while IFS='@' read -r needle replacement expected; do
  [ "$(grep -cF -- "$needle" "$JOB_SET")" -eq 1 ] || { echo "patch control needle is not unique" >&2; exit 1; }
  NEEDLE="$needle" REPLACEMENT="$replacement" awk '{ i=index($0,ENVIRON["NEEDLE"]); if(i) $0=substr($0,1,i-1) ENVIRON["REPLACEMENT"] substr($0,i+length(ENVIRON["NEEDLE"])); print }' "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
  ! cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set" || exit 1
  got="$(SELECT_WITH="$TMP/rule/tools/ci-job-set" SELECT_IN="$SEL_WORLD" SELECT_EVENT=merge_group SELECT_MACOS_PROOF="$patch_record" selection micro false "$PRICE")"
  [ "$got" != "$expected" ] && ok "must-fail: patch rule $needle" || bad "must-fail: patch rule $needle"
done <<ROWS
case "\$lane" in macos | cargo_macos) ;; *) ran=false ;; esac@case "\$lane" in macos | cargo_macos) ;; linux | cargo_linux) ran=true ;; *) ran=false ;; esac@$patch_expected
case "\$legs" in *macos-latest*) ;; *) queue="" ;; esac@:@$patch_expected
ROWS

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
