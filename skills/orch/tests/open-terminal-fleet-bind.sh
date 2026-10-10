#!/usr/bin/env bash
# open-terminal's overseer binding, lib/lane-cap.sh's overseer_bind: a launch
# under --state-dir runs in the overseer's repository, the one of the directory
# the fleet state's overseer record names, else of the directory
# workflow-state resolves the --state-dir to, by git common root or by origin
# OWNER/REPO, else, where neither names a
# repository, of the launch checkout itself, or in one that directory's
# ORCH_CONNECTED_REPOS lists by origin OWNER/REPO; any other is refused as
# overseer-foreign before the state is touched, and one that cannot be judged
# as overseer-unjudged, except a launch whose state does not parse, which the
# fleet cap refuses first as cap-unreadable. The lane record of a launch the list admits carries the
# listed repository as repo.
#
# The suite runs a copy of open-terminal beside copies of workflow-state,
# git-context and orch-env, with the worktree CLI, gh, the GUI terminal and
# the harness stubbed. The overseer runs in a repository of its own with one
# linked worktree, the shape a lane's worktree has, and a second clone; the
# target is the clone of another repository. LINEAR_TEAM is empty on every
# row, the configuration that leaves the item check with no checkout team to
# compare.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
export ORCH_LANE_HOST=local
# The fleet cap has its own suite, open-terminal-cap.sh, and is out of the way.
export ORCH_OVERSEER_LANES=1000
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"
# shellcheck source=lib/question-off.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/question-off.sh"
# mutant_scripts and mutate_file, the two halves of the controls below.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-fleet-bind: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-fleet-bind: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-fleet-bind: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
SCRATCH_PARENT="$(dirname -- "$TMP_ROOT")"

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

# Stubs: the GUI terminal and claude exit 0 without running anything, gh
# answers nothing, so the GitHub resolver falls to the origin remote, and lanes
# clears every lane.
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/ghostty"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/gh"
printf '#!/usr/bin/env bash\ncase "${1:-}" in check) exit 0 ;; list) echo "[]" ;; esac\nexit 0\n' > "$BIN/lanes"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"
chmod +x "$BIN/ghostty" "$BIN/gh" "$BIN/lanes" "$BIN/claude"
export TERMINAL=ghostty

# worktree: create and path answer with a directory under $TMP_ROOT/wt, no
# item exists yet, and merged answers unmerged.
STUB="$TMP_ROOT/worktree-stub"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
set -euo pipefail
d="$TMP_ROOT/wt/\${2:-unknown}"
case "\${1:-}" in
  exists) echo false ;;
  merged) exit 1 ;;
  path) printf '%s\n' "\$d" ;;
  create) mkdir -p "\$d"; git init -q "\$d"; git -C "\$d" config gc.auto 0; git -C "\$d" config maintenance.auto false; printf '%s\n' "\$d" ;;
  *) echo "unexpected worktree stub call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$STUB"

REPO="$TMP_ROOT/repo"
mutant_scripts repo >/dev/null || exit 1
orch_fixture_shared_libs "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config gc.auto 0
git -C "$REPO" config maintenance.auto false
OT="$REPO/scripts/open-terminal"
WS="$REPO/scripts/workflow-state"

# new_repo DIR ORIGIN — a repository with one commit, and ORIGIN as its origin
# remote where one is given.
new_repo() {
  git init -q "$1"
  git -C "$1" config gc.auto 0
  git -C "$1" config maintenance.auto false
  git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
  [[ -z "${2:-}" ]] || git -C "$1" remote add origin "$2"
}
OVERSEER_REPO="$TMP_ROOT/overseer-repo"
OVERSEER_WT="$TMP_ROOT/overseer-wt"
new_repo "$OVERSEER_REPO" git@github.com:own/fleet.git
git -C "$OVERSEER_REPO" worktree add -q "$OVERSEER_WT" -b lane
OVERSEER_CLONE="$TMP_ROOT/overseer-clone"
new_repo "$OVERSEER_CLONE" https://github.com/Own/Fleet.git
TARGET="$TMP_ROOT/target"
new_repo "$TARGET" https://github.com/acme/target.git
UPPER_TARGET="$TMP_ROOT/upper-target"
new_repo "$UPPER_TARGET" https://github.com/ACME/Target.git
BARE_TARGET="$TMP_ROOT/bare-target"
new_repo "$BARE_TARGET"
NO_GIT="$TMP_ROOT/no-git"
mkdir -p "$NO_GIT"
# A checkout git cannot read: its .git is a gitfile naming a gitdir that does
# not exist, which git refuses with the exit it gives a directory in no
# checkout.
UNREAD_CHECKOUT="$TMP_ROOT/unread-checkout"
mkdir -p "$UNREAD_CHECKOUT"
printf 'gitdir: %s\n' "$TMP_ROOT/missing-gitdir" > "$UNREAD_CHECKOUT/.git"

# connected VALUE — the overseer checkout's ORCH_CONNECTED_REPOS: `absent`
# writes no settings file, anything else is the value.
connected() {
  rm -f -- "$OVERSEER_REPO/kendex.settings.toml"
  [[ "$1" == absent ]] || printf '[env]\nORCH_CONNECTED_REPOS = "%s"\n' "$1" > "$OVERSEER_REPO/kendex.settings.toml"
}

# fleet KIND [CWD] — a fresh fleet state, into STATE: `cwd` is one at
# $TMP_ROOT/state, outside any checkout, whose overseer record names CWD;
# `bare` one whose overseer record names no directory and `none` no state at
# all, each at a --state-dir in the overseer's checkout; `bare-outside` and
# `none-outside` the same at $TMP_ROOT/state; `none-unread` no state at a
# --state-dir in $UNREAD_CHECKOUT.
fleet() {
  case "$1" in
    cwd | bare-outside | none-outside) STATE="$TMP_ROOT/state" ;;
    bare | none) STATE="$OVERSEER_REPO/tmp/fleet" ;;
    none-unread) STATE="$UNREAD_CHECKOUT/tmp/fleet" ;;
    *) echo "open-terminal-fleet-bind: fleet=unknown kind=$1" >&2; exit 1 ;;
  esac
  rm -rf -- "${TMP_ROOT:?}/state" "${OVERSEER_REPO:?}/tmp" "${UNREAD_CHECKOUT:?}/tmp"
  [[ "$1" != none* ]] || return 0
  "$WS" --state-dir "$STATE" init oversee >/dev/null
  if [[ "$1" == cwd ]]; then
    "$WS" --state-dir "$STATE" update oversee --arg cwd "$2" '.overseer = {cwd: $cwd}' >/dev/null
  else
    "$WS" --state-dir "$STATE" update oversee '.overseer = {pane: "%1"}' >/dev/null
  fi
}

# run_ot [SCRIPT=PATH] [CWD=PATH] [ENV=NAME=VALUE]... [WAKE] ARGS — one fleet
# launch into $STATE; sets OUT, ERR and RC. ENV= adds a variable to the
# launcher's environment, which otherwise carries no ORCH_CONNECTED_REPOS.
# WAKE runs a --wake, which takes no custom command, in place of the launch.
# Git looks for no checkout above $TMP_ROOT, so $TMP_ROOT/state, $NO_GIT and
# $TMP_ROOT itself, where the state-dir walk ends for a state not yet made,
# stay outside one wherever the scratch root sits.
run_ot() {
  local script="$OT" cwd="$PWD" extra=() mode=(--cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL")
  while [[ "${1:-}" == SCRIPT=* || "${1:-}" == CWD=* || "${1:-}" == ENV=* || "${1:-}" == WAKE ]]; do
    case "$1" in SCRIPT=*) script="${1#SCRIPT=}" ;; CWD=*) cwd="${1#CWD=}" ;; ENV=*) extra+=("${1#ENV=}") ;; WAKE) mode=(--wake) ;; esac
    shift
  done
  set +e
  OUT="$(cd "$cwd" && env -u ORCH_CONNECTED_REPOS PATH="$BIN:$PATH" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/claims" \
    GIT_CEILING_DIRECTORIES="$SCRATCH_PARENT" WORKTREE_CLI="$STUB" LANES_CLI="$BIN/lanes" LANES_HOME="$TMP_ROOT/home" LINEAR_TEAM= \
    GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' TMUX= TMUX_PANE= GH_REPO= ${extra[@]+"${extra[@]}"} \
    "$script" --state-dir "$STATE" --ghostty --harness claude "${mode[@]}" "$@" 2>"$TMP_ROOT/err")"
  RC=$?
  set -e
  ERR="$(cat "$TMP_ROOT/err")"
}
# record ITEM — the item's lane record as `repo=VALUE`, or `none`, as for a
# state the launch never created.
record() {
  "$WS" --state-dir "$STATE" exists oversee || { echo none; return 0; }
  "$WS" --state-dir "$STATE" get oversee '[.lanes[]? | select(.item == "'"$1"'") | "repo=\(.repo // "null")"] | if . == [] then "none" else join(",") end'
}
refused() { grep -c "^open-terminal: $1" <<<"$ERR" || true; }
# unparsable — overwrites the oversee state in $STATE with a body jq cannot
# parse.
unparsable() { printf '{\n' > "$STATE/workflow-state-oversee.json"; }
STATE_READ_LINE="open-terminal: overseer-unjudged cause=state-read state=oversee"
FOREIGN_LINE="open-terminal: overseer-foreign item=CC-1 repo=acme/target overseer=own/fleet route=connected-repos,peer-mail"

echo "=== a fleet launch runs in its overseer's repository or one it lists ==="
# The fleet state's kind, the overseer's checkout setting, the directory the
# launch runs from, a variable the launcher already holds, and the expected
# exit, lane record and overseer refusal count. A variable the launcher holds
# is what it loads from the checkout it is installed in, which can be the
# target's own. KENDEX_ENV_FILE names alt.env, the overseer checkout's private
# file that lists the target.
rows=(
  "cwd|absent|$OVERSEER_WT||rc=0 record=repo=null foreign=0|a worktree of the overseer's repository passes with the setting absent"
  "cwd||$OVERSEER_WT||rc=0 record=repo=null foreign=0|a worktree of the overseer's repository passes with the setting empty"
  "cwd|absent|$OVERSEER_CLONE||rc=0 record=repo=null foreign=0|a second clone of the overseer's repository passes by its origin with the setting absent"
  "cwd|absent|$TARGET||rc=1 record=none foreign=1|another repository's clone refuses overseer-foreign with the setting absent"
  "cwd|other/repo acme/target-web|$TARGET||rc=1 record=none foreign=1|a clone whose repository the setting does not list, beside one it prefixes, refuses overseer-foreign"
  "cwd|other/repo ACME/Target|$TARGET||rc=0 record=repo=acme/target foreign=0|a listed repository passes, matched case-insensitively, and its lane record carries it as repo"
  "cwd|acme/target|$UPPER_TARGET||rc=0 record=repo=ACME/Target foreign=0|a listed repository passes whatever casing the launch checkout's origin spells it in"
  "cwd|absent|$TARGET|ORCH_CONNECTED_REPOS=acme/target|rc=1 record=none foreign=1|a setting the target checkout or the launcher's own environment holds admits nothing"
  "cwd|absent|$TARGET|KENDEX_ENV_FILE=alt.env|rc=1 record=none foreign=1|the launcher's own private-file selector does not pick the overseer's private file"
  "none|absent|$OVERSEER_WT||rc=0 record=repo=null foreign=0|with no state yet a worktree of the overseer's repository passes, bound by the --state-dir"
  "none|absent|$TARGET||rc=1 record=none foreign=1|with no state yet another repository's clone refuses overseer-foreign"
  "bare|absent|$OVERSEER_WT||rc=0 record=repo=null foreign=0|with no overseer directory recorded a worktree of the overseer's repository passes, bound by the --state-dir"
  "bare|absent|$TARGET||rc=1 record=none foreign=1|with no overseer directory recorded another repository's clone refuses overseer-foreign"
  "bare-outside|absent|$OVERSEER_WT||rc=0 record=repo=null foreign=0|with no overseer directory recorded and the --state-dir outside any checkout, the launch checkout's own repository passes"
  "none-outside|absent|$OVERSEER_WT||rc=0 record=repo=null foreign=0|with no state yet and the --state-dir outside any checkout, the launch checkout's own repository passes"
  "none-outside|absent|$TARGET||rc=0 record=repo=null foreign=0|with no state yet and the --state-dir outside any checkout, the binding is the launch checkout's, so another clone passes too"
)
printf '[env]\nORCH_CONNECTED_REPOS = "acme/target"\n' > "$TARGET/kendex.settings.toml"
printf 'ORCH_CONNECTED_REPOS=acme/target\n' > "$OVERSEER_REPO/alt.env"
for row in "${rows[@]}"; do
  IFS='|' read -r kind setting cwd env expected label <<<"$row"
  connected "$setting"
  fleet "$kind" "$OVERSEER_REPO"
  env_args=()
  [[ -z "$env" ]] || env_args=("ENV=$env")
  run_ot CWD="$cwd" ${env_args[@]+"${env_args[@]}"} CC-1
  assert_eq "rc=$RC record=$(record CC-1) foreign=$(grep -cxF "$FOREIGN_LINE" <<<"$ERR" || true)" "$expected" "$label"
done
fleet cwd "$BARE_TARGET"
run_ot CWD="$BARE_TARGET" CC-1
assert_eq "rc=$RC foreign=$(refused 'overseer-foreign ')" "rc=0 foreign=0" \
  "the overseer's own repository passes on its common root where no origin names it"

echo "=== the refusal names the item, both repositories and both routes ==="
connected absent
fleet cwd "$OVERSEER_REPO"
run_ot CWD="$TARGET" CC-1
assert_eq "$(head -n 1 <<<"$ERR")" "$FOREIGN_LINE" \
  "the first line keys the refusal on the item, the target and overseer origins and the setting and peer-mail routes"

echo "=== connected launches use the overseer's fleet cap ==="
CAP_TARGET_SETTINGS="$(cat "$TARGET/kendex.settings.toml")"
CAP_PRIVATE_SETTINGS="$(cat "$OVERSEER_REPO/alt.env")"
connected_cap() { # SCRIPT OVERSEER_CAP LAUNCH_CAP ENV_VALUE ENV_FILE HELD
  local script="$1" overseer_cap="$2" launch_cap="$3" ambient="$4" private="$5" held="$6"
  printf '[env]\nORCH_CONNECTED_REPOS = "acme/target"\n' > "$OVERSEER_REPO/kendex.settings.toml"
  [[ "$overseer_cap" == absent ]] || printf 'ORCH_OVERSEER_LANES = "%s"\n' "$overseer_cap" >> "$OVERSEER_REPO/kendex.settings.toml"
  printf '[env]\nORCH_OVERSEER_LANES = "%s"\n' "$launch_cap" > "$TARGET/kendex.settings.toml"
  printf 'ORCH_OVERSEER_LANES=%s\n' "$launch_cap" > "$OVERSEER_REPO/alt.env"
  fleet cwd "$OVERSEER_REPO"
  "$WS" --state-dir "$STATE" update oversee --argjson held "$held" '.lanes = [range(0;$held) | {item:("CC-" + ((. + 2) | tostring)),status:"running"}]' >/dev/null
  run_ot SCRIPT="$script" CWD="$TARGET" "ENV=ORCH_OVERSEER_LANES=$ambient" "ENV=KENDEX_ENV_FILE=$private" CC-1
}
while IFS='|' read -r owner launch ambient private held want label; do
  connected_cap "$OT" "$owner" "$launch" "$ambient" "$private" "$held"
  cap_line="$(sed -n 's/^open-terminal: cap-reached .* cap=\([0-9]*\) .*/\1/p' <<<"$ERR")"
  assert_eq "rc=$RC cap=$cap_line record=$(record CC-1)" "$want" "$label"
done <<'ROWS'
5|3|3|alt.env|3|rc=0 cap= record=repo=acme/target|the overseer's higher cap admits a connected launch despite checkout, inherited and private-file caps
3|5|5|alt.env|3|rc=1 cap=3 record=none|a launch checkout's higher cap cannot let the fleet exceed its own cap
absent|5|5|alt.env|3|rc=1 cap=3 record=none|a cap set only in the launch checkout cannot raise the overseer's default cap
ROWS
# Each control keeps the same fleet and changes only where its cap is read.
CAP_DIR="$(mutant_scripts cap-directory open-terminal)"
mutate_file "$CAP_DIR/open-terminal" 'cd -- "$OVERSEER_DIR" && unset ORCH_OVERSEER_LANES KENDEX_ENV_FILE' 'cd -- "$CLAIM_ROOT" && unset ORCH_OVERSEER_LANES KENDEX_ENV_FILE'
CAP_ENV="$(mutant_scripts cap-inherited open-terminal)"
mutate_file "$CAP_ENV/open-terminal" 'unset ORCH_OVERSEER_LANES KENDEX_ENV_FILE && "$SCRIPT_DIR/orch-env" ORCH_OVERSEER_LANES 3' 'unset KENDEX_ENV_FILE && "$SCRIPT_DIR/orch-env" ORCH_OVERSEER_LANES 3'
CAP_PRIVATE="$(mutant_scripts cap-private-file open-terminal)"
mutate_file "$CAP_PRIVATE/open-terminal" 'unset ORCH_OVERSEER_LANES KENDEX_ENV_FILE && "$SCRIPT_DIR/orch-env" ORCH_OVERSEER_LANES 3' 'unset ORCH_OVERSEER_LANES && "$SCRIPT_DIR/orch-env" ORCH_OVERSEER_LANES 3'
for mutant in "$CAP_DIR" "$CAP_ENV" "$CAP_PRIVATE"; do
  connected_cap "$mutant/open-terminal" 5 3 3 alt.env 3
  assert_eq "rc=$RC cap=$(sed -n 's/^open-terminal: cap-reached .* cap=\([0-9]*\) .*/\1/p' <<<"$ERR") record=$(record CC-1)" \
    'rc=1 cap=3 record=none' "control: ${mutant%/scripts} loses the same admission guarantee"
done
printf '%s\n' "$CAP_TARGET_SETTINGS" > "$TARGET/kendex.settings.toml"
printf '%s\n' "$CAP_PRIVATE_SETTINGS" > "$OVERSEER_REPO/alt.env"

echo "=== a binding that cannot be judged launches nothing ==="
connected acme/target
fleet cwd "$OVERSEER_REPO"
run_ot CWD="$BARE_TARGET" CC-1
assert_eq "rc=$RC unjudged=$(grep -cx "open-terminal: overseer-unjudged cause=origin path=$BARE_TARGET" <<<"$ERR" || true) record=$(record CC-1)" \
  "rc=1 unjudged=1 record=none" "a clone with no origin remote, where the setting must be matched, is unjudged"
connected absent
fleet cwd "$OVERSEER_REPO"
run_ot CWD="$BARE_TARGET" CC-1
assert_eq "rc=$RC foreign=$(grep -cx "open-terminal: overseer-foreign item=CC-1 repo=$BARE_TARGET overseer=own/fleet route=connected-repos,peer-mail" <<<"$ERR" || true)" \
  "rc=1 foreign=1" "with no setting to match, a clone with no origin is refused and named by its directory"
fleet cwd "$TMP_ROOT/gone-overseer"
run_ot CWD="$TARGET" CC-1
assert_eq "rc=$RC unjudged=$(grep -cx "open-terminal: overseer-unjudged cause=overseer-root path=$TMP_ROOT/gone-overseer" <<<"$ERR" || true)" \
  "rc=1 unjudged=1" "an overseer directory git cannot read is unjudged"
connected absent
fleet cwd "$OVERSEER_REPO"
run_ot CWD="$NO_GIT" CC-1
assert_eq "rc=$RC unjudged=$(grep -cx "open-terminal: overseer-unjudged cause=checkout-root path=$NO_GIT" <<<"$ERR" || true) record=$(record CC-1)" \
  "rc=1 unjudged=1 record=none" \
  "a launch from a directory no git checkout holds is unjudged"
printf '[env]\nORCH_CONSUMER_REPOS = ""\n' > "$OVERSEER_REPO/kendex.settings.toml"
fleet cwd "$OVERSEER_REPO"
run_ot CWD="$TARGET" CC-1
assert_eq "rc=$RC unjudged=$(grep -cx "open-terminal: overseer-unjudged cause=setting path=$OVERSEER_REPO" <<<"$ERR" || true) retired=$(grep -c '^orch-env: retired-setting ' <<<"$ERR" || true)" \
  "rc=1 unjudged=1 retired=1" "a setting orch-env refuses to read from the overseer's checkout is unjudged, under orch-env's own line"
connected absent
fleet cwd "$OVERSEER_REPO"
unparsable
run_ot CWD="$TARGET" WAKE CC-1
assert_eq "rc=$RC unjudged=$(grep -cxF "$STATE_READ_LINE" <<<"$ERR" || true)" "rc=1 unjudged=1" \
  "a wake, which the cap does not count, on a state that does not parse is unjudged"
fleet cwd "$OVERSEER_REPO"
unparsable
run_ot CWD="$TARGET" CC-1
assert_eq "rc=$RC unreadable=$(grep -cx 'open-terminal: cap-unreadable item=CC-1 source=state' <<<"$ERR" || true) unjudged=$(grep -cxF "$STATE_READ_LINE" <<<"$ERR" || true)" \
  "rc=1 unreadable=1 unjudged=0" "a launch on a state that does not parse is the fleet cap's cap-unreadable, not overseer-unjudged"
connected absent
fleet none-unread
run_ot CWD="$TARGET" CC-1
assert_eq "rc=$RC unjudged=$(grep -cx "open-terminal: overseer-unjudged cause=overseer-root path=$UNREAD_CHECKOUT" <<<"$ERR" || true) record=$(record CC-1)" \
  "rc=1 unjudged=1 record=none" "a --state-dir below a .git entry git cannot read is unjudged, never outside any checkout"
# A workflow-state whose path read fails, planted in a private copy of the
# scripts: the binding cannot name the state directory it judges.
PATH_FAILS="$(mutant_scripts path-fails workflow-state)" || exit 1
mutate_file "$PATH_FAILS/workflow-state" '    path)      shift; cmd_path "$@" ;;' '    path)      shift; exit 1 ;;'
connected absent
fleet none
run_ot SCRIPT="$PATH_FAILS/open-terminal" CWD="$TARGET" CC-1
assert_eq "rc=$RC unjudged=$(grep -cxF "$STATE_READ_LINE" <<<"$ERR" || true) record=$(record CC-1)" "rc=1 unjudged=1 record=none" \
  "a state directory workflow-state cannot resolve is unjudged"

echo "=== a relative --state-dir binds where workflow-state resolves it ==="
# workflow-state joins a relative --state-dir to the launch checkout's main
# root, not to the launcher's cwd: from a subdirectory of the target, the value
# below names the overseer checkout's state directory, a sibling of the
# target's, while the same spelling read from the cwd names a directory that
# does not exist, whose nearest existing ancestor is in the target.
RELATIVE_STATE=../overseer-repo/tmp/fleet
mkdir -p "$TARGET/sub"
# relative_run [SCRIPT=PATH] — one launch from $TARGET/sub with no state yet,
# under $RELATIVE_STATE; the lane record is read at the directory it names.
relative_run() {
  connected absent
  fleet none
  STATE="$RELATIVE_STATE"
  run_ot "$@" CWD="$TARGET/sub" CC-1
  STATE="$OVERSEER_REPO/tmp/fleet"
}
relative_run
assert_eq "rc=$RC record=$(record CC-1) foreign=$(grep -cxF "$FOREIGN_LINE" <<<"$ERR" || true)" "rc=1 record=none foreign=1" \
  "a relative --state-dir that names the overseer's state directory refuses another repository's clone launched from a subdirectory"

# One control per rule, each on a copy of the script that keeps the matched
# text and drops its behaviour.
# control NAME FILE OLD NEW — mutates FILE, open-terminal or lib/lane-cap.sh,
# in a copy of the scripts and prints that copy's open-terminal.
control() {
  local dir
  dir="$(mutant_scripts "$1" "$2")" || exit 1
  mutate_file "$dir/$2" "$3" "$4"
  printf '%s\n' "$dir/open-terminal"
}
BIND=lib/lane-cap.sh
MUT="$(control same-root "$BIND" '[[ "$root" != "$launch_root" ]] || return 0' '[[ "$root" != "$launch_root" ]] || true')"
connected absent; fleet cwd "$BARE_TARGET"
run_ot SCRIPT="$MUT" CWD="$BARE_TARGET" CC-1
assert_eq "rc=$RC foreign=$(refused 'overseer-foreign ')" "rc=1 foreign=1" \
  "control: without the common-root comparison the overseer's own origin-less repository is refused"
MUT="$(control same-origin "$BIND" '[[ "$same" != true ]] || return 0' '[[ "$same" != true ]] || true')"
connected absent; fleet cwd "$OVERSEER_REPO"
run_ot SCRIPT="$MUT" CWD="$OVERSEER_CLONE" CC-1
assert_eq "rc=$RC foreign=$(refused 'overseer-foreign ')" "rc=1 foreign=1" \
  "control: without the origin comparison a second clone of the overseer's repository is refused"
MUT="$(control state-dir "$BIND" '    dir="${dir%/*}"' '    dir=/')"
connected absent; fleet bare
run_ot SCRIPT="$MUT" CWD="$TARGET" CC-1
assert_eq "rc=$RC foreign=$(refused 'overseer-foreign ')" "rc=0 foreign=0" \
  "control: without the --state-dir binding a state with no overseer directory admits another repository's clone"
MUT="$(control resolved-state-dir "$BIND" '    dir="${dir%/*}"' '    dir="$STATE_DIR"')"
relative_run SCRIPT="$MUT"
assert_eq "rc=$RC foreign=$(refused 'overseer-foreign ')" "rc=0 foreign=0" \
  "control: reading the raw --state-dir from the cwd binds a relative one to the target's checkout and admits it"
# The path-read control runs its mutant beside the failing workflow-state: the
# link mutant_scripts made is replaced by that private copy.
MUT="$(control path-read "$BIND" 'path oversee)" \
      || { ot_message overseer-unjudged cause=state-read' 'path oversee)" \
      || true || { ot_message overseer-unjudged cause=state-read')"
MUT_DIR="${MUT%/*}"
rm -- "${MUT_DIR:?}/workflow-state"
cp -p -- "$PATH_FAILS/workflow-state" "${MUT_DIR:?}/workflow-state"
connected absent; fleet none
run_ot SCRIPT="$MUT" CWD="$TARGET" CC-1
assert_eq "unjudged=$(grep -cxF "$STATE_READ_LINE" <<<"$ERR" || true)" "unjudged=0" \
  "control: without the path-read refusal a state directory workflow-state cannot resolve prints no state-read line"
MUT="$(control checkout-fallback "$BIND" '|| { root="$launch_root"; }' '|| { false && root="$launch_root"; }')"
connected absent; fleet none-outside
run_ot SCRIPT="$MUT" CWD="$OVERSEER_WT" CC-1
assert_eq "rc=$RC foreign=$(refused 'overseer-foreign ')" "rc=1 foreign=1" \
  "control: without the launch-checkout binding a --state-dir outside any checkout refuses the overseer's own repository"
MUT="$(control checkout-root "$BIND" '|| { ot_message overseer-unjudged cause=checkout-root "path=$CLAIM_ROOT" >&2; return 1; }' \
  '|| { false && ot_message overseer-unjudged cause=checkout-root "path=$CLAIM_ROOT" >&2; }')"
connected absent; fleet cwd "$OVERSEER_REPO"
run_ot SCRIPT="$MUT" CWD="$NO_GIT" CC-1
assert_eq "unjudged=$(refused 'overseer-unjudged cause=checkout-root ')" "unjudged=0" \
  "control: without the checkout-root refusal no overseer-unjudged line is printed"
MUT="$(control setting-dir "$BIND" 'connected="$(cd -- "$dir" &&' 'connected="$(cd -- "$CLAIM_ROOT" &&')"
connected absent; fleet cwd "$OVERSEER_REPO"
run_ot SCRIPT="$MUT" CWD="$TARGET" CC-1
assert_eq "rc=$RC foreign=$(refused 'overseer-foreign ')" "rc=0 foreign=0" \
  "control: reading the setting in the launch checkout lets the target's own setting admit it"
MUT="$(control env-file "$BIND" 'unset ORCH_CONNECTED_REPOS KENDEX_ENV_FILE && orch_connected_repos' 'unset ORCH_CONNECTED_REPOS && orch_connected_repos')"
connected absent; fleet cwd "$OVERSEER_REPO"
run_ot SCRIPT="$MUT" CWD="$TARGET" ENV=KENDEX_ENV_FILE=alt.env CC-1
assert_eq "rc=$RC foreign=$(refused 'overseer-foreign ')" "rc=0 foreign=0" \
  "control: keeping the launcher's private-file selector lets the overseer's other private file admit the target"
MUT="$(control listed "$BIND" 'if grep -qxF -- "$listed" <<<"$connected"; then' 'if false && grep -qxF -- "$listed" <<<"$connected"; then')"
connected 'other/repo ACME/Target'; fleet cwd "$OVERSEER_REPO"
run_ot SCRIPT="$MUT" CWD="$TARGET" CC-1
assert_eq "rc=$RC foreign=$(refused 'overseer-foreign ')" "rc=1 foreign=1" \
  "control: without the list match a listed repository is refused"
MUT="$(control launch-case "$BIND" "listed=\"\$(printf '%s' \"\$LAUNCH_NAME\" | tr '[:upper:]' '[:lower:]')\"" "listed=\"\$LAUNCH_NAME\"; : \"\$(printf '%s' \"\$LAUNCH_NAME\" | tr '[:upper:]' '[:lower:]')\"")"
connected acme/target; fleet cwd "$OVERSEER_REPO"
run_ot SCRIPT="$MUT" CWD="$UPPER_TARGET" CC-1
assert_eq "rc=$RC foreign=$(refused 'overseer-foreign ')" "rc=1 foreign=1" \
  "control: without lowercasing the launch checkout's origin a listed repository spelled in capitals is refused"
MUT="$(control inherited "$BIND" 'unset ORCH_CONNECTED_REPOS KENDEX_ENV_FILE && orch_connected_repos' 'unset KENDEX_ENV_FILE && orch_connected_repos')"
connected absent; fleet cwd "$OVERSEER_REPO"
run_ot SCRIPT="$MUT" CWD="$TARGET" ENV=ORCH_CONNECTED_REPOS=acme/target CC-1
assert_eq "rc=$RC foreign=$(refused 'overseer-foreign ')" "rc=0 foreign=0" \
  "control: keeping the launcher's own value lets it admit the target"
MUT="$(control origin "$BIND" '[[ -n "$LAUNCH_NAME" ]] || { ot_message overseer-unjudged cause=origin' '[[ -n "$LAUNCH_NAME" ]] || true || { ot_message overseer-unjudged cause=origin')"
connected acme/target; fleet cwd "$OVERSEER_REPO"
run_ot SCRIPT="$MUT" CWD="$BARE_TARGET" CC-1
assert_eq "unjudged=$(refused 'overseer-unjudged cause=origin ')" "unjudged=0" \
  "control: without the origin refusal a clone with no origin is not unjudged"
MUT="$(control record-repo open-terminal '[[ -n "$record_repo" ]] || record_repo="$CONNECTED_REPO"' '[[ -n "$record_repo" ]] || true')"
connected acme/target; fleet cwd "$OVERSEER_REPO"
run_ot SCRIPT="$MUT" CWD="$TARGET" CC-1
assert_eq "rc=$RC record=$(record CC-1)" "rc=0 record=repo=null" \
  "control: without the fallback the admitted lane's record names no repository"
MUT="$(control overseer-root "$BIND" 'ot_message overseer-unjudged cause=overseer-root "path=$cwd" >&2' \
  'false && ot_message overseer-unjudged cause=overseer-root "path=$cwd" >&2')"
fleet cwd "$TMP_ROOT/gone-overseer"
run_ot SCRIPT="$MUT" CWD="$TARGET" CC-1
assert_eq "unjudged=$(refused 'overseer-unjudged cause=overseer-root ')" "unjudged=0" \
  "control: without the unread-directory refusal no overseer-unjudged line is printed"
MUT="$(control setting "$BIND" '|| { ot_message overseer-unjudged cause=setting "path=$dir" >&2; return 1; }
  if' '|| true
  if')"
printf '[env]\nORCH_CONSUMER_REPOS = ""\n' > "$OVERSEER_REPO/kendex.settings.toml"
fleet cwd "$OVERSEER_REPO"
run_ot SCRIPT="$MUT" CWD="$TARGET" CC-1
assert_eq "unjudged=$(refused 'overseer-unjudged cause=setting ')" "unjudged=0" \
  "control: without the setting-read refusal no overseer-unjudged line is printed"
MUT="$(control state-read "$BIND" '[[ "$CAP_GATED" == true ]] || { ot_message overseer-unjudged cause=state-read state=oversee >&2; return 1; }
      OVERSEER_BIND=unread
      return 0' '[[ "$CAP_GATED" == true ]] || true || { ot_message overseer-unjudged cause=state-read state=oversee >&2; return 1; }
      cwd=""')"
connected absent; fleet cwd "$OVERSEER_REPO"; unparsable
run_ot SCRIPT="$MUT" CWD="$TARGET" WAKE CC-1
assert_eq "unjudged=$(grep -cxF "$STATE_READ_LINE" <<<"$ERR" || true)" "unjudged=0" \
  "control: judging a state that does not parse as one with no overseer directory prints no state-read line"
MUT="$(control cap-first "$BIND" '[[ "$CAP_GATED" == true ]] || { ot_message overseer-unjudged cause=state-read' \
  '[[ "$CAP_GATED" == never ]] || { ot_message overseer-unjudged cause=state-read')"
connected absent; fleet cwd "$OVERSEER_REPO"; unparsable
run_ot SCRIPT="$MUT" CWD="$TARGET" CC-1
assert_eq "unreadable=$(grep -cx 'open-terminal: cap-unreadable item=CC-1 source=state' <<<"$ERR" || true) unjudged=$(grep -cxF "$STATE_READ_LINE" <<<"$ERR" || true)" \
  "unreadable=0 unjudged=1" "control: refusing a launch's unparsable state in the binding prints state-read before the cap reads it"
MUT="$(control dotgit "$BIND" '[[ ! -e "$at/.git" && ! -L "$at/.git" ]] || return 0' '[[ ! -e "$at/.git" && ! -L "$at/.git" ]] || true')"
connected absent; fleet none-unread
run_ot SCRIPT="$MUT" CWD="$TARGET" CC-1
assert_eq "rc=$RC unjudged=$(refused 'overseer-unjudged ') record=$(record CC-1)" "rc=0 unjudged=0 record=repo=null" \
  "control: without the .git entry test a --state-dir in a checkout git cannot read binds to the launch checkout and admits it"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
