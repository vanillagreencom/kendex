#!/usr/bin/env bash
# ---
# name: command-safety
# event: PreToolUse
# matcher: Bash
# description: On harnesses that execute hooks, refuse shell tool command text matching COMMAND_SAFETY_DENY_PATTERN from project settings. An absent setting applies the shipped host-safety pattern, which refuses a systemd-run memory cap measured in kilobytes or megabytes; an explicit `^$` turns matching off, while unreadable input or settings still refuse. Matching is textual, including quoted text, and does not inspect the desktop or running processes.
# summary: Refuses shell commands matching a project's deny pattern, a kilobyte or megabyte systemd-run memory cap by default, and every command while its settings file cannot be read.
# safety: When executed, blocks command text matching the project's policy, or the shipped default where the project sets none, before the shell tool runs. Unreadable input, missing settings support, unreadable project settings (even where the unreadable part is a key this hook does not read), and invalid or explicitly empty patterns refuse execution. Every refusal opens with `command-safety: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
# timeout: 10
# requires-skills: [commit-guards]
# ---

set -euo pipefail

# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `command-safety: <key>=<value>`: a
# stable key for the condition and the value acted on — the missing tool, why
# the payload could not be read, the state of the project policy, or the exit
# status of a check that did not complete. The English explanation follows it.
# The keyed line stands first, at position 1. What a command this hook runs
# wrote is captured where the hook reads it and passed here as the cause, so
# it is replayed under the key rather than ahead of it.
# The EXIT trap below calls this, so the whole message is one group that
# cannot carry a failure out: a write that fails there would leave with the
# writer's status rather than the refusal's, which the harness runs past.
refuse() { # KEY VALUE [CAUSE]
  {
    printf 'command-safety: %s=%s\n' "$1" "$2"
    case "$1=$2" in
      missing-tools=*) echo "the commands ${2//,/, } are required and are not on PATH" ;;
      payload=unreadable) echo "the hook input could not be read" ;;
    cwd=*) echo "the working directory $2 could not be entered" ;;
      payload=invalid-json) echo "the hook input is not valid JSON, or names no command this hook can read" ;;
      payload=invalid-cwd) echo "the payload's working directory is not a string" ;;
        git=unreadable) echo "the Git working directory could not be resolved" ;;
      hook=unlocatable) echo "this hook's own directory could not be read, so its installed dependencies cannot be found" ;;
      settings=no-loader) echo "the command-safety bundle requires the installed commit-guards settings loader" ;;
      settings=unreadable) echo "the project settings could not be read, so COMMAND_SAFETY_DENY_PATTERN is unknown; the loader's line below names what to fix" ;;
      settings=empty) echo "COMMAND_SAFETY_DENY_PATTERN must be configured" ;;
      settings=invalid-pattern) echo "COMMAND_SAFETY_DENY_PATTERN is not a readable POSIX ERE" ;;
      refused=policy) echo "the command text matches this project's COMMAND_SAFETY_DENY_PATTERN" ;;
      refused=default-policy)
        echo "the command text sets a systemd-run MemoryMax= or MemoryHigh= cap in kilobytes or megabytes, which the hook's default COMMAND_SAFETY_DENY_PATTERN refuses: a cgroup starved by a cap that small can fail a kernel allocation and leave the host's root volume read-only"
        echo "run it with no memory cap, or with a cap in gigabytes; text that only mentions such a cap goes in a file, because matching reads the command text"
        echo "a project that wants another policy sets COMMAND_SAFETY_DENY_PATTERN in kendex.settings.toml [env] to replace the default, and the value \"^\$\" turns matching off" ;;
      exit=*) echo "the command safety check could not complete" ;;
    esac
    # The cause a command this hook ran wrote, captured at the site and
    # replayed here: under the keyed line, never ahead of it.
    [ -z "${3:-}" ] || printf '%s\n' "$3"
  } >&2 || :
  exit 2
}
# An exit that is neither a verdict (0) nor a refusal (2) is a check that did
# not complete, and it leaves as a refusal. The EXIT trap is what reaches every
# such exit on Bash 3.2 too: an ERR trap inherited through `set -E` fires there
# inside a command substitution even when the substitution stands on the left
# of `||`, which reads the settings loader's guarded probes as failures.
trap 'rc=$?; case $rc in 0 | 2) ;; *) refuse exit "$rc" ;; esac' EXIT
MISSING=""
for dependency in jq git grep cat dirname; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"
input="$(cat 2>&1)" || refuse payload unreadable "$input"
command_text="$(jq -r '
  def command_arg:
    if type == "object" then (.command // .cmd)
    elif type == "string" then
      (try fromjson catch null)
      | if type == "object" then (.command // .cmd) else null end
    else null end;
  [.tool_input.command, .tool_input.cmd, (.toolArgs | command_arg), .command, .cmd]
  | map(select(. != null))
  | if length == 0 then error("missing command") else .[0] end
  | if type == "string" then .
    elif type == "array" and all(.[]; type == "string") then join(" ")
    else error("invalid command") end
' <<<"$input" 2>/dev/null)" || refuse payload invalid-json
[ -n "$command_text" ] || exit 0
cwd="$(jq -r 'if .cwd == null then "" elif .cwd | type == "string" then .cwd else error("invalid cwd") end' <<<"$input" 2>/dev/null)" || refuse payload invalid-cwd
[ -n "$cwd" ] || cwd="$PWD"
# The requested path is kept: the substitution below holds cd's own words when
# the directory cannot be entered, and the physical path when it can, so the
# refusal names the path it was asked for and replays the cause under it.
requested_cwd="$cwd"
cwd="$(cd -- "$cwd" 2>&1 && pwd -P)" || refuse cwd "$requested_cwd" "$cwd"
# git's words come back in place of the path when it cannot answer, so the
# refusal below has the cause to replay: which .git entry it could not read.
root_status=0
root="$(git -C "$cwd" rev-parse --show-toplevel 2>&1)" || root_status=$?
if [ "$root_status" -ne 0 ]; then
  at="$cwd"
  while [ "$at" != / ]; do
    if [ -e "$at/.git" ] || [ -L "$at/.git" ]; then
      refuse git unreadable "$root"
    fi
    at="${at%/*}"
    [ -n "$at" ] || at=/
  done
  exit 0
fi

lib=
hook_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || refuse hook unlocatable
at="$hook_dir"
levels=0
# Registered hook layouts keep the scope's skills one or two directories
# above hooks. A wider walk can reach executable files outside the install.
while [ "$levels" -lt 3 ] && [ "$at" != "$root" ] && [ "$at" != / ]; do
  candidate="$at/skills/commit-guards/scripts/lib"
  if [ -e "$candidate/common.sh" ] || [ -L "$candidate/common.sh" ] \
    || [ -e "$candidate/settings.sh" ] || [ -L "$candidate/settings.sh" ]; then
    lib="$candidate"
    break
  fi
  at="${at%/*}"
  [ -n "$at" ] || at=/
  levels=$((levels + 1))
done
if [ -z "$lib" ]; then
  case "$hook_dir" in
    "$root"/*) lib="$root/.agents/skills/commit-guards/scripts/lib" ;;
  esac
fi
[ -f "$lib/common.sh" ] && [ -f "$lib/settings.sh" ] || refuse settings no-loader
GG_CHECK=command-safety
# shellcheck source=../skills/commit-guards/scripts/lib/common.sh
source "$lib/common.sh"
# shellcheck source=../skills/commit-guards/scripts/lib/settings.sh
source "$lib/settings.sh"
# cd runs twice on purpose: a substitution cannot move this shell, so the
# probe is what carries the cause into the refusal and the second one is the
# move. The second failure is unreachable in practice — the probe just
# succeeded — and refuses without a cause rather than not at all.
if ! ROOT_ERR=$( (cd -- "$root") 2>&1 ); then
  refuse cwd "$root" "$ROOT_ERR"
fi
cd -- "$root" || refuse cwd "$root"
# The loader's diagnostic is captured, not left to precede the refusal: on
# failure the substitution holds the loader's keyed line — for a value in
# another shape, the file, the line and the key — and a successful read is
# silent, so the pattern is not mixed with a diagnostic.
# A malformed value on a key this hook never reads still refuses: the loader
# judges the [env] table whole, as every kendex settings reader does, so a
# policy read past the bad line would come from a file the rest of the
# toolchain rejects. The replayed line names what to fix, so the caller can
# clear the refusal.
# The default is the host-safety rule every install gets: a systemd-run memory
# cap in K or M starved a build's cgroup into a kernel allocation failure that
# left a host's root volume read-only. skills/commit-guards'
# kendex.settings.toml.example declares the same value.
default_pattern='(^|[^[:alnum:]_-])systemd-run[[:space:]][^&;|]*Memory(Max|High)=[[:punct:]]?[0-9]+[KkMm]([^[:alnum:]]|$)'
pattern="$(gg_setting COMMAND_SAFETY_DENY_PATTERN "$default_pattern" 2>&1)" || refuse settings unreadable "$pattern"
[ -n "$pattern" ] || refuse settings empty
[ "$pattern" != '^$' ] || exit 0
status=0
# Shell line continuations can split a denied command or token. Keep the raw
# text too: single quotes preserve backslash-newline pairs as literal text.
# Bash 3.2 needs ANSI-C quoting expanded before the replacement pattern.
continuation=$'\\\n'
joined_command_text="${command_text//"$continuation"/}"
# grep's words on a pattern it cannot read are captured: stderr becomes the
# substitution's stdout and grep's own stdout is discarded, so the status still
# decides and the cause reaches the refusal below its keyed line.
GREP_ERR=$(printf '%s\n' "$command_text" "$joined_command_text" | LC_ALL=C grep -E -- "$pattern" 2>&1 >/dev/null) || status=$?
case "$status" in
  0)
    # The default's reason and remedy are known here; a project pattern's are
    # its own. A project that sets the default's own value refuses for the
    # default's reason, so it gets the default's text.
    if [ "$pattern" = "$default_pattern" ]; then
      refuse refused default-policy
    fi
    refuse refused policy
    ;;
  1) exit 0 ;;
  *) refuse settings invalid-pattern "$GREP_ERR" ;;
esac
