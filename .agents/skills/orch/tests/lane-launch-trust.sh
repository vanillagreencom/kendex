#!/usr/bin/env bash
# Tests for the folder trust a codex launch needs before it reads the arguments
# it was launched with: lib/lane-launch.sh's lane_codex_trust_prepare, and the
# two launchers that refuse rather than open a pane on the question.
#
# A Codex session started into a directory its config does not trust stops on
# `Do you trust the contents of this directory?` and waits. Every unattended
# launch — an overseer succession, a lane opened into a worktree nothing has
# trusted yet — has nobody at that pane, so the launch is spent on a question.
# The sections here are that contract:
#
#   § prepare   one row per shape the account's own config can be in, each
#               asserted on the EFFECTIVE config a launch would read, through
#               the production reader rather than a second scanner here
#   § form      the private home is reached by the environment variable that
#               names it, even on a machine whose account launcher is on PATH,
#               with the account dir beside it as the inverse
#   § refuse    a home that cannot be built ends as a refusal, and both
#               launchers carry that refusal's key
#   § account   the readers that ask which account a session is spending get
#               the account back, whatever CODEX_HOME holds
#   § control   four must-fail inverses, one per rule: the entry is read back
#               before the launch, the directory's own table is replaced and
#               never duplicated, the private home is never reached through an
#               account launcher, and a home names the account it sits under
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/skills/orch/scripts"
# shellcheck source=lib/waiter-assertions.sh
source "$TEST_DIR/lib/waiter-assertions.sh"
# copy_scripts and mutate_file, the two halves of the controls below.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

# Physical: on macOS the temp root sits under /var -> /private/var, and a
# config entry names the path the launch directory really is.
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'chmod -R u+rwX "$TMP_ROOT" 2>/dev/null; rm -rf "$TMP_ROOT"' EXIT

# The library under test, sourced into this shell: the preparation is a
# function, and a call to it is the smallest surface that can fail.
# shellcheck source=../scripts/lib/lane-launch.sh
source "$SCRIPTS_DIR/lib/lane-launch.sh"

# The hook approval an account config carries, in the shape schemas/lane-host.md
# § Codex hook approval states. Its survival into the effective config is what
# says the launch keeps the approvals the account already had, rather than
# running under a config holding the trust entry alone.
HOOK_ENTRY='[hooks.state."/repo/.codex/hooks.json:pre_tool_use:0:0"]'

# account_config NAME BODY — an account directory under NAME holding the
# account's own files, and its config.toml written from BODY where BODY is
# non-empty. An empty BODY leaves the account with no config at all, which is
# the shape a numbered account has before its shim has relinked one in.
account_config() { # NAME BODY
  local lane="$TMP_ROOT/$1/.1codex"
  mkdir -p "$lane/sessions"
  printf 'token\n' > "$lane/auth.json"
  if [ -n "$2" ]; then printf '%s\n' "$2" > "$lane/config.toml"; fi
}

# --- § prepare --------------------------------------------------------------
#
# One row per shape the account's config can be in when a launch reaches it.
# The answer is read back off the EFFECTIVE config — the one the harness would
# open — through lane_codex_trusted, the same call the preparation itself
# refuses on, so a row measures what the launch will meet.
#
#   route     which route the preparation took
#   trusted   does the effective config trust the launch directory
#   private   is the effective home a directory of this launch's own
#   hooks     how many of the account's hook approvals reached that config
#   tables    how many tables in it name the launch directory; a second one is
#             a duplicate key, which the harness rejects the whole file for
#   after     the value of a key in a table that FOLLOWS the launch
#             directory's own in the account config, or none where the account
#             carried no such pair. The drop takes one table and stops at the
#             next header; one that ran to the end of the file would leave the
#             private config holding the entry alone, and the launch would open
#             on the hook-approval dialog instead
echo "=== prepare: the effective config a codex launch reads ==="
prepare_row() { # NAME CONFIG_BODY
  local lane="$TMP_ROOT/$1/.1codex" dir="$TMP_ROOT/$1/wt" rc=0 config trusted private
  mkdir -p "$dir"
  account_config "$1" "$2"
  lane_codex_trust_prepare codex "$lane" "$dir" || rc=$?
  if [ "$rc" -ne 0 ]; then printf 'refused reason=%s\n' "$LANE_TRUST_REASON"; return 0; fi
  config="$LANE_TRUST_HOME/config.toml"
  trusted=no; ! lane_codex_trusted "$config" "$dir" || trusted=yes
  private=yes; [ "$LANE_TRUST_HOME" != "$lane" ] || private=no
  printf 'route=%s trusted=%s private=%s hooks=%s tables=%s after=%s\n' \
    "$LANE_TRUST_ROUTE" "$trusted" "$private" \
    "$(grep -c -F -e "$HOOK_ENTRY" "$config" || true)" \
    "$(grep -c -F -e "[projects.\"$dir\"]" "$config" || true)" \
    "$(toml_value "$config" features.multi_agent_v2 max_concurrent_threads_per_session || printf none)"
}

# The account config each row starts from. `$DIR` stands for the row's own
# launch directory, which only exists once the row runs.
config_for() { # NAME
  case "$1" in
    no-config) printf '' ;;
    trusts-another) printf '%s\ntrusted_hash = "sha256:aa"\n\n[projects."/elsewhere"]\ntrust_level = "trusted"\n' "$HOOK_ENTRY" ;;
    already-trusted) printf '%s\ntrusted_hash = "sha256:aa"\n\n[projects."$DIR"]\ntrust_level = "trusted"\n' "$HOOK_ENTRY" ;;
    answered-no) printf '%s\ntrusted_hash = "sha256:aa"\n\n[projects."$DIR"]\ntrust_level = "untrusted"\n\n[features.multi_agent_v2]\nmax_concurrent_threads_per_session = 6\n' "$HOOK_ENTRY" ;;
    table-then-more) printf '%s\ntrusted_hash = "sha256:aa"\n\n[projects."$DIR"]\napproval_policy = "never"\n\n[features.multi_agent_v2]\nmax_concurrent_threads_per_session = 6\n' "$HOOK_ENTRY" ;;
  esac
}

# NAME|EXPECTED. The hook count on the already-trusted row is read off the
# account's own config, which IS the effective one there.
PREPARE_ROWS=(
  'no-config|route=launch-home trusted=yes private=yes hooks=0 tables=1 after=none'
  'trusts-another|route=launch-home trusted=yes private=yes hooks=1 tables=1 after=none'
  'already-trusted|route=preapproved trusted=yes private=no hooks=1 tables=1 after=none'
  'table-then-more|route=launch-home trusted=yes private=yes hooks=1 tables=1 after=6'
  'answered-no|refused reason=trust-refused'
)
for row in "${PREPARE_ROWS[@]}"; do
  name="${row%%|*}"; want="${row#*|}"
  body="$(config_for "$name")"
  assert_eq "$(prepare_row "$name" "${body//\$DIR/$TMP_ROOT/$name/wt}")" "$want" "prepare: $name"
done

# An answer already recorded for this directory that is not trust is a refusal,
# never a gap: the row above is the account carrying `untrusted` for its own
# launch directory, which the preparation leaves exactly as it found it rather
# than launching at full trust against it.
assert_eq "$(cat "$TMP_ROOT/answered-no/.1codex/config.toml")" \
  "$(config_for answered-no | sed "s|\$DIR|$TMP_ROOT/answered-no/wt|")" \
  "a recorded refusal is left where it was written"

# The account's own config is never written by the preparation: it is a link
# the account shim repoints at every launch, so an entry put there belongs to
# nobody by the next one.
assert_eq "$(cat "$TMP_ROOT/table-then-more/.1codex/config.toml")" \
  "$(config_for table-then-more | sed "s|\$DIR|$TMP_ROOT/table-then-more/wt|")" \
  "the account's own config is left as it was"

# The account's files reach the launch by link, so a token the harness renews
# under this lane is renewed in the account's own auth.json rather than in a
# copy that expires apart from it. The home is asked of the builder rather than
# spelled here.
LINK_LANE="$TMP_ROOT/trusts-another/.1codex"
LINK_HOME="$(lane_codex_home_path "$LINK_LANE" "$TMP_ROOT/trusts-another/wt")"
printf 'renewed\n' > "$LINK_HOME/auth.json"
assert_eq "$(cat "$LINK_LANE/auth.json")" "renewed" \
  "a write through the private home reaches the account's own auth.json"

# The write mode that matters is the one a real writer uses. A rename over the
# name replaces the LINK and leaves the account's file as it was, so the claim
# above holds only for a writer that opens the existing file; `>` is that, and
# a rename is not. Asserted rather than assumed, because a row that only ever
# wrote with `>` would pass over a home whose links had all been replaced.
printf 'staged\n' > "$LINK_HOME/auth.json.tmp"
mv -f -- "$LINK_HOME/auth.json.tmp" "$LINK_HOME/auth.json"
assert_eq "$(cat "$LINK_LANE/auth.json") $(cat "$LINK_HOME/auth.json")" "renewed staged" \
  "a rename over the name detaches the link, leaving the account's own file behind"

# The next preparation puts that back: a name holding a link is freed and
# linked again, so a home is not left carrying its own copy of an account file.
# The same rule is what stops the loop descending into a REAL directory at the
# name, which `ln -s -f` does silently, one level deeper per launch.
mkdir -p "$LINK_LANE/plugins"
printf 'shipped\n' > "$LINK_LANE/plugins/one.json"
lane_codex_trust_prepare codex "$LINK_LANE" "$TMP_ROOT/trusts-another/wt"
assert_eq "$(cat "$LINK_HOME/auth.json") $(readlink "$LINK_HOME/plugins" || printf none)" \
  "renewed $LINK_LANE/plugins" \
  "a second preparation relinks a detached name and links a directory the account gained"

# A real directory at a name that should be a link is what the loop cannot put
# right, and it refuses instead of creating the link inside it.
rm -f -- "${LINK_HOME:?}/plugins"
mkdir -p "$LINK_HOME/plugins"
link_rc=0
lane_codex_trust_prepare codex "$LINK_LANE" "$TMP_ROOT/trusts-another/wt" || link_rc=$?
assert_eq "$link_rc reason=$LANE_TRUST_REASON $(ls "$LINK_HOME/plugins" | wc -l | tr -d ' ')" \
  "1 reason=home-entry 0" \
  "a real directory where a link belongs refuses, and nothing is created inside it"
rm -rf -- "${LINK_HOME:?}/plugins"

# --- § form -----------------------------------------------------------------
#
# lane_launch_form drops the environment prefix for an account whose launcher
# is on PATH, because such a launcher exports the lane variable for its own
# name and would overwrite the prefix. That is exactly what it would do to a
# private home, so the private home must never be judged as one; the account
# directory beside it is the inverse, and says the fixture really does hold a
# launcher to be found.
echo "=== form: how the private home reaches the harness ==="
form_answers() { # SCRIPTS_LIB
  local lane="$TMP_ROOT/trusts-another/.1codex" dir="$TMP_ROOT/trusts-another/wt"
  PATH="$TMP_ROOT/bin:$PATH" bash -c '
    set -uo pipefail
    source "$1"
    lane_codex_trust_prepare codex "$2" "$3" || exit 1
    printf "private=%s account=%s\n" \
      "$(lane_launch_form "codex -m gpt" codex "$LANE_TRUST_HOME" "")" \
      "$(lane_launch_form "codex -m gpt" codex "$2" "")"
  ' bash "$1" "$lane" "$dir"
}
mkdir -p "$TMP_ROOT/bin"
printf '#!/usr/bin/env bash\nexec codex "$@"\n' > "$TMP_ROOT/bin/1codex"
chmod +x "$TMP_ROOT/bin/1codex"
assert_eq "$(form_answers "$SCRIPTS_DIR/lib/lane-launch.sh")" \
  "private=prefix account=launcher:$TMP_ROOT/bin/1codex" \
  "the private home keeps the prefix where the account itself takes the launcher"

# --- § refuse ---------------------------------------------------------------
#
# A home that cannot be built is the launch refusing, never a launch that opens
# and meets the question. The account directory here sits under a regular file,
# so the create fails for every user this suite can run as.
echo "=== refuse: a home that cannot be built ==="
printf 'not a directory\n' > "$TMP_ROOT/blocked"
refuse_rc=0
# The failing mkdir's own diagnostic is the operator's cause and belongs on the
# launcher's stderr; here it is the expected outcome and would only clutter the
# row it belongs to.
lane_codex_trust_prepare codex "$TMP_ROOT/blocked/.1codex" "$TMP_ROOT/blocked-wt" 2>/dev/null || refuse_rc=$?
assert_eq "$refuse_rc reason=$LANE_TRUST_REASON" "1 reason=home-create" \
  "a home that cannot be created refuses, naming the step"

# An account config that EXISTS and cannot be read is a refusal, never the
# absence that stages an empty config: a numbered account's config.toml is a
# symlink its shim repoints, and a dangling one answers a readability test
# exactly as a missing file does. Read as absence, the launch starts with every
# table the account was approved for gone.
#
# REASON|EXPECTED, one row per shape the path can be in.
echo "=== refuse: an account config that cannot be read ==="
unreadable_reason() { # NAME MAKER
  local lane="$TMP_ROOT/$1/.1codex" dir="$TMP_ROOT/$1/wt" rc=0
  mkdir -p "$lane" "$dir"
  printf 'token\n' > "$lane/auth.json"
  "$2" "$lane/config.toml"
  lane_codex_trust_prepare codex "$lane" "$dir" 2>/dev/null || rc=$?
  printf '%s reason=%s\n' "$rc" "$LANE_TRUST_REASON"
}
make_dangling() { ln -s "$TMP_ROOT/no-such-render.toml" "$1"; }
make_unreadable() { printf 'x = 1\n' > "$1"; chmod 000 "$1"; }
make_directory() { mkdir -p "$1"; }
for row in 'dangling|make_dangling' 'mode000|make_unreadable' 'adirectory|make_directory'; do
  assert_eq "$(unreadable_reason "${row%%|*}" "${row#*|}")" "1 reason=config-unreadable" \
    "an account config that is ${row%%|*} refuses rather than staging an empty one"
done

# What each launcher DOES with that answer is its own behaviour and is pinned
# where each launcher's fixtures live: open-terminal-lane.sh has the row for the
# refused item, and oversee_succeed.sh the row for the refused successor. A grep
# of the catalog line here would survive a guard that stopped refusing.

# --- § account --------------------------------------------------------------
#
# A session launched under a private home carries THAT path in CODEX_HOME, and
# everything running inside it reads that variable to learn which account it is
# spending. A reader answering with the home instead spends one account under
# two names: the turn-end hook hands its mail to a lane nothing claimed, and the
# inventory a pick walks grows a second lane per launched worktree, so a second
# session opens on an account this one is already using.
#
# One row per shape CODEX_HOME can hold, through the readers themselves.
echo "=== account: what a reader answers for a launch home ==="
ACCOUNT_DIR="$TMP_ROOT/trusts-another/.1codex"
ACCOUNT_HOME="$(lane_codex_home_path "$ACCOUNT_DIR" "$TMP_ROOT/trusts-another/wt")"

# The reader inside a running session, sourced from the library the turn-end
# hook loads rather than called through the hook, which is the smallest surface
# that answers this question. SHAPE is what the pane's own foreground process
# offered: `codex` where that process is the harness, and the empty shape where
# it is anything else, which is what a pane running `lanes` itself shows.
caller_cfg() { # SHAPE CODEX_HOME
  CODEX_HOME="$2" bash -c '
    set -uo pipefail
    source "$1"
    lane_context_caller_cfg "$2"
  ' bash "$SCRIPTS_DIR/lib/lane-context.sh" "$1"
}

# SHAPE|VALUE|EXPECTED, the paths named relative to the account so a row reads
# as a shape rather than as a fixture path.
ACCOUNT_ROWS=(
  "codex|$ACCOUNT_DIR|$ACCOUNT_DIR"
  "codex|$ACCOUNT_HOME|$ACCOUNT_DIR"
  "codex|$TMP_ROOT/no-such-account|$TMP_ROOT/no-such-account"
  "|$ACCOUNT_HOME|$ACCOUNT_DIR"
  "|$ACCOUNT_DIR|$ACCOUNT_DIR"
)
for row in "${ACCOUNT_ROWS[@]}"; do
  shape="${row%%|*}"; rest="${row#*|}"; value="${rest%%|*}"; want="${rest#*|}"
  assert_eq "$(caller_cfg "$shape" "$value")" "$want" \
    "account: shape=${shape:-none} ${value#$TMP_ROOT/}"
done

# The other reader: the codex inventory `lanes` builds adds whatever CODEX_HOME
# names, so a launch home there must arrive as its account. Asserted on the
# listed directories, with the account discovered under the fixture home too,
# so a home listed raw shows up as an extra row rather than as a renamed one.
lanes_inventory() { # CODEX_HOME
  LANES_HOME="$TMP_ROOT/inv" CODEX_HOME="$1" ORCH_LANE_HOST=local \
    OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/inv-state" ORCH_LANES_FETCH_CMD=true \
    "$SCRIPTS_DIR/lanes" list --harness codex --json 2>/dev/null |
    jq -r '[.[].config_dir] | sort | join(",")'
}
mkdir -p "$TMP_ROOT/inv/.1codex" "$TMP_ROOT/inv-state"
printf 'token\n' > "$TMP_ROOT/inv/.1codex/auth.json"
INV_HOME="$(lane_codex_home_path "$TMP_ROOT/inv/.1codex" "$TMP_ROOT/inv/wt")"
assert_eq "$(lanes_inventory "$INV_HOME")" "$TMP_ROOT/inv/.1codex" \
  "a launch home in CODEX_HOME lists as the one account it was built under"

# --- § control --------------------------------------------------------------
#
# One inverse per rule the preparation enforces. Each mutates a private copy of
# the library, so the shipped one is never edited, and each asserts the shape
# its rule exists to prevent.
echo "=== control: the must-fail inverses ==="
MUTANT_SCRIPTS="$(copy_scripts lane-launch-mutant)"
MUTANT_LIB="$MUTANT_SCRIPTS/lib/lane-launch.sh"

# Rule 1: the entry is read back off the written config before the launch. A
# preparation that writes something the harness would not read as trust must
# refuse, not return a home.
mutate_file "$MUTANT_LIB" "\\ntrust_level = \"trusted\"\\n" "\\ntrust_level = \"asked\"\\n"
# The outcome AND the table count at the home the preparation would use, so a
# control that refuses still says what it wrote there.
mutant_prepare() { # LIB LANE DIR
  bash -c '
    set -uo pipefail
    source "$1"
    outcome=prepared
    lane_codex_trust_prepare codex "$2" "$3" 2>/dev/null || outcome="refused:$LANE_TRUST_REASON"
    home="$(lane_codex_home_path "$2" "$3")"
    tables="$(grep -c -F -e "[projects.\"$3\"]" "$home/config.toml" 2>/dev/null)" || tables=0
    printf "%s route=%s tables=%s\n" "$outcome" "${LANE_TRUST_ROUTE:-none}" "$tables"
  ' bash "$@"
}
mkdir -p "$TMP_ROOT/control-1/wt"
account_config control-1 ""
assert_eq "$(mutant_prepare "$MUTANT_LIB" "$TMP_ROOT/control-1/.1codex" "$TMP_ROOT/control-1/wt")" \
  "refused:entry-unreadable route=none tables=1" \
  "control: an entry the reader does not read back as trust refuses the launch"

# Rule 2: the directory's own table is replaced. Carrying the account's config
# through unchanged leaves that table in place beside the new one, which is a
# duplicate key rather than an override.
#
# The account here carries a table for the launch directory that says nothing
# about trust, which is the shape that both reaches this rule and is a table:
# a table answering `trusted` takes the preapproved route and one answering
# anything else is refused, so neither gets this far.
MUTANT_TWO="$(copy_scripts lane-launch-mutant-two)/lib/lane-launch.sh"
mutate_file "$MUTANT_TWO" 'toml_without_table "$config" "projects.\"$dir\""' 'cat -- "$config"'
mkdir -p "$TMP_ROOT/control-2/wt"
account_config control-2 "$(printf '[projects."%s"]\napproval_policy = "never"\n' "$TMP_ROOT/control-2/wt")"
# The mutant reports success: its own read-back finds the trust it appended, in
# the second of two headers for one key. That is the harm exactly — a config the
# harness rejects whole, handed to the launch as ready. The shipped side is the
# tables=1 every prepare row above pins.
assert_eq "$(mutant_prepare "$MUTANT_TWO" "$TMP_ROOT/control-2/.1codex" "$TMP_ROOT/control-2/wt")" \
  "prepared route=launch-home tables=2" \
  "control: carrying the account config through duplicates the directory's table"

# Rule 3: the private home's leaf carries no harness word, so the form judge
# never mistakes it for an account a launcher on PATH selects. The shape lives
# in lane-home.sh, so that is the file this one mutates; the launch library
# beside it in the copied tree sources the mutated one.
MUTANT_THREE_SCRIPTS="$(copy_scripts lane-launch-mutant-three)"
mutate_file "$MUTANT_THREE_SCRIPTS/lib/lane-home.sh" \
  "printf '%s/lane-launch/%s-%s/home\\n'" "printf '%s/lane-launch/%s-%s/1codex\\n'"
assert_eq "$(form_answers "$MUTANT_THREE_SCRIPTS/lib/lane-launch.sh")" \
  "private=launcher:$TMP_ROOT/bin/1codex account=launcher:$TMP_ROOT/bin/1codex" \
  "control: a private home named for the account is reached through the launcher"

# Rule 4: a launch home answers with the account it sits under. Without the
# rule the reader inside a session answers with the home, which is the account
# spent under a second name.
MUTANT_FOUR_SCRIPTS="$(copy_scripts lane-launch-mutant-four)"
mutate_file "$MUTANT_FOUR_SCRIPTS/lib/lane-home.sh" \
  '*/lane-launch/*/home) printf' '*/lane-launch/*/nowhere) printf'
assert_eq "$(CODEX_HOME="$ACCOUNT_HOME" bash -c '
    set -uo pipefail
    source "$1"
    lane_context_caller_cfg codex
  ' bash "$MUTANT_FOUR_SCRIPTS/lib/lane-context.sh")" \
  "$ACCOUNT_HOME" \
  "control: without the home-to-account rule a session reports the home as its account"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
