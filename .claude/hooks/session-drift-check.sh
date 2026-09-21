#!/usr/bin/env bash
# ---
# name: session-drift-check
# event: SessionStart
# description: On a fresh session start (not resume or compact), runs `kendex check --quiet` and surfaces kendex drift to the agent — outdated items (`kendex refresh`), items removed upstream (`kendex remove <name>`, `-g` in a global section), unreachable sources, and packages not yet evaluated against their sources (a background refresh settles them). Prints nothing when the install is current. When the kendex command is absent it says so with what that costs: which manifest file this project's declarations live in and what became of reading it, how many packages and bundles it declares, how the command is installed on this platform, that the user decides whether to install it before any workflow runs here, and that the files kendex renders whole are never hand-edited — the notice names the trees they are under, and every other tree kendex renders into is covered with them — while a harness's own settings file it writes one key in keeps every key it did not write. KENDEX_DRIFT_HOOK=off disables it. Not run on pi: the pi-hooks carrier runs its own drift report at session start. Not run on antigravity: it has no SessionStart event.
# summary: Tells a coding agent at the start of a session which installed packages no longer match their source, and what to run about it. Says nothing when everything matches.
# safety: Installs nothing and removes nothing, and never touches the project's git state. One write it may make in the project: where a declaration in kendex.toml sits on files no install record accounts for, the check plans the scope inside the budget this hook allows and, for each copy that is its source's render byte for byte, writes the scope's install record — the committed `.kendex-lock.json` and its machine half under `.cache/kendex/` — under kendex's scope write locks, recovering a pending apply journal first and leaving that record uncommitted for the next commit offer; a copy that differs is reported, never replaced. The plan is paid for once per state and memoized under kendex's own cache directory; a plan past the budget is reported as not checked and finished by the detached background process. The check never waits on the network; the rest of what it may write is kendex's own cache bookkeeping under ~/.kendex/cache (fetch stamps, snapshots, that memo), and when a source cache there is older than its TTL, a detached background process refreshes it (git fetch + reset, confined to that cache) and this hook does not wait for it. Every suggestion requires user approval before acting. Every notice opens with `session-drift-check: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key. `kendex check`'s own report is relayed on stdout under those lines, preserved exactly; which arm its exit code chose is a value on them, not a sentence in it.
# timeout: 30
# harnesses: [claude, codex, gemini, copilot, opencode, cursor]
# ---

# Strict, and a session must still start no matter what this hook hits: every
# command that can legitimately fail is guarded so this always reaches exit 0.
set -euo pipefail

# What the notice reads, each under its own name: kendex's report and the
# status it left, and the line an unguarded failure reached. A positional
# detail would mean a status to one caller and a line number to another, and a
# value whose meaning depends on the caller is not a stable value.
OUTPUT=""
RC=0
FAILED_LINE=""
PAYLOAD_ERR=""
PATH_ERR=""
# What the missing-kendex notice names: the manifest file this project's
# declarations would be in and what became of reading it, how many packages
# that read found, the route that installs the command on this platform, and
# the trees nothing may hand-edit. Each is settled at its own site below.
MANIFEST_FILE=""
MANIFEST_STATE=""
PKG_COUNT=""
INSTALL_ROUTE=""
# The harness trees a session must never edit by hand. This is
# `crates/core/src/discover.rs::MARKER_DIRS`, the dot-dirs kendex both finds a
# project by and renders into, spelled as directories;
# `tests/session-drift-check.test.sh` reads MARKER_DIRS out of that file and
# holds this value to it. It is the whole enumeration the notice carries, and
# it is not every tree kendex renders into — `.github/` is one MARKER_DIRS
# leaves out, because that directory marks nearly every repository — so the
# sentence carrying it says so rather than listing the rest by hand.
NEVER_EDIT=".agents/,.claude/,.codex/,.pi/,.gemini/,.opencode/,.cursor/"
# The tables a declaration is written in, which is what `packages=` counts.
# It mirrors `crates/core/src/manifest/validate/items.rs::ITEM_TABLES` plus
# `plugins`, which that list leaves out only because a plugin carries an
# enabled flag instead of a source; it is a declared install like any other.
# `tests/session-drift-check.test.sh` reads ITEM_TABLES out of that file and
# holds this list to it, so a kind added in Rust reddens this hook's suite.
COUNTED_KINDS="agents skills hooks commands mcp-servers pi-extensions bundles plugins"

# The project's declared packages and bundles, counted where kendex itself
# cannot be asked: the command is the manifest's parser, and the command is
# what is missing. Read with shell builtins alone — a notice about a deficient
# PATH must not need more of it, and a missing grep reported as a missing
# manifest would name the wrong cause. One declaration is one `[<kind>.<name>]`
# table written at the start of its line, its kind in COUNTED_KINDS and its
# name a single key; this counts those headers rather than standing up a second
# TOML reader. A source catalog publishes its kendex.toml as a definition and
# keeps its own install state in the sibling file, the rule
# crates/core/src/manifest/file.rs::project_manifest_path states.
manifest_facts() { # sets MANIFEST_FILE, MANIFEST_STATE, PKG_COUNT; empty count is unknown
  local line count=0 header kind name
  MANIFEST_FILE="kendex.toml"
  if [ -r kendex.toml ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        is_source_catalog[[:space:]]*=*true* | is_source_catalog=*true*)
          MANIFEST_FILE="kendex-local.toml"
          break
          ;;
        # A top-level key stands above the first table header
        # (crates/core/src/manifest/file.rs reads it off the root table), so
        # once a header is reached there is nothing left here to find.
        "["*) break ;;
      esac
    done <kendex.toml
  fi
  # A manifest that is absent and one that cannot be opened are different
  # facts, and only the second is a read failure. Neither yields a count — a
  # zero would read as a project that declares nothing — so the state is what
  # the notice matches on. MANIFEST_FILE stands in every case: it is the file
  # this project's manifest would be, and each sentence names it.
  if [ ! -r "$MANIFEST_FILE" ]; then
    if [ -e "$MANIFEST_FILE" ]; then
      MANIFEST_STATE="unreadable"
    else
      MANIFEST_STATE="absent"
    fi
    return 0
  fi
  MANIFEST_STATE="read"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "["*"."*) ;;
      *) continue ;;
    esac
    header="${line#[}"
    header="${header%%]*}"
    kind="${header%%.*}"
    name="${header#*.}"
    # Exactly one key after the kind. A second dot opens a sub-table of a
    # declaration — a hook's `[hooks.<name>.env]`, the environment table
    # docs/adapters/README.md describes — and that is not a second
    # declaration. A quoted name is one key however it is spelled, which is
    # how `[plugins."<name>@<market>"]` arrives: `@` is not a bare key
    # character, so the serializer quotes the whole name.
    case "$name" in
      '"'*'"' | "'"*"'") ;;
      *.*) continue ;;
    esac
    case " $COUNTED_KINDS " in
      *" $kind "*) count=$((count + 1)) ;;
    esac
  done <"$MANIFEST_FILE"
  PKG_COUNT="$count"
  return 0
}

# How the kendex command is installed here. OSTYPE is bash's own, set at
# startup and kept when the environment already carries one, so this reads
# nothing off PATH either.
install_route() { # sets INSTALL_ROUTE
  case "${OSTYPE:-}" in
    msys* | cygwin* | win32) INSTALL_ROUTE="https://kendex.ai/download" ;;
    *) INSTALL_ROUTE="curl -fsSL https://kendex.ai/install.sh | sh" ;;
  esac
}

# The skipped-for-a-missing-tool sentence, which both missing-tools arms end
# up writing: one spelling, so the two cannot drift apart.
missing_tools_line() { # COMMA-LIST
  printf 'kendex drift check skipped: %s is not on PATH\n' "${1//,/, }"
}

# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `session-drift-check: <key>=<value>`: a
# stable key for the condition and the value acted on — the missing tool, the
# unreachable project directory, what became of the check, or the status an
# unguarded command left. The English explanation and kendex's own report
# follow it. Every line goes to stdout, the session-start context channel.
# The keyed line stands first, at position 1, and every line this function
# writes goes to stdout: this hook has no stderr channel, and nothing it runs
# leaves a cause for it to replay — kendex's report is data it relays, not a
# diagnostic.
notice() { # KEY VALUE
  printf 'session-drift-check: %s=%s\n' "$1" "$2"
  case "$1=$2" in
    missing-tools=kendex)
      # Without the command nothing here can be checked, refreshed or
      # removed, so the notice carries what the session needs to decide what
      # to do about it: what this project has riding on kendex, how the
      # command is installed, and which trees stay generated either way. Each
      # is a value on a keyed line, because a state, a count, a route and a
      # directory list read out of prose are read differently by every reader.
      # `manifest=` and `manifest-file=` stand beside the count because they
      # are what the count means: both states that yield no count report
      # `packages=unknown`, and only those lines tell a read failure from a
      # project that has no manifest, and say which file was looked for —
      # kendex.toml for a plain project, kendex-local.toml for a catalog.
      printf 'session-drift-check: manifest=%s\n' "$MANIFEST_STATE"
      printf 'session-drift-check: manifest-file=%s\n' "$MANIFEST_FILE"
      printf 'session-drift-check: packages=%s\n' "${PKG_COUNT:-unknown}"
      printf 'session-drift-check: install=%s\n' "$INSTALL_ROUTE"
      printf 'session-drift-check: never-edit=%s\n' "$NEVER_EDIT"
      missing_tools_line "$2"
      # One judge for one question: manifest_facts settled which of the three
      # states this project is in, and each writes its own sentence. Each names
      # the file it settled on, which is kendex.toml for a plain project and
      # kendex-local.toml for a source catalog; a sentence saying only "the
      # manifest" would be false for one of them either way.
      case "$MANIFEST_STATE" in
        read)
          printf 'This project declares %s kendex package(s) or bundle(s) in %s. Without the kendex command none of them can be checked, refreshed or removed, and drift here goes unseen.\n' \
            "$PKG_COUNT" "$MANIFEST_FILE"
          ;;
        unreadable)
          printf 'This project has a %s, but it could not be opened, so how many packages it declares is unknown.\n' "$MANIFEST_FILE"
          ;;
        # `absent`, the third and last state manifest_facts sets.
        *)
          printf 'This project has no %s, so it declares no kendex packages of its own.\n' "$MANIFEST_FILE"
          ;;
      esac
      printf 'Install the kendex command on this platform with: %s\n' "$INSTALL_ROUTE"
      echo "Ask the user whether to install kendex before running any workflow in this project."
      printf 'Never hand-edit the files kendex renders whole under %s, or under any other tree it renders into: kendex writes those files end to end from their package sources, and the next apply or refresh overwrites every edit. Change the source package instead.\n' \
        "${NEVER_EDIT//,/, }"
      echo "A harness's own settings or configuration file, such as .claude/settings.json, is the exception: kendex writes its own keys there and every key it did not write stays intact, so a hand edit to one of those survives."
      ;;
    missing-tools=*) missing_tools_line "$2" ;;
    payload=invalid-json) echo "kendex drift check skipped: the session payload is not valid JSON" ;;
    payload=unreadable)
      echo "the session payload could not be read; the drift report below stands on its own"
      printf '%s\n' "$PAYLOAD_ERR"
      ;;
    path=*)
      printf 'kendex check could not run: project directory %s is not accessible; drift status unknown\n' "$2"
      printf '%s\n' "$PATH_ERR"
      ;;
    drift=found) printf '%s\n' "$OUTPUT" ;;
    check=could-not-run)
      # The status kendex left is a value, not a number inside a sentence: the
      # arm this hook chose and the code it chose it from are both parsed off
      # keyed lines, and the English below says the same for a person. The
      # exit-2 arm with nothing to relay is the one line that ends without a
      # colon; every other rendering of this notice, the embedded hook in
      # crates/core/src/drift/hook.rs and the Pi extension included, prints the
      # colon and the report under it, a blank line where there is none.
      printf 'session-drift-check: exit=%s\n' "$RC"
      printf 'kendex check could not run (exit %s); drift status unknown' "$RC"
      if [ "$RC" = 2 ] && [ -z "$OUTPUT" ]; then
        printf '\n'
      else
        printf ':\n%s\n' "$OUTPUT"
      fi
      ;;
    check=incomplete)
      printf 'session-drift-check: exit=%s\n' "$RC"
      printf 'kendex check incomplete (exit %s); some drift status unknown:\n%s\n' "$RC" "$OUTPUT"
      ;;
    exit=*)
      # Two facts, two keys: what the failure left, and where it reached.
      printf 'session-drift-check: line=%s\n' "$FAILED_LINE"
      printf 'kendex check could not run: drift hook failed at line %s (exit %s); drift status unknown\n' "$FAILED_LINE" "$2"
      ;;
  esac
  return 0
}

# Reaching this trap means an UNGUARDED command failed. Say so: an unexpected
# failure that printed nothing would read as a clean install.
# $LINENO means the failing line only where the trap reads it, so the trap is
# what records it.
trap 'rc=$?; FAILED_LINE=$LINENO; notice exit "$rc"; exit 0' ERR

# cat's own words are captured, not left to reach a stream this hook does not
# write: a session must start either way, so the read failure is reported under
# its own key on stdout and the check runs on.
INPUT=$(cat 2>&1) || { PAYLOAD_ERR="$INPUT"; INPUT=""; }

if [ "${KENDEX_DRIFT_HOOK:-}" = "off" ]; then
  exit 0
fi
# After the switch, so `off` silences this too.
[ -z "$PAYLOAD_ERR" ] || notice payload unreadable

# Fresh starts only. Claude Code sends source startup|resume|clear|compact;
# a resumed or compacted session already carries the report, and a per-compact
# rerun is the wallpaper this hook must not become.
#
# The payload is JSON and jq is the only thing that reads it: the key is the
# TOP-LEVEL `source`, and a text scan for it finds the same key nested in any
# other object, or the same characters inside an unrelated string value — a
# transcript path or a cwd is enough. Without jq the payload is unread, and an
# unread payload cannot be shown to be a fresh start, so the report is skipped
# rather than repeated on every compact.
if ! command -v jq >/dev/null 2>&1; then
  notice missing-tools jq
  exit 0
fi
if ! SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // ""' 2>/dev/null); then
  notice payload invalid-json
  exit 0
fi
case "$SOURCE" in
  resume|compact)
    exit 0
    ;;
esac

# Claude Code exports the project root; other harnesses launch the hook in it.
# Enter it separately so only kendex's own exit code drives classification.
# `--` so a directory whose name starts with a dash is a path, not an option.
# Entered before the binary is looked for, because a missing binary is
# reported against this project's manifest and that is read from here.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
# The probe carries cd's words into the notice; a substitution cannot move
# this shell, so the second cd is the move and the first is the cause.
if ! PATH_ERR=$( (cd -- "$PROJECT_DIR") 2>&1 ); then
  notice path "$PROJECT_DIR"
  exit 0
fi
cd -- "$PROJECT_DIR" || { notice path "$PROJECT_DIR"; exit 0; }

# The hook only exists because kendex installed it, so a missing binary is
# almost always a PATH gap — never a blocker. It is still the end of every
# kendex operation in this project, so the notice says what is at stake and
# what installs the command.
if ! command -v kendex >/dev/null 2>&1; then
  manifest_facts
  install_route
  notice missing-tools kendex
  exit 0
fi

# kendex's exit code IS the classification; under errexit a bare failing
# assignment would abort before `RC=$?` could run.
OUTPUT=$(kendex check --quiet 2>&1) || RC=$?

case "$RC" in
  0)
    exit 0
    ;;
  1)
    # Drift found, or packages awaiting evaluation.
    notice drift found
    ;;
  2)
    # kendex could not check, in part or at all. A report carrying a
    # "could not check" section checked everything else and says what it
    # could not; it is printed as incomplete, never as a crash. Output
    # that opens with kendex's own Error: line or clap's usage error:
    # comes from before the check read anything, so nothing was checked
    # and it reads as could-not-run.
    case "$OUTPUT" in
      "" | Error:* | error:*) notice check could-not-run ;;
      *) notice check incomplete ;;
    esac
    ;;
  *)
    # Anything else is not a kendex verdict: a signal, a timeout, a
    # binary that could not start.
    notice check could-not-run
    ;;
esac

exit 0
