#!/usr/bin/env bash
# Which kendex the render proof runs. A diff whose only changed path is the
# install record runs the executable HARNESS_CI_LOCK_KENDEX names; every other
# diff, and that one with the variable unset, runs the `kendex` on PATH.
#
# Two doubles stand for the two verifiers a caller can supply: the
# pinned release on PATH, which knows the record's registration shape `v1`
# alone, and the rolling main build, which also knows `v2`. Each refuses a
# record whose shape it does not know, as `kendex verify` does a registration
# written by a newer kendex, and passes one it knows. Each answers `--version`
# from its own directory, answers `verify --help`, and records proof calls. The
# review-gate writer installs a legacy release and a supporting rolling build.
# A third lock kendex whose `--version` exits non-zero is named unreadable.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

export VERIFIER_CALLS="$SANDBOX/verifier-calls"
export VERIFIER_ARGS="$SANDBOX/verifier-args"
export VERIFIER_DOCUMENT="$SANDBOX/verifier-document"
# The document a passing run prints: the record owned whole, and the one
# skill tree the non-record row changes.
printf '%s\n' '{"version":1,"clean":true,"checked":2,"failed":0,"rows":[{"state":"ok","positions":[{"path":".kendex-lock.json","owns":"file"}]},{"state":"ok","positions":[{"path":".agents/skills/orch","owns":"tree"}]}]}' \
  >"$VERIFIER_DOCUMENT"

write_verifier() { # NAME VERSION BOT_FLAG_SUPPORTED SHAPE...
  local dir="$SANDBOX/$1"
  mkdir -p "$dir"
  printf '%s\n' "$2" >"$dir/version"
  printf '%s\n' "$3" >"$dir/bot-flag-supported"
  shift 3
  printf '%s\n' "$@" >"$dir/knows"
  cat >"$dir/kendex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bot_flag_supported="$(cat "$here/bot-flag-supported")"
if [ "$*" = --version ]; then
  version="$(cat "$here/version")"
  [ -n "$version" ] || exit 1
  printf 'kendex %s\n' "$version"
  exit 0
fi
if [ "$*" = 'verify --help' ]; then
  printf '%s\n' '  --scope <SCOPE> --json'
  if [ "$bot_flag_supported" = true ]; then
    printf '%s\n' '  --bot-instructions-from <DIR>'
  fi
  exit 0
fi
printf '%s\n' "${here##*/}" >>"$VERIFIER_CALLS"
printf '%s\n' "$@" >>"$VERIFIER_ARGS"
for arg in "$@"; do
  if [ "$arg" = --bot-instructions-from ] && [ "$bot_flag_supported" != true ]; then
    exit 2
  fi
done
shape="$(sed -n 's/.*"registration":"\([^"]*\)".*/\1/p' .kendex-lock.json)"
grep -qxF -- "$shape" "$here/knows" ||
  { echo "hook guard [claude]: its settings entry is out of sync" >&2; exit 1; }
cat "$VERIFIER_DOCUMENT"
STUB
  chmod +x "$dir/kendex"
}
write_verifier pinned 1.2.0 false v1
write_verifier lock 1.2.0+main.365.1cdc8b27 true v1 v2
write_verifier unversioned '' false v1
PINNED_PATH="$SANDBOX/pinned:$PATH"
LOCK_KENDEX="$SANDBOX/lock/kendex"
not_executable="$SANDBOX/not-executable"
printf '#!/usr/bin/env bash\n' >"$not_executable"

record() { # REPO SHAPE
  printf '{"entries":{"hook:guard:claude":{"registration":"%s"}}}\n' "$2" >"$1/.kendex-lock.json"
}

repo="$(new_repo lock-verifier)"
printf '%s\n' '[".kendex-generated.json",".kendex-lock.json",".agents/skills/orch/SKILL.md"]' \
  >"$repo/.kendex-generated.json"
record "$repo" v1
commit_paths "$repo" "a consumer recording one hook" .agents/skills/orch/SKILL.md
base="$(git -C "$repo" rev-parse HEAD)"

# label | lock kendex (unset, lock, unversioned, not-executable) | changes
# | class line | verifier calls | proof capability (legacy, bot, none)
rows=0
while IFS='|' read -r label lock changes want calls proof; do
  rows=$((rows + 1))
  git -C "$repo" checkout -q -B case "$base"
  for change in $changes; do
    case "$change" in
      record) record "$repo" v2 ;;
      skill) printf 'rendered again\n' >>"$repo/.agents/skills/orch/SKILL.md" ;;
      *) echo "lock-verifier: unknown change $change" >&2; exit 1 ;;
    esac
  done
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$label"
  : >"$VERIFIER_CALLS"
  : >"$VERIFIER_ARGS"
  case "$lock" in
    unset) lock_env=(env -u HARNESS_CI_LOCK_KENDEX) ;;
    lock) lock_env=(env HARNESS_CI_LOCK_KENDEX="$LOCK_KENDEX") ;;
    unversioned) lock_env=(env HARNESS_CI_LOCK_KENDEX="$SANDBOX/unversioned/kendex") ;;
    not-executable) lock_env=(env HARNESS_CI_LOCK_KENDEX="$not_executable") ;;
    *) echo "lock-verifier: unknown lock kendex $lock" >&2; exit 1 ;;
  esac
  err="$(PATH="$PINNED_PATH" "${lock_env[@]}" "$CHANGE_CLASS" --repo "$repo" \
    --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
  assert_eq "$label" "$want" "$(printf '%s\n' "$err" | sed -n 's/^class: //p')"
  assert_eq "$label: verifiers run" "$calls" "$(paste -sd' ' - <"$VERIFIER_CALLS")"
  case "$proof" in
    legacy) want_args='verify --scope project --json' ;;
    bot) want_args="verify --scope project --json --bot-instructions-from $(dirname "$CHANGE_CLASS")/../../bot-instructions" ;;
    none) want_args='' ;;
    *) echo "lock-verifier: unknown proof capability $proof" >&2; exit 1 ;;
  esac
  if [ "$proof" != none ]; then
    want_args="$want_args --base $base --at-record"
  fi
  assert_eq "$label: proof arguments" "$want_args" "$(paste -sd' ' - <"$VERIFIER_ARGS")"
done <<'CASES'
a record in a shape the pinned release does not know is a render under the lock kendex|lock|record|class=render measured=true cause=renders-match-their-sources|lock|bot
the same record is refused by the pinned release, named with its version|unset|record|class=standard measured=false cause=verify-refused verifier=path version=1.2.0|pinned|legacy
a render beside the record runs the pinned release though the lock kendex is set|lock|record skill|class=standard measured=false cause=verify-refused verifier=path version=1.2.0|pinned|legacy
a render with no record change runs the pinned release though the lock kendex is set|lock|skill|class=render measured=true cause=renders-match-their-sources|pinned|legacy
a lock kendex that is not executable is no verifier|not-executable|record|class=standard measured=false cause=no-verifier verifier=lock||none
a lock kendex whose version cannot be read is named unreadable in its refusal|unversioned|record|class=standard measured=false cause=verify-refused verifier=lock version=unreadable|unversioned|legacy
CASES
require_rows lock-verifier "$rows"

# The verifier that ran is on the log with its version, pass or refusal.
git -C "$repo" checkout -q -B case "$base"
record "$repo" v2
git -C "$repo" commit -q -am "the record alone"
lock_err="$(PATH="$PINNED_PATH" HARNESS_CI_LOCK_KENDEX="$LOCK_KENDEX" "$CHANGE_CLASS" \
  --repo "$repo" --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
assert_eq "the log names the lock kendex and its version" \
  "render-verifier: verifier=lock version=1.2.0+main.365.1cdc8b27" \
  "$(printf '%s\n' "$lock_err" | grep '^render-verifier: ')"

# Must-fail control for the selection rule: a planted copy whose lock-only
# arm can never be taken runs the pinned release on the record-only diff
# above, with the lock kendex set, and answers that release's refusal.
select_line='  if [ "$changed" = .kendex-lock.json ] && [ -n "${HARNESS_CI_LOCK_KENDEX:-}" ]; then'
unselected="$(mutant unselected change-class "$select_line" "  if false && ${select_line#  if }")"
if cmp -s -- "$CHANGE_CLASS" "$unselected"; then
  assert_eq "the control changes the copy" changed unchanged
fi
: >"$VERIFIER_CALLS"
control_err="$(PATH="$PINNED_PATH" HARNESS_CI_LOCK_KENDEX="$LOCK_KENDEX" "$unselected" \
  --repo "$repo" --event pull_request --base "$base" --head HEAD 2>&1 >/dev/null)"
assert_eq "a classifier that never selects the lock kendex refuses the record" \
  "class=standard measured=false cause=verify-refused verifier=path version=1.2.0" \
  "$(printf '%s\n' "$control_err" | sed -n 's/^class: //p')"
assert_eq "and ran the pinned release alone" pinned "$(paste -sd' ' - <"$VERIFIER_CALLS")"

# Must-fail control: probing the release's help drops the supported option
# from the rolling lock verifier's proof, despite selecting that verifier.
help_line='  if verify_help="$("$verifier" verify --help 2>/dev/null </dev/null)" &&'
wrong_help="$(mutant wrong-help change-class "$help_line" \
  '  if verify_help="$(kendex verify --help 2>/dev/null </dev/null)" &&')"
: >"$VERIFIER_CALLS"
: >"$VERIFIER_ARGS"
PATH="$PINNED_PATH" HARNESS_CI_LOCK_KENDEX="$LOCK_KENDEX" "$wrong_help" \
  --repo "$repo" --event pull_request --base "$base" --head HEAD >/dev/null 2>&1
assert_eq "wrong help still selects the lock verifier" lock "$(paste -sd' ' - <"$VERIFIER_CALLS")"
assert_eq "wrong help loses the lock verifier's supported option" \
  "verify --scope project --json --base $base --at-record" "$(paste -sd' ' - <"$VERIFIER_ARGS")"

report lock-verifier
