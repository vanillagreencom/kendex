#!/usr/bin/env bash
# ---
# name: block-worktree-refresh
# event: PreToolUse
# matcher: Bash
# description: Refuse a `kendex` command that writes the project scope (`refresh`, `apply`, `add`, `remove`, `update-pi`, `updates --apply`, `pin`, `fork`, `adopt`, `drift-hook`, `source add|remove|enable|disable`, `marketplace subscribe|unsubscribe`) when the working directory is a linked git worktree, the command does not name the global scope, and the project the write lands in is not the worktree's own; and whenever a `cd`, `pushd`, `env -C` or `sudo -D` stands before the verb in the same command, since the directory the write lands in cannot then be read from the command. The project a bare verb writes is the one kendex resolves from the working directory; where that project has no manifest of its own in the linked worktree (kendex.toml, or kendex-local.toml for a source catalog), its declarations are the main checkout's, so a project-scope write renders into that checkout and removes what it does not expect there. Where it has one, it is a project in its own right and its target is unambiguous, so every writing verb but `update-pi` passes there bare. `refresh`, `apply` and `updates --apply` pass in any worktree once they name their target with `--project-path PATH`: the directory the write lands in is then the command's own word; `update-pi` is refused in every worktree at the project scope. Names the forms that are right: `--project-path PATH` where the verb takes it and the installed kendex lists the flag, the same command from the main checkout, or the verb's global form (`--global` for add, `--scope global` for update-pi, either for the rest, the `source` subcommands included). An installed kendex whose `refresh --help` does not list `--project-path` is named with its version instead of the flag it lacks.
# summary: Stops a kendex command that writes a project from inside a linked git worktree, where the write would land somewhere the command does not name.
# safety: Reads the command text and asks git whether the tool call's working directory has a git dir that differs from its common dir, which is what makes a worktree linked, and for a linked worktree its root; walks up from the working directory to that root for the project kendex would write, and tests whether its manifest exists, reading its kendex.toml only for the text `is_source_catalog`; the hook itself writes nothing. A git that cannot answer refuses. The verb is the first word naming one after a `kendex` word, anywhere in the command except the text the shell would not run: the words inside a quoted span, a heredoc body its command reads as data, and a comment are masked out before the command is read, so prose spelling the pair is not refused, while a span or a heredoc body that a shell, `eval`, `source` or `.` word runs is read as the command it is; a quote that cannot be paired leaves the whole text to be read, so a command this hook could not take apart is refused rather than passed. The command is read by the commit-guards skill's command-position library, found in the install beside the hook; without it every call is refused. The bare `kendex <source>` shorthand for add is not read, since matching it would match every read too. `kendex help VERB`, a matched verb with `--help`, `-h` or `--plan` among the words Bash passes it, `kendex updates` without `--apply`, `kendex verify`, `list`, `report`, `check` — whose one write, the scope's install record for copies it proves against their source, renders nothing into any checkout — and every other verb pass. `-g`/`--global`, `--scope`, `--project-path`, `--apply`, `--help`, `-h` and `--plan` are read from the words Bash passes kendex after the verb in its own segment, and for a `source` subcommand also from the option words between `source` and it, where its parser takes them too: a redirection operator and the file it opens are not arguments, a standalone `--` ends the options, and a word there the shell settles only when it runs (a parameter expansion, a glob, a brace, or a backslash) grants no exemption and counts as `--apply`; a command substitution, and a quoted span the command reader opens as command text with the words after it, are cut out of the segment and not read. update-pi's `--check` is read from the segment's text. A command carrying `-g`, `--global` or `--scope global` there, with no other `--scope` beside it, passes because it names the scope this hook does not guard, and a `refresh`, `apply` or `updates` carrying `--project-path` there passes because it names the project it writes, the value itself being read by kendex, which refuses the flag without one. On the refusal path only, and only where the refusal of `refresh`, `apply` or `updates --apply` would offer `--project-path`, the hook runs `kendex refresh --help` and `kendex --version` once from the PATH it was given, reads whether the help lists the flag, and captures what both wrote; a kendex that is not on PATH or whose help cannot be read is named as unasked, and the flag is not offered. That kendex is a binary of its own: its first run on a machine records the command's path under kendex's data directory, and it writes into no checkout. A payload that cannot be read, an empty one included, is refused, never skipped. Every refusal opens with `block-worktree-refresh: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
# timeout: 10
# ---

set -euo pipefail

# What the refusals name, empty until each is known: the kendex verb, the
# working directory judged, the project a bare verb typed there writes and
# the manifest file that makes it one, whose project that is (`worktree`
# where that manifest exists in the linked worktree, `main` where it does
# not), the .git entry git could not read, and git's own words on a question
# it could not answer.
VERB=""
CWD=""
PROJECT=""
MANIFEST=""
OWNER=""
AT=""
REASON=""
# What kind of writer a verb is, the one answer every decision below
# dispatches on: `target` for the three that write a whole scope and take
# `--project-path PATH`; `pi` for update-pi, which runs in a linked worktree
# only as `kendex update-pi --scope global`; `typed` for every other writing
# verb, which writes the one project it is typed in and has no such flag.
verb_kind() { # VERB -> KIND
  case "$1" in
    refresh | apply | updates) KIND=target ;;
    update-pi) KIND=pi ;;
    *) KIND=typed ;;
  esac
}
# Whether the installed kendex takes `--project-path`, asked once and only
# where a refusal would offer the flag: the one judge of a verb's flags is
# the installed CLI's own parser, read through `kendex refresh --help`, since
# a version number cannot tell a main build from the release and a table of
# flags per version here would be a second copy of that parser. Running the
# installed kendex is running a binary of its own: its first run on a
# machine records the command's path under the data directory, and it
# writes into no checkout. CLI_FLAG is `listed`, `missing` or
# `unasked`; CLI_VERSION is the first line `kendex --version` wrote, and
# CLI_REASON why the CLI could not be asked. What either command writes is
# captured here, never left to precede the keyed line.
CLI_FLAG=""
CLI_VERSION=""
CLI_REASON=""
probe_cli() { # -> CLI_FLAG, CLI_VERSION, CLI_REASON
  local help
  [ -z "$CLI_FLAG" ] || return 0
  if ! command -v kendex >/dev/null 2>&1; then
    CLI_FLAG=unasked
    CLI_REASON="kendex is not on PATH"
    return 0
  fi
  CLI_VERSION=$(kendex --version 2>&1) || CLI_VERSION=""
  CLI_VERSION=${CLI_VERSION%%$'\n'*}
  if ! help=$(kendex refresh --help 2>&1); then
    CLI_FLAG=unasked
    CLI_REASON="kendex refresh --help failed: ${help%%$'\n'*}"
    return 0
  fi
  case "$help" in
    *--project-path*) CLI_FLAG=listed ;;
    *) CLI_FLAG=missing ;;
  esac
}
# The forms of VERB that are right, for the refusal naming them. `global_form`
# sets its global form as its parser spells it. `target_form` sets its named-target form
# where it has one and the installed kendex lists the flag, else the reason
# the flag is not offered; only a whole-scope verb has such a form, so only
# that kind asks the installed kendex anything.
GLOBAL_FORM=""
TARGET_FORM=""
NO_TARGET=""
global_form() { # VERB -> GLOBAL_FORM
  case "$1" in
    add) GLOBAL_FORM='--global' ;;
    update-pi) GLOBAL_FORM='--scope global' ;;
    *) GLOBAL_FORM='--scope global (or --global)' ;;
  esac
}
target_form() { # VERB -> TARGET_FORM, NO_TARGET
  TARGET_FORM=""
  NO_TARGET=""
  verb_kind "$1"
  case "$KIND" in
    pi | typed)
      NO_TARGET="$1 has no --project-path form"
      return 0
      ;;
    target) ;;
  esac
  # Offering the flag to a kendex without it would name a command the
  # installed kendex refuses.
  probe_cli
  case "$CLI_FLAG" in
    listed) TARGET_FORM="--project-path PATH" ;;
    missing) NO_TARGET="the installed kendex ($CLI_VERSION) predates --project-path, so no command from here names the project it writes; update it with kendex update" ;;
    unasked) NO_TARGET="the installed kendex could not be asked whether it takes --project-path ($CLI_REASON), so the flag is not offered" ;;
    *)
      echo "internal: the CLI probe left CLI_FLAG as '$CLI_FLAG', which is none of listed, missing or unasked" >&2
      exit 2
      ;;
  esac
}
# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `block-worktree-refresh: <key>=<value>`:
# a stable key for the condition and the value acted on — the missing tool, why
# the payload could not be read, the verb refused, or git's exit status. The
# English explanation and the two forms that are right follow on later lines.
# The keyed line stands first, at position 1. What a command this hook runs
# wrote is captured where the hook reads it and passed here as the cause, so
# it is replayed under the key rather than ahead of it.
refuse() { # KEY VALUE [CAUSE]
  printf 'block-worktree-refresh: %s=%s\n' "$1" "$2" >&2
  case "$1=$2" in
    missing-tools=*)
      echo "the commands ${2//,/, } are required to read the hook payload and the worktree and are not on PATH; refusing rather than skipping the guard" >&2
      ;;
    missing-library=*)
      echo "the commit-guards skill's $2 is not installed beside this hook, and it is what reads the command; install the commit-guards skill in this scope. Refusing rather than skipping the guard" >&2
      ;;
    payload=unreadable)
      echo "the hook payload could not be read from stdin; refusing rather than skipping the guard" >&2
      ;;
    payload=empty)
      echo "the hook payload is empty, which would read as an absent command; refusing rather than skipping the guard" >&2
      ;;
    payload=invalid-json)
      echo "the hook payload is not valid JSON, or names a command that is not a string; refusing rather than skipping the guard" >&2
      ;;
    payload=invalid-cwd)
      echo "the payload's cwd is not a string; refusing rather than skipping the guard" >&2
      ;;
    moved=*)
      global_form "$VERB"
      target_form "$VERB"
      echo "refusing 'kendex $VERB' at project scope after a cd, pushd, env -C or sudo -D in the same command: the directory the write lands in cannot be established from the command's words." >&2
      if [ -n "$TARGET_FORM" ]; then
        echo "  Name the project in the command instead: $TARGET_FORM. Or run kendex as its own command from the project it writes, or pass $GLOBAL_FORM for a global change." >&2
      else
        echo "  Run kendex as its own command from the project it writes, or pass $GLOBAL_FORM for a global change; $NO_TARGET." >&2
      fi
      ;;
    refused=*)
      global_form "$VERB"
      echo "refusing 'kendex $VERB' at project scope from the linked worktree $CWD." >&2
      verb_kind "$VERB"
      case "$OWNER:$KIND" in
        worktree:pi)
          echo "  In a linked worktree update-pi runs only as: kendex update-pi $GLOBAL_FORM" >&2
          ;;
        main:*)
          target_form "$VERB"
          echo "  The project here, $PROJECT, has no $MANIFEST of its own in this worktree, so its declarations are the main checkout's (the first line of 'git worktree list'); a project-scope write from here renders into that checkout and removes what it does not expect there." >&2
          if [ -n "$TARGET_FORM" ]; then
            echo "  Name the project in the command instead: $TARGET_FORM. Or run the same command from the main checkout, or pass $GLOBAL_FORM for a global change. Reads (kendex verify, check, list) are not refused." >&2
          else
            echo "  Run the same command from the main checkout, or pass $GLOBAL_FORM for a global change; $NO_TARGET. Reads (kendex verify, check, list) are not refused." >&2
          fi
          ;;
        worktree:typed | worktree:target)
          echo "internal: a verb that writes the project it is typed in was refused in a worktree that owns its project; the owner loop and this message disagree." >&2
          ;;
      esac
      ;;
    git=unreadable)
      echo "$AT/.git exists but git could not read a repository there, so whether $CWD is a linked worktree is unknown and the write is refused" >&2
      ;;
    git=unresolvable)
      echo "a directory git named or answered for under $CWD could not be entered, so the write is refused" >&2
      ;;
    git=*)
      echo "git could not say whether $CWD is a linked worktree, or which worktree it is, so the write is refused:" >&2
      printf '%s\n' "$REASON" >&2
      ;;
  esac
  # The cause a command this hook ran wrote, captured at the site and replayed
  # here: under the keyed line, never ahead of it.
  [ -z "${3:-}" ] || printf '%s\n' "$3" >&2
  exit 2
}

# jq reads the payload and git answers the one question. Without either the
# command cannot be judged, and an unjudged command is refused. The value names
# every one of them the PATH is missing, in the order checked.
MISSING=""
for dependency in jq git cat; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"

# The command reader is commit-guards' command-position library. A catalog hook
# ships as one file, so the library comes from this hook's own install, never
# from whichever repository the session has open, by the walk
# hooks/lane-mail-check.sh owns for its reader: from the hook's physical
# directory up five levels, stopping at the open repository's root and after
# the home directory, where Pi's global hook sits four levels down, each
# level's `skills/` and shared `.agents/skills/` tree; then the home's shared
# tree, for a harness root CODEX_HOME, PI_CODING_AGENT_DIR or COPILOT_HOME moved
# out of the home; then the repository's own copy, only where this hook is
# installed in that repository. Without it no command can be read, and the
# call is refused.
LIBRARY=commit-guards/scripts/lib/command-position.sh
HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
HOOK_DIR=$(cd -P -- "$HOOK_DIR" 2>/dev/null && pwd -P) || HOOK_DIR=""
HOME_DIR=$(cd -P -- "${HOME:-/}" 2>/dev/null && pwd -P) || HOME_DIR=""
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT=""
FOUND_LIBRARY=""
AT=$HOOK_DIR
LEVELS=0
while [ -n "$AT" ] && [ "$LEVELS" -lt 5 ] && [ "$AT" != "$ROOT" ] && [ "$AT" != / ]; do
  for candidate in "$AT/skills/$LIBRARY" "$AT/.agents/skills/$LIBRARY"; do
    if [ -f "$candidate" ]; then
      FOUND_LIBRARY=$candidate
      break
    fi
  done
  { [ -z "$FOUND_LIBRARY" ] && [ "$AT" != "$HOME_DIR" ]; } || break
  AT=${AT%/*}
  [ -n "$AT" ] || AT=/
  LEVELS=$((LEVELS + 1))
done
if [ -z "$FOUND_LIBRARY" ] && [ -n "$HOME_DIR" ] && [ "$HOME_DIR" != "$ROOT" ] \
  && [ -f "$HOME_DIR/.agents/skills/$LIBRARY" ]; then
  FOUND_LIBRARY="$HOME_DIR/.agents/skills/$LIBRARY"
fi
if [ -z "$FOUND_LIBRARY" ] && [ -n "$ROOT" ] && [ -f "$ROOT/.agents/skills/$LIBRARY" ]; then
  case "$HOOK_DIR" in
    "$ROOT"/*) FOUND_LIBRARY="$ROOT/.agents/skills/$LIBRARY" ;;
  esac
fi
[ -n "$FOUND_LIBRARY" ] || refuse missing-library "$LIBRARY"
# shellcheck source=../skills/commit-guards/scripts/lib/command-position.sh
source "$FOUND_LIBRARY"

# cat's words are captured, not left to precede the refusal: on failure the
# substitution holds what it wrote, and the refusal replays it under the keyed
# line. A cat that succeeds is silent, so the payload is not mixed with a
# diagnostic on the passing side.
INPUT=$(cat 2>&1) || refuse payload unreadable "$INPUT"
# An empty payload is no payload: jq reads nothing from it and says nothing,
# which would pass as an absent command.
case "$INPUT" in
  *[![:space:]]*) ;;
  *) refuse payload empty ;;
esac

# A payload that does not parse, or that names a command which is not a
# string, is refused rather than skipped. An absent command is the empty
# string and passes. The command is read where each harness carries it:
# `tool_input.command` (Claude Code, Codex, Gemini CLI and the Pi carrier), a
# bare `command`, or Copilot's `toolArgs.command`, whose `toolArgs` arrives as
# an object or as one JSON-encoded string. The null tests are spelled out
# because jq's `//` reads `false` as absent, and `false` is not a command
# either.
COMMAND=$(printf '%s' "$INPUT" \
  | jq -r 'def copilot: .toolArgs
             | if . == null then null elif type == "string" then fromjson else . end
             | if . == null then null elif type == "object" then .command else error end;
           if .tool_input.command != null then .tool_input.command
           elif .command != null then .command
           elif copilot != null then copilot
           else "" end
           | if type == "string" then . else error end' 2>/dev/null) ||
  refuse payload invalid-json

# The verb as a word after a `kendex` word, judged one segment at a time over
# the text the shell would run: `command_segments` cuts the command into
# segments and masks what the shell would not run. A read-only option exempts
# the write only where it reaches kendex as a word of the verb's own segment,
# read by the same option reader as the scope. The global scope is not this hook's, and `-g`,
# `--global` or `--scope global` exempts a write only when it reaches kendex
# as an argument of the verb's own segment and no `--scope project` or
# `--scope all` does too, because kendex gives `--scope` precedence over
# `--global`; read across the whole command the word would let
# `kendex refresh -g && kendex refresh` through on the first command's word.
# `kendex updates` is a write only with `--apply`, which delegates to refresh.
# The bare `kendex <source>` shorthand for add is not read: matching it means
# matching every `kendex <word>`, reads included, and that is the whole CLI.
command_segments "$COMMAND"
CHECK_RE='(^|[[:space:]])(--check|-c)([[:space:]]|$)'
# A `cd` or `pushd` word in the verb's segment or an earlier one moves the
# shell before kendex runs, and `env -C`/`--chdir` and `sudo -D`/`--chdir`
# start the command they run in another directory, so the directory git is
# asked about below is not the one the write lands in; such a command is
# refused whatever that directory says, since the effective one cannot be
# established from words. The option is read as a word after `env` or
# `sudo` anywhere in the segment, a short one inside a cluster included.
MOVE_RE='(^|[^[:alnum:]_.-])((cd|pushd)([[:space:]]|$)|env([[:space:]]+[^[:space:]]+)*[[:space:]]+(-[[:alnum:]]*C|--chdir)|sudo([[:space:]]+[^[:space:]]+)*[[:space:]]+(-[[:alnum:]]*D|--chdir))'
KENDEX_RE='(^|[^[:alnum:]_.-])kendex["'"'"']?([[:space:]]|$)'

# The writing verb of one segment, and the text after it. A quote may close
# the command word or wrap the verb, as in `"/path/kendex" refresh` and
# `kendex 'refresh'`, and any words may stand between them, as in
# `kendex --global refresh` or `kendex --harness claude refresh`. Those root
# options and their values are dropped by the CLI once a subcommand follows,
# so only the words AFTER the verb are read for its options. The verb is the
# first word that names one, and `source` and `marketplace` name one only
# with their writing subcommand as the next word: a later word is an
# argument, such as a skill named `refresh` in `kendex add x --skill refresh`.
# `kendex help VERB` is clap's help subcommand, a read: `help` as the first
# word after `kendex` names no verb, wherever a verb stands after it.
# `source` takes `-g`/`--global` and `--scope` on itself as well as after its
# subcommand, so an option word between `source` and the subcommand keeps
# the group open, with the value after `--scope`, and those words lead the
# tail for the option reader.
# The verbs are every shipped command that writes a scope: the item verbs,
# `updates --apply`, `pin`, `fork`, `adopt`, `drift-hook`, and the writing
# subcommands of `source` and `marketplace`. FOUND is empty where the segment
# names none; TAIL keeps a leading space so a word at its start has an edge.
writing_verb() { # SEGMENT -> FOUND, TAIL
  local rest word raw glued group="" lead="" value="" first=1
  FOUND=""
  TAIL=""
  [[ $1 =~ $KENDEX_RE ]] || return 0
  rest=${1#*"${BASH_REMATCH[0]}"}
  while :; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || return 0
    word=${rest%%[[:space:]]*}
    rest=${rest#"$word"}
    raw=$word
    # A redirection glued to the word, as in `refresh>/dev/null`, ends the
    # word Bash passes; it stays in the tail for the option reader.
    glued=${word#"${word%%[<>]*}"}
    word=${word%%[<>]*}
    word=${word#[\"\']}
    word=${word%[\"\']}
    if [ -n "$first" ]; then
      first=""
      [ "$word" != help ] || return 0
    fi
    if [ -n "$value" ]; then
      value=""
      lead="$lead $raw"
      continue
    fi
    case "$group:$word" in
      :refresh | :apply | :add | :remove | :update-pi | :updates | :pin | :fork | :adopt | :drift-hook)
        FOUND=$word
        ;;
      source:add | source:remove | source:enable | source:disable | marketplace:subscribe | marketplace:unsubscribe)
        FOUND="$group $word"
        ;;
      source:-*)
        lead="$lead $raw"
        [ "$word" != --scope ] || value=1
        continue
        ;;
      *:source | *:marketplace)
        group=$word
        lead=""
        continue
        ;;
      *)
        group=""
        lead=""
        continue
        ;;
    esac
    TAIL="$lead $glued$rest"
    return 0
  done
}

# The four options this hook decides on — `-g`/`--global`, `--scope`,
# `--project-path` and `--apply` — read from the words of the verb's own
# segment as Bash passes them rather than from its text. A redirection
# operator and the file it opens are the shell's, never an argument, whether
# the file is glued to the operator (`>--global`), quoted (`> "--global"`) or
# its own word, and a real option stays one on either side of a redirection.
# A standalone `--` ends the options, so no word after it is one. Each word
# is read in order, because the one before it decides whether it is the
# value of `--scope` or `--project-path`.
#
# A word in the segment whose value the shell settles only when it runs — a
# parameter expansion, a glob, a brace, or a backslash, which can also join
# it to the next word — may be any word at all, `--` and `--scope=project`
# included, so it grants nothing: the scope is then the project scope,
# `--apply` counts as present, and a `--project-path` after it is not read as
# a target, since the word before could have ended the options. A quote is
# removed as the shell removes it. Words the command reader cut out of the
# segment are not read at all: a command substitution, and a quoted span it
# opens as command text together with every word after it.
#
# ARG_SCOPE is `unnamed`, `global` or `project`: kendex gives `--scope`
# precedence over `-g` and `--global`, so a `--scope` whose value is not the
# plain word `global` is the project scope whatever stands beside it.
# ARG_TARGET and ARG_APPLY are 1 where a real `--project-path` or `--apply`
# reaches kendex. The value `--project-path` names is not read: kendex
# refuses the flag without one. ARG_READ is 1 where a real `--help`, `-h`
# or `--plan` reaches kendex, on which it prints and writes nothing; an
# unsure word anywhere in the segment withdraws it, since that word may be
# the `--` that turns a later `--help` into a positional.
read_options() { # TAIL -> ARG_SCOPE, ARG_TARGET, ARG_APPLY, ARG_READ
  local rest=$1 word next head value="" operand="" unsure=""
  ARG_SCOPE=unnamed
  ARG_TARGET=""
  ARG_APPLY=""
  ARG_READ=""
  while :; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || break
    word=${rest%%[[:space:]]*}
    rest=${rest#"$word"}
    # A backslash before a blank makes the blank part of the word.
    while [[ $word == *\\ ]] && [ -n "$rest" ]; do
      word=$word${rest:0:1}
      rest=${rest:1}
      next=${rest%%[[:space:]]*}
      word=$word$next
      rest=${rest#"$next"}
    done
    if [ -n "$operand" ]; then
      operand=""
      continue
    fi
    # A `<` or `>` outside a quote starts a redirection: `<` inside a quoted
    # span was masked by the command reader, and a `>` behind a quote in
    # the word may be inside one, which leaves the word unsure. What stands
    # before the operator is an argument unless it is empty or the digits
    # of a file descriptor; the file follows the operator in the same word
    # or, where the word ends there, is the next word.
    case "$word" in
      *[\<\>]*)
        head=${word%%[<>]*}
        next=${word#"$head"}
        next=${next#"${next%%[!<>]*}"}
        [ -n "$next" ] || operand=1
        case "$head" in
          *[\"\']*)
            unsure=1
            continue
            ;;
          "") continue ;;
          *[!0-9]*) word=$head ;;
          *) continue ;;
        esac
        ;;
    esac
    # `--project-path=VALUE` names a target whatever its value holds, as
    # the spelling with the value in the next word does.
    case "$value:$word" in
      :--project-path=*) [ -n "$unsure" ] || ARG_TARGET=1 ;;
    esac
    case "$word" in
      *[\$\\*?[{}]*)
        unsure=1
        value=""
        continue
        ;;
    esac
    word=${word//[\"\']/}
    case "$value:$word" in
      scope:global) [ "$ARG_SCOPE" = project ] || ARG_SCOPE=global ;;
      scope:*) ARG_SCOPE=project ;;
      target:*) ;;
      :--) break ;;
      :-g | :--global) [ "$ARG_SCOPE" = project ] || ARG_SCOPE=global ;;
      :--scope) value=scope; continue ;;
      :--scope=global) [ "$ARG_SCOPE" = project ] || ARG_SCOPE=global ;;
      :--scope=*) ARG_SCOPE=project ;;
      :--project-path | :--project-path=*)
        [ -n "$unsure" ] || ARG_TARGET=1
        [ "$word" != --project-path ] || { value=target; continue; }
        ;;
      :--apply) ARG_APPLY=1 ;;
      :--help | :-h | :--plan) ARG_READ=1 ;;
    esac
    value=""
  done
  # A `--scope` whose value the segment does not hold is one whose value is
  # not known here: the command reader cuts a quoted span after a word ending
  # in `sh`, `refresh` among them, into a segment of its own.
  if [ -n "$unsure" ] || [ "$value" = scope ]; then
    ARG_SCOPE=project
    ARG_APPLY=1
  fi
  [ -z "$unsure" ] || ARG_READ=""
}

# Every project-scope write the command makes, one verb per line, in order.
# A write after a `cd` or `pushd` is refused here, before git is asked
# anything.
WRITES=""
MOVED=""
while IFS= read -r SEGMENT; do
  [[ $SEGMENT =~ $MOVE_RE ]] && MOVED=1
  writing_verb "$SEGMENT"
  [ -n "$FOUND" ] || continue
  read_options "$TAIL"
  # A verb asked for its help or its plan prints and writes nothing.
  [ -z "$ARG_READ" ] || continue
  # `update-pi --check` previews and writes nothing.
  if [ "$FOUND" = update-pi ] && [[ $TAIL =~ $CHECK_RE ]]; then
    continue
  fi
  if [ "$FOUND" = updates ] && [ -z "$ARG_APPLY" ]; then
    continue
  fi
  # `--project-path PATH` names the checkout the write lands in. This guard
  # exists because that directory could not be read from the command; named
  # there, it can, and the write goes to the project the words carry however
  # the shell moved. Only `refresh`, `apply` and `updates --apply` take the
  # flag; every other writing verb has no such form and stays refused.
  verb_kind "$FOUND"
  case "$KIND" in
    target) [ -z "$ARG_TARGET" ] || continue ;;
    pi | typed) ;;
  esac
  [ "$ARG_SCOPE" != global ] || continue
  if [ -n "$MOVED" ]; then
    VERB=$FOUND
    refuse moved "$VERB"
  fi
  WRITES=$WRITES$FOUND$NL
done <<EOF
$SEGMENTS
EOF
if [ -z "$WRITES" ]; then
  exit 0
fi

# The tool call's directory wins over the session directory: Codex sends
# `tool_input.workdir`, other harnesses can send `tool_input.cwd`, and the
# payload `cwd` remains the fallback. A carrier with none uses the directory
# where the hook runs.
# The assignment stands inside the condition: bare, its own status would end
# the script under errexit and the empty-cwd test below would never run.
if ! CWD=$(printf '%s' "$INPUT" \
  | jq -r 'if .tool_input.workdir != null then .tool_input.workdir
           elif .tool_input.cwd != null then .tool_input.cwd
           elif .cwd != null then .cwd
           else "" end
           | if type == "string" then . else error end' 2>/dev/null); then
  refuse payload invalid-cwd
fi
[ -n "$CWD" ] || CWD=$PWD

# Git answers for the directory itself: the redirect variables that would make
# it answer for another repository are dropped, as kendex drops them, and its
# messages are read in English.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_CEILING_DIRECTORIES
export LC_ALL=C
# Outside a repository there is no worktree to protect and kendex answers for
# itself. Git names that case with a parenthetical on the parents it searched
# (the parent directories, or the parents up to a mount point); a `.git` file
# that points nowhere gets the same words without it, and that is a repository
# git could not read, not the absence of one. Any other failure is a git that
# could not answer, and an unanswered question refuses. The answer is read
# from stdout alone; the reason for a failure is read from stderr only once
# there is one, so tracing git cannot turn an answer into a refusal.
if ! DIRS=$(git -C "$CWD" rev-parse --git-dir --git-common-dir 2>/dev/null); then
  REASON_STATUS=0
  REASON=$(git -C "$CWD" rev-parse --git-dir --git-common-dir 2>&1 >/dev/null) || REASON_STATUS=$?
  case "$REASON" in
    *"not a git repository (or any"*)
      # Git says the same words above a `.git` entry it could not read as
      # above none at all. A `.git` on the way up is a repository that could
      # not be read, and the write is refused; none is the absence.
      AT=$(cd -- "$CWD" 2>/dev/null && pwd -P) || AT=$CWD
      while :; do
        if [ -e "$AT/.git" ] || [ -L "$AT/.git" ]; then
          refuse git unreadable
        fi
        [ "$AT" != / ] || exit 0
        AT=${AT%/*}
        [ -n "$AT" ] || AT=/
      done
      ;;
  esac
  # The status git left is the value: it is what separates a repository git
  # refused to read from a directory it could not reach.
  refuse git "$REASON_STATUS"
fi
GIT_DIR_LINE=${DIRS%%$'\n'*}
COMMON_DIR_LINE=${DIRS#*$'\n'}
# Both answers are relative to CWD when git prints them short; resolving each
# to a physical path is what lets the comparison hold across symlinked roots.
# cd's own words come back in place of the path when it cannot enter one, so
# the caller has the cause to replay under its keyed line rather than leaving
# cd to write ahead of it.
resolve() { # PATH -> physical path, or cd's words on failure
  case "$1" in
    /*) (cd -- "$1" 2>&1 && pwd -P) ;;
    *) (cd -- "$CWD/$1" 2>&1 && pwd -P) ;;
  esac
}
if ! GIT_DIR=$(resolve "$GIT_DIR_LINE"); then
  refuse git unresolvable "$GIT_DIR"
elif ! COMMON_DIR=$(resolve "$COMMON_DIR_LINE"); then
  refuse git unresolvable "$COMMON_DIR"
fi
if [ "$GIT_DIR" = "$COMMON_DIR" ]; then
  exit 0
fi

# Whose project a bare verb typed here writes, asked as kendex asks it. The
# project is the first directory up from the physical working directory
# that `crates/core/src/discover.rs::project_root_from` takes for a root: one
# holding one of that file's markers, listed here in the same spelling. Its
# refusal of the home directory is not repeated, since a walk bounded by a
# worktree's root does not reach the home directory from below it. The walk
# stops at the linked worktree's root, since a project above it is not the
# worktree's own. The file that declares the project follows kendex's rule,
# `crates/core/src/manifest/file.rs::project_manifest_path`: kendex-local.toml
# for a source catalog, kendex.toml otherwise. This hook does not parse TOML,
# so any readable kendex.toml whose text names `is_source_catalog` counts as
# a catalog: every file kendex reads as one is among them, and a file this
# misreads is refused, never passed. Where that file exists in the worktree
# the project is the worktree's own, and the verbs that write one project by
# being typed inside it write that one. The file is not otherwise read: one
# that will not parse is still this project's, and kendex reports it before
# it writes. Where it does not exist, or no project is found inside the
# worktree, the declarations are the main checkout's, which the refusal
# points at. The main checkout is not derived from the common dir, which a
# repository made with --separate-git-dir keeps outside its checkout;
# `git worktree list` names the checkout first.
MARKER_DIRS=(.claude .codex .opencode .cursor .pi .agents .gemini)
MARKER_FILES=(kendex.toml .kendex-lock.json .mcp.json opencode.json opencode.jsonc .github/copilot-instructions.md)
is_project_root() { # DIR -> 0 where kendex takes DIR for a project root
  local marker
  for marker in "${MARKER_DIRS[@]}"; do
    [ ! -d "$1/$marker" ] || return 0
  done
  for marker in "${MARKER_FILES[@]}"; do
    [ ! -f "$1/$marker" ] || return 0
  done
  return 1
}
# A file that cannot be read is no source catalog, as kendex reads it; one
# that stops reading part-way counts as one.
declares_catalog() { # KENDEX_TOML -> 0 where its text names is_source_catalog
  local text
  [ -r "$1" ] || return 1
  text=$(cat -- "$1" 2>/dev/null) || return 0
  case "$text" in
    *is_source_catalog*) return 0 ;;
  esac
  return 1
}
if ! TOP=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null); then
  TOP_STATUS=0
  REASON=$(git -C "$CWD" rev-parse --show-toplevel 2>&1 >/dev/null) || TOP_STATUS=$?
  refuse git "$TOP_STATUS"
fi
if ! TOP=$(resolve "$TOP"); then
  refuse git unresolvable "$TOP"
elif ! AT=$(cd -- "$CWD" 2>&1 && pwd -P); then
  refuse git unresolvable "$AT"
fi
PROJECT=""
while :; do
  if is_project_root "$AT"; then
    PROJECT=$AT
    break
  fi
  [ "$AT" != "$TOP" ] && [ "$AT" != / ] || break
  AT=${AT%/*}
  [ -n "$AT" ] || AT=/
done
case "$PROJECT/" in
  "$TOP"/*) ;;
  *) PROJECT="" ;;
esac
MANIFEST=kendex.toml
OWNER=main
if [ -n "$PROJECT" ]; then
  if declares_catalog "$PROJECT/kendex.toml"; then
    MANIFEST=kendex-local.toml
  fi
  if [ -e "$PROJECT/$MANIFEST" ] || [ -L "$PROJECT/$MANIFEST" ]; then
    OWNER=worktree
  fi
else
  PROJECT=$TOP
fi
# A project that owns its manifest is the one a bare verb typed there
# writes, whole-scope writers included, so the target is unambiguous and
# nothing is refused; update-pi runs in a worktree only at the global scope.
while IFS= read -r VERB; do
  [ -n "$VERB" ] || continue
  verb_kind "$VERB"
  case "$OWNER:$KIND" in
    worktree:typed | worktree:target) ;;
    worktree:pi | main:target | main:pi | main:typed) refuse refused "$VERB" ;;
  esac
done <<EOF
$WRITES
EOF
