# shellcheck shell=bash
#
# The one answer to "how does a resolved lane reach the launched harness, and
# is the pane really running it". Every launcher that starts a harness on a
# chosen account builds its command here — open-terminal for a work item,
# oversee-succeed for a successor overseer — so a second builder cannot drift
# from the first and launch onto an account nobody picked.
#
# Sourced, never run.

# lane_account_check below compares two config dirs through lane_claims_canon,
# the one normaliser for a lane path. A caller that had not sourced that sibling
# would run both comparisons as an absent command, and two DIFFERENT accounts
# would compare equal as the empty string — the guard reporting `verified` for
# the very disagreement it exists to catch. The dependency is this file's, so
# this file takes it. That sibling sets `set -euo pipefail` as it loads, so a
# caller that must stay errexit-free restores its own posture after sourcing
# this file, the way `lanes` already does at its lib seam.
# shellcheck source=lane-claims.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lane-claims.sh"

# lane_codex_trust_prepare below reads a codex config.toml for one key and
# writes it back without one table. That reading is shared with `spawn-adapter`,
# which asks the same file a different question, so it lives in its own library
# and both callers source it rather than each carrying a scanner of its own.
# shellcheck source=toml.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toml.sh"

# The private home the preparation below builds is named by lane-home.sh, which
# also takes such a path back apart for the readers outside this launch that ask
# which account a session is spending.
# shellcheck source=lane-home.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lane-home.sh"

# The env prefix that puts a launch on a chosen account: the harness names the
# variable, the directory IS the account. One mapping for every caller — the
# chooser in `lanes` that hands a picked lane back as a prefix, and the
# launchers that render it into a command — so a harness added to one of them
# cannot go on being prefixed with the other harness's variable, which starts it
# on whatever account that harness defaults to with nothing on screen saying so.
#
# Codex is named and every other harness takes the Claude variable, which is
# what a local `--lane` launch on a further harness has always done; `lanes`
# measures claude and codex only and produces no third value here. A harness
# added to this repository adds its arm HERE.
lane_env_prefix() { # HARNESS DIR
  local var=CLAUDE_CONFIG_DIR
  [[ "$1" != codex ]] || var=CODEX_HOME
  printf '%s=%s\n' "$var" "$2"
}

# How each harness spells the two choices a lane launch must make, for every
# caller that READS a launch's flags and every caller that WRITES them: the
# launcher that refuses a launch naming neither, and the successor builder in
# `oversee-succeed` that renders them. Stated here once, in the file that owns
# per-harness launch mapping, so a harness that renames its effort flag cannot
# leave one copy behind and have the launcher refuse every launch of it while
# the builder writes the old word.
#
# One row per harness,
# `HARNESS|MODEL SPELLINGS|EFFORT SPELLINGS|EFFORT-IN-MODEL|ATTACH WORD`, each
# spelling list space-separated, so a consumer's harness or a new flag spelling
# is one row rather than a code path. A spelling that ends in `=` is a whole
# token with its value attached; any other is a flag word taking the next token
# or an attached `=VALUE`. `-` as the effort list is a harness whose launch form
# has no effort flag, and such a launch names the model alone. The fourth field
# is the separator that attaches the effort to the model VALUE where the harness
# accepts it there, `-` where it does not; a launch using that form has named
# both choices in one token. The fifth is the flag word an attached-value
# spelling rides on when one is WRITTEN — codex's `-c` carries the whole
# `model_reasoning_effort=` token — and `-` where the effort is a plain flag
# word that takes its value as the next one.
#
# The FIRST spelling of each list is the one written; the rest are further
# spellings a caller may have typed, which launch_choice_value reads.
#
# Read out of each harness's own help, never from memory:
#   claude    `claude --help`: `--model <model>`, `--effort <level>`.
#   codex     `codex --help`: `-m, --model <MODEL>`; reasoning effort is a
#             config override, `-c, --config <key=value>` carrying the
#             `model_reasoning_effort` key, so the whole token is the spelling.
#   opencode  the flags table of `opencode [project]`, the form start_cmd
#             renders: `--model, -m`, and no effort flag at all. `--variant`
#             belongs to `opencode run`, which this script never launches.
#   pi        `pi --help`: `--model <pattern>` "supports provider/id and optional
#             `:<thinking>`", `--thinking <level>`. The colon form is the fourth
#             field: `--model sonnet:high` names the level pi will run at, so a
#             launch passing it has made the effort choice and is not asked for
#             it again.
LAUNCH_CHOICE_FLAGS=(
  'claude|--model|--effort|-|-'
  'codex|-m --model|model_reasoning_effort=|-|-c'
  'opencode|-m --model|-|-|-'
  'pi|--model|--thinking|:|-'
)
# The row for harness $1, empty where the table names no such harness.
launch_choice_row() { # HARNESS
  local row
  for row in "${LAUNCH_CHOICE_FLAGS[@]}"; do
    [[ "${row%%|*}" != "$1" ]] || { printf '%s\n' "$row"; return; }
  done
}

# The model spellings a launch on harness $1 is read with: that harness's own,
# or EVERY spelling the table names when the launch names no harness. A launch
# naming no harness ANYWHERE in its argv carries its own argv in --cmd and
# reaches no gate, because no row judges it, but the lane record still names the
# model it passes and which harness will read that word is not this launcher's
# to know. A caller that can name the harness passes it: open-terminal reads one
# out of a `--lane auto:<h>` spec where no --harness was given, and hands that
# harness here, so such a launch is read and judged by its own row. Derived from
# the same rows, so a spelling is added in one place and both readings get it.
launch_choice_model_spellings() { # [HARNESS]
  local row spellings word out=""
  for row in "${LAUNCH_CHOICE_FLAGS[@]}"; do
    [[ -z "$1" || "${row%%|*}" == "$1" ]] || continue
    IFS='|' read -r _ spellings _ _ _ <<<"$row"
    for word in $spellings; do
      case " $out " in *" $word "*) ;; *) out="$out $word" ;; esac
    done
  done
  printf '%s\n' "${out# }"
}
# The effort spellings a launch on harness $1 is read with, empty where there is
# no effort word to name at all: a row whose effort list is `-`, the table's way
# of saying that harness's launch form has no effort flag, and a harness the
# table holds no row for. One question, answered here beside launch_choice_effort
# rather than by a caller reading that sentinel for itself.
launch_choice_effort_spellings() { # HARNESS
  local row spellings
  row="$(launch_choice_row "$1")"
  [[ -n "$row" ]] || return 0
  IFS='|' read -r _ _ spellings _ _ <<<"$row"
  [[ "$spellings" != - ]] || return 0
  printf '%s\n' "$spellings"
}

# The value one launch names for one choice, empty where it names none, over as
# many texts as the caller hands it, first match winning.
#
# Several texts, because the LANE RECORD of a launch no row judges names the
# model that launch passes whatever text carries it (the comment above
# launch_choice_model_spellings). This is not a precedence that makes a word
# interchangeable between two texts: a caller judging a launch hands this the
# text the launch actually RUNS, since a --cmd template is rendered verbatim and
# --launch-flags reach a harness only through a command the caller builds.
# open-terminal refuses the two together for that reason, as
# launch-flags-unreachable, so its readings have one text to give.
#
# read -a, not `for tok in $2`, for the reason start_cmd states: a bare
# expansion globs the very brackets a model id can carry.
launch_choice_value() { # SPELLINGS TEXT...
  local spellings="$1"
  shift
  local -a words=() tokens=()
  local text word tok i
  read -r -a words <<<"$spellings"
  for text in "$@"; do
    [[ -n "$text" ]] || continue
    tokens=()
    read -r -a tokens <<<"$text"
    i=0
    while (( i < ${#tokens[@]} )); do
      tok="${tokens[i]}"
      for word in ${words[@]+"${words[@]}"}; do
        if [[ "$word" == *= ]]; then
          [[ "$tok" == "$word"* ]] || continue
          printf '%s\n' "${tok#"$word"}"
          return
        fi
        if [[ "$tok" == "$word="* ]]; then
          printf '%s\n' "${tok#"$word"=}"
          return
        fi
        if [[ "$tok" == "$word" ]] && (( i + 1 < ${#tokens[@]} )); then
          printf '%s\n' "${tokens[i+1]}"
          return
        fi
      done
      i=$((i + 1))
    done
  done
  # Naming no value is an ordinary answer here, the refusal below being what
  # acts on it, so the status says the search ran rather than what it found.
  # `i=$((i + 1))` above for the same reason: `(( i++ ))` answers 1 on the
  # first token and errexit would end the run inside this substitution.
  return 0
}

# The EFFORT one launch names, empty where it names none or where the harness has
# no effort flag at all. Read with that harness's own spelling, and then, where
# the row names a separator, from the model value: pi documents its thinking
# level on `--model <pattern>` as `sonnet:high`, so a launch passing that has
# made both choices in one token and is not asked for the level again. The
# separator lives in the row, so a harness added with a colon form needs no
# second edit anywhere, and a caller asking this library what effort a launch
# named gets the same answer the launcher acts on.
#
# A separator with nothing after it names no level, which its caller refuses.
launch_choice_effort() { # HARNESS TEXT [TEXT]
  local row effort_spellings in_model model effort
  row="$(launch_choice_row "$1")"
  [[ -n "$row" ]] || return 0
  IFS='|' read -r _ _ effort_spellings in_model _ <<<"$row"
  [[ "$effort_spellings" != - ]] || return 0
  effort="$(launch_choice_value "$effort_spellings" "$2" "${3:-}")"
  if [[ -z "$effort" && "$in_model" != - ]]; then
    model="$(launch_choice_value "$(launch_choice_model_spellings "$1")" "$2" "${3:-}")"
    [[ "$model" != *"$in_model"* ]] || effort="${model##*"$in_model"}"
  fi
  printf '%s\n' "$effort"
}

# The model and effort words a launch of HARNESS passes, written from that
# harness's own row and quoted for the shell the caller is building a command
# in. The inverse of launch_choice_value, over the same row: what this writes is
# what that reads, so a successor overseer cannot be given a spelling the
# launcher would refuse.
#
# Empty, status 0, where MODEL is empty: a caller with no model to pass names
# neither word. Status 1 where a MODEL is named and the table holds no row for
# that harness, which is not an answer but the absence of one. A harness whose
# row has no effort spelling takes the model alone; so does an empty EFFORT.
launch_choice_write() { # HARNESS MODEL EFFORT
  local row model_spellings effort_spellings attach word out
  # No model to pass is an answer: the caller names neither word, and an effort
  # beside a default model is half a choice. A model the table has no row for is
  # NOT an answer — nothing here knows how that harness spells it, and writing
  # nothing would launch it on whatever default it ships. The caller refuses.
  [[ -n "$2" ]] || return 0
  row="$(launch_choice_row "$1")"
  [[ -n "$row" ]] || return 1
  IFS='|' read -r _ model_spellings effort_spellings _ attach <<<"$row"
  read -r word _ <<<"$model_spellings"
  out="$word $(printf %q "$2")"
  if [[ "$effort_spellings" != - && -n "$3" ]]; then
    read -r word _ <<<"$effort_spellings"
    if [[ "$word" == *= ]]; then
      # An attached-value spelling is one token, and the row names the flag word
      # it rides on.
      out="$out $attach $(printf %q "$word$3")"
    else
      out="$out $word $(printf %q "$3")"
    fi
  fi
  printf '%s\n' "$out"
}

# A value the pane's own shell reads back as itself.
lane_single_quote() { # VALUE
  local escaped="'\\''"
  printf "'%s'" "${1//\'/$escaped}"
}

# The trust record a Codex launch reads BEFORE it reads the arguments it was
# launched with: `[projects."<dir>"] trust_level = "trusted"` in the config.toml
# the launch's CODEX_HOME names. Without it the harness opens on `Do you trust
# the contents of this directory?` and stays there, and an unattended launch —
# an overseer succession, a lane opened into a worktree nothing has trusted yet
# — has nobody at the pane to answer, so the whole launch is spent on a
# question.
#
# A sandboxed lane gets this from the provider's pre-approval step
# (../../schemas/lane-host.md § Provider protocol). A control-host launch has
# no such step and cannot be given one by editing the account: a numbered
# account's config.toml is a link the account shim points at the shared fleet
# render on every launch, so an entry written there is gone by the next launch
# and is visible to no fixture. The launch therefore builds a CODEX_HOME OF ITS OWN
# under the account, holding the account's own files by link and one config.toml
# of its own carrying the account's config plus the entry.
#
# lane_codex_trust_prepare's answer, read by the caller that reports the route
# beside its own launch line and refuses when the entry could not be made.
LANE_TRUST_ROUTE=""
LANE_TRUST_HOME=""
LANE_TRUST_REASON=""

# lane_codex_trusted CONFIG DIR — what CONFIG says about opening into DIR.
#
#   0  trusted outright: the harness starts into DIR with no question
#   1  the config does not say: no file, no table, no key, or a value the
#      reader could not take
#   2  the config carries an answer for DIR that is not trust
#
# The last two are kept apart because only the middle one licenses writing an
# entry. Codex's own trust level takes exactly `trusted` and `untrusted`, so a
# config answering `untrusted` for this directory holds a recorded decision in
# the tool's own spelling, and overwriting it would run the launch at full trust
# against the answer somebody gave.
lane_codex_trusted() { # CONFIG DIR
  local value
  value="$(toml_value "$1" "projects.\"$2\"" trust_level)" || return 1
  [ "$value" = trusted ] || return 2
}

# lane_codex_recorded DIR CONFIG... — what somebody has ALREADY recorded for
# DIR, over every config a launch on this lane can read, as lane_codex_trusted's
# own status with the strictest answer winning: 2 where any of them answers
# something that is not trust, 0 where one trusts and none refuses, 1 where none
# of them says anything.
#
# One reader, because the question has more than one file to ask. A launch on
# the launch-home route runs with CODEX_HOME at the private home, so that is the
# config codex writes a folder-trust answer into; a check that read the account
# alone found nothing there, rebuilt the home from the account and appended
# trust over the answer somebody had given. A config location added later is one
# more argument here rather than a second per-file check a new site can miss.
lane_codex_recorded() { # DIR CONFIG...
  local dir="$1" config rc out=1
  shift
  for config in "$@"; do
    rc=0
    lane_codex_trusted "$config" "$dir" || rc=$?
    [ "$rc" != 2 ] || return 2
    [ "$rc" != 0 ] || out=0
  done
  return "$out"
}

# Make the trust entry for LAUNCH_DIR exist in the config a HARNESS launch on
# LANE_DIR will read, and say which home that is. Prints nothing; the answer is
# the three variables above, so a caller names the route in its own launch line.
#
#   LANE_TRUST_ROUTE   `none` for a harness that asks no such question,
#                      `preapproved` where the account's own config already
#                      trusts the directory, `launch-home` where this built a
#                      private home carrying the entry
#   LANE_TRUST_HOME    the CODEX_HOME the launch must run under
#   LANE_TRUST_REASON  set on a non-zero return, naming what could not be done
#
# HARNESS is taken rather than tested by each caller, the way lane_launch_form
# beside it takes one: a caller then makes one unconditional call and handles
# one refusal, instead of repeating a harness test, a call, a swap and a
# refusal around it.
#
# Status 1 is the LAUNCH READINESS answer, and the caller refuses on it rather
# than opening a pane on a dialog. The closing step reads back the entry the
# launch needs from the config that was just written: a home another launch
# rewrote between the write and the read, a write that reported success and
# produced nothing, and a path that broke the header across lines all end
# there. A path carrying a quote or a backslash does NOT: the reader here
# matches the header this wrote, while the harness reads both characters as
# TOML string syntax and takes the file, or the key, to say something else.
# Neither reaches here from a path kendex builds.
lane_codex_trust_prepare() { # HARNESS LANE_DIR LAUNCH_DIR
  local harness="$1" lane dir="$3" config home entry name staged rc=0
  LANE_TRUST_ROUTE=""
  LANE_TRUST_HOME="$2"
  LANE_TRUST_REASON=""
  if [ "$harness" != codex ]; then
    LANE_TRUST_ROUTE=none
    return 0
  fi
  # The ACCOUNT, never a private home. A caller inside a launched session reads
  # its own CODEX_HOME to name its lane, and a home taken raw here would hold
  # the next home inside it, one level deeper per launch, each level linking
  # the level above rather than the account.
  lane="$(lane_launch_home_account "$2")" || { LANE_TRUST_REASON=home-path; return 1; }
  [ -n "$lane" ] || { LANE_TRUST_REASON=home-path; return 1; }
  LANE_TRUST_HOME="$lane"
  config="$lane/config.toml"
  # An existing config this process cannot read is a refusal and never an
  # absence. A numbered account's config.toml IS a symlink the account shim
  # repoints, and a dangling one answers a readability test exactly as a missing
  # file does; read as absence it stages an empty config, and the launch starts
  # with every table the account was approved for gone, the hook approval among
  # them, on the hook-approval dialog rather than the folder-trust one.
  if { [ -e "$config" ] || [ -L "$config" ]; } && { [ ! -f "$config" ] || [ ! -r "$config" ]; }; then
    LANE_TRUST_REASON=config-unreadable
    return 1
  fi
  home="$(lane_codex_home_path "$lane" "$dir")" || { LANE_TRUST_REASON=home-path; return 1; }
  # Read from BOTH configs a launch here can open, so an answer recorded in the
  # private home is honoured exactly as one recorded in the account is. That
  # home is where the launch-home route points CODEX_HOME, so it is where codex
  # writes the answer somebody gives at the pane.
  lane_codex_recorded "$dir" "$config" "$home/config.toml" || rc=$?
  [ "$rc" != 2 ] || { LANE_TRUST_REASON=trust-refused; return 1; }
  # `preapproved` is the ACCOUNT's own answer and only the account's: a
  # `trusted` in the private home is this preparation's own earlier write, and
  # reading it as the account's would skip the rebuild that carries across
  # whatever the account has been approved for since.
  rc=0
  lane_codex_trusted "$config" "$dir" || rc=$?
  [ "$rc" != 0 ] || { LANE_TRUST_ROUTE=preapproved; return 0; }
  # The whole private tree is the account's own secrets by another name, so it
  # is created private and the files written into it are protected by it.
  ( umask 077 && mkdir -p -- "$home" ) || { LANE_TRUST_REASON=home-create; return 1; }
  # The transcript store belongs to the ACCOUNT. The harness creates what is
  # missing under the home it is given, so a store absent at this moment is
  # created inside the private home, where open-terminal's relaunch scan never
  # looks: that scan reads `<account>/sessions`, and a rollout written anywhere
  # else is a resume that silently starts a fresh thread. Made in the account
  # first so the loop below links it like any other entry. Every other name the
  # harness invents after this point is created privately and stays there; this
  # is the one such name anything here reads.
  ( umask 077 && mkdir -p -- "$lane/sessions" ) || { LANE_TRUST_REASON=account-store; return 1; }
  # The account's own files by link, never by copy: a token the harness renews
  # under this lane is renewed in the account's auth.json, and the transcripts a
  # resumed launch is scanned for stay where the account keeps them. config.toml
  # is the one file this home owns, and `lane-launch` holds this home, so
  # linking it in would nest the tree inside itself.
  for entry in "$lane"/* "$lane"/.[!.]*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name="${entry##*/}"
    { [ "$name" != config.toml ] && [ "$name" != lane-launch ]; } || continue
    # A REAL directory at the name refuses. `ln -s -f` replaces a link and
    # replaces a plain file, but at a directory it descends INTO it, creates the
    # link inside and reports success, so a home that once held a directory of
    # its own gains another level under that name at every launch. A plain file
    # is replaced on purpose, and the producer is the rule two lines above: a
    # name the account did not hold when this home was built is created here and
    # stays here, so once the account gains that name there are two copies of
    # it, and the link makes the account's the one this lane reads. No producer
    # here detaches a link: the codex write that puts a credential at this name
    # opens the existing path, so it lands in the account's own file.
    if [ -d "$home/$name" ] && [ ! -L "$home/$name" ]; then
      LANE_TRUST_REASON=home-entry
      return 1
    fi
    ln -sfn -- "$entry" "$home/$name" || { LANE_TRUST_REASON=home-link; return 1; }
  done
  # Staged under this shell's own pid and renamed over the target, so a launch
  # reading this home while another writes it meets the whole previous config or
  # the whole new one, never half a file the harness refuses to parse, and two
  # writers never share the file they are staging into. Every arm from here
  # takes the staged file away before it refuses: one left behind is another
  # file per refused launch, in the directory the config-write message sends the
  # operator to read.
  #
  # The account's config carries everything the account was approved for — the
  # hook approval the fleet install composed onto it, and every other launch
  # directory's trust — minus this directory's own table, which the entry below
  # states outright. Dropped rather than left in place because a harness that
  # already recorded its own answer for this directory declares that table, and
  # a second header for it is a duplicate key the harness rejects the whole file
  # for: the launch would then start on no config at all rather than on a
  # question.
  staged="$home/config.toml.$$"
  if [ -f "$config" ]; then
    toml_without_table "$config" "projects.\"$dir\"" > "$staged" \
      || { rm -f -- "${staged:?}"; LANE_TRUST_REASON=config-write; return 1; }
  else
    : > "$staged" || { rm -f -- "${staged:?}"; LANE_TRUST_REASON=config-write; return 1; }
  fi
  # A leading newline, because the account's config ends inside whatever table
  # it ends in and a header appended to that line would be read as part of it.
  printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$dir" >> "$staged" \
    || { rm -f -- "${staged:?}"; LANE_TRUST_REASON=config-write; return 1; }
  mv -f -- "$staged" "$home/config.toml" \
    || { rm -f -- "${staged:?}"; LANE_TRUST_REASON=config-install; return 1; }
  lane_codex_trusted "$home/config.toml" "$dir" || { LANE_TRUST_REASON=entry-unreadable; return 1; }
  LANE_TRUST_ROUTE=launch-home
  LANE_TRUST_HOME="$home"
  return 0
}

# The ONE decision about how a resolved lane reaches the launched harness, made
# once per launch and read both by the launch line and by the account check that
# follows the pane open. Prints one of:
#   launcher:<path>  launch through that file, with no env prefix
#   prefix           launch under the env prefix, and check the pane
#   unchecked        launch under the env prefix where a lane was resolved;
#                    nothing of ours to check either way
#
# A LAUNCHER is a command named for the lane's own config directory — its
# basename without the leading dot — which selects the account itself. Where one
# exists it is the WHOLE selector and the prefix is dropped: such a wrapper
# exports the lane variable for its OWN name, so under `env VAR=<picked> claude`
# it overwrites the prefix and the lane runs on another account with nothing on
# screen saying so. The config directory's basename, never a lane alias: an
# operator can rename a lane to `work`, and no `work` command exists. The name
# is derived the way `lanes` derives its own, `basename --` then the leading
# dot, so every spelling that reaches `lanes` reaches this judge identically.
# `${dir##*/}` is not that: a trailing slash, which `--lane` and an
# ORCH_LANE_DIRS entry both carry through unnormalised, strips the whole value
# and leaves no name to judge. One normalisation, not a case per spelling.
#
# An absolute, executable path only, so a shell builtin sharing the lane's name
# is not mistaken for a wrapper. That path is also what gets RENDERED, quoted.
# A bare word in the launch line is resolved AGAIN by the pane's own shell, and
# a tmux server started before a PATH change or a login shell that reorders PATH
# resolves a different file or none while the env prefix has already been
# dropped — the function judging one file and the pane running another. An
# absolute path leaves the wrapper's own account selection intact, since it
# reads its invocation name and `${0##*/}` of `/…/bin/1claude` is `1claude`.
#
# The name must CARRY the harness word and not BE it. The harness binary is the
# thing being configured, never a configurator: `claude` for a lane at
# `~/.claude` or `<dir>/accounts/claude`, and `codex` for one at
# `~/.config/codex`, would select that harness's own default account while the
# dropped prefix stopped selecting anything. A name belonging to the OTHER
# harness is the same mistake pointed elsewhere — a lane and a harness are
# chosen independently, so a codex lane launched under claude would otherwise
# render `1codex` running claude's arguments. Both fall through to the prefix
# form, which selected these lanes correctly all along.
#
# Local claude and codex launches only, which the caller establishes before it
# asks: a launch on another machine answers about the wrong PATH, and
# CLAUDE_CONFIG_DIR and CODEX_HOME are those two harnesses' own variables. A
# rendered command that does not open on the harness word has no first word to
# replace, so it keeps the prefix — which the account check still verifies.
#
# TEMPLATE non-empty says the command is the CALLER'S own, from a --cmd
# template, whose first word is not ours to replace. It is an input to this
# judge rather than a tag a caller writes for itself, so every launch that ASKS
# gets its form from this one line. A launch that never asks — a hosted one,
# which runs on another machine and carries no local lane prefix — keeps
# whatever its caller initialised the form to, and is read back by nothing.
lane_launch_form() { # CMD HARNESS LANE_DIR [TEMPLATE]
  local cmd="$1" harness="$2" dir="$3" template="${4:-}" name path
  if [[ -z "$dir" || -n "$template" ]] || [[ ! "$harness" =~ ^(claude|codex)$ ]]; then
    printf 'unchecked\n'
    return
  fi
  name="$(basename -- "$dir")" || { printf 'prefix\n'; return; }
  name="${name#.}"
  if [[ "$name" != *"$harness"* || "$name" == "$harness" ]]; then printf 'prefix\n'; return; fi
  path="$(command -v -- "$name" 2>/dev/null)" || path=""
  if [[ "$path" == /* && -x "$path" && "$cmd" == "$harness "* ]]; then
    printf 'launcher:%s\n' "$path"
  else
    printf 'prefix\n'
  fi
}

# The launch line for a command that must run on a chosen account, under the
# form lane_launch_form picked for it.
#
# The prefix value is quoted by lane_single_quote, not wrapped in bare quotes:
# lane dirs are paths, an unquoted space would split the env assignment inside
# the launch shell, and a bare pair closes early on a dir carrying an
# apostrophe — which the pane shell then rejects for an unterminated string,
# starting no harness and leaving the launch to time out naming nothing about
# quoting. Only open-terminal refuses such a dir before it gets here; a lane
# reaching this builder from anywhere else has no such gate, so the escaping is
# this builder's to do.
#
# The lane is recorded in the launched command itself, so `ps` and the pane's
# own first line show which account a stalled session belongs to — as the
# launcher's own path, or as the env prefix where the machine has no launcher.
# Not the window title: both launchers open their window with an explicit -n,
# which turns tmux's automatic rename off, so the title keeps the name it was
# given and never carries the launch line.
lane_launch_line() { # CMD HARNESS LANE_VAR LANE_DIR FORM
  local cmd="$1" harness="$2" var="$3" dir="$4" form="$5"
  case "$form" in
    launcher:*) printf '%s %s\n' "$(lane_single_quote "${form#launcher:}")" "${cmd#"$harness" }" ;;
    *) printf 'env %s=%s %s\n' "$var" "$(lane_single_quote "$dir")" "$cmd" ;;
  esac
}

# The lane variable's value in the DEEPEST process under pane pid $1 that
# carries it, empty when none does. Breadth first, so no carrier found later is
# shallower than one found earlier.
#
# Deepest, not first: under `env VAR=<picked> claude` the env process carries
# the picked value while a wrapper below it can already have replaced it, and a
# shallow read would report an agreement the running harness does not have.
#
# Exit 2 when the descendant probe itself failed, which is not an answer at all:
# pgrep's 0 and 1 are its two answers and anything else is the probe breaking.
# pgrep, not `ps --ppid`, which is procps-only and rejected by BSD ps.
lane_observed_dir() { # PANE_PID NAME
  local name="$2" frontier next pid kids value rc found=""
  frontier="$(pgrep -P "$1" 2>/dev/null)" || { rc=$?; [[ "$rc" -eq 1 ]] || return 2; frontier=""; }
  while [[ -n "$frontier" ]]; do
    next=""
    for pid in $frontier; do
      kids="$(pgrep -P "$pid" 2>/dev/null)" || { rc=$?; [[ "$rc" -eq 1 ]] || return 2; kids=""; }
      [[ -z "$kids" ]] || next+="$kids"$'\n'
      # A process that exits mid-walk takes its /proc entry with it; that is an
      # absent value, not a broken probe.
      # 2> BEFORE <: redirections apply left to right, so a suppression written
      # after the input would report a missing /proc entry on the still-open
      # stderr — a shell error in the launch output for the very case the
      # comment above calls an absent value.
      value="$(tr '\0' '\n' 2>/dev/null < "/proc/$pid/environ" | sed -n "s/^$name=//p" | tail -1)" || value=""
      [[ -z "$value" ]] || found="$value"
    done
    frontier="$next"
  done
  printf '%s\n' "$found"
}

# lane_account_readable FORM — true for a launch this check can read back at
# all: one this machine started under a lane of its own, by env prefix or by
# the account launcher. A hosted launch runs on another machine and an
# `unchecked` one carries no lane, so neither has a local pane to read.
#
# Its own name because a caller has to ask the same question BEFORE the check:
# waiting for the harness to come up ahead of a read that will not happen is
# the whole of that wait spent for nothing.
lane_account_readable() { # FORM
  case "$1" in prefix|launcher:*) return 0 ;; *) return 1 ;; esac
}

# lane_process_env_readable — true where this machine lets a process be read
# back for the environment it was handed. /proc/<pid>/environ is the whole of
# that reading, so a host without /proc — every macOS run — offers the check
# below no observation to make: it names no-process-environment and leaves the
# launch standing, however healthy the pane is.
#
# Its own name because the condition is asked twice: here, by the check, and by
# a test deciding which of its rows this host can produce at all. A second
# spelling would let the two drift and pin an outcome the check cannot reach.
lane_process_env_readable() {
  [[ -r "/proc/$$/environ" ]]
}

# The smallest bound an observation can settle inside, in seconds. A settle is
# two reads a second apart, so a check handed less than this can never verify an
# account and never catch a mismatch, whatever the pane is doing and whatever
# the loop in lane_account_check would otherwise have reported. Callers that
# share one deadline between several waits size their bounds against it.
LANE_SETTLE_MIN_SECS=1

# The account the pane is REALLY running on, against the one that was picked.
# A wrapper on PATH exports the lane variable for its own name, so a launch can
# be running on an account nobody picked while the claim recorded for it counts
# against the picked one and nothing on screen says so.
#
# The guard fails closed on what it OBSERVES and never on what it could not: an
# observed disagreement returns 1 and the caller closes the window, while no
# readable per-process environment, no pane pid, a broken descendant probe and
# no descendant carrying the variable inside the bound each return 0 with the
# reason named, and leave a healthy lane running.
#
# The outcome is one tagged value in LANE_ACCOUNT_RESULT, which every caller
# matches to choose its own message: `skipped`, `verified`, `mismatch`, or
# `unobserved:<reason>`. LANE_ACCOUNT_OBSERVED carries the dir it settled on.
#
# BOUND is how many seconds the caller gives the reading to settle, never below
# LANE_SETTLE_MIN_SECS above.
#
# An observation counts only once it SETTLES: two reads a second apart carrying
# the same value. The first non-empty read is not the harness's answer — under
# the env-prefix form the launch child carries the picked value from its own
# execve until the wrapper's exec lands, and trusting that read would confirm an
# account the pane is about to stop running.
#
# Settling proves repetition, never that the exec has landed. /proc/<pid>/environ
# is written at execve, so a wrapper slower than the settle window carries the
# value it was handed throughout and two agreeing reads agree about the wrapper.
# Only the caller can close that gap, by asking once the harness is certainly
# what answers: once the pane draws the harness's own screen, or once it shows a
# running turn — pane_harness_up in lib/lane-state.sh is that question.
#
# The premise is the CALLER'S, and neither shipped caller treats it as proven.
# open-terminal waits for it best effort and, where the wait comes back empty,
# reports the reading that follows as unobserved rather than as a verified
# account. oversee-succeed's FIRST read is deliberately unpremised — it exists
# to catch a disagreement that is already true, before the successor has had a
# turn — and only its second read, taken once the pane shows a running turn,
# carries the premise and is the one its window closes on.
# shellcheck disable=SC2034  # LANE_ACCOUNT_RESULT and LANE_ACCOUNT_OBSERVED are
# this function's answer, read by the caller that matches on it.
lane_account_check() { # PANE LANE_VAR PICKED FORM BOUND
  local pane="$1" name="$2" picked="$3" form="$4" bound="$5" pid observed rc waited=0 settled=""
  LANE_ACCOUNT_OBSERVED=""
  LANE_ACCOUNT_RESULT=skipped
  lane_account_readable "$form" || return 0
  lane_process_env_readable || { LANE_ACCOUNT_RESULT=unobserved:no-process-environment; return 0; }
  pid="$(tmux display-message -p -t "$pane" '#{pane_pid}')" || pid=""
  # 0 is not a pane's pid, and walking from it reads processes belonging to no
  # pane at all — an unrelated lane's harness among them, which would refuse a
  # healthy window over a reading that was never about it.
  [[ "$pid" =~ ^[0-9]+$ && "$pid" != 0 ]] || { LANE_ACCOUNT_RESULT=unobserved:pane-pid; return 0; }
  # Defensive: no shipped caller can drive this arm. open-terminal passes
  # $ORCH_TMUX_VERIFY_SECS, which its own gate refuses unless it is a positive
  # integer, and oversee-succeed asks succ_budget_bound, which floors every
  # bound at this constant. It exists so a caller that computes its own bound is
  # named for what it did: left to the loop, that bound would answer
  # `unsettled`, `no-lane-variable` or `descendant-probe` by whatever its first
  # read happened to find, each of which tells an operator something about the
  # pane when what happened is that the caller had no budget left to look.
  (( bound >= LANE_SETTLE_MIN_SECS )) || { LANE_ACCOUNT_RESULT=unobserved:no-settle-budget; return 0; }
  while :; do
    rc=0
    observed="$(lane_observed_dir "$pid" "$name")" || rc=$?
    [[ "$rc" -eq 0 ]] || { LANE_ACCOUNT_RESULT=unobserved:descendant-probe; return 0; }
    [[ -z "$observed" || "$observed" != "$settled" ]] || break
    settled="$observed"
    if (( waited >= bound )); then
      # A value that never repeated is a pane still changing hands, which is not
      # the same miss as never seeing one at all.
      if [[ -n "$settled" ]]; then LANE_ACCOUNT_RESULT=unobserved:unsettled
      else LANE_ACCOUNT_RESULT=unobserved:no-lane-variable; fi
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  LANE_ACCOUNT_OBSERVED="$observed"
  if [[ "$(lane_claims_canon "$(lane_launch_home_account "$observed")")" \
     == "$(lane_claims_canon "$(lane_launch_home_account "$picked")")" ]]; then
    LANE_ACCOUNT_RESULT=verified
    return 0
  fi
  LANE_ACCOUNT_RESULT=mismatch
  return 1
}
