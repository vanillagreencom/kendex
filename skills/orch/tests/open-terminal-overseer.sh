#!/usr/bin/env bash
# open-terminal's overseer binding: a launch under --state-dir runs in the
# repository of the directory the fleet state's overseer record names, or in
# one that directory's ORCH_CONNECTED_REPOS lists by origin OWNER/REPO; any
# other is refused as overseer-foreign before the state is touched, and one
# that cannot be judged as overseer-unjudged. The lane record of a launch the
# list admits carries the listed repository as repo.
#
# The suite runs a copy of open-terminal beside copies of workflow-state,
# git-context and orch-env, with the worktree CLI, gh, the GUI terminal and
# the harness stubbed. The overseer runs in a repository of its own with one
# linked worktree, the shape a lane's worktree has; the target is the clone of
# another repository. LINEAR_TEAM is empty on every row, the configuration
# that leaves the item check with no checkout team to compare.
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
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-overseer: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-overseer: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-overseer: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

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
mkdir -p "$REPO/scripts/lib"
cp "$SCRIPTS_DIR/open-terminal" "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/workflow-state" "$SCRIPTS_DIR/git-context" "$SCRIPTS_DIR/lane-marker" "$SCRIPTS_DIR/orch-env" "$REPO/scripts/"
cp -R "$SCRIPTS_DIR/lib/." "$REPO/scripts/lib/"
cp -R "$SCRIPTS_DIR/copilot-lane-context" "$REPO/scripts/"
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
TARGET="$TMP_ROOT/target"
new_repo "$TARGET" https://github.com/acme/target.git
BARE_TARGET="$TMP_ROOT/bare-target"
new_repo "$BARE_TARGET"

# connected VALUE — the overseer checkout's ORCH_CONNECTED_REPOS: `absent`
# writes no settings file, anything else is the value.
connected() {
  rm -f -- "$OVERSEER_REPO/kendex.settings.toml"
  [[ "$1" == absent ]] || printf '[env]\nORCH_CONNECTED_REPOS = "%s"\n' "$1" > "$OVERSEER_REPO/kendex.settings.toml"
}

# fleet DIR CWD — a fresh fleet state at DIR whose overseer record names CWD.
fleet() {
  rm -rf -- "$1"
  "$WS" --state-dir "$1" init oversee >/dev/null
  "$WS" --state-dir "$1" update oversee --arg cwd "$2" '.overseer = {cwd: $cwd}' >/dev/null
}
STATE="$TMP_ROOT/state"

# run_ot [SCRIPT=PATH] [CWD=PATH] [ENV=NAME=VALUE]... ARGS — one fleet launch
# into $STATE; sets OUT, ERR and RC. ENV= adds a variable to the launcher's
# environment, which otherwise carries no ORCH_CONNECTED_REPOS.
run_ot() {
  local script="$OT" cwd="$PWD" extra=()
  while [[ "${1:-}" == SCRIPT=* || "${1:-}" == CWD=* || "${1:-}" == ENV=* ]]; do
    case "$1" in SCRIPT=*) script="${1#SCRIPT=}" ;; CWD=*) cwd="${1#CWD=}" ;; ENV=*) extra+=("${1#ENV=}") ;; esac
    shift
  done
  set +e
  OUT="$(cd "$cwd" && env -u ORCH_CONNECTED_REPOS PATH="$BIN:$PATH" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/claims" \
    WORKTREE_CLI="$STUB" LANES_CLI="$BIN/lanes" LANES_HOME="$TMP_ROOT/home" LINEAR_TEAM= \
    GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' TMUX= TMUX_PANE= GH_REPO= ${extra[@]+"${extra[@]}"} \
    "$script" --state-dir "$STATE" --ghostty --harness claude \
    --cmd "true --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" "$@" 2>"$TMP_ROOT/err")"
  RC=$?
  set -e
  ERR="$(cat "$TMP_ROOT/err")"
}
# record ITEM — the item's lane record as `repo=VALUE`, or `none`.
record() { "$WS" --state-dir "$STATE" get oversee '[.lanes[]? | select(.item == "'"$1"'") | "repo=\(.repo // "null")"] | if . == [] then "none" else join(",") end'; }
refused() { grep -c "^open-terminal: $1" <<<"$ERR" || true; }
FOREIGN_LINE="open-terminal: overseer-foreign item=CC-1 repo=acme/target overseer=own/fleet route=connected-repos,peer-mail"

echo "=== a fleet launch runs in its overseer's repository or one it lists ==="
# The overseer's checkout setting, the directory the launch runs from, a
# variable the launcher already holds, the item, and the expected exit, lane
# record and overseer refusal count. A variable the launcher holds is what it
# loads from the checkout it is installed in, which can be the target's own.
rows=(
  "absent|$OVERSEER_WT||CC-1|rc=0 record=repo=null foreign=0|a worktree of the overseer's repository passes with the setting absent"
  "|$OVERSEER_WT||CC-1|rc=0 record=repo=null foreign=0|a worktree of the overseer's repository passes with the setting empty"
  "absent|$TARGET||CC-1|rc=1 record=none foreign=1|another repository's clone refuses overseer-foreign with the setting absent"
  "other/repo|$TARGET||CC-1|rc=1 record=none foreign=1|a clone whose repository the setting does not list refuses overseer-foreign"
  "other/repo ACME/Target|$TARGET||CC-1|rc=0 record=repo=acme/target foreign=0|a listed repository passes, matched case-insensitively, and its lane record carries it as repo"
  "absent|$TARGET|ORCH_CONNECTED_REPOS=acme/target|CC-1|rc=1 record=none foreign=1|a setting the target checkout or the launcher's own environment holds admits nothing"
)
printf '[env]\nORCH_CONNECTED_REPOS = "acme/target"\n' > "$TARGET/kendex.settings.toml"
for row in "${rows[@]}"; do
  IFS='|' read -r setting cwd env item expected label <<<"$row"
  connected "$setting"
  fleet "$STATE" "$OVERSEER_REPO"
  env_args=()
  [[ -z "$env" ]] || env_args=("ENV=$env")
  run_ot CWD="$cwd" ${env_args[@]+"${env_args[@]}"} "$item"
  assert_eq "rc=$RC record=$(record "$item") foreign=$(grep -cxF "$FOREIGN_LINE" <<<"$ERR" || true)" "$expected" "$label"
done

echo "=== the refusal names the item, both repositories and both routes ==="
connected absent
fleet "$STATE" "$OVERSEER_REPO"
run_ot CWD="$TARGET" CC-1
assert_eq "$(head -n 1 <<<"$ERR")" "$FOREIGN_LINE" \
  "the first line keys the refusal on the item, the target and overseer origins and the setting and peer-mail routes"

echo "=== a binding that cannot be judged launches nothing ==="
connected acme/target
fleet "$STATE" "$OVERSEER_REPO"
run_ot CWD="$BARE_TARGET" CC-1
assert_eq "rc=$RC unjudged=$(grep -cx "open-terminal: overseer-unjudged cause=origin path=$BARE_TARGET" <<<"$ERR" || true) record=$(record CC-1)" \
  "rc=1 unjudged=1 record=none" "a clone with no origin remote, where the setting must be matched, is unjudged"
connected absent
fleet "$STATE" "$OVERSEER_REPO"
run_ot CWD="$BARE_TARGET" CC-1
assert_eq "rc=$RC foreign=$(grep -cx "open-terminal: overseer-foreign item=CC-1 repo=$BARE_TARGET overseer=own/fleet route=connected-repos,peer-mail" <<<"$ERR" || true)" \
  "rc=1 foreign=1" "with no setting to match, a clone with no origin is refused and named by its directory"
fleet "$STATE" "$TMP_ROOT/gone-overseer"
run_ot CWD="$TARGET" CC-1
assert_eq "rc=$RC unjudged=$(grep -cx "open-terminal: overseer-unjudged cause=overseer-root path=$TMP_ROOT/gone-overseer" <<<"$ERR" || true)" \
  "rc=1 unjudged=1" "an overseer directory git cannot read is unjudged"
printf '[env]\nORCH_CONSUMER_REPOS = ""\n' > "$OVERSEER_REPO/kendex.settings.toml"
fleet "$STATE" "$OVERSEER_REPO"
run_ot CWD="$TARGET" CC-1
assert_eq "rc=$RC unjudged=$(grep -cx "open-terminal: overseer-unjudged cause=setting path=$OVERSEER_REPO" <<<"$ERR" || true) retired=$(grep -c '^orch-env: retired-setting ' <<<"$ERR" || true)" \
  "rc=1 unjudged=1 retired=1" "a setting orch-env refuses to read from the overseer's checkout is unjudged, under orch-env's own line"

# One control per rule, each on a copy of the script that keeps the matched
# text and drops its behaviour.
# control NAME OLD NEW — prints the mutant's path.
control() {
  local ot
  ot="$(mutant_scripts "$1" open-terminal)/open-terminal" || exit 1
  mutate_file "$ot" "$2" "$3"
  printf '%s\n' "$ot"
}
MUT="$(control same-root 'if [[ "$overseer_root" != "$launch_root" ]]; then' 'if false && [[ "$overseer_root" != "$launch_root" ]]; then')"
connected absent; fleet "$STATE" "$OVERSEER_REPO"
run_ot SCRIPT="$MUT" CWD="$TARGET" CC-1
assert_eq "rc=$RC foreign=$(refused 'overseer-foreign ')" "rc=0 foreign=0" \
  "control: without the common-root comparison another repository's clone is admitted"
MUT="$(control listed '[[ "$listed" != true ]] ||' '[[ "$listed" == "$listed" ]] ||')"
connected 'other/repo ACME/Target'; fleet "$STATE" "$OVERSEER_REPO"
run_ot SCRIPT="$MUT" CWD="$TARGET" CC-1
assert_eq "rc=$RC foreign=$(refused 'overseer-foreign ')" "rc=1 foreign=1" \
  "control: without the list match a listed repository is refused"
MUT="$(control inherited 'env -u ORCH_CONNECTED_REPOS "$SCRIPT_DIR/orch-env"' 'env "$SCRIPT_DIR/orch-env"')"
connected absent; fleet "$STATE" "$OVERSEER_REPO"
run_ot SCRIPT="$MUT" CWD="$TARGET" ENV=ORCH_CONNECTED_REPOS=acme/target CC-1
assert_eq "rc=$RC foreign=$(refused 'overseer-foreign ')" "rc=0 foreign=0" \
  "control: keeping the launcher's own value lets it admit the target"
MUT="$(control origin '[[ -n "$launch_name" ]] || { ot_message overseer-unjudged cause=origin' '[[ -n "$launch_name" ]] || true || { ot_message overseer-unjudged cause=origin')"
connected acme/target; fleet "$STATE" "$OVERSEER_REPO"
run_ot SCRIPT="$MUT" CWD="$BARE_TARGET" CC-1
assert_eq "unjudged=$(refused 'overseer-unjudged cause=origin ')" "unjudged=0" \
  "control: without the origin refusal a clone with no origin is not unjudged"
MUT="$(control record-repo '[[ -n "$record_repo" ]] || record_repo="$CONNECTED_REPO"' '[[ -n "$record_repo" ]] || true')"
connected acme/target; fleet "$STATE" "$OVERSEER_REPO"
run_ot SCRIPT="$MUT" CWD="$TARGET" CC-1
assert_eq "rc=$RC record=$(record CC-1)" "rc=0 record=repo=null" \
  "control: without the fallback the admitted lane's record names no repository"
MUT="$(control overseer-root '|| { ot_message overseer-unjudged cause=overseer-root "path=$overseer_cwd" >&2; exit 1; }' \
  '|| { false && ot_message overseer-unjudged cause=overseer-root "path=$overseer_cwd" >&2; }')"
fleet "$STATE" "$TMP_ROOT/gone-overseer"
run_ot SCRIPT="$MUT" CWD="$TARGET" CC-1
assert_eq "unjudged=$(refused 'overseer-unjudged cause=overseer-root ')" "unjudged=0" \
  "control: without the unread-directory refusal no overseer-unjudged line is printed"
MUT="$(control setting '|| { ot_message overseer-unjudged cause=setting "path=$overseer_cwd" >&2; exit 1; }
      launch_name=' '|| true
      launch_name=')"
printf '[env]\nORCH_CONSUMER_REPOS = ""\n' > "$OVERSEER_REPO/kendex.settings.toml"
fleet "$STATE" "$OVERSEER_REPO"
run_ot SCRIPT="$MUT" CWD="$TARGET" CC-1
assert_eq "unjudged=$(refused 'overseer-unjudged cause=setting ')" "unjudged=0" \
  "control: without the setting-read refusal no overseer-unjudged line is printed"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
