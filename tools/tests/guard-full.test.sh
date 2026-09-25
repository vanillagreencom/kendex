#!/usr/bin/env bash
# tools/guard --full, the completion run: the working-tree bot-instructions
# check, the cross-target compile of core and the CLI, the Rust inputs that
# decide whether it and cargo doc run, the suites of the trees the branch
# touched, and a test binary's death by a signal named apart from a failing
# test. Every compiler and toolchain call is a stub in fake-bin.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GUARD_FULL_CROSS_DOC

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/guard-world.sh
. "$TEST_DIR/lib/guard-world.sh"

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

FULL_GUARD=1
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
# rustfmt's status: 1 for a diff it wrote, 0 when that write failed. A write
# straight to the guard's own stream, FMT_FULL_STREAM, lands on a full device.
if [ "$*" = "fmt --check" ] && [ -n "${FMT_FULL_STREAM:-}" ]; then
  [ ! /dev/stdout -ef "$FMT_FULL_STREAM" ] || exec >/dev/full
  printf 'Diff in src/lib.rs:\n' && exit 1
  exit 0
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
  "a cold target below the start floor refuses before cargo|CARGO_TARGET_DIR=$TMP/cold/target DF_FREE_KIB_START=$G|1|guard: cargo-space-start=free-kib=$G target-kib=0 min-gib=24|0"
  "the build in a warm target counts toward the start floor|CARGO_TARGET_DIR=$TMP/warm DU_KIB=$((23 * G)) DF_FREE_KIB_START=$G|0||1"
  "free space below the exhaustion floor refuses before the target is measured|DU_FAIL=1 CARGO_TARGET_DIR=$TMP/inc DF_FREE_KIB_START=708|1|guard: cargo-space-free=free-kib=708 min-free-mib=512|0"
  "an incremental directory is not room|CARGO_TARGET_DIR=$TMP/inc DU_KIB=$((30 * G)) DU_INCREMENTAL_KIB=$((8 * G)) DF_FREE_KIB_START=$G|1|guard: cargo-space-start=free-kib=$G target-kib=$((22 * G)) min-gib=24|0"
  "a volume above the start floor reaches the cargo block|DF_FREE_KIB_START=$high_free_kib|0||1"
  "an unreadable start probe is named and the block still runs|DF_FAIL_CALL=1 DF_FREE_KIB_START=$G|0|guard-note: cargo-space-unreadable=target|1"
  "an unreadable target size is named and the block still runs|DU_FAIL=1 CARGO_TARGET_DIR=$TMP/warm DF_FREE_KIB_START=$G|0|guard-note: cargo-target-unreadable=$TMP/warm|1"
  "an exhausted volume fails after zero cargo exit codes, with cross-target checks left to CI|GUARD_FULL_CROSS_DOC=ci DF_FREE_KIB_START=$high_free_kib DF_FREE_KIB_END=0|1|guard: cargo-space-end=free-kib=0 min-mib=512|1"
  "an unreadable end probe fails the run|DF_FAIL_CALL=2 DF_FREE_KIB_START=$high_free_kib|1|guard: cargo-space-end-unreadable=target|1"
  "a start floor that is not a whole number refuses|GUARD_MIN_FREE_GB=16GiB DF_FREE_KIB_START=$high_free_kib|2|guard: cargo-space-setting=GUARD_MIN_FREE_GB|0"
  "an exhaustion floor that is not a whole number refuses|GUARD_EXHAUSTED_FREE_MB=512MB DF_FREE_KIB_START=$high_free_kib DF_FREE_KIB_END=0|2|guard: cargo-space-setting=GUARD_EXHAUSTED_FREE_MB|0"
  "an exhaustion floor of zero refuses|GUARD_EXHAUSTED_FREE_MB=0 DF_FREE_KIB_START=$high_free_kib DF_FREE_KIB_END=0|2|guard: cargo-space-setting=GUARD_EXHAUSTED_FREE_MB|0"
)
# A touched suite that leaves a marker: a refused start must end the run before
# the suite lane, where a suite may run cargo of its own.
SUITE_MARKER="$TMP/suite-ran"
for f in skills/demo/tests/demo.test.sh .agents/skills/demo/tests/demo.test.sh; do
  printf ': >"$SUITE_MARKER"\n' >>"$R/$f"
done
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
0|/^space_stop() {/,/^}/s/^  exit 1$/  :/
0|/^  while \[ ! -e "\$path" \]; do$/,/^  done$/d
1|s/"\$((cargo_free_start_kib + cargo_target_start_kib))"/"$cargo_free_start_kib"/
2|s/^  elif \[ "\$cargo_free_start_kib" -lt/  elif false \&\& [ "$cargo_free_start_kib" -lt/
2|s/^  elif \[ "\$cargo_free_start_kib" -lt/  elif cargo_target_kib "$cargo_target_path" >\/dev\/null \&\& [ "$cargo_free_start_kib" -lt/
3|s/{ kib -= \$1 }/{ }/
7|s/^    say cargo-space-end "free-kib/    note cargo-space-end "free-kib/
8|s/^    say cargo-space-end-unreadable/    note cargo-space-end-unreadable/
9|s/"" | \*\[!0-9\]\*) refuse cargo-space-setting/"") refuse cargo-space-setting/
10|/^  whole_setting GUARD_EXHAUSTED_FREE_MB/d
11|s/^    \*\[!0\]\*) ;;$/    *) ;;/
4|/^  export CARGO_INCREMENTAL=0$/d
EDITS
git -C "$R" checkout -q -- skills/demo/tests/demo.test.sh .agents/skills/demo/tests/demo.test.sh

# Every other lane fails its own write on a full stream too, so only fmt's
# write straight to the guard's stream lands on the device.
if [ -e /dev/full ]; then
  fmt_full_row() { # GUARD_PATH — sets OUT and RC
    : >"$DF_CALL_LOG"
    RC=0
    (cd "$R" && env PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" DF_CALL_LOG="$DF_CALL_LOG" \
      FMT_FULL_STREAM="$TMP/guard-stream" DF_FREE_KIB_START="$high_free_kib" DF_FREE_KIB_END="$high_free_kib" \
      RUSTUP_INSTALLED_TARGETS="$BOTH" "$1" --full >"$TMP/guard-stream" 2>&1 </dev/null) || RC=$?
    OUT="$(cat "$TMP/guard-stream")"
  }
  fmt_full_row "$GUARD"
  [ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: cargo-fmt=workspace"*"Diff in src/lib.rs:"* ]] \
    && ok "a format diff fails validation when a write to the guard's stream would fail" \
    || bad "a format diff fails validation when a write to the guard's stream would fail" "rc=$RC out=$OUT"
  if mutant_guard 's/  fmt_out=$(cargo fmt --check 2>&1) || say/  fmt_out=""; cargo fmt --check || say/'; then
    fmt_full_row "$MUTANT_TOOLS/guard"
    [ "$RC" -eq 0 ] \
      && ok "control: with fmt writing to the guard's stream the same diff passes" \
      || bad "control: with fmt writing to the guard's stream the same diff passes" "rc=$RC out=$OUT"
  else
    bad "control: the fmt capture could not be removed from a guard copy"
  fi
else
  echo "  skip  /dev/full is absent; the full-output fmt row did not run"
fi
rm -f "$R/fake-bin/df" "$R/fake-bin/du"

: >"$CARGO_CALL_LOG"
run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_LIST_RESULT=1
[ "$RC" -ne 0 ] && case "$OUT" in *"guard: rustup-targets=unreadable"*) true ;; *) false ;; esac \
  && ok "a failed installed-target lookup blocks guard" \
  || bad "a failed installed-target lookup blocks guard" "rc=$RC out=$OUT"
run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_INSTALLED_TARGETS=x86_64-unknown-linux-gnu
[ "$RC" -ne 0 ] &&
  case "$OUT" in *"guard: missing-target=$APPLE"*) true ;; *) false ;; esac &&
  case "$OUT" in *"guard: missing-target=$WINDOWS"*) true ;; *) false ;; esac \
  && ok "every missing target is refused with its own install command" \
  || bad "every missing target is refused with its own install command" "rc=$RC out=$OUT"
if grep -qE -- "--target ($APPLE|$WINDOWS)\$" "$CARGO_CALL_LOG"; then
  bad "a missing target is not handed to cargo" "$(cat "$CARGO_CALL_LOG")"
else
  ok "a missing target is not handed to cargo"
fi
: >"$CARGO_CALL_LOG"
run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_INSTALLED_TARGETS="$WINDOWS"
[ "$RC" -ne 0 ] && case "$OUT" in *"guard: missing-target=$APPLE"*) true ;; *) false ;; esac &&
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
  OUT=""
  RC=0
  OUT="$(cd "$R" && env PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" REAL_FIND="$REAL_FIND" \
    RUSTUP_INSTALLED_TARGETS="$BOTH" "$@" "$guard_path" --full 2>&1 </dev/null)" || RC=$?
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
# checks, and printed TEXT; a run with no TEXT printed no notice.
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
    [[ "$OUT" != *"guard-note:"* ]]
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
docs/notes.md||main|FAIL_FIND=1|1|run|guard: compiled-includes=crates|a failed include read is refused, and both still run
docs/notes.md||none||0|run||a committed crate change with no origin/main to diff against runs both
ROWS
[ "$((PASS + FAIL))" -gt "$before" ] || { echo "no row was asserted: the cross-doc gate" >&2; exit 2; }
# One control per rule: each mutant removes that rule from a guard copy, and
# the row the rule decides turns to the verdict the rule was there to refuse.
# An edit carries no |, the column separator. EDIT|TOUCH|SETTING|BASE|ENV|RC|CALLS|TEXT|LABEL.
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
s/if ! includes=\$(compiled_includes)/if ! includes=$(true)/|docs/authoring/README.md||main||0|skip|guard-note: cross-doc-skipped=no-rust-input|with the include derivation emptied an included file skips both
s/if (pending \&\& match/if (0 \&\& match/|docs/split.md||main||0|skip|guard-note: cross-doc-skipped=no-rust-input|with the next-line literal unread a file named on the line after skips both
s/if \[ "\$cross_doc" = ci \]; then/if false; then/|crates/app/src/mine.rs|ci|main||0|run||with the ci branch removed the setting at ci runs both
s/say cross-doc-setting "\$cross_doc"; //|crates/app/src/mine.rs|never|main||0|run||with the refusal removed an unknown setting passes
/\[ -n "\$touched" \]/d|-||main||0|skip|guard-note: cross-doc-skipped=no-rust-input|with the empty-set rule removed a branch that touches nothing skips both
/say compiled-includes crates/{n;d;}|docs/notes.md||main|FAIL_FIND=1|1|skip|guard: compiled-includes=crates|with the failed read left undecided a prose file skips both
/\[ "\$base_resolved" -eq 1 \]/d|docs/notes.md||none||0|skip|guard-note: cross-doc-skipped=no-rust-input|with the base rule removed a committed crate change with no origin/main skips both
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
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: test-binary-signal=11"*"review_fixes-ff58"*"SIGSEGV"* ]] \
  && [[ "$OUT" != *"guard: cargo-test=workspace"* ]] \
  && ok "a runner killed by a signal is reported as the artifact's death, not a failing test" \
  || bad "a runner killed by a signal is reported as the artifact's death, not a failing test" "rc=$RC out=$OUT"
run_guard PATH="$R/fake-bin:$PATH" RUSTUP_INSTALLED_TARGETS="$BOTH" CARGO_TEST_STDERR="$ASSERTION"
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: cargo-test=workspace"* ]] && [[ "$OUT" != *"guard: test-binary-signal="* ]] \
  && ok "a failing assertion still reads as tests failed" \
  || bad "a failing assertion still reads as tests failed" "rc=$RC out=$OUT"
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

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
