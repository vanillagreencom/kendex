#!/usr/bin/env bash
# scripts/pr-order keeps unset visibility defaults and honors explicit settings.
# Inputs: scripts/pr-order, scripts/orch-env, lib/gh-repo.sh and the shared loaders.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/shared-skill-libs.sh"
source "$TEST_DIR/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)" || exit 1
[[ -d "$TMP_ROOT" && ! -L "$TMP_ROOT" ]] || exit 1
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || exit 1
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
LIVE="$SKILL_DIR/scripts/pr-order"
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/checkout" "$TMP_ROOT/elsewhere"
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$STUB_LOG"
[[ "$STUB_VISIBILITY" != UNREAD ]] || exit 1
printf '%s\n' "$STUB_VISIBILITY"
EOF
chmod +x "$TMP_ROOT/bin/gh"
run() { # SCRIPT VALUE VISIBILITY
  : > "$TMP_ROOT/gh-calls"
  rm -f "${TMP_ROOT:?}/checkout/kendex.settings.toml"
  [[ "$2" == unset ]] || printf '[env]\nORCH_PR_ORDER = "%s"\n' "$2" > "$TMP_ROOT/checkout/kendex.settings.toml"
  set +e
  OUT="$(cd "$TMP_ROOT/elsewhere" && env -u ORCH_PR_ORDER -u KENDEX_ENV_FILE \
    GH_REPO=fixture/repo PATH="$TMP_ROOT/bin:$PATH" STUB_LOG="$TMP_ROOT/gh-calls" STUB_VISIBILITY="$3" \
    "$1" "$TMP_ROOT/checkout" 2>"$TMP_ROOT/err")"
  RC=$?
  set -e
}
while IFS='|' read -r value visibility want_order cause; do
    want_rc=0
    [[ -z "$cause" ]] || want_rc=2
    run "$LIVE" "$value" "$visibility"
    assert_eq "$RC ${OUT:-empty}" "$want_rc $want_order" "setting=$value visibility=$visibility"
    want_calls=
    [[ "$value" != unset ]] || want_calls='repo view fixture/repo --json visibility --jq .visibility'
    assert_eq "$(cat "$TMP_ROOT/gh-calls")" "$want_calls" "only an unset order reads visibility"
    if [[ "$want_rc" == 2 ]]; then
      assert_eq "$(sed -n 's/^pr-order-error: cause=\([^ ]*\).*/\1/p' "$TMP_ROOT/err")" "$cause" "unreadable or unknown order refuses"
    fi
done <<'ROWS'
unset|PUBLIC|pr-order=review-first|
unset|PRIVATE|pr-order=open-first|
unset|INTERNAL|pr-order=review-first|
review-first|PUBLIC|pr-order=review-first|
review-first|PRIVATE|pr-order=review-first|
review-first|INTERNAL|pr-order=review-first|
open-first|PUBLIC|pr-order=open-first|
open-first|PRIVATE|pr-order=open-first|
open-first|INTERNAL|pr-order=open-first|
push-first|PUBLIC|pr-order=push-first|
push-first|PRIVATE|pr-order=push-first|
push-first|INTERNAL|pr-order=push-first|
push-first|UNREAD|pr-order=push-first|
unknown|PUBLIC|empty|setting-unknown
unknown|PRIVATE|empty|setting-unknown
unknown|INTERNAL|empty|setting-unknown
unset|UNREAD|empty|visibility-unreadable
unset|UNKNOWN|empty|visibility-unknown
ROWS
# A visibility decision after settings overrides a consumer's explicit choice.
MUTANT_SCRIPTS="$(mutant_scripts visibility-order pr-order)" || exit 1
orch_fixture_shared_libs "${MUTANT_SCRIPTS%/scripts}"
MUTANT="$MUTANT_SCRIPTS/pr-order"
mutate_file "$MUTANT" "printf 'pr-order=%s\\n' \"\$order\"" $'visibility="$(gh repo view --json visibility --jq .visibility)"\ncase "$visibility" in PRIVATE) order=open-first ;; *) order=review-first ;; esac\nprintf \'pr-order=%s\\n\' "$order"'
run "$MUTANT" push-first PUBLIC
assert_eq "$OUT" pr-order=review-first "control: visibility mutation breaks public push-first"
run "$MUTANT" review-first PRIVATE
assert_eq "$OUT" pr-order=open-first "control: visibility mutation breaks private review-first"
MUTANT_SCRIPTS="$(mutant_scripts unset-order pr-order)" || exit 1
orch_fixture_shared_libs "${MUTANT_SCRIPTS%/scripts}"
MUTANT="$MUTANT_SCRIPTS/pr-order"
mutate_file "$MUTANT" 'private) order=open-first ;;' 'private) order=review-first ;;'
run "$MUTANT" unset PRIVATE
assert_eq "$OUT" pr-order=review-first "control: changing the unset private default breaks compatibility"
MUTANT_SCRIPTS="$(mutant_scripts caller-order pr-order)" || exit 1
orch_fixture_shared_libs "${MUTANT_SCRIPTS%/scripts}"
MUTANT="$MUTANT_SCRIPTS/pr-order"
mutate_file "$MUTANT" 'cd -- "$worktree"' ':'
run "$MUTANT" push-first PUBLIC
assert_eq "$OUT" pr-order=review-first "control: removing the worktree change loses its setting"
printf 'pass: %d fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
