#!/usr/bin/env bash
# tools/guard --full, the completion run: the working-tree bot-instructions
# check, the decision-ID check, the cross-target compile of core and the CLI, the Rust inputs that
# decide whether it and cargo doc run, the suites of the trees the branch
# touched, and a test binary's death by a signal named apart from a failing
# test.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GUARD_FULL_CROSS_DOC

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/guard-world.sh
. "$TEST_DIR/lib/guard-world.sh"
# Unreachable bounds: a --full run that bypasses GUARD_TEST_BOUNDS refuses on
# every host, not only on one short of space.
export GUARD_MIN_FREE_GB=1000000 GUARD_EXHAUSTED_FREE_MB=1000000000

echo "=== bot instructions: full validation reads the worktree; the staged check is the chain's lane ==="
BOT="$REPO/.agents/skills/bot-instructions/scripts/bot-instructions"
printf '\n[bot-instructions.bots]\ncodex = true\ncopilot = true\n' >>"$R/kendex.toml"
printf '\n## Code Review Rules\n\nFixture rules.\n' >>"$R/AGENTS.md"
git -C "$R" add -A
# `adopt` takes the hand-written region over and reports it under
# `agents-region` with exit 1, because the managed region is one directive
# line; the `render` below is the migration. Exit 1 is every adopt-path
# finding's status, so the finding is named rather than the status accepted
# bare.
ADOPT_OUT="$("$BOT" adopt --repo "$R" 2>&1)" || {
  [ "$?" -eq 1 ] && [[ "$ADOPT_OUT" == *"agents-region:"* ]] \
    || { echo "adopt failed without agents-region: $ADOPT_OUT" >&2; exit 1; }
}
"$BOT" render --repo "$R" >/dev/null
git -C "$R" add -A
run_guard
[ "$RC" -eq 0 ] && ok "matching staged bot output passes" || bad "matching staged bot output passes" "$OUT"
printf '\nStale instructions.\n' >>"$R/.github/copilot-instructions.md"
run_guard
[ "$RC" -eq 0 ] && ok "commit checks ignore unstaged bot edits" || bad "commit checks ignore unstaged bot edits" "$OUT"
FULL_GUARD=1
run_guard
[ "$RC" -eq 1 ] && [[ "$OUT" == *"drift:"*".github/copilot-instructions.md"* ]] \
  && [[ "$OUT" == *"guard: bot-instructions=1"* ]] \
  && ok "full validation rejects stale worktree bot output" \
  || bad "full validation rejects stale worktree bot output" "rc=$RC out=$OUT"
FULL_GUARD=0
git -C "$R" add .github/copilot-instructions.md
"$BOT" render --repo "$R" >/dev/null
run_guard
# The commit-guards pre-commit chain runs `bot-instructions check --staged`
# as its own lane before this script; a second staged run here would judge
# the same index twice.
[ "$RC" -eq 0 ] && [[ "$OUT" != *"drift:"* ]] \
  && ok "commit checks leave the staged bot check to the chain's lane" \
  || bad "commit checks leave the staged bot check to the chain's lane" "rc=$RC out=$OUT"
git -C "$R" reset -q --hard HEAD
rm -rf -- "$R/.github"

echo "=== a decision ID two INDEX rows share reds full validation; CI also judges decision identity ==="
# The world's kendex.settings.toml names docs/decisions. The world has no
# remote, so its local main is the base; that commit has no INDEX.md, the base
# half passes with its index-absent notice, and the duplicate half decides.
mkdir -p "$R/docs/decisions"
printf '%s\n' \
  '| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |' \
  '|------|----|----------|----------|-----------|--------------|--------|------|' \
  '| 2026-01-10 | D035 | P-1 | One | Reason | Never | Active | [Full](D035-one.md) |' \
  '| 2026-01-11 | D035 | P-2 | Two | Reason | Never | Active | [Full](D035-two.md) |' \
  >"$R/docs/decisions/INDEX.md"
FULL_GUARD=0
run_guard
[ "$RC" -eq 0 ] && [[ "$OUT" != *"guard: decision-ids="* ]] \
  && ok "the commit chain leaves decision IDs to full validation or CI" \
  || bad "the commit chain leaves decision IDs to full validation or CI" "rc=$RC out=$OUT"
FULL_GUARD=1
run_guard
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: decision-ids=1"* ]] \
  && [[ "$OUT" == *"error=id-duplicate-row id=D035 rows=3,4"* ]] \
  && [[ "$OUT" == *"notice=base-unverified ref=main reason=index-absent"* ]] \
  && [[ "$OUT" != *$'\n'"error=base-unverified"* ]] \
  && ok "full validation reds through the decision-ID lane, naming the rows" \
  || bad "full validation reds through the decision-ID lane, naming the rows" "rc=$RC out=$OUT"
if mutant_guard 's/say decision-ids "\$decision_status"/:/g'; then
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$MUTANT_TOOLS/guard" --full 2>&1 </dev/null)" || RC=$?
  [ "$RC" -eq 0 ] \
    && ok "control: with the decision-ID finding cut the same INDEX passes" \
    || bad "control: with the decision-ID finding cut the same INDEX passes" "rc=$RC out=$OUT"
else
  bad "control: the decision-ID finding could not be cut from a guard copy"
fi
FULL_GUARD=0
FULL_GUARD=1
run_guard DECISIONS_BASE_REF=missing-base
[ "$RC" -eq 1 ] && [[ "$OUT" == *'guard: decision-ids=1'* ]] \
  && [[ "$OUT" == *'guard-note: no-verdict=decision-ids=1'* ]] \
  && ok 'an unavailable decision base cannot hide duplicate local IDs' \
  || bad 'decision code finding takes priority' "rc=$RC out=$OUT"
sed '4d' "$R/docs/decisions/INDEX.md" >"$TMP/unique-index"
cp "$TMP/unique-index" "$R/docs/decisions/INDEX.md"
run_guard DECISIONS_BASE_REF=missing-base
[ "$RC" -eq 3 ] && [[ "$OUT" == *'guard-note: no-verdict=decision-ids=1'* ]] \
  && [[ "$OUT" != *'guard: decision-ids='* ]] \
  && ok 'an unavailable decision base has no verdict' \
  || bad 'decision base no-verdict' "rc=$RC out=$OUT"
if mutant_guard 's/unrun decision-ids "\$decision_status"/:/'; then
  GUARD="$MUTANT_TOOLS/guard" run_guard DECISIONS_BASE_REF=missing-base
  [ "$RC" -eq 0 ] && ok 'control: dropping unavailable-base evidence turns its row red' \
    || bad 'decision base control' "rc=$RC out=$OUT"
else bad 'decision base control changed nothing'; fi
FULL_GUARD=0
rm -rf -- "$R/docs/decisions"

echo "=== a file Bash 3.2 cannot parse reds full validation, and only full validation ==="
# The shape from the failure the lane answers: a `case` inside a command
# substitution whose patterns carry no leading `(`. Bash 5 parses it, so no
# host shell and no text scan reports it, and before this lane the first
# report was the macOS CI leg.
printf '%s\n' '#!/usr/bin/env bash' \
  'verdicts=$(for v in a b; do' \
  '  case "$v" in' \
  '    a) echo one ;;' \
  '  esac' \
  'done)' \
  'printf "%s\\n" "$verdicts"' >"$R/tools/planted.sh"
FULL_GUARD=0
run_guard
[ "$RC" -eq 0 ] \
  && ok "the commit chain passes it: the lane is full validation's, so a commit needs no Bash 3.2" \
  || bad "the commit chain passes it: the lane is full validation's, so a commit needs no Bash 3.2" "rc=$RC out=$OUT"
FULL_GUARD=1
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: bash32-parse=1"* ]] \
  && [[ "$OUT" == *"bash32-parse: syntax=1"* ]] && [[ "$OUT" == *"tools/planted.sh"* ]] \
  && ok "full validation reds through the parse lane, naming the file" \
  || bad "full validation reds through the parse lane, naming the file" "rc=$RC out=$OUT"
if mutant_guard '/TOOLS_DIR\/bash32-parse/d'; then
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$MUTANT_TOOLS/guard" --full 2>&1)" || RC=$?
  [ "$RC" -eq 0 ] \
    && ok "control: with the parse lane deleted the same file passes" \
    || bad "control: with the parse lane deleted the same file passes" "rc=$RC out=$OUT"
else
  bad "control: the parse lane could not be deleted from a guard copy"
fi
rm -f "$R/tools/planted.sh"

echo "=== an absent Bash 3.2 parser has no verdict ==="
cp "$GUARD" "$MUTANT_TOOLS/guard"
cp "$MUTANT_TOOLS/bash32-parse" "$TMP/parser-kept"
printf '#!/usr/bin/env bash\nprintf "bash32-parse: no-bash32=absent\\n"\nexit 2\n' >"$MUTANT_TOOLS/bash32-parse"
GUARD="$MUTANT_TOOLS/guard" run_guard
[ "$RC" -eq 3 ] && [[ "$OUT" == *'guard-note: no-verdict=bash32-parse=2'* ]] \
  && ok 'a missing parser reports no-verdict with its host cause' \
  || bad 'missing parser no-verdict' "rc=$RC out=$OUT"
if mutant_guard 's/2) unrun bash32-parse/2) note bash32-parse/'; then
  GUARD="$MUTANT_TOOLS/guard" run_guard
  [ "$RC" -eq 0 ] && ok 'control: dropping the unavailable parser result turns its row red' \
    || bad 'missing parser control' "rc=$RC out=$OUT"
else bad 'missing parser control changed nothing'; fi
cp "$TMP/parser-kept" "$MUTANT_TOOLS/bash32-parse"

FULL_GUARD=1
echo "=== full validation runs the ceiling check, and no growth check ==="
# The merge base with origin/main resolves, and a document grown from it to
# its ceiling passes: completion judges the ceiling alone.
# The Bash 3.2 container uses host-owned storage, outside the fixture's cleanup.
GUARD_TEST_ENV=(-i "PATH=$PATH" "HOME=$HOME")
git -C "$R" config gc.auto 0
git -C "$R" config maintenance.auto false
mkdir -p "$R/pkg"
printf '%1005s' '' >"$R/pkg/AGENTS.md"
git -C "$R" add pkg/AGENTS.md
git -C "$R" commit -q -m "chore: document at branch point"
git -C "$R" update-ref refs/remotes/origin/main HEAD
printf '%1024s' '' >"$R/pkg/AGENTS.md"
git -C "$R" add pkg/AGENTS.md
run_guard DOC_LIMITS_SETTINGS_FILE=/dev/null DOC_LIMITS_CLASSES=pkg/AGENTS.md=1k
[ "$RC" -eq 0 ] && [[ "$OUT" == *"notice=documents-checked"* ]] \
  && ok "a document grown to its ceiling from the merge base passes completion" \
  || bad "a document grown to its ceiling from the merge base passes completion" "rc=$RC out=$OUT"
printf '%1025s' '' >"$R/pkg/AGENTS.md"
git -C "$R" add pkg/AGENTS.md
run_guard DOC_LIMITS_SETTINGS_FILE=/dev/null DOC_LIMITS_CLASSES=pkg/AGENTS.md=1k
[ "$RC" -eq 1 ] && [[ "$OUT" == *"notice=document-over-limit path=pkg/AGENTS.md"* ]] \
  && [[ "$OUT" == *"guard: doc-limits=1"* ]] \
  && ok "a load-point document over its ceiling reds completion" \
  || bad "a load-point document over its ceiling reds completion" "rc=$RC out=$OUT"
doc_limits_matches="$(grep -cFx '  "$TOOLS_DIR/../.agents/skills/doc-limits/scripts/doc-limits" || say doc-limits "$?"' "$GUARD")" \
  || { echo 'ceiling control: call match failed' >&2; exit 1; }
[ "$doc_limits_matches" -eq 1 ] \
  || { echo 'ceiling control: call edit has no unique match' >&2; exit 1; }
if mutant_guard 's#^  "\$TOOLS_DIR/\.\./\.agents/skills/doc-limits/scripts/doc-limits" || say doc-limits "\$?"$#  :#'; then
  GUARD="$MUTANT_TOOLS/guard" run_guard DOC_LIMITS_SETTINGS_FILE=/dev/null DOC_LIMITS_CLASSES=pkg/AGENTS.md=1k
  [ "$RC" -eq 0 ] && [[ "$OUT" != *"notice=document-over-limit"* ]] \
    && ok "control: without the ceiling call the over-limit document passes completion" \
    || bad "control: without the ceiling call the over-limit document passes completion" "rc=$RC out=$OUT"
else
  bad "control: the ceiling call could not be removed from a guard copy"
fi
git -C "$R" update-ref -d refs/remotes/origin/main
reset_world
unset GUARD_TEST_ENV

echo "=== full validation compiles every cross target ==="
mkdir -p "$R/fake-bin"
cat >"$R/fake-bin/rustup" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = "target list --installed" ]
[ "${RUSTUP_LIST_RESULT:-0}" -eq 0 ]
# Space-separated in, one target per line out, the shape guard greps.
for t in ${RUSTUP_INSTALLED_TARGETS:-}; do printf '%s\n' "$t"; done
SH
cat >"$R/fake-bin/cargo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CARGO_CALL_LOG"
[ -z "${CARGO_ENV_LOG:-}" ] || printf '%s|incremental=%s\n' "$*" "${CARGO_INCREMENTAL:-unset}" >>"$CARGO_ENV_LOG"
# Cargo may be installed without its optional Clippy or rustfmt component.
if [ "${1:-}" = "${MISSING_COMPONENT:-}" ]; then
  printf "error: 'cargo-%s' is not installed for the toolchain\n" "$1" >&2
  exit 1
fi
# rustfmt's status: 1 for a diff it wrote, 0 when that write failed. A write
# straight to the guard's own stream, FMT_FULL_STREAM, lands on a full device.
if [ "$*" = "fmt --check" ] && [ -n "${FMT_FULL_STREAM:-}" ]; then
  [ ! /dev/stdout -ef "$FMT_FULL_STREAM" ] || exec >/dev/full
  printf 'Diff in src/lib.rs:\n' && exit 1
  exit 0
fi
# A test run under CARGO_WRITE_UNIT leaves that source state's unit in the
# target, as a build after a dependency change writes one under a new hash.
if [ "$*" = "test --workspace --quiet" ] && [ -n "${CARGO_WRITE_UNIT:-}" ]; then
  mkdir -p "$CARGO_TARGET_DIR/debug/deps"
  printf 'unit\n' >"$CARGO_TARGET_DIR/debug/deps/unit-$CARGO_WRITE_UNIT.rlib"
fi
for t in ${CROSS_CHECK_FAIL:-}; do
  if [ "$*" = "check -p kendex-core -p kendex-cli --all-targets --target $t" ]; then
    exit 1
  fi
done
SH
chmod +x "$R/fake-bin/rustup" "$R/fake-bin/cargo"
printf '[workspace]\n' >"$R/Cargo.toml"
git -C "$R" add Cargo.toml
CARGO_CALL_LOG="$TMP/cargo-calls"
# The platforms the release builds and this host does not run. Written out
# here on purpose: a list read back from guard would pass whatever guard
# named.
APPLE=aarch64-apple-darwin
WINDOWS=x86_64-pc-windows-msvc
BOTH="$APPLE $WINDOWS"
check_call() { # TARGET — the one cargo line guard is allowed to run for it
  printf 'check -p kendex-core -p kendex-cli --all-targets --target %s' "$1"
}

echo "=== full validation protects the cargo target volume ==="
cat >"$R/fake-bin/df" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ -e "${!#}" ] || exit 1
printf 'call\n' >>"$DF_CALL_LOG"
call="$(wc -l <"$DF_CALL_LOG" | tr -d ' ')"
[ "${DF_FAIL_CALL:-0}" -ne "$call" ] || exit 1
free="${DF_FREE_KIB_START:?}"
[ "$call" -eq 1 ] || free="${DF_FREE_KIB_END:?}"
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on'
printf 'tmpfs 999999 1 %s 1%% /target\n' "$free"
SH
cat >"$R/fake-bin/du" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ -z "${DU_FAIL:-}" ] || exit 1
shift
for p in "$@"; do
  case "$p" in
    */incremental) printf '%s\t%s\n' "${DU_INCREMENTAL_KIB:?}" "$p" ;;
    *) printf '%s\t%s\n' "${DU_KIB:?}" "$p" ;;
  esac
done
SH
chmod +x "$R/fake-bin/df" "$R/fake-bin/du"
mkdir -p "$TMP/warm" "$TMP/inc/debug/incremental"
DF_CALL_LOG="$TMP/df-calls"
CARGO_ENV_LOG="$TMP/cargo-env"
G=$((1024 * 1024))
high_free_kib=$((30 * G))
# label | env | exit | keyed line, empty for none | 1 when cargo ran. Unset
# CARGO_TARGET_DIR is the world's absent target/; $TMP/cold/target is absent
# below an existing directory.
SPACE_ROWS=(
  "a cold target below the start floor has no verdict before cargo|CARGO_TARGET_DIR=$TMP/cold/target DF_FREE_KIB_START=$G|3|guard-note: no-verdict=cargo-space-start=free-kib=$G target-kib=0 min-gib=24|0"
  "the build in a warm target counts toward the start floor|CARGO_TARGET_DIR=$TMP/warm DU_KIB=$((23 * G)) DF_FREE_KIB_START=$G|0||1"
  "free space below the exhaustion floor has no verdict before the target is measured|DU_FAIL=1 CARGO_TARGET_DIR=$TMP/inc DF_FREE_KIB_START=708|3|guard-note: no-verdict=cargo-space-free=free-kib=708 min-free-mib=512|0"
  "an incremental directory is not room|CARGO_TARGET_DIR=$TMP/inc DU_KIB=$((30 * G)) DU_INCREMENTAL_KIB=$((8 * G)) DF_FREE_KIB_START=$G|3|guard-note: no-verdict=cargo-space-start=free-kib=$G target-kib=$((22 * G)) min-gib=24|0"
  "a volume above the start floor reaches the cargo block|DF_FREE_KIB_START=$high_free_kib|0||1"
  "an unreadable start probe has no verdict before cargo|DF_FAIL_CALL=1 DF_FREE_KIB_START=$G|3|guard-note: no-verdict=cargo-space-unreadable=target|0"
  "an unreadable target size has no verdict before cargo|DU_FAIL=1 CARGO_TARGET_DIR=$TMP/warm DF_FREE_KIB_START=$G|3|guard-note: no-verdict=cargo-target-unreadable=$TMP/warm|0"
  "an exhausted volume has no verdict after zero cargo exit codes, with cross-target checks left to CI|GUARD_FULL_CROSS_DOC=ci DF_FREE_KIB_START=$high_free_kib DF_FREE_KIB_END=0|3|guard-note: no-verdict=cargo-space-end=free-kib=0 min-mib=512|1"
  "an unreadable end probe has no verdict|DF_FAIL_CALL=2 DF_FREE_KIB_START=$high_free_kib|3|guard-note: no-verdict=cargo-space-end-unreadable=target|1"
  "a malformed start floor has no verdict|GUARD_MIN_FREE_GB=16GiB DF_FREE_KIB_START=$high_free_kib|3|guard-note: no-verdict=cargo-space-setting=GUARD_MIN_FREE_GB|0"
  "a malformed exhaustion floor has no verdict|GUARD_EXHAUSTED_FREE_MB=512MB DF_FREE_KIB_START=$high_free_kib DF_FREE_KIB_END=0|3|guard-note: no-verdict=cargo-space-setting=GUARD_EXHAUSTED_FREE_MB|0"
  "a zero exhaustion floor has no verdict|GUARD_EXHAUSTED_FREE_MB=0 DF_FREE_KIB_START=$high_free_kib DF_FREE_KIB_END=0|3|guard-note: no-verdict=cargo-space-setting=GUARD_EXHAUSTED_FREE_MB|0"
  "a compile error stays blocking when the end volume is exhausted|CROSS_CHECK_FAIL=$APPLE DF_FREE_KIB_START=$high_free_kib DF_FREE_KIB_END=0|1|guard-note: no-verdict=cargo-space-end=free-kib=0 min-mib=512|1"
)
# A touched suite that leaves a marker: a refused start must end the run before
# the suite lane, where a suite may run cargo of its own.
SUITE_MARKER="$TMP/suite-ran"
printf ': >"$SUITE_MARKER"\n' >>"$R/skills/demo/tests/demo.test.sh"
space_row_holds() { # N — run row N under $GUARD; succeed when every expectation holds
  local env rc key ran did=0 suite=0
  IFS='|' read -r _ env rc key ran <<<"${SPACE_ROWS[$1]}"
  read -ra row_env <<<"$env"
  : >"$DF_CALL_LOG"
  : >"$CARGO_CALL_LOG"
  : >"$CARGO_ENV_LOG"
  rm -f -- "${SUITE_MARKER:?}"
  run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" CARGO_ENV_LOG="$CARGO_ENV_LOG" SUITE_MARKER="$SUITE_MARKER" \
    DF_CALL_LOG="$DF_CALL_LOG" DF_FREE_KIB_END="$high_free_kib" RUSTUP_INSTALLED_TARGETS="$BOTH" \
    GUARD_MIN_FREE_GB=24 GUARD_EXHAUSTED_FREE_MB=512 CARGO_INCREMENTAL=1 "${row_env[@]}"
  [ ! -s "$CARGO_CALL_LOG" ] || did=1
  [ ! -e "$SUITE_MARKER" ] || suite=1
  # The touched demo suite runs exactly where cargo does, and every cargo
  # call that ran inherited the guard's CARGO_INCREMENTAL=0.
  [ "$RC" -eq "$rc" ] && [ "$did" -eq "$ran" ] && [ "$suite" -eq "$ran" ] && { [ -z "$key" ] || [[ "$OUT" == *"$key"$'\n'* ]]; } &&
    ! grep -qvF '|incremental=0' "$CARGO_ENV_LOG" &&
    [ "$(wc -l <"$CARGO_ENV_LOG")" -eq "$(wc -l <"$CARGO_CALL_LOG")" ]
}
for n in "${!SPACE_ROWS[@]}"; do
  label="${SPACE_ROWS[$n]%%|*}"
  space_row_holds "$n" && ok "$label" || bad "$label" "rc=$RC out=$OUT calls=$(cat "$CARGO_CALL_LOG")"
done
# One control per rule: row N | the edit that removes the rule.
while IFS='|' read -r n edit; do
  label="${SPACE_ROWS[$n]%%|*}"
  if mutant_guard "$edit"; then
    GUARD="$MUTANT_TOOLS/guard" space_row_holds "$n" \
      && bad "control: the row fails with the rule removed: $label" "edit=$edit" \
      || ok "control: the row fails with the rule removed: $label"
  else
    bad "control: the edit changed no guard line: $edit"
  fi
done <<'EDITS'
0|/^space_stop() {/,/^}/s/^  exit "\$fail"$/  :/
0|/^  while \[ ! -e "\$path" \]; do$/,/^  done$/d
1|s/"\$((cargo_free_start_kib + cargo_target_start_kib))"/"$cargo_free_start_kib"/
2|s/^  elif \[ "\$cargo_free_start_kib" -lt/  elif false \&\& [ "$cargo_free_start_kib" -lt/
2|s/^  elif \[ "\$cargo_free_start_kib" -lt/  elif cargo_target_kib "$cargo_target_path" >\/dev\/null \&\& [ "$cargo_free_start_kib" -lt/
3|s/{ kib -= \$1 }/{ }/
5|s/^    space_stop cargo-space-unreadable/    note cargo-space-unreadable/
6|s/^    space_stop cargo-target-unreadable/    note cargo-target-unreadable/
7|s/^    unrun cargo-space-end "free-kib/    note cargo-space-end "free-kib/
8|s/^    unrun cargo-space-end-unreadable/    note cargo-space-end-unreadable/
9|s/"" | \*\[!0-9\]\*) space_stop cargo-space-setting/"") space_stop cargo-space-setting/
10|/^  whole_setting GUARD_EXHAUSTED_FREE_MB/d
11|s/^    \*\[!0\]\*) ;;$/    *) ;;/
4|/^  export CARGO_INCREMENTAL=0$/d
12|s/\[ "\$fail" -eq 1 \] || fail=3/fail=3/
EDITS
git -C "$R" checkout -q -- skills/demo/tests/demo.test.sh

for component in clippy fmt; do
  : >"$DF_CALL_LOG"
  run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" DF_CALL_LOG="$DF_CALL_LOG" \
    DF_FREE_KIB_START="$high_free_kib" DF_FREE_KIB_END="$high_free_kib" RUSTUP_INSTALLED_TARGETS="$BOTH" MISSING_COMPONENT="$component"
  [ "$RC" -eq 3 ] && [[ "$OUT" == *"guard-note: no-verdict=missing-tool=cargo-$component"* ]] \
    && ok "workspace: missing $component has no verdict" \
    || bad "workspace component availability: $component" "rc=$RC out=$OUT"
  if mutant_guard "s/if ! cargo $component --version >\/dev\/null 2>\&1/if false/"; then
    : >"$DF_CALL_LOG"
    GUARD="$MUTANT_TOOLS/guard" run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" DF_CALL_LOG="$DF_CALL_LOG" \
      DF_FREE_KIB_START="$high_free_kib" DF_FREE_KIB_END="$high_free_kib" RUSTUP_INSTALLED_TARGETS="$BOTH" MISSING_COMPONENT="$component"
    expected=1; diagnostic='guard: clippy=workspace'
    if [ "$component" = fmt ]; then expected=0; diagnostic='guard-note: cargo-fmt=workspace'; fi
    [ "$RC" -eq "$expected" ] && [[ "$OUT" == *"$diagnostic"* ]] \
      && ok "control: removing $component availability turns its host row red" \
      || bad "component availability control: $component" "rc=$RC out=$OUT"
  else bad "component availability control changed nothing: $component"; fi
done

# Every other lane fails its own write on a full stream too, so only fmt's
# write straight to the guard's stream lands on the device.
if [ -e /dev/full ]; then
  fmt_full_row() { # GUARD_PATH — sets OUT and RC
    : >"$DF_CALL_LOG"
    RC=0
    (cd "$R" && env "${GUARD_TEST_BOUNDS[@]}" PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" DF_CALL_LOG="$DF_CALL_LOG" \
      FMT_FULL_STREAM="$TMP/guard-stream" DF_FREE_KIB_START="$high_free_kib" DF_FREE_KIB_END="$high_free_kib" \
      RUSTUP_INSTALLED_TARGETS="$BOTH" "$1" --full >"$TMP/guard-stream" 2>&1 </dev/null) || RC=$?
    OUT="$(cat "$TMP/guard-stream")"
  }
  fmt_full_row "$GUARD"
  [ "$RC" -eq 0 ] && [[ "$OUT" == *"guard-note: cargo-fmt=workspace"*"Diff in src/lib.rs:"* ]] \
    && ok "a format diff warns and passes" \
    || bad "a format diff warns and passes" "rc=$RC out=$OUT"
  if mutant_guard 's/  fmt_out=$(cargo fmt --check 2>&1) || note/  fmt_out=$(cargo fmt --check 2>\&1) || say/'; then
    fmt_full_row "$MUTANT_TOOLS/guard"
    [ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: cargo-fmt=workspace"* ]] \
      && ok "control: with formatting blocking the same diff fails" \
      || bad "control: with formatting blocking the same diff fails" "rc=$RC out=$OUT"
  else
    bad "control: the fmt capture could not be removed from a guard copy"
  fi
else
  echo "  skip  /dev/full is absent; the full-output fmt row did not run"
fi

# A full run deletes nothing from target/: the second of two runs leaves the
# first run's superseded unit beside its own. What bounds target/ across rounds
# is the round-start prune, outside every validation run, and
# skills/orch/tests/round_prune.sh measures it across two simulated validation
# runs of the same shape.
RUNS_TARGET="$TMP/two-runs/target"
mkdir -p "$RUNS_TARGET/debug"
: >"$RUNS_TARGET/debug/.cargo-lock"
runs_units() { (cd "$RUNS_TARGET" && find . -name 'unit-*' | sed 's|.*/||' | sort | paste -s -d ',' -); }
RUNS_SEEN="before=[$(runs_units)]"
for unit in 1 2; do
  : >"$DF_CALL_LOG"
  run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" DF_CALL_LOG="$DF_CALL_LOG" \
    DF_FREE_KIB_START="$high_free_kib" DF_FREE_KIB_END="$high_free_kib" DU_KIB=0 DU_INCREMENTAL_KIB=0 \
    RUSTUP_INSTALLED_TARGETS="$BOTH" CARGO_TARGET_DIR="$RUNS_TARGET" CARGO_WRITE_UNIT="$unit"
  RUNS_SEEN="$RUNS_SEEN rc$unit=$RC after$unit=[$(runs_units)]"
done
[ "$RUNS_SEEN" = "before=[] rc1=0 after1=[unit-1.rlib] rc2=0 after2=[unit-1.rlib,unit-2.rlib]" ] \
  && ok "two full runs leave target/ holding both runs' units: the guard deletes nothing" \
  || bad "two full runs leave target/ holding both runs' units: the guard deletes nothing" "$RUNS_SEEN out=$OUT"
rm -f "$R/fake-bin/df" "$R/fake-bin/du"

: >"$CARGO_CALL_LOG"
run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_LIST_RESULT=1
[ "$RC" -eq 3 ] && case "$OUT" in *"guard-note: no-verdict=rustup-targets=unreadable"*) true ;; *) false ;; esac \
  && ok "a failed installed-target lookup blocks guard" \
  || bad "a failed installed-target lookup blocks guard" "rc=$RC out=$OUT"
run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_INSTALLED_TARGETS=x86_64-unknown-linux-gnu
[ "$RC" -ne 0 ] &&
  case "$OUT" in *"guard-note: no-verdict=missing-target=$APPLE"*) true ;; *) false ;; esac &&
  case "$OUT" in *"guard-note: no-verdict=missing-target=$WINDOWS"*) true ;; *) false ;; esac \
  && ok "every missing target is refused with its own install command" \
  || bad "every missing target is refused with its own install command" "rc=$RC out=$OUT"
if grep -qE -- "--target ($APPLE|$WINDOWS)\$" "$CARGO_CALL_LOG"; then
  bad "a missing target is not handed to cargo" "$(cat "$CARGO_CALL_LOG")"
else
  ok "a missing target is not handed to cargo"
fi
: >"$CARGO_CALL_LOG"
run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_INSTALLED_TARGETS="$WINDOWS"
[ "$RC" -eq 3 ] && case "$OUT" in *"guard-note: no-verdict=missing-target=$APPLE"*) true ;; *) false ;; esac &&
  [ "$(grep -cFx "$(check_call "$WINDOWS")" "$CARGO_CALL_LOG")" -eq 1 ] \
  && ok "a missing target does not stop the targets after it" \
  || bad "a missing target does not stop the targets after it" "rc=$RC out=$OUT log=$(cat "$CARGO_CALL_LOG")"
# The loop counts its own rows: an emptied target list is a red, never a green.
before=$((PASS + FAIL))
for failing in "$APPLE" "$WINDOWS"; do
  : >"$CARGO_CALL_LOG"
  run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_INSTALLED_TARGETS="$BOTH" CROSS_CHECK_FAIL="$failing"
  [ "$RC" -ne 0 ] && case "$OUT" in *"guard: cross-check=$failing"*) true ;; *) false ;; esac \
    && ok "a failing $failing compiler verdict blocks guard, naming it" \
    || bad "a failing $failing compiler verdict blocks guard, naming it" "rc=$RC out=$OUT"
done
[ "$((PASS + FAIL))" -gt "$before" ] || { echo "no row was asserted: the cross-target failures" >&2; exit 2; }
: >"$CARGO_CALL_LOG"
run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_INSTALLED_TARGETS="$BOTH"
[ "$RC" -eq 0 ] \
  && ok "installed targets that all compile reach the host suite" \
  || bad "installed targets that all compile reach the host suite" "rc=$RC out=$OUT"
for key in rustup-targets missing-target; do
  if mutant_guard "s/unrun $key/note $key/"; then
    if [ "$key" = missing-target ]; then
      GUARD="$MUTANT_TOOLS/guard" run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_INSTALLED_TARGETS=""
    else
      GUARD="$MUTANT_TOOLS/guard" run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_LIST_RESULT=1
    fi
    [ "$RC" -eq 0 ] && ok "control: losing $key evidence turns its host row red" \
      || bad "cross-toolchain control: $key" "rc=$RC out=$OUT"
  else bad "cross-toolchain control changed nothing: $key"; fi
done
[ "$(grep -cFx "$(check_call "$APPLE")" "$CARGO_CALL_LOG")" -eq 1 ] &&
  [ "$(grep -cFx "$(check_call "$WINDOWS")" "$CARGO_CALL_LOG")" -eq 1 ] \
  && ok "guard asks cargo once for every cross target's core and CLI tests" \
  || bad "guard asks cargo once for every cross target's core and CLI tests" "$(cat "$CARGO_CALL_LOG")"
FULL_GUARD=0
git -C "$R" reset -q HEAD -- Cargo.toml
rm -f "$R/Cargo.toml"

echo "=== the cross-target checks and cargo doc run for a Rust input, and a setting leaves them to CI ==="
pre_gated_head="$(git -C "$R" rev-parse HEAD)"
# The stubs stay out of every touched set here, so a row with nothing edited
# reads an empty one.
cp "$R/.git/info/exclude" "$TMP/exclude.saved"
printf 'fake-bin/\n' >>"$R/.git/info/exclude"
# A find that fails the include derivation's walk under FAIL_FIND=1 and is
# the real find for every other caller.
REAL_FIND="$(command -v find)"
cat >"$R/fake-bin/find" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${FAIL_FIND:-0}" -eq 1 ] && [ "${1:-}" = crates ] && [ "${4:-}" = -name ] && [ "${5:-}" = '*.rs' ]; then
  exit 1
fi
exec "$REAL_FIND" "$@"
SH
chmod +x "$R/fake-bin/find"
# A crate that includes two files outside crates/: one literal on the macro's
# own line, one on the line after it, the shape rustfmt gives a long one.
mkdir -p "$R/crates/app/src" "$R/docs/authoring"
printf '[package]\nname = "kendex-app"\n\n[lints]\nworkspace = true\n' >"$R/crates/app/Cargo.toml"
printf 'const GUIDE: &str = include_str!("../../../docs/authoring/README.md");\n' >"$R/crates/app/src/mine.rs"
printf 'const SPLIT: &str = include_str!(\n    "../../../docs/split.md"\n);\n' >"$R/crates/app/src/split.rs"
printf '# guide\n' >"$R/docs/authoring/README.md"
printf '# split\n' >"$R/docs/split.md"
printf '# notes\n' >"$R/docs/notes.md"
printf '[workspace]\n' >"$R/Cargo.toml"
printf '# lock\n' >"$R/Cargo.lock"
git -C "$R" add crates/app docs Cargo.toml Cargo.lock
git -C "$R" commit -q -m "chore: a crate that includes two docs files"
gated_head="$(git -C "$R" rev-parse HEAD)"
DOC_CALL="doc --no-deps --document-private-items --workspace --quiet"
# GUARD_PATH TOUCH BASE [VAR=VALUE...] — the world at the crate commit with
# TOUCH edited (- edits nothing), origin/main at that commit under BASE=main
# and absent under BASE=none, run by that guard.
gated_run() {
  local guard_path="$1" touch="$2" base="$3"
  shift 3
  git -C "$R" reset -q --hard "$gated_head"
  case "$base" in
    main) git -C "$R" update-ref refs/remotes/origin/main "$gated_head" ;;
    none) git -C "$R" update-ref -d refs/remotes/origin/main ;;
    *) echo "gated_run: no base named $base" >&2; exit 2 ;;
  esac
  [ "$touch" = - ] || printf '// edit\n' >>"$R/$touch"
  : >"$CARGO_CALL_LOG"
  GUARD="$guard_path" FULL_GUARD=1 run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" \
    REAL_FIND="$REAL_FIND" RUSTUP_INSTALLED_TARGETS="$BOTH" "$@"
}
gated_ran() { # — both cross targets and cargo doc, once each
  [ "$(grep -cFx "$(check_call "$APPLE")" "$CARGO_CALL_LOG")" -eq 1 ] &&
    [ "$(grep -cFx "$(check_call "$WINDOWS")" "$CARGO_CALL_LOG")" -eq 1 ] &&
    [ "$(grep -cFx "$DOC_CALL" "$CARGO_CALL_LOG")" -eq 1 ]
}
gated_skipped() { # — neither a cross target nor cargo doc, and the host test run still
  ! grep -qE -- '--target |^doc ' "$CARGO_CALL_LOG" &&
    grep -qFx "test --workspace --quiet" "$CARGO_CALL_LOG"
}
# RC CALLS TEXT — the last run exited RC, ran (run) or skipped (skip) both
# checks, and printed TEXT; a run with no TEXT printed no cross-doc notice.
gated_verdict() {
  [ "$RC" -eq "$1" ] || return 1
  case "$2" in
    run) gated_ran ;;
    skip) gated_skipped ;;
    *) echo "gated_verdict: no call verdict named $2" >&2; exit 2 ;;
  esac || return 1
  if [ -n "$3" ]; then
    [[ "$OUT" == *"$3"* ]]
  else
    [[ "$OUT" != *"guard-note: cross-doc-skipped="* ]]
  fi
}
# One row per input the gate decides on: TOUCH|SETTING|BASE|ENV|RC|CALLS|TEXT|LABEL.
# The loop counts its own rows: an emptied table is a red, never a green.
before=$((PASS + FAIL))
while IFS='|' read -r touch setting base extra rc calls text label; do
  [ -n "$touch" ] || continue
  env_args=()
  [ -z "$setting" ] || env_args+=("GUARD_FULL_CROSS_DOC=$setting")
  [ -z "$extra" ] || env_args+=("$extra")
  gated_run "$GUARD" "$touch" "$base" ${env_args[@]+"${env_args[@]}"}
  gated_verdict "$rc" "$calls" "$text" && ok "$label" \
    || bad "$label" "rc=$RC out=$OUT calls=$(cat "$CARGO_CALL_LOG")"
done <<'ROWS'
docs/notes.md||main||0|skip|guard-note: cross-doc-skipped=no-rust-input|a prose file compiled code does not include skips both, naming why
crates/app/src/mine.rs||main||0|run||a crate source runs both
Cargo.lock||main||0|run||the workspace lock runs both
docs/authoring/README.md||main||0|run||a file an include_str! on its own line names runs both
docs/split.md||main||0|run||a file an include_str! names on the line after it runs both
crates/app/src/mine.rs|ci|main||0|skip|guard-note: cross-doc-skipped=ci|the setting at ci leaves both to CI for a crate source
crates/app/src/mine.rs|run|main||0|run||the setting at run keeps both for a crate source
crates/app/src/mine.rs|never|main||1|run|guard: cross-doc-setting=never|a setting that is neither run nor ci is refused, and both still run
-||main||0|run||a branch at its base with a clean tree touches nothing, and both run
docs/notes.md||main|FAIL_FIND=1|1|run|guard: rust-reads=crates|a failed include read is refused, and both still run
docs/notes.md||none||0|run||a committed crate change with no origin/main to diff against runs both
ROWS
[ "$((PASS + FAIL))" -gt "$before" ] || { echo "no row was asserted: the cross-doc gate" >&2; exit 2; }
# One control per rule: each mutant removes that rule from a guard copy, and
# the row the rule decides turns to the verdict the rule was there to refuse.
# An edit carries no |, the column separator. EDIT|TOUCH|SETTING|BASE|ENV|RC|CALLS|TEXT|LABEL.
base_rule_matches="$(grep -c '^  \[ "\$base_resolved" -eq 1 \].*rust_input=1$' "$GUARD")" \
  || { echo 'cross-doc control: base rule match failed' >&2; exit 1; }
[ "$base_rule_matches" -eq 1 ] \
  || { echo 'cross-doc control: base rule edit has no unique match' >&2; exit 1; }
before=$((PASS + FAIL))
while IFS='|' read -r edit touch setting base extra rc calls text label; do
  [ -n "$edit" ] || continue
  if mutant_guard "$edit"; then
    env_args=()
    [ -z "$setting" ] || env_args+=("GUARD_FULL_CROSS_DOC=$setting")
    [ -z "$extra" ] || env_args+=("$extra")
    gated_run "$MUTANT_TOOLS/guard" "$touch" "$base" ${env_args[@]+"${env_args[@]}"}
    gated_verdict "$rc" "$calls" "$text" && ok "control: $label" \
      || bad "control: $label" "rc=$RC out=$OUT calls=$(cat "$CARGO_CALL_LOG")"
  else
    bad "control: $label" "the edit changed nothing in a guard copy: $edit"
  fi
done <<'ROWS'
s/^  rust_input=0$/  rust_input=1/|docs/notes.md||main||0|run||with the touched-set gate removed a prose file runs both
s/^    includes=\$(compiled_includes)/    includes=$(true)/|docs/authoring/README.md||main||0|skip|guard-note: cross-doc-skipped=no-rust-input|with the include derivation emptied an included file skips both
s/if \[ "\$cross_doc" = ci \]; then/if false; then/|crates/app/src/mine.rs|ci|main||0|run||with the ci branch removed the setting at ci runs both
s/say cross-doc-setting "\$cross_doc"; //|crates/app/src/mine.rs|never|main||0|run||with the refusal removed an unknown setting passes
/\[ -n "\$touched" \]/d|-||main||0|skip|guard-note: cross-doc-skipped=no-rust-input|with the empty-set rule removed a branch that touches nothing skips both
/^  workspace_every=1$/d|docs/notes.md||main|FAIL_FIND=1|1|skip|guard: rust-reads=crates|with the failed read left undecided a prose file skips both
s/^\(  \[ "\$base_resolved" -eq 1 \].*rust_input=1\)$/  : #\1/|docs/notes.md||none||0|skip|guard-note: cross-doc-skipped=no-rust-input|with the base rule removed a committed crate change with no origin/main skips both
ROWS
[ "$((PASS + FAIL))" -gt "$before" ] || { echo "no row was asserted: the cross-doc gate controls" >&2; exit 2; }
rm -f "$R/fake-bin/find"
cp "$TMP/exclude.saved" "$R/.git/info/exclude"
git -C "$R" reset -q --hard "$pre_gated_head"
git -C "$R" update-ref -d refs/remotes/origin/main

echo "=== full validation runs the suites of the trees the branch touched ==="
FULL_GUARD=1
# A second skill whose suite fails whenever it runs: the selection is proven
# by that suite staying silent until its tree is touched.
mkdir -p "$R/skills/quiet/tests"
printf '#!/usr/bin/env bash\nexit 1\n' >"$R/skills/quiet/tests/quiet.test.sh"
git -C "$R" add skills/quiet
git -C "$R" commit -q -m "chore: a skill whose suite fails"
printf 'echo more\n' >>"$R/skills/demo/scripts/demo.sh"
printf 'echo more\n' >>"$R/.agents/skills/demo/scripts/demo.sh"
run_guard
[ "$RC" -eq 0 ] && [[ "$OUT" == *"=== skills/demo/tests/demo.test.sh"* ]] && [[ "$OUT" != *"skills/quiet"* ]] \
  && ok "a touched skill's suite runs in full validation and an untouched skill's does not" \
  || bad "a touched skill's suite runs in full validation and an untouched skill's does not" "rc=$RC out=$OUT"
printf 'echo touched\n' >>"$R/skills/quiet/tests/quiet.test.sh"
run_guard
[ "$RC" != 0 ] && [[ "$OUT" == *"guard: suite=skills/quiet/tests/quiet.test.sh"* ]] \
  && ok "a touched skill's failing suite reds full validation, naming the skill" \
  || bad "a touched skill's failing suite reds full validation, naming the skill" "rc=$RC out=$OUT"
if mutant_guard '/say suite "\$t"/d'; then
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$MUTANT_TOOLS/guard" --full 2>&1)" || RC=$?
  [ "$RC" -eq 0 ] \
    && ok "control: with the suite lane deleted the failing suite passes" \
    || bad "control: with the suite lane deleted the failing suite passes" "rc=$RC out=$OUT"
else
  bad "control: the suite lane could not be deleted from a guard copy"
fi
FULL_GUARD=0
git -C "$R" checkout -q -- skills .agents

# The touched set is the branch diff against origin/main plus the working
# tree. A move out of one tree into another, committed past origin/main so the
# working tree is clean and the branch diff is the only read that sees it,
# names the tree it left: that tree's suite runs.
FULL_GUARD=1
suite_lane_head="$(git -C "$R" rev-parse HEAD)"
mkdir -p "$R/skills/quiet/scripts"
printf '#!/usr/bin/env bash\necho quiet\n' >"$R/skills/quiet/scripts/quiet.sh"
# A second script stays behind so the move leaves no empty roster directory.
printf '#!/usr/bin/env bash\necho stays\n' >"$R/skills/quiet/scripts/stays.sh"
git -C "$R" add skills/quiet
git -C "$R" commit -q -m "chore: a script in the quiet skill"
git -C "$R" update-ref refs/remotes/origin/main HEAD
git -C "$R" mv skills/quiet/scripts/quiet.sh hooks/quiet.sh
git -C "$R" commit -q -m "chore: move the quiet script into hooks"
run_guard
[ "$RC" != 0 ] && [[ "$OUT" == *"guard: suite=skills/quiet/tests/quiet.test.sh"* ]] \
  && ok "a committed move out of a skill runs the suite of the tree it left" \
  || bad "a committed move out of a skill runs the suite of the tree it left" "rc=$RC out=$OUT"
if mutant_guard 's/diff --no-renames --name-only "\$suites_base"/diff --name-only "$suites_base"/'; then
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$MUTANT_TOOLS/guard" --full 2>&1)" || RC=$?
  [ "$RC" -eq 0 ] \
    && ok "control: with rename detection back on the branch diff the source tree's suite stays silent" \
    || bad "control: with rename detection back on the branch diff the source tree's suite stays silent" "rc=$RC out=$OUT"
else
  bad "control: --no-renames could not be removed from the branch diff in a guard copy"
fi

# A branch diff that fails must red the lane by itself: the working-tree read
# beside it succeeds, so only the diff's own status can carry the failure.
git -C "$R" update-ref refs/remotes/origin/main HEAD
cat >"$R/fake-bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
is_suite_diff=0
last=""
for arg in "$@"; do last="$arg"; done
if [[ " $* " == *" diff "* && " $* " == *" --no-renames "* && "$last" == "--" ]]; then
  is_suite_diff=1
fi
[ "${FAIL_SUITE_DIFF:-0}" -eq 1 ] && [ "$is_suite_diff" -eq 1 ] && exit 2
exec "$REAL_GIT" "$@"
SH
chmod +x "$R/fake-bin/git"
run_guard PATH="$R/fake-bin:$PATH" REAL_GIT="$REAL_GIT" FAIL_SUITE_DIFF=1
[ "$RC" != 0 ] && [[ "$OUT" == *"guard: touched-set=branch-diff"* ]] \
  && ok "a failed branch diff reds the suite lane beside a good working-tree read" \
  || bad "a failed branch diff reds the suite lane beside a good working-tree read" "rc=$RC out=$OUT"
if mutant_guard 's/{ branch_touched=""; say touched-set branch-diff; }/branch_touched=""/'; then
  OUT=""
  RC=0
  OUT="$(cd "$R" && PATH="$R/fake-bin:$PATH" REAL_GIT="$REAL_GIT" FAIL_SUITE_DIFF=1 "$MUTANT_TOOLS/guard" --full 2>&1)" || RC=$?
  [ "$RC" -eq 0 ] \
    && ok "control: with the diff's status unchecked the failed diff passes" \
    || bad "control: with the diff's status unchecked the failed diff passes" "rc=$RC out=$OUT"
else
  bad "control: the branch diff's status check could not be removed from a guard copy"
fi
rm -f "$R/fake-bin/git"
git -C "$R" reset -q --hard "$suite_lane_head"
git -C "$R" update-ref -d refs/remotes/origin/main
FULL_GUARD=0

echo "=== full validation runs, of a skill and of hooks/, the suites the changed files map to ==="
# Each tree holds a suite named for the changed script and one no changed file
# maps to, which fails whenever it runs. guard-range.test.sh holds the mapping
# rule itself; this section holds that --full takes it.
FULL_GUARD=1
narrow_head="$(git -C "$R" rev-parse HEAD)"
mkdir -p "$R/skills/narrow/scripts" "$R/skills/narrow/tests"
printf '#!/usr/bin/env bash\necho alpha\n' >"$R/skills/narrow/scripts/alpha.sh"
printf '#!/usr/bin/env bash\necho alpha-ran\n' >"$R/skills/narrow/tests/alpha.test.sh"
printf '#!/usr/bin/env bash\nexit 1\n' >"$R/skills/narrow/tests/beta.test.sh"
printf '#!/usr/bin/env bash\necho narrow\n' >"$R/hooks/narrow.sh"
printf '#!/usr/bin/env bash\necho narrow-ran\n' >"$R/hooks/tests/narrow.test.sh"
printf '#!/usr/bin/env bash\nexit 1\n' >"$R/hooks/tests/unreached.test.sh"
git -C "$R" add skills/narrow hooks
git -C "$R" commit -q -m "chore: a skill and hooks with a suite no change maps to"
printf 'echo more\n' >>"$R/skills/narrow/scripts/alpha.sh"
printf 'echo more\n' >>"$R/hooks/narrow.sh"
narrow_row_holds() { # [SELECTION] — the row's verdict over OUT and RC
  [ "$RC" -eq 0 ] &&
    [ "$(sed -n '$p' <<<"$OUT")" = "validate: lanes=guard-scans selection=${1:-subset}" ] &&
    [[ "$OUT" == *"=== skills/narrow/tests/alpha.test.sh"* ]] &&
    [[ "$OUT" == *"=== hooks/tests/narrow.test.sh"* ]] &&
    [[ "$OUT" == *"guard-note: suites=1/2 reason=mapped tree=skills/narrow"* ]] &&
    [[ "$OUT" == *"guard-note: suites=1/3 reason=mapped tree=hooks"* ]] &&
    [[ "$OUT" != *"beta.test.sh"* ]] && [[ "$OUT" != *"unreached.test.sh"* ]]
}
run_guard
narrow_row_holds \
  && ok "full validation runs the mapped suites of a skill and of hooks/, and not the rest" \
  || bad "full validation runs the mapped suites of a skill and of hooks/, and not the rest" "rc=$RC out=$OUT"
# Two must-fail controls, one per direction: full validation back on whole
# sets runs the suites nothing maps to, and a dropped selection skips the
# suites the change maps to. Either turns the row red, and each asserts the
# cause it plants: its exit and the lines, joined by `~`, only that cause
# prints. A sed expression holds `|`, so `#` separates the fields.
narrow_controls=(
  'whole sets under --full#s/case "\$d" in skills\/\* | hooks | tools) run="" ;; esac/case "$MODE:$d" in range:skills\/* | range:hooks | range:tools) run="" ;; esac/#1#guard: suite=skills/narrow/tests/beta.test.sh~guard: suite=hooks/tests/unreached.test.sh'
  'the mapped selection dropped#s/run="\$run\$sel$/run="$run/#0#guard-note: suites=0/2 reason=mapped tree=skills/narrow~guard-note: suites=0/3 reason=mapped tree=hooks'
)
for row in "${narrow_controls[@]}"; do
  IFS='#' read -r name expr want_rc clauses <<<"$row"
  if mutant_guard "$expr"; then
    OUT=""
    RC=0
    OUT="$(cd "$R" && "$MUTANT_TOOLS/guard" --full 2>&1 </dev/null)" || RC=$?
    cause=1
    [ "$RC" -eq "$want_rc" ] || cause=0
    while IFS= read -r clause; do
      [[ "$OUT" == *"$clause"* ]] || cause=0
    done <<<"${clauses//\~/$'\n'}"
    ! narrow_row_holds && [ "$cause" -eq 1 ] \
      && ok "control: with $name the row fails" \
      || bad "control: with $name the row fails" "rc=$RC out=$OUT"
  else
    bad "control: $name could not be planted in a guard copy"
  fi
done
printf 'echo more\n' >>"$R/skills/demo/scripts/demo.sh"
printf 'echo more\n' >>"$R/.agents/skills/demo/scripts/demo.sh"
run_guard
narrow_row_holds all && [[ "$OUT" == *"guard-note: suites=1/1 reason=mapped tree=skills/demo"* ]] \
  && ok "a whole mapped tree beside smaller mapped trees reports all in full validation" \
  || bad "a whole mapped tree beside smaller mapped trees reports all in full validation" "rc=$RC out=$OUT"
git -C "$R" reset -q --hard "$narrow_head"
FULL_GUARD=0

echo "=== refresh changes run the release-tree suites ==="
FULL_GUARD=1
mkdir -p "$R/refresh/tests"
printf '#!/usr/bin/env bash\necho refresh-runner\n' >"$R/refresh/refresh-consumer.sh"
printf '#!/usr/bin/env bash\necho refresh-suite-ran\n' >"$R/refresh/tests/refresh-consumer.test.sh"
git -C "$R" add refresh
git -C "$R" commit -q -m "chore: release refresh fixture"
printf 'echo changed\n' >>"$R/refresh/refresh-consumer.sh"
run_guard
[ "$RC" -eq 0 ] && [[ "$OUT" == *"=== refresh/tests/refresh-consumer.test.sh"* ]] &&
  [[ "$OUT" == *"refresh-suite-ran"* ]] \
  && ok "a changed release script runs its refresh suite" \
  || bad "release refresh suite selection" "rc=$RC out=$OUT"
if mutant_guard '/^      refresh\/\*)$/,/^        ;;/d'; then
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$MUTANT_TOOLS/guard" --full 2>&1 </dev/null)" || RC=$?
  [ "$RC" -eq 0 ] && [[ "$OUT" != *"refresh-suite-ran"* ]] \
    && ok "control: removing refresh selection skips the changed script's suite" \
    || bad "release refresh suite selection control" "rc=$RC out=$OUT"
else bad "release refresh selection control changed nothing"; fi
git -C "$R" reset -q --hard HEAD
FULL_GUARD=0

echo "=== a test binary's death by a signal is named apart from a failing test ==="
FULL_GUARD=1
# A workspace for the test run; the rustup stub above answers the cross-target
# lookup with both targets installed.
printf '[workspace]\n' >"$R/Cargo.toml"
cat >"$R/fake-bin/cargo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = "test --workspace --quiet" ] || exit 0
printf '%s\n' "$CARGO_TEST_STDERR" >&2
exit 101
SH
chmod +x "$R/fake-bin/cargo"
# cargo's own report of a runner whose executable died, as it prints it.
DEATH="$(printf '%s\n' \
  'error: test failed, to rerun pass `-p kendex-core --test review_fixes`' \
  '' \
  'Caused by:' \
  '  process didn'"'"'t exit successfully: `target/debug/deps/review_fixes-ff58 --quiet` (signal: 11, SIGSEGV: invalid memory reference)')"
ASSERTION="$(printf '%s\n' \
  'test a_case ... FAILED' \
  'error: test failed, to rerun pass `-p kendex-core --test review_fixes`')"
# The same death line for a compiler cargo launched, under cargo's compile
# failure rather than its test failure.
COMPILER_DEATH="$(printf '%s\n' \
  'error: could not compile `kendex-core` (lib test)' \
  '' \
  'Caused by:' \
  '  process didn'"'"'t exit successfully: `rustc --crate-name kendex_core ...` (signal: 9, SIGKILL: kill)')"
run_guard PATH="$R/fake-bin:$PATH" RUSTUP_INSTALLED_TARGETS="$BOTH" CARGO_TEST_STDERR="$DEATH"
[ "$RC" -eq 3 ] && [[ "$OUT" == *"guard-note: no-verdict=test-binary-signal=11"*"review_fixes-ff58"*"SIGSEGV"* ]] \
  && [[ "$OUT" != *"guard: cargo-test=workspace"* ]] \
  && ok "a runner killed by a signal is reported as the artifact's death, not a failing test" \
  || bad "a runner killed by a signal is reported as the artifact's death, not a failing test" "rc=$RC out=$OUT"
run_guard PATH="$R/fake-bin:$PATH" RUSTUP_INSTALLED_TARGETS="$BOTH" CARGO_TEST_STDERR="$ASSERTION"
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: cargo-test=workspace"* ]] && [[ "$OUT" != *"guard: test-binary-signal="* ]] \
  && ok "a failing assertion still reads as tests failed" \
  || bad "a failing assertion still reads as tests failed" "rc=$RC out=$OUT"
run_guard PATH="$R/fake-bin:$PATH" RUSTUP_INSTALLED_TARGETS="$BOTH" CARGO_TEST_STDERR="$ASSERTION
$DEATH"
[ "$RC" -eq 1 ] && [[ "$OUT" == *'guard-note: no-verdict=test-binary-signal=11'* ]] \
  && [[ "$OUT" == *'guard: cargo-test=workspace'* ]] \
  && ok 'a signal cannot hide an assertion that already failed' \
  || bad 'assertion before signal' "rc=$RC out=$OUT"
if mutant_guard '/^      if grep -qE.*test result: FAILED/,/^      fi$/d'; then
  GUARD="$MUTANT_TOOLS/guard" run_guard PATH="$R/fake-bin:$PATH" RUSTUP_INSTALLED_TARGETS="$BOTH" CARGO_TEST_STDERR="$ASSERTION
$DEATH"
  [ "$RC" -eq 3 ] && [[ "$OUT" != *'guard: cargo-test=workspace'* ]] \
    && ok 'control: losing the assertion finding turns the mixed row red' \
    || bad 'assertion before signal control' "rc=$RC out=$OUT"
else bad 'assertion before signal control changed nothing'; fi
run_guard PATH="$R/fake-bin:$PATH" RUSTUP_INSTALLED_TARGETS="$BOTH" CARGO_TEST_STDERR="$COMPILER_DEATH"
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: cargo-test=workspace"* ]] && [[ "$OUT" != *"guard: test-binary-signal="* ]] \
  && ok "a compiler killed by a signal is not named as a test binary's death" \
  || bad "a compiler killed by a signal is not named as a test binary's death" "rc=$RC out=$OUT"
if mutant_guard 's/if \[ -n "\$death" \]; then/if false; then/'; then
  GUARD="$MUTANT_TOOLS/guard" run_guard PATH="$R/fake-bin:$PATH" RUSTUP_INSTALLED_TARGETS="$BOTH" CARGO_TEST_STDERR="$DEATH"
  [ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: cargo-test=workspace"* ]] && [[ "$OUT" != *"guard: test-binary-signal="* ]] \
    && ok "control: with the death check removed the same death reads as tests failed" \
    || bad "control: with the death check removed the same death reads as tests failed" "rc=$RC out=$OUT"
else
  bad "control: the death check could not be removed from a guard copy"
fi
rm -f "$R/Cargo.toml"

echo "=== missing suite peers have no verdict while assertions still block ==="
mkdir -p "$R/pi-extensions/peers"
printf '{"scripts":{"test":"node test.mjs"}}\n' >"$R/pi-extensions/peers/package.json"
cat >"$R/fake-bin/npm" <<'SH'
#!/usr/bin/env bash
[ -z "${PEER_LAUNCHER_LOG:-}" ] || printf '%s\n' "$*" >>"$PEER_LAUNCHER_LOG"
if [ "${MISSING_NPM_NODE:-0}" = 1 ]; then
  printf '%s\n' "/usr/bin/env: ‘node’: No such file or directory" >&2
  exit 127
fi
[ "$*" != --version ] || exit 0
printf '%s\n' "$PEER_SUITE_OUTPUT"
exit 1
SH
chmod +x "$R/fake-bin/npm"
# Complete shipped Bun producers: pi-qol npm test, renderer code-blocks,
# and tmux trace-layout. Checkout roots and trailing spaces are normalized.
# Bash 3.2 scans quotes inside substitution here-documents. Read these
# outside a substitution; EOF is the expected nonzero read status.
IFS= read -r -d '' BUN_PEER <<'OUTPUT' || :
bun test v1.4.2 (744846f84)

extensions/__tests__/code-blocks.test.ts:

# Unhandled error between tests
-------------------------------
error: Cannot find module '@earendil-works/pi-tui' from '/package/extensions/__tests__/code-blocks.test.ts'
-------------------------------


 0 pass
 1 fail
 1 error
Ran 1 test across 1 file. [7.00ms]
OUTPUT
IFS= read -r -d '' TMUX_PEER <<'OUTPUT' || :
bun test v1.4.2 (744846f84)

pi-extensions/pi-agents-tmux/tests/trace-layout.test.ts:

# Unhandled error between tests
-------------------------------
error: Cannot find module '@earendil-works/pi-tui' from '/package/tests/trace-layout.test.ts'
-------------------------------


 0 pass
 1 fail
 1 error
Ran 1 test across 1 file. [23.00ms]
OUTPUT
IFS= read -r -d '' QOL_PEER <<'OUTPUT' || :

> @vanillagreen/pi-qol@2.4.0 test
> bun test ./tests

bun test v1.4.2 (744846f84)

tests/retention.test.ts:
(pass) a headless session loads no session-search index at startup, and shutdown releases a loaded one [31.26ms]
(pass) only the latest queued resume action stays pending, and session_shutdown drops it [7.01ms]
(pass) the loaded index and parsed prompts are released after the default TTL and on release [6.82ms]
(pass) opening session search after the index was released shows the overlay before the reload finishes [2.17ms]
(pass) notification cooldowns: a key inside its cooldown stays suppressed after another key is sent [1.84ms]
(pass) notification cooldowns: session_shutdown forgets every cooldown [0.44ms]
(pass) the index keeps each session's text to the per-session cap and the sum to the index cap, newest first [59.41ms]
(pass) parsed prompts are kept for a bounded number of sessions [5.63ms]
(pass) thinking durations are bounded and finished labels are released at agent_end, running ones kept [12.95ms]

tests/transcript-risk-math.test.ts:
(pass) evaluateTranscriptRisk: no characters [0.04ms]
(pass) evaluateTranscriptRisk: below the threshold
(pass) evaluateTranscriptRisk: at the threshold
(pass) evaluateTranscriptRisk: above the threshold
(pass) evaluateTranscriptRisk: disabled threshold
(pass) evaluateTranscriptRisk: no messages
(pass) evaluateTranscriptRisk: error from the serializer

tests/chunked-summary.test.ts:
(pass) orchestrateChunkedSummary: single short summary keeps the seed and instructions [0.70ms]
(pass) orchestrateChunkedSummary: every summarize request fits the input cap [1.09ms]
(pass) orchestrateChunkedSummary: large partial summaries require repeated reduction [0.70ms]
(pass) orchestrateChunkedSummary: already aborted signal refuses before a request [0.29ms]
(pass) orchestrateChunkedSummary: empty chunk summary refuses further requests [0.13ms]
(pass) orchestrateChunkedSummary: previous summary advances across chunks and seeds final reduction [0.13ms]

tests/session-search-async-jsonl.test.ts:
(pass) async JSONL keeps split UTF-8 records, skips oversized lines and closes on cancellation [185.33ms]

tests/notifications.test.ts:
(pass) audible terminal bell [0.30ms]
(pass) muted terminal bell [0.08ms]
(pass) default OSC BEL terminator [0.14ms]
(pass) muted OSC ST terminator [0.10ms]
(pass) every tmux call carries a deadline, and a stalled tmux leaves the caller free [0.44ms]
(pass) the bell goes to the source pane tty and the OSC notification to the pane's session's client tty [32.04ms]
(pass) a tmux answer its deadline killed counts as no answer [3.32ms]
(pass) the window mark renames the pane's window as tmux reports it at each notification, and clearing names it back [0.45ms]
(pass) a window mark cleared while its notification is in flight is not set [0.33ms]
(pass) the window mark and the tmux message do not wait on the terminal writes [51.72ms]
(pass) a pane tty that never drains leaves later notifications' OSC and tmux messages free [12.16ms]
(pass) a client tty that never drains leaves later notifications' OSC and tmux messages free [4.57ms]

tests/session-search-index-budget.test.ts:
(pass) async index bounds per-session prompt text [16.23ms]
(pass) async index bounds aggregate prompt text [59.84ms]

tests/statusline-account.test.ts:
(pass) a confirmed login is shown [1.31ms]
(pass) showAccount off hides a confirmed login [0.30ms]
(pass) an unconfirmed login shows nothing [0.29ms]
(pass) no bridge shows nothing [0.25ms]
(pass) a non-bridge provider hides the account [0.91ms]
(pass) no model hides the account [0.30ms]
(pass) the account reader selects the visible Pi session [0.33ms]
(pass) a v1 store with the reader is accepted [0.26ms]
(pass) a later version is refused [0.17ms]
(pass) a store with no version is refused [0.28ms]
(pass) a store with no reader is refused [0.19ms]
(pass) a non-callable reader is refused [0.19ms]
(pass) a non-object is refused [0.16ms]
(pass) an absent publisher is refused [0.17ms]

tests/session-search-regex.test.ts:
QOL_REGEX_DEADLINE {"bytes":1048577,"elapsedMs":58.77463799999998}
QOL_REGEX_DEADLINE {"bytes":1048577,"elapsedMs":1035.361798}
(pass) a pathological user regex over 1 MiB returns a deadline error without blocking input [3903.84ms]
(pass) regex hit snippets use worker match positions and cancelled workers return no hits [40.27ms]

tests/pi-ai-compat.test.ts:
(pass) complete falls back to the compatibility entrypoint [0.15ms]
(pass) complete prefers the root export [0.01ms]
(pass) retry helper receives the standard policy [0.14ms]
(pass) absent retry helper calls the producer once [0.05ms]
(pass) retry helper receives signal and callbacks [0.14ms]
(pass) retry helper success is returned [0.08ms]
(pass) retry helper aborted result is preserved [0.04ms]

tests/chunk-conversation.test.ts:
(pass) chunkConversationText: under the cap [0.02ms]
(pass) chunkConversationText: disabled cap
(pass) chunkConversationText: paragraph boundaries preserve the complete conversation
(pass) chunkConversationText: hard split without paragraph boundaries

tests/session-search-actions.test.ts:
(pass) Copy and Fork own delayed complete prompts across shortcuts, menus and pending commands [177.28ms]

tests/provider-headers.test.ts:
(pass) null deletion marker [0.18ms]
(pass) empty header value
(pass) numeric header value
(pass) absent headers
(pass) array headers
(pass) empty header record

tests/statusline-toggle.test.ts:
(pass) default statusline installation [1.66ms]
(pass) disabled statusline retains editor helpers [0.46ms]
(pass) working indicator routing: compact=true, statusline=true, mode=animated [5.31ms]
(pass) working indicator routing: compact=true, statusline=true, mode=static [1.32ms]
(pass) working indicator routing: compact=true, statusline=true, mode=unset [0.60ms]
(pass) working indicator routing: compact=true, statusline=false, mode=animated [1.04ms]
(pass) working indicator routing: compact=true, statusline=false, mode=static [0.62ms]
(pass) working indicator routing: compact=true, statusline=false, mode=unset [0.58ms]
(pass) working indicator routing: compact=false, statusline=true, mode=animated [0.61ms]
(pass) working indicator routing: compact=false, statusline=true, mode=static [1.10ms]
(pass) working indicator routing: compact=false, statusline=true, mode=unset [0.55ms]
(pass) working indicator routing: compact=false, statusline=false, mode=animated [0.40ms]
(pass) working indicator routing: compact=false, statusline=false, mode=static [0.63ms]
(pass) working indicator routing: compact=false, statusline=false, mode=unset [0.57ms]
(pass) session_info_changed refreshes the UI title [2.68ms]
(pass) session_info_changed is inert without a UI [0.35ms]

tests/qol-agent-end.test.ts:
(pass) qol event wiring: registers end, settled and compact handlers [1.59ms]
(pass) qol event wiring: settlement waits for compaction completion [1.71ms]
(pass) qol event wiring: settlement waits for compaction error [0.58ms]
(pass) qol event wiring: below-threshold usage does not dispatch [0.50ms]
(pass) qol event wiring: repeated end and settled events deduplicate pending and in-flight work [0.49ms]
(pass) qol event wiring: session_compact suppresses the same trigger after completion [0.58ms]
(pass) qol event wiring: Pi auto-compaction between end and settled suppresses dispatch and the next cycle [0.46ms]
(pass) qol event wiring: missing compact function warns and allows retry [0.53ms]
(pass) qol event wiring: late old-session compact event cannot consume a new-session trigger [0.59ms]
(pass) qol event wiring: late old-session compact event cannot suppress retry after Already compacted [0.56ms]
(pass) qol event wiring: budgetGuard with Pi compaction.enabled user=false project=undefined and QOL {} [7.95ms]
(pass) qol event wiring: budgetGuard with Pi compaction.enabled user=true project=undefined and QOL {} [1.06ms]
(pass) qol event wiring: budgetGuard with Pi compaction.enabled user=undefined project=undefined and QOL {} [0.87ms]
(pass) qol event wiring: budgetGuard with Pi compaction.enabled user=true project=undefined and QOL {"compaction.budgetGuardEnabled":false} [0.63ms]
(pass) qol event wiring: budgetGuard with Pi compaction.enabled user=true project=false and QOL {} [0.67ms]
(pass) qol event wiring: budgetGuard with Pi compaction.enabled user=false project=true and QOL {} [0.60ms]
(pass) qol event wiring: idle with Pi compaction.enabled user=false project=undefined and QOL {"compaction.idleEnabled":true} [0.60ms]
(pass) qol event wiring: idle with Pi compaction.enabled user=true project=undefined and QOL {"compaction.idleEnabled":true} [7.45ms]
(pass) qol event wiring: idle with Pi compaction.enabled user=undefined project=undefined and QOL {"compaction.idleEnabled":true} [0.67ms]
(pass) qol event wiring: idle with Pi compaction.enabled user=true project=undefined and QOL {} [0.68ms]

tests/session-search-jsonl.test.ts:
(pass) session JSONL line reader streams across small chunks [0.49ms]

tests/schedule.test.ts:
(pass) parseDurationMs: 20 [0.21ms]
(pass) parseDurationMs: 20m [0.11ms]
(pass) parseDurationMs: 90s
(pass) parseDurationMs: 500ms
(pass) parseDurationMs: 1.5h
(pass) parseDurationMs: 1h45m
(pass) parseDurationMs: 1h30s
(pass) parseDurationMs: 45m10s
(pass) parseDurationMs: 1h45m30s
(pass) parseDurationMs: 2d3h4m5s6ms
(pass) parseDurationMs: 0m
(pass) parseDurationMs: forever
(pass) parseDurationMs: 1h2h
(pass) parseDurationMs: 30s1h
(pass) parseDurationMs: 1h30
(pass) parseDurationMs: 1h30xs
(pass) parseDurationMs: 31d [0.02ms]
(pass) parseScheduleCommandArgs: 20m this is my message [0.06ms]
(pass) parseScheduleCommandArgs: 1h45m do thing later
(pass) parseScheduleCommandArgs: 1h30s do thing later
(pass) parseScheduleCommandArgs: 45m10s do thing later
(pass) parseScheduleCommandArgs: list
(pass) parseScheduleCommandArgs: cancel all
(pass) parseScheduleCommandArgs: cancel abc
(pass) schedule lifecycle: idle delivery waits for the timer and records session events [23.95ms]
(pass) schedule lifecycle: preview keeps queued style, hides ids and caps visible messages [0.54ms]
(pass) schedule lifecycle: busy delivery uses followUp [0.13ms]
(pass) schedule lifecycle: cancel all clears timers and pending state [0.23ms]
(pass) schedule lifecycle: branch restore rearms and delivers the pending message [0.16ms]

tests/statusline-thinking.test.ts:
(pass) max thinking level [0.05ms]
(pass) unknown thinking level
(pass) max thinking theme token [0.08ms]

tests/runtime-copy-peers.test.ts:
50 |
51 | describe("copied runtime against the installed Pi peers", () => {
52 | 	test("the copy imports and runs through the package's installed peers and is removed on success and failure", () => {
53 | 		const pin = process.env[PIN_ENV];
54 | 		const run = probe(packageDir, pin);
55 | 		expect(run.stderr).toBe("");
                          ^
error: expect(received).toBe(expected)

- ""
+ "runtime-copy-peers: peer-unresolved peer=@earendil-works/pi-agent-core cause=[Cannot find package '@earendil-works/pi-agent-core' imported from /package/tests/runtime-copy-peers.probe.ts]
+ "

- Expected  - 1
+ Received  + 2

      at <anonymous> (/package/tests/runtime-copy-peers.test.ts:55:22)
(fail) copied runtime against the installed Pi peers > the copy imports and runs through the package's installed peers and is removed on success and failure [25.45ms]
83 | 			const dir = packageContext(row.parent, row.peers);
84 | 			try {
85 | 				if (row.patch) patchFile(join(dir, row.patch.file), row.patch.from, row.patch.to);
86 | 				const run = probe(dir, row.pin, row.preload);
87 | 				if (row.refusal === null) expect({ rule: row.rule, exitCode: run.exitCode, stdout: run.stdout, stderr: run.stderr }).toMatchObject({ rule: row.rule, exitCode: 0, stdout: expect.stringMatching(/^runtime-copy-peers: proved /), stderr: "" });
88 | 				else expect({ rule: row.rule, exitCode: run.exitCode, refused: run.stderr.startsWith(`runtime-copy-peers: ${row.refusal}`), stderr: run.stderr }).toMatchObject({ rule: row.rule, exitCode: 1, refused: true });
                                                                                                                                                           ^
error: expect(received).toMatchObject(expected)

  {
    "exitCode": 1,
-   "refused": true,
+   "refused": false,
    "rule": "inside the package",
+   "stderr":
+ "runtime-copy-peers: peer-unresolved peer=@earendil-works/pi-agent-core cause=[Cannot find package '@earendil-works/pi-agent-core' imported from /package/tmp/qol-search-test-YuJHKx/tests/runtime-copy-peers.probe.ts]
+ "
+ ,
  }

- Expected  - 1
+ Received  + 5

      at <anonymous> (/package/tests/runtime-copy-peers.test.ts:88:151)
(fail) copied runtime against the installed Pi peers > each precondition rule and teardown refuses its planted defect [90.83ms]

tests/budget-guard-runtime.test.ts:
(pass) dispatch fires once per crossing key [0.31ms]
(pass) dispatch deduplicates a repeated trigger after completion within the same bucket [0.13ms]
(pass) session_compact satisfies the current crossing key [0.10ms]
(pass) session_compact clears suppression after usage falls below the trigger [0.09ms]
(pass) session_compact allows a genuinely new trigger key [0.09ms]
(pass) Already compacted is benign only after a later session_compact [0.21ms]
(pass) Already compacted remains an error without a later session_compact [0.11ms]
(pass) a delayed unrelated error stays visible without clearing a session-satisfied key [0.09ms]
(pass) dispatch refuses a new bucket while the first crossing is in flight [0.04ms]
(pass) dispatch with no trigger clears the crossing key [0.08ms]
(pass) dispatch refuses when ctx.compact is missing and notifies the user [0.07ms]
(pass) dispatch propagates the sentinel in customInstructions [0.04ms]
(pass) dispatch exposes persistent status until compaction callback finishes [0.06ms]
(pass) dispatch clears persistent status on async compact failure [0.07ms]
(pass) dispatch clears state and notifies on synchronous compact throw [0.16ms]
(pass) dispatch onError clears the crossing key so the next agent_end retries [0.11ms]
(pass) dispatch respects a stale-context callback by ignoring the call [0.05ms]
(pass) reset clears in-flight and key state [0.06ms]
(pass) session_compact from an old reset generation cannot satisfy the current trigger [0.12ms]
(pass) reset invalidates delayed callbacks without mutating the next dispatch [7.73ms]

tests/handle-qol-compaction.test.ts:
(pass) handleQolCompaction: disabled custom compaction without sentinel [1.13ms]
(pass) handleQolCompaction: sentinel bypass writes the bounded summary and handoff [2.07ms]
(pass) handleQolCompaction: handoff filesystem failure warns while retaining the summary [2.54ms]
(pass) handleQolCompaction: summarizer failure cancels when fallback is disabled [1.03ms]
(pass) handleQolCompaction: summarizer failure falls back to Pi by default [0.86ms]
(pass) handleQolCompaction: empty messages skip custom compaction [0.17ms]

tests/images-submit.test.ts:
(pass) input refuses a 50 MiB image without reading it and restores only an empty editor [485.49ms]
(pass) headless input reports image refusal on stderr and stays handled [26.61ms]
(pass) image budget adds every file and existing clipboard image before any read [306.23ms]
(pass) a file that grows after stat is refused before encoding [17.29ms]
(pass) image reads are asynchronous and valid bytes retain MIME type; directories refuse [18.29ms]

tests/session-user-messages.test.ts:
(pass) session user messages retain prompt text and timestamp [0.45ms]

tests/transcript-risk.test.ts:
(pass) below the character budget [3.05ms]
(pass) above the character budget [0.09ms]
(pass) empty messages
(pass) disabled character budget
(pass) serializer dependency throws [0.07ms]

tests/session-search-component.benchmark.test.ts:
QOL_COMPONENT_BENCHMARK {"sessions":500,"keys":20,"coldMs":563.8044060000002,"coldCalls":{"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0},"maxMs":27.118390000000545,"steps":[{"ms":27.118390000000545,"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0},{"ms":24.77361800000017,"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0},{"ms":21.755973999999696,"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0},{"ms":21.49308999999994,"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0},{"ms":22.599161000000095,"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0},{"ms":21.341981999999916,"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0},{"ms":22.070826999999554,"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0},{"ms":24.096419999999853,"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0},{"ms":21.278636999999435,"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0},{"ms":20.923423000000184,"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0},{"ms":21.147800000000643,"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0},{"ms":21.00580700000046,"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0},{"ms":21.333740000000034,"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0},{"ms":21.75001499999962,"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0},{"ms":21.22045900000012,"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0},{"ms":21.689784999999574,"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0},{"ms":21.639288999999735,"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0},{"ms":23.633786000000327,"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0},{"ms":23.023568999999952,"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0},{"ms":22.665831000000253,"realpathSync":0,"readSync":0,"wholeLogReadFileSync":0}]}
(pass) component benchmark: 500 sessions, 20 completed keystrokes, bounded hot calls [1084.31ms]

tests/compaction-handoff.test.ts:
(pass) piUserDir honors PI_CODING_AGENT_DIR [0.22ms]
(pass) safeFileName: safe segment [0.13ms]
(pass) safeFileName: traversal separators [0.08ms]
(pass) safeFileName: mixed separators [0.06ms]
(pass) sessionIdFromManager: session id [0.10ms]
(pass) sessionIdFromManager: file basename [0.08ms]
(pass) sessionIdFromManager: process fallback [0.07ms]
(pass) sessionIdFromManager: stale accessors [0.12ms]
(pass) findLatestTaskState: latest tool result state [0.12ms]
(pass) findLatestTaskState: empty branch [0.10ms]
(pass) findLatestTaskState: no tool result [0.06ms]
(pass) collectArtifactRefs: recent file paths [0.35ms]
(pass) collectArtifactRefs: bounded recent paths [0.08ms]
(pass) buildBudgetHandoff captures preparation and session state [0.21ms]
(pass) writeBudgetHandoffArtifact: stamped and latest files [3.24ms]
(pass) writeBudgetHandoffArtifact: disabled writer [0.13ms]
(pass) writeBudgetHandoffArtifact: filesystem error is forwarded [0.15ms]
(pass) writeBudgetHandoffArtifact: session id remains inside the supplied root [0.56ms]
(pass) budget handoff: session_start prunes gone lanes or files, including latest.json [1.80ms]
(pass) budget handoff: session_start prunes old lanes or files, including latest.json [4.95ms]
(pass) budget handoff: session_start prunes fresh lanes or files, including latest.json [1.06ms]

tests/compaction-length-stop.test.ts:
(pass) generateQolSummary rejects a summary with stopReason length [0.58ms]
(pass) generateQolSummary accepts a summary with stopReason stop [0.28ms]

tests/budget-trigger.test.ts:
(pass) computeBudgetTrigger: disabled above the percent threshold [0.04ms]
(pass) computeBudgetTrigger: percent threshold [0.01ms]
(pass) computeBudgetTrigger: percent threshold numeric closeness [0.03ms]
(pass) computeBudgetTrigger: token threshold without a context window [0.02ms]
(pass) computeBudgetTrigger: same bucket at 172000 tokens
(pass) computeBudgetTrigger: same bucket at 175000 tokens
(pass) computeBudgetTrigger: first bucket at 120000 tokens
(pass) computeBudgetTrigger: second bucket at 220000 tokens
(pass) computeBudgetTrigger: zero token count
(pass) computeBudgetTrigger: non-finite token count
(pass) isBudgetGuardCompaction: budget guard marker [0.02ms]
(pass) isBudgetGuardCompaction: user request
(pass) isBudgetGuardCompaction: absent instructions

tests/compaction-model-resolution.test.ts:
(pass) compaction model resolution strips max thinking suffix [0.11ms]

tests/rate-limit-auto-resume.test.ts:
(pass) parseDurationLikeMs: 6m0s [0.45ms]
(pass) extractResetAtFromHeaders: retry-after [0.33ms]
(pass) extractResetAtFromHeaders: retry-after-ms [0.14ms]
(pass) extractResetAtFromHeaders: x-ratelimit-reset-requests [0.18ms]
(pass) extractResetAtFromHeaders: anthropic-ratelimit-requests-reset [0.12ms]
(pass) looksLikeRateLimitText: Error: 429 Too Many Requests [0.20ms]
(pass) looksLikeRateLimitText: normal tool failure [0.12ms]
(pass) extractResetAtFromText: Rate limited. Try again in 2 minutes [0.32ms]
(pass) rate-limit lifecycle: external rate-limit event schedules the configured message after reset plus buffer [1.83ms]
(pass) rate-limit lifecycle: external reset retained through message_end without a reset schedules the configured message after reset plus buffer [6.82ms]
(pass) rate-limit lifecycle: provider response headers schedules the configured message after reset plus buffer [0.55ms]
(pass) rate-limit lifecycle: message_end text schedules the configured message after reset plus buffer [0.45ms]
(pass) rate-limit lifecycle: agent_end text schedules the configured message after reset plus buffer [0.49ms]
(pass) rate-limit lifecycle: disabled setting creates no timer [0.31ms]
(pass) rate-limit lifecycle: successful assistant turn ignores a transient provider 429 [0.34ms]
(pass) rate-limit lifecycle: setting disabled before delivery [0.59ms]
(pass) rate-limit lifecycle: new turn before delivery [0.38ms]

tests/session-search-async.test.ts:
(pass) async index streams prompts and resolves a shared project once without sync reads [15.40ms]
(pass) shutdown cancels a load and a late result cannot replace the next load [28.70ms]
(pass) scope uses prepared canonical paths, including symlinked projects [15.94ms]
(pass) typing is debounced and closing cancels the pending query and late index publication [44.18ms]
(pass) query cancellation stops before matching and preserves prompt ranking and snippet text [58.49ms]

tests/context-usage.test.ts:
(pass) absent transcript risk [2.42ms]
(pass) payload below the warning budget [0.21ms]
(pass) payload above the warning budget [0.21ms]
(pass) serializer error stays on one line [0.12ms]

tests/auto-rename-max-tokens.test.ts:
(pass) auto-rename output-token cap: unset reads the shipped default [2.06ms]
(pass) auto-rename output-token cap: a configured value is sent as set [1.05ms]

tests/pending-queue.test.ts:
(pass) a restored-queue status line renders with no side padding [0.48ms]
(pass) an empty-queue status line renders with no side padding [0.15ms]
(pass) any other text keeps its padding [0.13ms]
(pass) an unchanged Text is scanned once, and again only when its text changes [0.34ms]
(pass) restore puts pi-tui's own render back, and a later install patches again [0.17ms]
(pass) a marker this module did not write keeps its render through install, restore and install [0.18ms]
(pass) a session without a UI leaves Text unpatched [0.14ms]
(pass) the session installs the patch at start and removes it at shutdown [26.81ms]

tests/statusline-provider.test.ts:
(pass) provider label: github-copilot [0.57ms]
(pass) provider label: openai [0.77ms]
(pass) provider label: openai-codex [0.25ms]
(pass) provider label: pi-claude [0.30ms]
(pass) provider label: anthropic [1.79ms]
(pass) provider label: google-vertex [2.30ms]
(pass) provider label: amazon-bedrock [0.49ms]
(pass) provider label: openrouter [1.96ms]
(pass) provider label: xai [0.80ms]
(pass) provider label: team_proxy-east [0.40ms]
(pass) provider label: MyProxy [0.56ms]
(pass) provider label: constructor [0.59ms]
(pass) persisted provider toggle: undefined [0.32ms]
(pass) persisted provider toggle: false [0.57ms]
(pass) persisted provider toggle: true [0.28ms]
(pass) provider follows model selection and persisted settings without reload [0.44ms]
(pass) no selected model has no dangling provider separator [0.38ms]
(pass) spinner prefix and provider fit width 0 [0.32ms]
(pass) spinner prefix and provider fit width 1 [0.23ms]
(pass) spinner prefix and provider fit width 12 [0.33ms]
(pass) spinner prefix and provider fit width 40 [0.25ms]
(pass) spinner prefix and provider fit width 120 [0.27ms]

2 tests failed:
(fail) copied runtime against the installed Pi peers > the copy imports and runs through the package's installed peers and is removed on success and failure [25.45ms]
(fail) copied runtime against the installed Pi peers > each precondition rule and teardown refuses its planted defect [90.83ms]

 273 pass
 2 fail
 810 expect() calls
Ran 275 tests across 34 files. [7.16s]
OUTPUT
# Bun 1.4.2 on a shipped relative import whose file is gone, at load and
# inside a test; a missing file is a source defect, never a peer.
IFS= read -r -d '' BUN_RELATIVE <<'OUTPUT' || :
bun test v1.4.2 (744846f84)

tests/diagnostics.test.ts:

# Unhandled error between tests
-------------------------------
error: Cannot find module '../extensions/diagnostics.ts' from '/package/tests/diagnostics.test.ts'
-------------------------------


 0 pass
 1 fail
 1 error
Ran 1 test across 1 file. [51.00ms]
OUTPUT
IFS= read -r -d '' BUN_RELATIVE_IN_TEST <<'OUTPUT' || :
bun test v1.4.2 (744846f84)

tests/diagnostics.test.ts:
error: Cannot find module './nope.ts' from '/package/tests/diagnostics.test.ts'
(fail) dyn [12.24ms]

 0 pass
 1 fail
Ran 1 test across 1 file. [12.00ms]
OUTPUT
INDEPENDENT=$'error: expect(received).toBe(expected)\nExpected: true\nReceived: false\n(fail) an independent behavior check'
UNKNOWN=$'# Unhandled error between tests\n-------------------------------\nTypeError: undefined is not an object\n-------------------------------'
# The producer reports its own outcome. Summary rows can repeat it or expose
# an unexplained failure, but cannot invent a different diagnostic outcome.
QOL_MIXED=${QOL_PEER%$'\n2 tests failed:'*}
QOL_MIXED="$QOL_MIXED
$INDEPENDENT

3 tests failed:
(fail) copied runtime against the installed Pi peers > the copy imports and runs through the package's installed peers and is removed on success and failure [25.45ms]
(fail) copied runtime against the installed Pi peers > each precondition rule and teardown refuses its planted defect [90.83ms]
(fail) an independent behavior check

 273 pass
 3 fail
 811 expect() calls
Ran 276 tests across 34 files. [7.16s]"
BUN_MIXED=${BUN_PEER%$'\n 0 pass'*}
BUN_UNKNOWN="$BUN_MIXED
$UNKNOWN

 0 pass
 2 fail
 2 error
Ran 2 tests across 2 files. [7.00ms]"
BUN_MIXED="$BUN_MIXED
$INDEPENDENT

1 tests failed:
(fail) an independent behavior check

 0 pass
 2 fail
 1 error
Ran 2 tests across 2 files. [7.00ms]"
PEER_ROWS=(
  'Node missing peer|Error [ERR_MODULE_NOT_FOUND]: Cannot find package @earendil-works/pi-ai|3|no-verdict|absent'
  "Node quoted missing peer|Error [ERR_MODULE_NOT_FOUND]: Cannot find package '@earendil-works/pi-ai' imported from /package/tests/a.mjs|3|no-verdict|absent"
  "Bun unhandled missing relative file|$BUN_RELATIVE|1|suite|absent"
  "Bun missing relative file inside a test|$BUN_RELATIVE_IN_TEST|1|suite|absent"
  "Node missing absolute file|Error [ERR_MODULE_NOT_FOUND]: Cannot find module '/package/extensions/a.mjs' imported from /package/tests/a.mjs|1|suite|absent"
  "Node missing drive-letter file|Error [ERR_MODULE_NOT_FOUND]: Cannot find module 'C:\\package\\extensions\\a.mjs' imported from C:\\package\\tests\\a.mjs|1|suite|absent"
  "Node require of a missing relative file|Error: Cannot find module '../extensions/a'|1|suite|absent"
  "renderer unhandled missing peer|$BUN_PEER|3|no-verdict|absent"
  "tmux unhandled missing peer|$TMUX_PEER|3|no-verdict|absent"
  "unhandled missing peer beside an assertion|$BUN_MIXED|1|suite|absent"
  "unhandled missing peer beside an unknown error|$BUN_UNKNOWN|1|suite|absent"
  "Pi probe failures repeated in Bun summary|$QOL_PEER|3|no-verdict|absent"
  "Pi probe beside an independent assertion|$QOL_MIXED|1|suite|absent"
  "unexplained summary failure|$BUN_PEER
 2 fail|1|suite|absent"
  "unknown failure in repeated summary|$QOL_PEER
(fail) a case with no diagnostic report|1|suite|absent"
  "peers installed but module missing|$BUN_PEER|1|suite|present"
  'assertion without node_modules|AssertionError [ERR_ASSERTION]: expected equal values|1|suite|absent'
)
PEER_BASE=$(git -C "$R" rev-parse HEAD) || exit 1
for script in test test:ci; do
  printf '{"scripts":{"%s":"bun test ./tests"}}\n' "$script" >"$R/pi-extensions/peers/package.json"
  for row in "${PEER_ROWS[@]}"; do
    # Read the fields without read consuming only the first output line.
    label=${row%%|*}; row=${row#*|}
    peers=${row##*|}; row=${row%|*}
    output=${row%|*|*}; expected=${row#"$output"|}; key=${expected#*|}; expected=${expected%%|*}
    if [ "$peers" = present ]; then mkdir "$R/pi-extensions/peers/node_modules"; fi
    diagnostic='guard: suite=pi-extensions/peers'
    [ "$key" != no-verdict ] || diagnostic='guard-note: no-verdict=missing-peers=pi-extensions/peers'
    run_guard PATH="$R/fake-bin:$PATH" PEER_SUITE_OUTPUT="$output"
    [ "$RC" -eq "$expected" ] && [[ "$OUT" == *"$diagnostic"* ]] \
      && ok "$script: $label" || bad "$script: $label" "rc=$RC out=$OUT"
    if [ "$peers" = present ]; then rmdir "$R/pi-extensions/peers/node_modules"; fi
  done
  # command resolution and env's missing Node diagnostic are the two host
  # producers that prevent npm from starting a declared suite at all.
  for mode in full range; do
    mode_args=(--full)
    [ "$mode" = full ] || mode_args=(--range "$PEER_BASE")
    for launcher in npm node; do
      launcher_env=(MISSING_NPM_NODE=1)
      expected_call=--version
      if [ "$launcher" = npm ]; then
        launcher_env=('BASH_FUNC_command%%=() { if [ "$*" = "-v npm" ]; then return 1; fi; builtin command "$@"; }')
        expected_call=""
      fi
      : >"$TMP/npm-launcher-calls"
      OUT=""; RC=0
      OUT="$(cd "$R" && env "${GUARD_TEST_BOUNDS[@]}" PATH="$R/fake-bin:$PATH" PEER_LAUNCHER_LOG="$TMP/npm-launcher-calls" \
        PEER_SUITE_OUTPUT="$INDEPENDENT" "${launcher_env[@]}" "$GUARD" "${mode_args[@]}" 2>&1 </dev/null)" || RC=$?
      launcher_calls=$(cat "$TMP/npm-launcher-calls")
      [ "$RC" -eq 3 ] && [[ "$OUT" == *'guard-note: no-verdict=missing-tool=npm'* ]] \
        && [[ "$OUT" != *'guard: suite='* ]] && [ "$launcher_calls" = "$expected_call" ] \
        && ok "$mode $script: missing $launcher prevents suite start and has no verdict" \
        || bad "$mode $script: missing $launcher launcher" "rc=$RC out=$OUT calls=$launcher_calls"
      if mutant_guard 's#if ! command -v npm .*; then#if false; then#'; then
        OUT=""; RC=0
        OUT="$(cd "$R" && env "${GUARD_TEST_BOUNDS[@]}" PATH="$R/fake-bin:$PATH" PEER_SUITE_OUTPUT="$INDEPENDENT" \
          "${launcher_env[@]}" "$MUTANT_TOOLS/guard" "${mode_args[@]}" 2>&1 </dev/null)" || RC=$?
        [ "$RC" -eq 1 ] && [[ "$OUT" == *'guard: suite=pi-extensions/peers'* ]] \
          && ok "control: $mode $script without launcher availability misjudges missing $launcher" \
          || bad "launcher availability control: $mode $script $launcher" "rc=$RC out=$OUT"
      else bad "launcher availability control changed nothing: $mode $script $launcher"; fi
    done
  done
done
if mutant_guard 's/unrun missing-peers "\$1"/say suite "$1"/'; then
  GUARD="$MUTANT_TOOLS/guard" run_guard PATH="$R/fake-bin:$PATH" PEER_SUITE_OUTPUT="$BUN_PEER"
  [ "$RC" -eq 1 ] && [[ "$OUT" == *'guard: suite=pi-extensions/peers'* ]] \
    && ok 'control: losing missing-peer classification turns its row red' \
    || bad 'missing-peer control' "rc=$RC out=$OUT"
else bad 'missing-peer control changed nothing'; fi
if mutant_guard 's/)Cannot find (module|package) /)never-matches /'; then
  GUARD="$MUTANT_TOOLS/guard" run_guard PATH="$R/fake-bin:$PATH" PEER_SUITE_OUTPUT="$BUN_RELATIVE"
  [ "$RC" -eq 3 ] && [[ "$OUT" == *'guard-note: no-verdict=missing-peers=pi-extensions/peers'* ]] \
    && ok 'control: reading a relative specifier as a peer turns the relative-file row red' \
    || bad 'relative specifier control' "rc=$RC out=$OUT"
else bad 'relative specifier control changed nothing'; fi
if mutant_guard 's/exit !(missing \&\& !behavior)/exit !missing/'; then
  GUARD="$MUTANT_TOOLS/guard" run_guard PATH="$R/fake-bin:$PATH" PEER_SUITE_OUTPUT="$QOL_MIXED"
  [ "$RC" -eq 3 ] && [[ "$OUT" == *'guard-note: no-verdict=missing-peers=pi-extensions/peers'* ]] \
    && ok 'control: ignoring independent failures turns the mixed-peer row red' \
    || bad 'independent failure control' "rc=$RC out=$OUT"
else bad 'independent failure control changed nothing'; fi
if mutant_guard 's/if (summary)/if (0)/'; then
  GUARD="$MUTANT_TOOLS/guard" run_guard PATH="$R/fake-bin:$PATH" PEER_SUITE_OUTPUT="$QOL_PEER"
  [ "$RC" -eq 1 ] && [[ "$OUT" == *'guard: suite=pi-extensions/peers'* ]] \
    && ok 'control: recounting summary rows turns the repeated-peer row red' \
    || bad 'summary outcome control' "rc=$RC out=$OUT"
else bad 'summary outcome control changed nothing'; fi
if mutant_guard 's/unavailable_errors++/unavailable_errors += 0/'; then
  GUARD="$MUTANT_TOOLS/guard" run_guard PATH="$R/fake-bin:$PATH" PEER_SUITE_OUTPUT="$BUN_PEER"
  [ "$RC" -eq 1 ] && [[ "$OUT" == *'guard: suite=pi-extensions/peers'* ]] \
    && ok 'control: omitting loader outcomes turns the unhandled-peer row red' \
    || bad 'unhandled outcome control' "rc=$RC out=$OUT"
else bad 'unhandled outcome control changed nothing'; fi
rm -- "$R/fake-bin/npm"
rm -r -- "$R/pi-extensions/peers"

echo "=== full validation runs the lanes the change class selects ==="
# dev-validate-run hands over the class, the docs verdict and the changed
# paths as DEV_VALIDATE_CLASS, DEV_VALIDATE_DOCS_ONLY and a DEV_VALIDATE_PATHS
# file. Each lane is read off the call it makes: cargo and npm log their calls, and the parse
# lane is a stub here because its real pass needs a Bash 3.2 this row does not
# judge. A guard copy runs beside that stub under the same package link the
# mutants use.
LANE_TOOLS="$TMP/lane-tools"
# Outside the world, which each row cleans; rustup is the stub above.
LANE_BIN="$TMP/lane-bin"
mkdir -p "$LANE_TOOLS" "$LANE_BIN"
cp "$R/fake-bin/rustup" "$LANE_BIN/rustup"
cp "$REPO/tools/bash32-lint" "$REPO/tools/ci-job-set" "$REPO/tools/test-roster" \
  "$REPO/tools/macos-test-contracts" "$REPO/tools/macos-test-contracts.json" \
  "$REPO/tools/rust-reads" "$REPO/tools/shipped-refs" "$LANE_TOOLS/"
cp -R "$REPO/tools/lib" "$LANE_TOOLS/lib"
printf '#!/usr/bin/env bash\necho "stub: bash32-parse"\n' >"$LANE_TOOLS/bash32-parse"
chmod +x "$LANE_TOOLS/bash32-parse"
lane_guard() { # [SED-EXPR] — the guard copy the rows run, edited when given
  sed "${1:-}" "$GUARD" >"$LANE_TOOLS/guard"
  chmod +x "$LANE_TOOLS/guard"
  [ -z "${1:-}" ] || ! cmp -s "$GUARD" "$LANE_TOOLS/guard" ||
    { echo "lane_guard: the edit '$1' changed nothing" >&2; exit 2; }
}
cat >"$LANE_BIN/cargo" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = metadata ]; then exec "$REAL_CARGO" "$@"; fi
printf '%s\n' "$*" >>"$CARGO_CALL_LOG"
SH
cat >"$LANE_BIN/npm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NPM_CALL_LOG"
SH
chmod +x "$LANE_BIN/cargo" "$LANE_BIN/npm"
NPM_CALL_LOG="$TMP/npm-calls"
REAL_CARGO="$(command -v cargo)" || exit 2
mkdir -p "$R/ui"
# Selection reads real Cargo metadata; compilation stays logged by the stub.
mkdir -p "$R/crates/core/src" "$R/crates/cli/src" "$R/crates/cli/tests"
printf '[workspace]\nmembers = ["crates/core", "crates/cli"]\nresolver = "2"\n[workspace.lints.rust]\n' >"$R/Cargo.toml"
printf '[package]\nname = "kendex-core"\nversion = "0.1.0"\n[lints]\nworkspace = true\n' >"$R/crates/core/Cargo.toml"
cat >"$R/crates/cli/Cargo.toml" <<'TOML'
[package]
name = "kendex-cli"
version = "0.1.0"
[dependencies]
kendex-core = { path = "../core" }
[lints]
workspace = true
[[test]]
name = "cli_smoke"
path = "tests/cli_smoke.rs"
TOML
printf 'pub fn core() {}\n' >"$R/crates/core/src/lib.rs"
printf 'pub fn cli() {}\n' >"$R/crates/cli/src/lib.rs"
printf 'fn smoke() {}\n' >"$R/crates/cli/tests/cli_smoke.rs"
printf '{}\n' >"$R/ui/package.json"
git -C "$R" add Cargo.toml crates/core crates/cli ui/package.json
git -C "$R" commit -q -m "chore: a workspace and a ui package"
lanes_head="$(git -C "$R" rev-parse HEAD)"
git -C "$R" update-ref refs/remotes/origin/main HEAD
# The lanes one guard run reached, in a fixed order.
lanes_ran() {
  local seen="" lane
  for lane in suites parse lint apple windows test ui; do
    case "$lane" in
      suites) [[ "$OUT" == *"=== skills/demo/tests/demo.test.sh"* ]] ;;
      parse) [[ "$OUT" == *"stub: bash32-parse"* ]] ;;
      lint) grep -qFx "clippy --workspace --all-targets --quiet" "$CARGO_CALL_LOG" ;;
      apple) grep -qF -- "--target aarch64-apple-darwin" "$CARGO_CALL_LOG" ;;
      windows) grep -qF -- "--target x86_64-pc-windows-msvc" "$CARGO_CALL_LOG" ;;
      test) grep -qFx "test --workspace --quiet" "$CARGO_CALL_LOG" ;;
      ui) [ -s "$NPM_CALL_LOG" ] ;;
    esac && seen="$seen $lane"
  done
  printf '%s' "${seen# }"
}
PATHS_FILE="$TMP/changed-paths"
run_lanes() { # CLASS DOCS PATH... — guard --full with PATHs touched and handed over; sets OUT and RC
  local class="$1" docs="$2" p
  local handed=()
  shift 2
  git -C "$R" reset -q --hard "$lanes_head"
  git -C "$R" clean -qfd
  : >"$PATHS_FILE"
  for p in "$@"; do
    mkdir -p "$R/$(dirname "$p")"
    printf 'touched\n' >>"$R/$p"
    printf '%s\n' "$p" >>"$PATHS_FILE"
  done
  [ -z "$class" ] ||
    handed=("DEV_VALIDATE_CLASS=$class" "DEV_VALIDATE_DOCS_ONLY=$docs" "DEV_VALIDATE_PATHS=${HANDED_PATHS:-$PATHS_FILE}")
  : >"$CARGO_CALL_LOG"
  : >"$NPM_CALL_LOG"
  OUT=""
  RC=0
  OUT="$(cd "$R" && env -u DEV_VALIDATE_CLASS -u DEV_VALIDATE_DOCS_ONLY -u DEV_VALIDATE_PATHS \
    "${GUARD_TEST_BOUNDS[@]}" ${handed[@]+"${handed[@]}"} \
    PATH="$LANE_BIN:$PATH" REAL_CARGO="$REAL_CARGO" CARGO_CALL_LOG="$CARGO_CALL_LOG" NPM_CALL_LOG="$NPM_CALL_LOG" \
    RUSTUP_INSTALLED_TARGETS="$BOTH" "$LANE_TOOLS/guard" --full 2>&1 </dev/null)" || RC=$?
}
# Path lists are blank-separated and split unquoted on purpose. The crate
# path is the Rust input the cross-target checks wait for.
CODE="skills/demo/scripts/demo.sh .agents/skills/demo/scripts/demo.sh crates/core/src/lib.rs"
# A skill and a tool, the diff no build input and no ui/ path is in.
SKILL_TOOL="skills/demo/scripts/demo.sh .agents/skills/demo/scripts/demo.sh tools/demo-tool.sh"
ALL="suites parse lint apple windows test ui"
# class|docs verdict|changed paths|the lanes that run
LANE_ROWS=(
  "||$CODE|$ALL"
  "standard|false|$CODE ui/app.ts|$ALL"
  "standard|false|$CODE|suites parse lint apple windows test"
  "standard|false|$SKILL_TOOL|suites parse test"
  "standard|true|docs/guide.md|test"
  "render|false|$CODE|"
  "trivial|true|$CODE|"
  "micro|false|$CODE|suites parse lint apple windows test"
  "small|false|$CODE ui/app.ts|$ALL"
  "micro|false|docs/guide.md|test"
  "||crates/core/src/lib.rs ui/app.ts|parse lint apple windows test ui"
)
lane_guard
for row in "${LANE_ROWS[@]}"; do
  IFS='|' read -r class docs paths want <<<"$row"
  run_lanes "$class" "$docs" $paths
  got="$(lanes_ran)"
  [ "$RC" -eq 0 ] && [ "$got" = "$want" ] && [ "$(sed -n '$p' <<<"$OUT")" = 'validate: lanes=guard-scans selection=all' ] \
    && ok "class '${class:-unset}' docs-only '${docs:-unset}' over $paths runs: ${want:-no heavy lane}" \
    || bad "class '${class:-unset}' docs-only '${docs:-unset}' over $paths runs: ${want:-no heavy lane}" "rc=$RC got=$got out=$OUT"
done
[ "$(grep -cF "printf 'validate: lanes=%s" "$GUARD")" -eq 1 ] || { echo 'lane control: reporting edit has no unique match' >&2; exit 1; }
lane_guard "/^printf 'validate: /s/^/: # /"
run_lanes '' '' $CODE ui/app.ts
[ "$RC" -eq 0 ] && [ "$(sed -n '$p' <<<"$OUT")" != 'validate: lanes=guard-scans selection=all' ] \
  && ok "control: without the final report the lane assertion turns red" \
  || bad "control: without the final report the lane assertion turns red" "$OUT"
lane_guard 's/^suite_selection=""$/suite_selection=subset/'
run_lanes render false $CODE
[ "$RC" -eq 0 ] && [ "$(lanes_ran)" = "" ] \
  && [ "$(sed -n '$p' <<<"$OUT")" = 'validate: lanes=guard-scans selection=subset' ] \
  && ok "control: with the default reporting subset a disabled shell lane fails its all assertion" \
  || bad "control: with the default reporting subset a disabled shell lane fails its all assertion" "rc=$RC out=$OUT"
lane_guard
run_lanes stale false $CODE
[ "$RC" -eq 2 ] && [[ "$OUT" == *"guard: validate-class=stale"* ]] && [ "$(lanes_ran)" = "" ] \
  && ok "a class ci-job-set has no selection for is refused before any lane runs" \
  || bad "a class ci-job-set has no selection for is refused before any lane runs" "rc=$RC out=$OUT"
# The runner's class fallback, an empty paths file, runs every lane, green.
: >"$TMP/empty-paths"
HANDED_PATHS="$TMP/empty-paths" run_lanes standard false $SKILL_TOOL
[ "$RC" -eq 0 ] && [[ "$OUT" == *"guard-note: lane-selection=class-fallback"* ]] && [ "$(lanes_ran)" = "suites parse lint test ui" ] \
  && ok "the runner's class fallback, an empty paths file, runs every lane and passes" \
  || bad "the runner's class fallback, an empty paths file, runs every lane and passes" "rc=$RC got=$(lanes_ran) out=$OUT"
lane_guard '/^  elif \[ -z "\$selected_paths" \]; then$/,/^    note lane-selection class-fallback$/d'
HANDED_PATHS="$TMP/empty-paths" run_lanes standard false $SKILL_TOOL
[ "$RC" -ne 0 ] \
  && ok "control: with the fallback unread the empty paths file reds the run" \
  || bad "control: with the fallback unread the empty paths file reds the run" "rc=$RC out=$OUT"
lane_guard
# A narrow class whose paths file cannot be read selects nothing: every lane
# runs and the run is red, never a stand-down on no paths.
HANDED_PATHS="$TMP/absent-paths" run_lanes micro false $CODE
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: lane-selection=paths-unreadable"* ]] && [ "$(lanes_ran)" = "$ALL" ] \
  && ok "an unreadable paths file is a finding and every lane runs" \
  || bad "an unreadable paths file is a finding and every lane runs" "rc=$RC got=$(lanes_ran) out=$OUT"
# The issue's inverse: a guard that reads no class runs the whole battery on
# the trivial row.
lane_guard 's/\[ "\$MODE" = full \] \&\& \[ -n "\$validate_class" \]; then/[ "$MODE" = full ] \&\& false; then/'
run_lanes trivial true $CODE
[ "$(lanes_ran)" = "$ALL" ] \
  && ok "control: with the class unread the trivial row runs every lane" \
  || bad "control: with the class unread the trivial row runs every lane" "rc=$RC got=$(lanes_ran)"
# A guard that asks the lane table for every class but standard, as it once
# did, runs every lane on the skill-and-tool row CI narrows.
lane_guard 's/\[ "\$MODE" = full \] \&\& \[ -n "\$validate_class" \]; then/[ "$MODE" = full ] \&\& [ "$validate_class" != standard ]; then/'
# The cross targets wait for a Rust input, which this row has none of.
run_lanes standard false $SKILL_TOOL
[ "$(lanes_ran)" = "suites parse lint test ui" ] \
  && ok "control: with standard read as every lane the skill-and-tool row runs every lane" \
  || bad "control: with standard read as every lane the skill-and-tool row runs every lane" "rc=$RC got=$(lanes_ran)"
# A suite a lane runs inherits none of the selection: the outer run's class
# would otherwise choose the lanes of every guard that suite starts, the way
# this file's own rows once ran under a prose-only micro selection. The
# touched demo suite prints what reached it.
inherited_row() { # — sets OUT and RC
  git -C "$R" reset -q --hard "$lanes_head"
  git -C "$R" clean -qfd
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "inner=${DEV_VALIDATE_CLASS-unset}:${DEV_VALIDATE_DOCS_ONLY-unset}:${DEV_VALIDATE_PATHS-unset}"' >"$R/skills/demo/tests/demo.test.sh"
  printf 'skills/demo/tests/demo.test.sh\n' >"$PATHS_FILE"
  OUT=""
  RC=0
  OUT="$(cd "$R" && env "${GUARD_TEST_BOUNDS[@]}" DEV_VALIDATE_CLASS=micro DEV_VALIDATE_DOCS_ONLY=false DEV_VALIDATE_PATHS="$PATHS_FILE" \
    PATH="$LANE_BIN:$PATH" REAL_CARGO="$REAL_CARGO" CARGO_CALL_LOG="$CARGO_CALL_LOG" NPM_CALL_LOG="$NPM_CALL_LOG" \
    RUSTUP_INSTALLED_TARGETS="$BOTH" "$LANE_TOOLS/guard" --full 2>&1 </dev/null)" || RC=$?
}
lane_guard
inherited_row
[ "$RC" -eq 0 ] && [[ "$OUT" == *"inner=unset:unset:unset"* ]] \
  && ok "a suite run under a micro selection inherits none of it" \
  || bad "a suite run under a micro selection inherits none of it" "rc=$RC out=$OUT"
lane_guard '/^unset DEV_VALIDATE_CLASS DEV_VALIDATE_DOCS_ONLY DEV_VALIDATE_PATHS$/d'
inherited_row
[[ "$OUT" == *"inner=micro:false:$PATHS_FILE"* ]] \
  && ok "control: with the selection left exported the suite inherits it" \
  || bad "control: with the selection left exported the suite inherits it" "rc=$RC out=$OUT"
# Lanes come from the output file, not stderr, where the stub selects lint.
cp "$LANE_TOOLS/ci-job-set" "$TMP/ci-job-set.real"
printf '%s\n' '#!/usr/bin/env bash' \
  'rows="shell_shards=false macos_legs=false ui=false bot_instructions=false cargo_linux=false' \
  '  cargo_macos=false cargo_lint=false cargo_windows=false cargo_windows_check=false"' \
  'printf "%s\n" $rows >>"$GITHUB_OUTPUT"; printf "%s\n" $rows cargo_lint=true >&2' >"$LANE_TOOLS/ci-job-set"
chmod +x "$LANE_TOOLS/ci-job-set"
lane_guard
run_lanes micro false docs/guide.md
[ "$RC" -eq 0 ] && [ "$(lanes_ran)" = "" ] \
  && ok "the lanes are read from the output file alone" \
  || bad "the lanes are read from the output file alone" "rc=$RC got=$(lanes_ran) out=$OUT"
lane_guard 's/lanes="\$selected"/lanes="$selection"/'
run_lanes micro false docs/guide.md
[ "$(lanes_ran)" = "lint" ] \
  && ok "control: with the lanes read from both streams stderr selects the lint lane" \
  || bad "control: with the lanes read from both streams stderr selects the lint lane" "rc=$RC got=$(lanes_ran)"
cp "$TMP/ci-job-set.real" "$LANE_TOOLS/ci-job-set"
lane_guard 's/lane_on cargo_linux; then/lane_on cargo_linx; then/'
run_lanes micro false $CODE
[ "$RC" -eq 2 ] && [[ "$OUT" == *"guard: lane-unknown=cargo_linx"* ]] \
  && ok "a lane name the selection does not carry is refused, never read as stood down" \
  || bad "a lane name the selection does not carry is refused, never read as stood down" "rc=$RC out=$OUT"
git -C "$R" reset -q --hard "$SEED"
git -C "$R" clean -qfd
git -C "$R" update-ref -d refs/remotes/origin/main

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
