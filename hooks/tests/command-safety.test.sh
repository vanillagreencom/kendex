#!/usr/bin/env bash
# Tests for the fixed environment refusal and the project's
# COMMAND_SAFETY_DENY_PATTERN, or its own default_pattern where the project
# sets none; this suite owns that default's rows. Every refusal opens with
# `command-safety: <key>=<value>` — the key naming the condition, the value
# naming the state of the policy or the status a check left. `check` asserts
# the exit status of a row; `assert_first` pins the line the refusal opened
# with, which is what a reader parses.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
common_git="$(git -C "$ROOT" rev-parse --git-common-dir)" || exit 1
case "$common_git" in /*) ;; *) common_git="$ROOT/$common_git" ;; esac
scratch_parent="$(cd -- "$common_git/.." && pwd -P)" || exit 1
mkdir -p "$scratch_parent/tmp"
# HOOK_UNDER_TEST overrides the hook each fixture installs, so a must-fail
# control runs against these same assertions.
hook_source="${HOOK_UNDER_TEST:-$ROOT/hooks/command-safety.sh}"
scratch="$(mktemp -d "$scratch_parent/tmp/command-safety-test.XXXXXX")" || { echo 'command-safety-test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $scratch && ! -L $scratch ]] || { echo 'command-safety-test: scratch=not-a-directory' >&2; exit 1; }
scratch="$(cd -- "$scratch" && pwd -P)" || { echo 'command-safety-test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "$scratch"' EXIT
repo="$scratch/project"
mkdir -p "$repo/.claude/hooks" "$repo/.agents/skills/commit-guards/scripts"
git -C "$repo" init -q
git -C "$repo" config gc.auto 0
git -C "$repo" config maintenance.auto false
cp "$hook_source" "$repo/.claude/hooks/command-safety.sh"
cp -R "$ROOT/skills/commit-guards/scripts/lib" "$repo/.agents/skills/commit-guards/scripts/lib"
hook="$repo/.claude/hooks/command-safety.sh"
unset COMMAND_SAFETY_DENY_PATTERN COMMIT_GUARDS_SETTINGS_FILE

settings() { # [SOURCE_FILE]: the file whose one COMMAND_SAFETY_DENY_PATTERN line becomes the policy
  local source="${1:-$ROOT/docs/authoring/command-safety.md}"
  printf '[env]\n' >"$repo/kendex.settings.toml"
  awk '/^COMMAND_SAFETY_DENY_PATTERN = / { print; found++ } END { if (found != 1) { printf "%s: expected one COMMAND_SAFETY_DENY_PATTERN line, found %d\n", FILENAME, found > "/dev/stderr"; exit 1 } }' \
    "$source" >>"$repo/kendex.settings.toml"
}
settings
passed=0
failed=0
. "$ROOT/hooks/tests/lib/process-count.sh"
process_count_setup "$scratch"
process_count_reset
cost_payload=$(jq -nc --arg cwd "$repo" '{tool_input:{command:"git status"},cwd:$cwd}')
cost_status=0
env "PATH=$COUNT_BIN" "BASH_ENV=$COUNT_TRACE" "PROCESS_COUNT_LOG=$COUNT_LOG" "$BASH" "$hook" \
  <<<"$cost_payload" >"$scratch/cost.out" 2>"$scratch/cost.err" || cost_status=$?
jq_count=$(process_count_command jq)
printf 'cost command-safety jq=%s processes=%s\n' "$jq_count" "$(process_count_total)"
if [ "$cost_status" -eq 0 ] && [ "$jq_count" -eq 1 ]; then
  passed=$((passed + 1))
else
  printf 'FAIL payload read cost: exit=%s jq=%s\n' "$cost_status" "$jq_count"
  failed=$((failed + 1))
fi
if [ "${1:-}" = --cost-row ]; then
  [ "$failed" -eq 0 ]
  exit
fi
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  cost_mutant="$scratch/two-payload-reads.sh"
  [ ! -L "$hook_source" ] || exit 1
  awk '/^fields=.*jq -er / { print "jq -r empty <<<\"$input\" >/dev/null"; changed++ }
    { print } END { if (changed != 1) exit 1 }' "$hook_source" > "$cost_mutant" || exit 1
  cmp -s -- "$hook_source" "$cost_mutant" && exit 1
  control_status=0
  env -i "HOME=$HOME" "PATH=$PATH" "HOOK_UNDER_TEST=$cost_mutant" "$BASH" "${BASH_SOURCE[0]}" --cost-row \
    > "$scratch/two-reads.log" 2>&1 || control_status=$?
  if [ "$control_status" -eq 1 ] && grep -q '^FAIL payload read cost:' "$scratch/two-reads.log"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL duplicate payload read control: exit=%s\n' "$control_status"
  fi
fi
# `first` is line 1, the contract: the hook captures what a command it ran
# wrote and replays it under the keyed line, so nothing precedes the key.
# `cause` says whether that captured text is there. The reader is the shared
# one; this suite writes stderr somewhere of its own, so it passes the path.
first=-
# shellcheck source=lib/first-line.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/first-line.sh"
check() { # EXPECTED COMMAND LABEL [CWD] [HOOK]
  local expected="$1" command="$2" label="$3" payload_cwd="${4:-$repo}" payload_hook="${5:-$hook}" payload status=0 output
  payload="$(jq -nc --arg command "$command" --arg cwd "$payload_cwd" '{tool_input:{command:$command},cwd:$cwd}')"
  output="$(printf '%s' "$payload" | "$BASH" "$payload_hook" 2>"$scratch/stderr")" || status=$?
  first="$(first_line "$scratch/stderr")"
  cause="$(cause_below "$scratch/stderr")"
  if [ "$status" -eq "$expected" ]; then
    printf 'PASS %s\n' "$label"
    passed=$((passed + 1))
  else
    printf 'FAIL %s: exit %s, expected %s: %s%s\n' "$label" "$status" "$expected" "$output" "$(cat "$scratch/stderr")"
    failed=$((failed + 1))
  fi
}

assert_cause() { # WANT LABEL
  if [ "$cause" = "$1" ]; then
    printf 'PASS %s\n' "$2"
    passed=$((passed + 1))
  else
    printf 'FAIL %s: cause %s, expected %s\n' "$2" "$cause" "$1"
    failed=$((failed + 1))
  fi
}

# What a probe says here is what the hook must have replayed: the row runs
# the same command rather than pinning a wording, so it holds on any platform
# and on any version of the tool. `cause=present` cannot serve this — the
# hook's own English is also a line under line 1.
assert_replays() { # PROBE_OUTPUT LABEL
  if [ -z "$1" ]; then
    printf 'FAIL %s: the probe said nothing, so the row would pass on anything\n' "$2"
    failed=$((failed + 1))
    return
  fi
  case "$(cat "$scratch/stderr")" in
    *"$1"*)
      printf 'PASS %s\n' "$2"
      passed=$((passed + 1))
      ;;
    *)
      printf 'FAIL %s: the cause is not under the keyed line: %s\n' "$2" "$(cat "$scratch/stderr")"
      failed=$((failed + 1))
      ;;
  esac
}

assert_first() { # WANT LABEL
  if [ "$first" = "$1" ]; then
    printf 'PASS %s\n' "$2"
    passed=$((passed + 1))
  else
    printf 'FAIL %s: first line %s, expected %s\n' "$2" "$first" "$1"
    failed=$((failed + 1))
  fi
}

# KEN-3813 expressly requires this remedy example as well as the keyed
# verdict. The remaining English is not pinned. Every command below stays
# fixture data submitted only to the hook, including all planted controls.
# A JSON escape keeps the coprocess data word out of the Bash syntax lint.
environment_rows() {
  local row fields expected command_json label world payload payload_cwd status output payload_hook
  local want first_key invalid shape_kind before=$((passed + failed))
  mkdir -p "$scratch/policy-tools"
  for tool in jq cat; do ln -sf "$(command -v "$tool")" "$scratch/policy-tools/$tool"; done
  while IFS= read -r row; do
    fields=$(jq -r '[.[0], (.[1] | tojson), .[2], (.[3] // "project")] | @tsv' <<<"$row") || exit 1
    IFS=$'\t' read -r expected command_json label world <<<"$fields"
    printf -v command_json '%b' "$command_json"
    label="environment: $label"; payload_cwd=$repo; invalid=false; shape_kind=tool
    printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = "^$"\n' >"$repo/kendex.settings.toml"
    case "$world" in
      outside) payload_cwd=/ ;;
      gone) payload_cwd="$scratch/not-created" ;;
      invalid-cwd) invalid=true ;;
      bad-settings) printf '[env\n' >"$repo/kendex.settings.toml" ;;
      empty-pattern) printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = ""\n' >"$repo/kendex.settings.toml" ;;
      invalid-pattern) printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = "["\n' >"$repo/kendex.settings.toml" ;;
      absent-policy) rm -- "$repo/kendex.settings.toml" ;;
      absent-loader) mv "$repo/.agents/skills/commit-guards/scripts/lib" "$scratch/environment-loader" ;;
      cmd | copilot | copilot-string | top) shape_kind=$world ;;
    esac
    payload=$(jq -nc --argjson submitted "$command_json" --arg cwd "$payload_cwd" --argjson invalid "$invalid" --arg shape "$shape_kind" '
      {cwd:(if $invalid then 42 else $cwd end)} +
      (if $shape == "cmd" then {tool_input:{cmd:$submitted}}
       elif $shape == "copilot" then {toolArgs:{command:$submitted}}
       elif $shape == "copilot-string" then {toolArgs:({command:$submitted} | tojson)}
       elif $shape == "top" then {command:$submitted}
       else {tool_input:{command:$submitted}} end)') || exit 1
    status=0
    if [ "$world" = missing-policy-tools ]; then
      output=$(env "PATH=$scratch/policy-tools" "$BASH" "$hook" <<<"$payload" 2>"$scratch/stderr") || status=$?
    else
      output=$("$BASH" "$hook" <<<"$payload" 2>"$scratch/stderr") || status=$?
    fi
    [ "$world" != absent-loader ] || mv "$scratch/environment-loader" "$repo/.agents/skills/commit-guards/scripts/lib"
    first_key=$(first_line "$scratch/stderr")
    want=-; [ "$expected" -ne 2 ] || want='command-safety: refused=environment-dump'
    if [ "$status" -eq "$expected" ] && [ "$first_key" = "$want" ] && [ -z "$output" ]; then
      printf 'PASS %s\n' "$label"; passed=$((passed + 1))
    else
      printf 'FAIL %s: exit=%s expected=%s first=%s expected-first=%s stdout=[%s]\n' "$label" "$status" "$expected" "$first_key" "$want" "$output"
      failed=$((failed + 1))
    fi
    if [ "$expected" -eq 2 ]; then
      if grep -F -- "systemctl --user show-environment | grep '^NAME='" "$scratch/stderr" >/dev/null; then
        passed=$((passed + 1))
      else
        printf 'FAIL %s remedy: missing required filtered form\n' "$label"; failed=$((failed + 1))
      fi
    fi
  done <<'ENVIRONMENT_ROWS'
[2,"env","bare-env"]
[2,"printenv","bare-printenv"]
[2,"export -p","export-list"]
[2,"set","shell-state"]
[2,"declare -p","declare-print"]
[2,"declare -x","declare-export"]
[2,"typeset -x","typeset-export"]
[2,"systemctl show-environment","system-environment"]
[2,"systemctl --user show-environment","incident"]
[2,"cat /proc/self/environ","proc-cat"]
[2,"tr '\\0' '\\n' < /proc/self/environ","proc-tr"]
[2,"strings /proc/self/environ","proc-strings"]
[2,"xargs -0 < /proc/self/environ","proc-xargs"]
[2,"cat < /proc/self/environ","proc-cat-stdin"]
[2,"strings < /proc/self/environ","proc-strings-stdin"]
[2,"cat /proc/*/environ","proc-glob"]
[2,"cat /proc/$PID/environ","proc-literal-parts"]
[2,"env NAME=value","env-assignment-only"]
[2,"env -0","env-null"]
[2,"env --","env-options-end"]
[2,"env -- NAME=value","env-options-end-assignment"]
[2,"env -- NAME=value printenv","env-options-end-printenv"]
[2,"env -- NAME=value systemctl --user show-environment","env-options-end-systemctl"]
[2,"command env -- NAME=value printenv","command-env-options-end-dump"]
[2,"sudo env -- NAME=value printenv","sudo-env-options-end-dump"]
[0,"env -- NAME=value git status","env-options-end-launcher"]
[0,"env -- NAME=value printenv NAME","env-options-end-named"]
[2,"printenv --","printenv-options-end"]
[2,"printenv -0","printenv-null"]
[2,"printenv $NAME","unresolved-name"]
[2,"printenv \"$NAME\"","quoted-unresolved-name"]
[2,"export -px","combined-export-flags"]
[2,"declare -px","combined-declare-flags"]
[2,"typeset -p","typeset-print"]
[2,"systemctl --user show-environment NAME","systemctl-not-a-variable-read"]
[0,"env | grep NAME","bare-name-filter"]
[0,"env | grep '^NAME='","anchored-filter"]
[0,"env | grep -E '^(A|B)='","finite-filter"]
[0,"printenv | grep '^NAME='","printenv-filter"]
[0,"export -p | grep '^NAME='","export-filter"]
[0,"set | grep '^NAME='","set-filter"]
[0,"declare -p | grep '^NAME='","declare-print-filter"]
[0,"declare -x | grep '^NAME='","declare-export-filter"]
[0,"typeset -x | grep '^NAME='","typeset-filter"]
[0,"systemctl show-environment | grep '^NAME='","system-filter"]
[0,"systemctl --user show-environment | grep '^NAME='","session-filter"]
[2,"cat /proc/self/environ | grep '^NAME='","proc-cat-filter"]
[0,"tr '\\0' '\\n' < /proc/self/environ | grep '^NAME='","proc-tr-filter"]
[0,"strings /proc/self/environ | grep '^NAME='","proc-strings-filter"]
[2,"xargs -0 < /proc/self/environ | grep '^NAME='","proc-xargs-filter"]
[0,"cat /proc/self/environ | tr '\\0' '\\n' | grep '^NAME='","proc-conversion-filter"]
[0,"cat -- /proc/self/environ | tr '\\000' '\\n' | grep NAME","proc-options-end-conversion"]
[0,"cat < /proc/self/environ | tr '\\0' '\\n' | grep NAME","proc-stdin-conversion"]
[0,"strings < /proc/self/environ | grep NAME","strings-default-records"]
[0,"env -0 | tr '\\0' '\\n' | grep NAME","env-nul-conversion"]
[0,"printenv -0 | tr '\\0' '\\n' | grep NAME","printenv-nul-conversion"]
[2,"env -0 | grep NAME","env-raw-nul"]
[2,"printenv -0 | grep NAME","printenv-raw-nul"]
[2,"env | grep -z NAME","env-grep-nul-mode"]
[2,"printenv | grep -z NAME","printenv-grep-nul-mode"]
[2,"systemctl --user show-environment | grep -z NAME","session-grep-nul-mode"]
[2,"env | grep -a NAME","env-grep-text-mode"]
[2,"cat /proc/self/environ | grep -a NAME","proc-grep-text-mode"]
[2,"cat /proc/self/environ | grep -z NAME","proc-grep-nul-mode"]
[2,"xargs -0 < /proc/self/environ | grep NAME","xargs-flattened-records"]
[2,"xargs -0 < /proc/self/environ | tr '\\0' '\\n' | grep NAME","xargs-conversion-cannot-repair-records"]
[2,"cat -v /proc/self/environ | tr '\\0' '\\n' | grep NAME","cat-transformed-records"]
[2,"cat -A /proc/self/environ | tr '\\0' '\\n' | grep NAME","cat-all-transformations"]
[2,"cat -n < /proc/self/environ | tr '\\0' '\\n' | grep NAME","cat-numbered-records"]
[2,"cat /proc/$PID/environ | tr '\\0' '\\n' | grep NAME","proc-unresolved-path-framing"]
[2,"tr -d '\\0' < /proc/self/environ | grep NAME","tr-deleted-records"]
[2,"tr -d '\\0' < /proc/self/environ | tr '\\0' '\\n' | grep NAME","tr-conversion-cannot-repair-records"]
[2,"strings -s ' ' /proc/self/environ | grep NAME","strings-changed-separator"]
[2,"strings --output-separator=' ' /proc/self/environ | tr '\\0' '\\n' | grep NAME","strings-conversion-cannot-repair-records"]
[2,"env --unknown | tr '\\0' '\\n' | grep NAME","env-unknown-option-framing"]
[2,"printenv --unknown | tr '\\0' '\\n' | grep NAME","printenv-unknown-option-framing"]
[2,"printenv \"$NAME\" | grep NAME","printenv-unresolved-option-framing"]
[2,"declare -p --unknown | grep NAME","declare-unknown-option-framing"]
[2,"systemctl --user --unknown show-environment | tr '\\0' '\\n' | grep NAME","systemctl-unknown-option-framing"]
[0,"printenv NAME","named-variable"]
[0,"printenv -- NAME","named-variable-options-end"]
[0,"printenv A B","named-variables"]
[0,"env NAME=value git status","launcher"]
[0,"env -i NAME=value git status","empty-launcher"]
[0,"env -- git status","launcher-options-end"]
[0,"env -u env git status","launcher-option-value"]
[0,"export NAME=value","export-assignment"]
[0,"export -p NAME","export-named"]
[0,"declare -p NAME","declare-named"]
[0,"declare -x NAME","declare-export-named"]
[0,"typeset -x NAME","typeset-named"]
[0,"set -e","set-option"]
[0,"set --","set-arguments"]
[0,"systemctl --user show SOME_UNIT","other-systemctl"]
[0,"cat /proc/self/status","other-proc-file"]
[2,"env NAME=value printenv","launcher-dump"]
[2,"env NAME=value env","launcher-env-chain"]
[2,"command env","command-prefix"]
[2,"command -p -- printenv","command-path-prefix"]
[0,"command -v env","command-query"]
[0,"command -V printenv","command-description"]
[2,"sudo env","sudo-prefix"]
[2,"sudo -u root -- env","sudo-user-prefix"]
[2,"sudo --user=root printenv","sudo-inline-user"]
[0,"sudo -u env git status","sudo-option-value"]
[0,"sudo env NAME=value git status","sudo-launcher"]
[2,"sudo env NAME=value printenv","sudo-launcher-dump"]
[2,"bash -c 'env'","opaque-shell-program"]
[2,"bash -c 'env | grep NAME'","opaque-shell-filter"]
[2,"env -S 'printenv'","opaque-env-split"]
[2,"env --split-string='printenv'","opaque-env-inline-split"]
[2,"env -S 'printenv | grep NAME'","opaque-env-filter"]
[2,"env | cat","unfiltered-pipe"]
[2,"env | grep '.*'","wildcard-filter"]
[2,"env | grep -v NAME","inverted-filter"]
[2,"env | grep -e NAME -e '.*'","additional-broad-pattern"]
[2,"env | grep NAME other-file","filter-replaced-stdin"]
[2,"env | grep NAME < other-file","filter-input-redirect"]
[2,"env | grep -Z NAME","unknown-filter-option"]
[2,"env | grep \"$NAME\"","unresolved-filter"]
[2,"env | tee dump | grep NAME","intermediate-copy"]
[2,"env > dump | grep NAME","stdout-file"]
[2,"env >&2 | grep NAME","stdout-duplication"]
[2,"env>dump | grep NAME","adjacent-stdout-file"]
[0,"env 2>/dev/null | grep NAME","stderr-file"]
[0,"env | grep -e NAME","explicit-pattern"]
[0,"env | grep -- NAME","filter-options-end"]
[2,"env && printf done | grep NAME","and-list"]
[2,"env || printf done | grep NAME","or-list"]
[2,"env; printf done | grep NAME","separate-filter"]
[2,"env; grep NAME","separate-grep"]
[2,"env & grep NAME","background-list"]
[2,"env\ngrep NAME","newline-list"]
[2,"env | grep NAME; printenv","later-dump"]
[2,"env | grep NAME | printenv","later-pipe-dump"]
[0,"env | grep NAME; printenv A","filtered-list"]
[2,"(env)","nested-dump"]
[2,"{ env; }","brace-dump"]
[2,"{ NAME=value env; }","brace-assignment-dump"]
[2,"if true; then env; fi","if-body-dump"]
[2,"if env; then :; fi","if-condition-dump"]
[2,"if true; then NAME=value env; fi","if-body-assignment-dump"]
[2,"if false; then :; elif printenv; then :; fi","elif-condition-dump"]
[2,"if false; then :; else set; fi","else-body-dump"]
[2,"for ITEM in first; do printenv; done","for-body-dump"]
[2,"while true; do set; done","while-body-dump"]
[2,"while env; do :; done","while-condition-dump"]
[2,"until env; do :; done","until-condition-dump"]
[2,"! env","negated-dump"]
[2,"time env","timed-dump"]
[2,"time -p env","timed-posix-dump"]
[2,"builtin set","builtin-dump"]
[2,"exec env","exec-dump"]
[2,"exec -- env","exec-options-end-dump"]
[2,"function f { env; }; f","function-syntax-dump"]
[2,"function f { e'n'v; }; f","function-split-dump"]
[2,"function f { en\\\nv; }; f","function-continued-dump"]
[2,"function f { env | grep NAME; }; f","function-conservative-filter"]
[2,"coproc { env; }","coprocess-syntax-dump"]
[2,"coproc WORKER { printenv; }","named-coprocess-dump"]
[2,"coproc WORKER { env | grep NAME; }","coprocess-conservative-filter"]
[2,"time -p -- env","time-option-suffix-dump"]
[2,"time --unknown NAME env | grep NAME","time-unknown-suffix-dump"]
[2,"function f { :; printf '%s' env; }; f","unsupported-list-evidence"]
[2,"function f { : | printf '%s' env; }; f","unsupported-pipe-evidence"]
[2,"case WORD in NAME) env;; esac","case-syntax-dump"]
[2,"select ITEM in first; do env; done","select-syntax-dump"]
[2,"[[ env ]]","conditional-data-conservative"]
[2,"exec -a NAME env","exec-name-option-dump"]
[2,"exec -c printenv","exec-cleared-option-dump"]
[2,"exec -a NAME env | grep NAME","exec-option-conservative-filter"]
[2,"builtin -- set","builtin-option-dump"]
[2,"command exec -a NAME env","forwarded-exec-option-dump"]
[2,"command builtin -- set","forwarded-builtin-option-dump"]
[0,"exec git status","exec-ordinary-target"]
[0,"exec -a NAME git status","exec-option-ordinary-target"]
[0,"builtin echo ready","builtin-ordinary-target"]
[0,"function f { git status; }; f","function-without-known-dump"]
[0,"coproc WORKER { git status; }","coprocess-without-known-dump"]
[0,"time -p -- git status","time-without-known-dump"]
[0,"for ITEM in first; do git status; done","loop-without-known-dump"]
[0,"case WORD in NAME) git status;; esac","case-without-known-dump"]
[0,"printf '%s' 'function f { env; }'","quoted-function-data"]
[0,"printf '%s' \u0063oproc env","syntax-arguments-are-data"]
[0,"\"function\" env","quoted-head-is-an-executable"]
[0,"fun\\ction env","escaped-head-is-an-executable"]
[0,"/usr/bin/time env","pathname-basename-is-not-syntax"]
[0,"command function f env","launcher-target-is-not-syntax"]
[0,"env NAME=value function f env","env-target-is-not-syntax"]
[0,"# function f { env; }\ngit status","syntax-comment-data"]
[2,"{ env | grep NAME; }","brace-conservative-filter"]
[2,"for ITEM in env; do :; done","loop-data-conservative"]
[0,"printf '%s' '{ env; }'","quoted-brace-data"]
[0,"printf '%s' ${NAME}","parameter-brace-data"]
[2,"printenv ${NAME}","parameter-brace-not-a-literal-name"]
[2,"(env | grep NAME)","nested-filter"]
[2,"(env) | grep NAME","outer-filter"]
[2,"printf '%s' \"$(env)\"","substitution-dump"]
[2,"printf '%s' \"$(env | grep NAME)\"","substitution-filter"]
[2,"printf '%s' \"$(env)\" | grep NAME","substitution-outer-filter"]
[2,"printf '%s' `env`","backtick-dump"]
[0,"printf '%s' 'env | grep NAME'","quoted-data"]
[0,"printf '%s' '$(env)'","single-quoted-substitution"]
[0,"printf '%s' env","argument-data"]
[0,"printf '%s' 'env'","quoted-argument-data"]
[0,"# env\ngit status","comment-data"]
[2,"\"env\"","quoted-producer"]
[2,"e'n'v","split-producer"]
[2,"en\\v","escaped-producer"]
[2,"/usr/bin/env","absolute-producer"]
[2,"en\\\nv","continued-producer"]
[2,"env | grep 'NAME","unclosed-filter"]
[2,"env # | grep NAME","comment-filter"]
[2,"env","explicit-policy-off"]
[0,"systemd-run --user --scope -p MemoryMax=64M cargo test","policy-off-memory-cap"]
[2,"env","outside-git","outside"]
[2,"env","unreadable-cwd","gone"]
[2,"env","invalid-cwd","invalid-cwd"]
[2,"env","bad-settings","bad-settings"]
[2,"env","empty-pattern","empty-pattern"]
[2,"env","invalid-pattern","invalid-pattern"]
[2,"env","absent-policy","absent-policy"]
[2,"env","absent-loader","absent-loader"]
[2,"env","missing-policy-tools","missing-policy-tools"]
[2,"env","cmd-payload","cmd"]
[2,"env","copilot-payload","copilot"]
[2,"env","copilot-string-payload","copilot-string"]
[2,"env","top-payload","top"]
[0,"printenv NAME","copilot-named","copilot"]
[0,"printenv NAME","copilot-string-named","copilot-string"]
[2,["printenv"],"array-dump"]
[0,["printenv","NAME"],"array-named"]
[0,["printf","%s","env"],"array-data"]
[2,["systemctl","--user","show-environment","|","grep","NAME"],"array-pipe-is-data"]
[2,["env","NAME=value"],"array-assignment-only"]
[2,["env","--","NAME=value"],"array-options-end-assignment"]
[2,["env","--","NAME=value","printenv"],"array-options-end-printenv"]
[2,["env","--","NAME=value","systemctl","--user","show-environment"],"array-options-end-systemctl"]
[0,["env","--","NAME=value","git","status"],"array-options-end-launcher"]
[0,["env","--","NAME=value","printenv","NAME"],"array-options-end-named"]
[0,["{","env"],"array-brace-is-an-executable"]
[0,["then","env"],"array-keyword-is-an-executable"]
[0,["NAME=value","env"],"array-assignment-is-an-executable"]
[0,["function","f","{","env"],"array-function-is-an-executable"]
[0,["coproc","{","env"],"array-coprocess-is-an-executable"]
[0,["time","-p","--","env"],"array-time-is-an-executable"]
[0,["exec","-a","NAME","env"],"array-exec-is-an-executable"]
[0,["env","NAME=value","git","status"],"array-launcher"]
ENVIRONMENT_ROWS
  [ "$((passed + failed))" -gt "$before" ] || { echo 'FAIL environment table has no rows'; failed=$((failed + 1)); }
  settings
}
environment_rows
if [ "${1:-}" = --environment-rows ]; then
  printf '%s passed, %s failed\n' "$passed" "$failed"
  [ "$failed" -eq 0 ]
  exit
fi

if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  planted=""
  while IFS='|' read -r defect failed_row; do
    if [ "$defect" != "$planted" ]; then
    planted=$defect
    mutant="$scratch/environment-$defect.sh"
    awk -v defect="$defect" '
      function swap(from, to, at) {
        at = index($0, from)
        if (at) { $0 = substr($0, 1, at - 1) to substr($0, at + length(from)); changed++ }
      }
      defect == "no-check" { swap("if environment_dump \"$command_kind\"; then", "if false; then") }
      defect == "late-check" && $0 == "if environment_dump \"$command_kind\"; then" {
        block = $0; getline; block = block "\n" $0; getline; block = block "\n" $0; changed++; next
      }
      defect == "late-check" && $0 == "[ \"$pattern\" != '\''^$'\'' ] || exit 0" { print; print block; next }
      defect == "unrelated-filter" {
        swap("[ -z \"$compound\" ] || return 0", "[ -z \"$compound\" ] || return 0; for ((j=stage; j<${#decisions[@]}; j++)); do [ \"${decisions[$j]}\" != filter ] || continue 2; done")
      }
      defect == "launcher-pass" && $0 == "        env)" { print; print "          program=\"\"; mode=other; break"; changed++; next }
      defect == "nested-pass" && $0 == "  n=${#tokens[@]}" { print "  [ -z \"$compound\" ] || return 1"; changed++ }
      defect == "broad-filter" { swap("[[ $pattern =~ $filter_re ]]", "[[ -n $pattern ]]") }
      defect == "env-terminator" { swap("--) options_ended=1; pos=$((pos + 1)); continue ;;", "--) pos=$((pos + 1)); break ;;") }
      defect == "grep-record-flags" { swap("^-[EFq]+$", "^-[EFazq]+$") }
      defect == "nul-records" && $0 == "    case \"${decisions[$stage]}\" in" {
        print "    [ \"${decisions[$stage]}\" != dump-nul ] || decisions[stage]=dump-lines"; changed++
      }
      defect == "unproved-records" { swap("unrouted | dump-unknown) return 0 ;;", "unrouted) return 0 ;; dump-unknown) continue ;;") }
      defect == "shell-prefix" { swap("if [[ $opaque =~ $opaque_re ]]; then", "if [ -z \"$opaque_from\" ] && [[ $opaque =~ $opaque_re ]]; then") }
      defect == "suffix-first-word" && /for \(\(j=opaque_from;/ {
        swap("j<${#tokens[@]}", "j<opaque_from+1 && j<${#tokens[@]}")
      }
      defect == "suffix-stage-only" && /for \(\(j=opaque_from;/ { swap("j<${#tokens[@]}", "j<end") }
      defect == "head-basename" && $0 == "      case \"${args[$pos]}\" in" {
        $0 = "      case \"${args[$pos]##*/}\" in"; changed++
      }
      defect == "quoted-head" { swap("syntax_head=${arg_unquoted[$pos]}", "syntax_head=1") }
      defect == "array-head" { swap("if [ -n \"$syntax_head\" ]; then", "if [ -n \"$syntax_head\" ] || [ \"$1\" = argv ]; then") }
      { print }
      END { if (changed != 1) exit 1 }
    ' "$hook_source" >"$mutant" || exit 1
    if cmp -s -- "$hook_source" "$mutant"; then echo "FAIL environment control $defect changed no bytes"; exit 1; fi
    control_status=0
    env -i "HOME=$HOME" "PATH=$PATH" "HOOK_UNDER_TEST=$mutant" "$BASH" "${BASH_SOURCE[0]}" --environment-rows \
      >"$scratch/environment-$defect.log" 2>&1 || control_status=$?
    fi
    if [ "$control_status" -eq 1 ] && grep -F -- "$failed_row" "$scratch/environment-$defect.log" >/dev/null; then
      printf 'PASS environment control %s rejects its planted rule failure\n' "$defect"; passed=$((passed + 1))
    else
      printf 'FAIL environment control %s: exit=%s missing=%s\n' "$defect" "$control_status" "$failed_row"; failed=$((failed + 1))
    fi
  done <<'ENVIRONMENT_CONTROLS'
no-check|FAIL environment: incident: exit=0 expected=2
late-check|FAIL environment: explicit-policy-off: exit=0 expected=2
unrelated-filter|FAIL environment: separate-filter: exit=0 expected=2
launcher-pass|FAIL environment: launcher-dump: exit=0 expected=2
nested-pass|FAIL environment: substitution-dump: exit=0 expected=2
broad-filter|FAIL environment: wildcard-filter: exit=0 expected=2
env-terminator|FAIL environment: env-options-end-assignment: exit=0 expected=2
env-terminator|FAIL environment: array-options-end-printenv: exit=0 expected=2
grep-record-flags|FAIL environment: env-grep-nul-mode: exit=0 expected=2
nul-records|FAIL environment: proc-cat-filter: exit=0 expected=2
unproved-records|FAIL environment: xargs-flattened-records: exit=0 expected=2
unproved-records|FAIL environment: cat-transformed-records: exit=0 expected=2
unproved-records|FAIL environment: tr-conversion-cannot-repair-records: exit=0 expected=2
unproved-records|FAIL environment: strings-conversion-cannot-repair-records: exit=0 expected=2
shell-prefix|FAIL environment: brace-dump: exit=0 expected=2
shell-prefix|FAIL environment: if-body-dump: exit=0 expected=2
shell-prefix|FAIL environment: timed-dump: exit=0 expected=2
shell-prefix|FAIL environment: function-syntax-dump: exit=0 expected=2
shell-prefix|FAIL environment: coprocess-syntax-dump: exit=0 expected=2
shell-prefix|FAIL environment: time-option-suffix-dump: exit=0 expected=2
shell-prefix|FAIL environment: exec-name-option-dump: exit=0 expected=2
shell-prefix|FAIL environment: exec-cleared-option-dump: exit=0 expected=2
shell-prefix|FAIL environment: forwarded-exec-option-dump: exit=0 expected=2
shell-prefix|FAIL environment: forwarded-builtin-option-dump: exit=0 expected=2
suffix-first-word|FAIL environment: function-syntax-dump: exit=0 expected=2
suffix-first-word|FAIL environment: time-option-suffix-dump: exit=0 expected=2
suffix-first-word|FAIL environment: exec-name-option-dump: exit=0 expected=2
suffix-stage-only|FAIL environment: unsupported-list-evidence: exit=0 expected=2
suffix-stage-only|FAIL environment: unsupported-pipe-evidence: exit=0 expected=2
head-basename|FAIL environment: pathname-basename-is-not-syntax: exit=2 expected=0
quoted-head|FAIL environment: quoted-head-is-an-executable: exit=2 expected=0
array-head|FAIL environment: array-function-is-an-executable: exit=2 expected=0
ENVIRONMENT_CONTROLS
fi
# This repository's own policy, the Quickshell example in
# docs/authoring/command-safety.md, is its content rather than this hook's
# behaviour; a tools/guard lane owns it, with its control in
# tools/tests/guard.test.sh. What stays here is the hook's own
# default_pattern, and that a project pattern replaces it: a project pattern
# refuses, and a command outside it does not.
printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = "^never-matches-anything$"\n' \
  >"$repo/kendex.settings.toml"
check 0 'systemd-run --user --scope -p MemoryMax=64M cargo test -p kendex-core' 'a project pattern replaces the default'
printf '[env]\n' >"$repo/kendex.settings.toml"
# The default is the policy here. Commands stay in JSON payloads; this suite
# never runs the capped commands it asks the hook to judge.
while IFS='|' read -r command_json label; do
  command="$(jq -nr "$command_json")" || exit 1
  check 2 "$command" "$label"
  assert_first 'command-safety: refused=default-policy' "$label names the default policy"
done <<'CONTINUATIONS'
"systemd-run --user --scope -p MemoryMax=64M cargo test"|single-line MemoryMax
"systemd-run --user --scope -p MemoryHigh=64M cargo test"|single-line MemoryHigh
"systemd-run --user --scope \\\n-p MemoryMax=64M cargo test"|continued-line MemoryMax
"systemd-run --user --scope \\\n-p MemoryHigh=64M cargo test"|continued-line MemoryHigh
"systemd-ru\\\nn --user --scope -p MemoryM\\\nax=64M cargo test"|continued tokens
CONTINUATIONS
check 0 $'systemd-run --user --scope \\\n-p CPUWeight=10 cargo test' 'an allowed continued command passes'
# Single quotes keep this pair. Only the raw line ends in a backslash, so
# this row fails if matching drops the raw text and uses only joined text.
cat >"$repo/kendex.settings.toml" <<'RAW_POLICY'
[env]
COMMAND_SAFETY_DENY_PATTERN = "BLOCK_THIS.$"
RAW_POLICY
check 2 $'printf \'%s\' \'BLOCK_THIS\\\nTAIL\'' 'raw quoted continuation'
assert_first 'command-safety: refused=policy' 'raw quoted data reaches the policy key'
settings

# A fresh install has no settings line, or no settings file at all; the
# hook's own default is then the policy.
for unconfigured in empty-env no-file; do
  case "$unconfigured" in
    empty-env) printf '[env]\n' >"$repo/kendex.settings.toml" ;;
    no-file) rm -f -- "$repo/kendex.settings.toml" ;;
  esac
  while IFS='|' read -r command_json label; do
    command="$(jq -nr "$command_json")" || exit 1
    check 2 "$command" "$unconfigured: the default refuses $label"
    assert_first 'command-safety: refused=default-policy' "$unconfigured: $label names the default policy"
  done <<'DEFAULT_REFUSES'
"systemd-run --user --scope -p MemoryMax=64M cargo test"|a bare MemoryMax
"systemd-run --user --scope -p MemoryHigh=512K cargo test"|a bare MemoryHigh
"systemd-run --user --scope -p MemoryMax=\"64M\" cargo test"|a quoted MemoryMax
DEFAULT_REFUSES
  check 0 'systemd-run --user --scope -p MemoryMax=2G cargo test' "$unconfigured: the default passes a gigabyte cap"
  check 0 'git status' "$unconfigured: the default passes an unrelated command"
done
# The default is written three times: the hook applies it, the commit-guards
# example declares it for the app's Customize tab, and the doc prints it.
# Each copy is read from its own file, the example through the settings
# loader the hook uses.
default_in_hook="$(awk -v p="default_pattern='" '
  index($0, p) == 1 { v = substr($0, length(p) + 1); sub(/.$/, "", v); print v; n++ }
  END { exit n != 1 }' "$hook_source")" || exit 1
default_in_doc="$(awk '
  /^```text$/ { inside = 1; next }
  inside && /^```$/ { inside = 0; next }
  inside { print; n++ }
  END { exit n != 1 }' "$ROOT/docs/authoring/command-safety.md")" || exit 1
default_in_example="$(cd -- "$scratch" && COMMIT_GUARDS_SETTINGS_FILE="$ROOT/skills/commit-guards/kendex.settings.toml.example" \
  GG_CHECK=command-safety bash -c '
  source "$1/common.sh"
  source "$1/settings.sh"
  gg_setting COMMAND_SAFETY_DENY_PATTERN ""
' _ "$ROOT/skills/commit-guards/scripts/lib")" || exit 1
if [ -n "$default_in_hook" ] && [ "$default_in_example" = "$default_in_hook" ] &&
  [ "$default_in_doc" = "$default_in_hook" ]; then
  printf 'PASS the example and the doc carry the hook default\n'
  passed=$((passed + 1))
else
  printf 'FAIL the example and the doc carry the hook default: hook [%s] example [%s] doc [%s]\n' \
    "$default_in_hook" "$default_in_example" "$default_in_doc"
  failed=$((failed + 1))
fi
printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = "^$"\n' >"$repo/kendex.settings.toml"
check 0 'systemd-run --user --scope -p MemoryMax=64M cargo test' 'an explicit ^$ turns matching off'
printf '[env]\n' >"$repo/kendex.settings.toml"
check 0 'systemd-run --user --scope -p MemoryMax=64M cargo test' 'a global hook outside Git leaves the hook inactive' /
mkdir -p "$scratch/outside"
printf 'gitdir: /missing\n' >"$scratch/outside/.git"
check 0 'git status' 'an unresolved Git worktree warns' "$scratch/outside"
assert_first 'command-safety: git=unreadable' 'and the git key names the working directory it could not resolve'
assert_replays "$(git -C "$scratch/outside" rev-parse --show-toplevel 2>&1 || true)" \
  "and git's own words on the entry it could not read stand under it"
mv "$scratch/outside/.git" "$scratch/unresolved-git-marker"
printf '[env\n' >"$repo/kendex.settings.toml"
check 0 'git status' 'malformed project settings warn'
assert_first 'command-safety: settings=unreadable' 'and the value says the settings could not be read'
assert_cause present "and the loader's own words are replayed under it"
# A malformed value on a key the hook never reads still warns, and the
# refusal carries the loader's line naming the file, the line and the key.
# The probe runs the installed loader itself, so the row asserts the hook's
# replay; the loader's own suite pins that line's value.
printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = "BLOCK_THIS"\nOTHER = "a"b"\n' >"$repo/kendex.settings.toml"
check 0 'git status' 'an inner double quote on a key the hook does not read warns'
assert_first 'command-safety: settings=unreadable' 'and the value says the settings could not be read'
assert_replays "$(cd "$repo" && GG_CHECK=command-safety bash -c '
  source "$1/common.sh"
  source "$1/settings.sh"
  gg_setting COMMAND_SAFETY_DENY_PATTERN "^\$"
' _ "$repo/.agents/skills/commit-guards/scripts/lib" 2>&1 || true)" \
  "and the loader's line naming the file, line and key stands under it"
settings

# Every payload shape a shipped harness sends, each counted as a row rather
# than a bare FAIL: the two spellings of the command field, an argument array,
# and Copilot's object and string forms in both directions.
shape() { # EXPECTED FIRST PAYLOAD_JSON LABEL
  local expected="$1" want_first="$2" payload="$3" label="$4" status=0 output
  output="$(cd -- "$repo" && printf '%s' "$payload" | bash "$hook" 2>"$scratch/stderr")" || status=$?
  first="$(first_line "$scratch/stderr")"
  cause="$(cause_below "$scratch/stderr")"
  # The status alone cannot tell a refusal for the right reason from one for
  # the wrong reason, and every shape here is meant to reach the policy.
  if [ "$status" -eq "$expected" ] && [ "$first" = "$want_first" ] && [ -z "$output" ]; then
    printf 'PASS %s\n' "$label"
    passed=$((passed + 1))
  else
    printf 'FAIL %s: exit %s (want %s), first %s (want %s), stdout [%s]\n' \
      "$label" "$status" "$expected" "$first" "$want_first" "$output"
    failed=$((failed + 1))
  fi
}
# The table counts its own rows: an emptied row list is a refusal, never a
# silently shorter run.
before=$((passed + failed))
while IFS='|' read -r expected want_first filter label; do
  [ -n "$expected" ] || continue
  [ "$want_first" != - ] || want_first='-'
  shape "$expected" "$want_first" "$(jq -nc --arg cwd "$repo" "$filter")" "$label"
done <<'SHAPES'
2|command-safety: refused=policy|{tool_input:{cmd:"qs -c vshell"},cwd:$cwd}|a refused command under the cmd field
2|command-safety: refused=policy|{tool_input:{command:["qs","-c","vshell"]},cwd:$cwd}|a refused command as an argument array
2|command-safety: refused=policy|{toolName:"bash",toolArgs:{command:"qs -c vshell"},cwd:$cwd}|a refused command under a Copilot toolArgs object
0|-|{toolName:"bash",toolArgs:{command:"git status"},cwd:$cwd}|an allowed command under a Copilot toolArgs object
2|command-safety: refused=policy|{toolName:"bash",toolArgs:"{\"command\":\"qs -c vshell\"}",cwd:$cwd}|a refused command under a Copilot toolArgs string
0|-|{toolName:"bash",toolArgs:"{\"command\":\"git status\"}",cwd:$cwd}|an allowed command under a Copilot toolArgs string
0|command-safety: payload=invalid-cwd|{tool_input:{command:"git status"},cwd:42}|a non-string working directory warns
0|-|{tool_input:{command:""},cwd:{}}|an empty command still bypasses the working directory read
0|-|{tool_input:{command:"\n\n"},cwd:{}}|a command containing only trailing newlines still bypasses the working directory read
0|-|{tool_input:{command:"git status"}}|an allowed command without cwd uses the caller directory
2|command-safety: refused=policy|{tool_input:{command:"qs -c vshell"}}|a denied command without cwd uses the caller policy
0|-|{tool_input:{command:"git status"},cwd:($cwd + "\n\n")}|working directory trailing newlines keep the previous read behavior
0|-|{tool_input:{command:"git status\n\u0027; $(touch SHOULD_NOT_RUN); \u0027"},cwd:$cwd}|shell syntax in command text stays data
SHAPES
[ ! -e "$repo/SHOULD_NOT_RUN" ] || { printf 'FAIL payload text executed\n'; failed=$((failed + 1)); }
quoted_cwd="$repo/quoted'"$'\t\nback\\slash'
mkdir -p -- "$quoted_cwd"
check 0 'git status' 'tabs, newlines, quotes and backslashes in the working directory remain data' "$quoted_cwd"
printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = "(^$|NEVER_MATCH)"\n' > "$repo/kendex.settings.toml"
check 0 $'git status\n\n' 'command trailing newlines keep the previous read behavior'
settings
[ "$((passed + failed))" -gt "$before" ] || { printf 'FAIL no payload shape was asserted\n'; failed=$((failed + 1)); }

# A cwd the payload names and the hook cannot enter: the value is the path as
# it was requested, not the empty string the failed probe would leave behind.
check 0 'git status' 'a cwd that cannot be entered warns' "$scratch/gone"
assert_first "command-safety: cwd=$scratch/gone" 'and the value is the path the payload asked for'

# Every external command this hook runs, one world each: without dirname it
# cannot find its own directory, and the refusal must still open with the key.
nodirname="$scratch/nodirname"
mkdir -p "$nodirname"
for tool in jq git grep cat mktemp rm; do
  ln -sf "$(command -v "$tool")" "$nodirname/$tool"
done
# And a world holding none of them: the value is the whole list, in check
# order, which a one-tool world cannot tell from an accumulator that
# overwrites instead of appending.
notools="$scratch/notools"
mkdir -p "$notools"
# These rows share the file-backed stdin owner with the other hook suites.
. "$ROOT/hooks/tests/lib/payload-rows.sh"
PAYLOAD_ROOT="$scratch/missing-tool-payload"
mkdir -p "$PAYLOAD_ROOT"
PAYLOAD_PREFIX='command-safety: '
PAYLOAD_BASH="$BASH"
payload=$(jq -nc --arg cwd "$repo" '{tool_input:{command:"git status"},cwd:$cwd}')
while IFS='|' read -r label path key; do
  got=$(payload_run "$hook" "$repo" "$path" "$payload")
  if [ "$got" = "rc=0 first=$key" ] && [ "$(grep -c '^command-safety: ' "$PAYLOAD_ROOT/stderr")" -eq 1 ]; then
    printf 'PASS %s\n' "$label"; passed=$((passed + 1))
  else
    printf 'FAIL %s: %s\n' "$label" "$got"; failed=$((failed + 1))
  fi
done <<ROWS
with none of them the value is the whole list, in check order|$notools|missing-tools=jq,git,grep,cat,dirname,mktemp,rm
without dirname the warning names it|$nodirname|missing-tools=dirname
ROWS

printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = "^other-command$"\n' >"$repo/kendex.settings.toml"
check 0 'qs -c vshell' 'policy is configured, not tied to Quickshell'
check 2 'other-command' 'a different project policy takes effect'
assert_first 'command-safety: refused=policy' 'a command the policy matches names the policy'
printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = "BLOCK_THIS"\n' >"$repo/kendex.settings.toml"
check 2 "printf '%s' 'BLOCK_THIS'" 'matching quoted text is refused'
check 0 'git status' 'a command outside the policy passes'
assert_first - 'a command it allows says nothing at all'

# Every state of the policy the hook can find, each its own value under the
# settings key, so a reader tells a broken pattern from an absent one.
printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = "["\n' >"$repo/kendex.settings.toml"
check 0 'scripts/validate qml' 'invalid pattern warns'
assert_first 'command-safety: settings=invalid-pattern' 'and the value says the pattern is unreadable'
printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = ""\n' >"$repo/kendex.settings.toml"
check 0 'scripts/validate qml' 'empty pattern warns'
assert_first 'command-safety: settings=empty' 'and the value says the pattern is empty'
settings
before=$((passed + failed))
while IFS='|' read -r payload label; do
  [ -n "$payload" ] || continue
  shape 0 'command-safety: payload=invalid-json' "$payload" "$label"
done <<'PAYLOADS'
not JSON|a payload that is not JSON is refused unread
{"tool_input":{"command":false}}|a command that is not a string is refused unread
{"tool_input":{}}|a payload naming no command is refused unread
PAYLOADS
[ "$((passed + failed))" -gt "$before" ] || { printf 'FAIL no unreadable payload was asserted\n'; failed=$((failed + 1)); }


settings
mkdir -p "$repo/.claude/skills/commit-guards/scripts"
mv "$repo/.agents/skills/commit-guards/scripts/lib" "$repo/.claude/skills/commit-guards/scripts/lib"
check 2 'qs -c vshell' 'copy delivery finds the installed dependency'
check 0 'scripts/validate qml' 'copy delivery allows validation'
printf 'return 1\n' >"$repo/.claude/skills/commit-guards/scripts/lib/common.sh"
check 0 'scripts/validate qml' 'a failed settings loader warns and allows the call'
assert_first 'command-safety: support=unreadable' 'and the support key names the failed installed load'
mv "$repo/.claude/skills/commit-guards/scripts/lib" "$scratch/absent-lib"
check 0 'scripts/validate qml' 'missing settings support warns'

# Each control plants one defect in a copy and reruns these assertions; a
# defect's rows are adjacent, and each names the line that copy must print,
# from FAIL through the got and expected values of its own instrument, so an
# exit row, a first-line row and the copy check are read alike. The exact
# failure proves the planted rule, not a bad policy or loader, made the row
# red. The default_pattern defects edit one rule of the shipped default: no
# default at all, no quoted value, and a unit widened to gigabytes; the
# default-key defect sends the default's refusal out under the project key.
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  planted=
  while IFS='|' read -r defect want; do
    if [ "$defect" != "$planted" ]; then
      planted="$defect"
      mutant="$scratch/$defect.sh"
      awk -v defect="$defect" -v q="'" '
        function swap(from, to,   at) {
          at = index($0, from)
          if (at) { $0 = substr($0, 1, at - 1) to substr($0, at + length(from)); changed++ }
        }
        defect == "no-default" && /^default_pattern=/ {
          $0 = "default_pattern=" q "^$" q; changed++
        }
        defect == "no-quote" && /^default_pattern=/ { swap("[[:punct:]]?", "") }
        defect == "unit-g" && /^default_pattern=/ { swap("[KkMm]", "[KkMmGg]") }
        defect == "default-key" { swap("refuse refused default-policy", "refuse refused policy") }
        defect == "no-cwd-fallback" { swap("cwd=\"$PWD\"", "cwd=/") }
        { print }
        END { if (changed != 1) exit 1 }
      ' "$hook_source" >"$mutant" || exit 1
      if cmp -s -- "$hook_source" "$mutant"; then
        printf 'FAIL control %s changed no bytes\n' "$defect"
        exit 1
      fi
      control_status=0
      env -i HOME="$HOME" PATH="$PATH" HOOK_UNDER_TEST="$mutant" \
        bash "${BASH_SOURCE[0]}" >"$scratch/$defect.log" 2>&1 || control_status=$?
    fi
    if [ "$control_status" -eq 1 ] && awk -v want="$want" '
      index($0, want) == 1 { found = 1 }
      END { exit !found }' "$scratch/$defect.log"; then
      printf 'PASS control %s prints %s\n' "$defect" "$want"
      passed=$((passed + 1))
    else
      printf 'FAIL control %s: exit %s; missing line %s\n' "$defect" "$control_status" "$want"
      cat "$scratch/$defect.log"
      failed=$((failed + 1))
    fi
  done <<'CONTROLS'
no-default|FAIL empty-env: the default refuses a bare MemoryMax: exit 0, expected 2:
no-default|FAIL no-file: the default refuses a bare MemoryMax: exit 0, expected 2:
no-quote|FAIL empty-env: the default refuses a quoted MemoryMax: exit 0, expected 2:
no-quote|FAIL no-file: the default refuses a quoted MemoryMax: exit 0, expected 2:
no-quote|FAIL the example and the doc carry the hook default: hook [
unit-g|FAIL empty-env: the default passes a gigabyte cap: exit 2, expected 0:
unit-g|FAIL no-file: the default passes a gigabyte cap: exit 2, expected 0:
default-key|FAIL empty-env: a bare MemoryMax names the default policy: first line command-safety: refused=policy, expected command-safety: refused=default-policy
no-cwd-fallback|FAIL a denied command without cwd uses the caller policy:
CONTROLS
fi
TMP_ROOT=$scratch
ERR_FILE="$scratch/stderr"
PASS=0
FAIL=0
HOOK=$hook_source
ln -s "$ROOT/skills" "$scratch/skills"
. "$ROOT/hooks/tests/lib/assert.sh"
# Env::global_skills_dir and the harness adapters emit these installed roots.
# One table covers native, shared, relocated, partial and unavailable support.
global_reader_rows() {
  local label hook_dir library state expected key home installed project payload status marker native
  while IFS='|' read -r label hook_dir library state expected key; do
    home="$scratch/global-layouts/$label"
    rm -rf -- "$home"
    project="$home/project"
    installed="$home/$hook_dir/command-safety.sh"
    marker="$home/project-loader-ran"
    mkdir -p "${installed%/*}" "$project/.agents/skills/commit-guards/scripts/lib"
    git -C "$project" init -q
    git -C "$project" config gc.auto 0
    git -C "$project" config maintenance.auto false
    cp "$HOOK" "$installed"
    cp -R "$ROOT/skills/commit-guards/scripts/lib/." "$project/.agents/skills/commit-guards/scripts/lib/"
    printf 'printf ran >"%s"\nreturn 1\n' "$marker" >"$project/.agents/skills/commit-guards/scripts/lib/common.sh"
    printf '[env]\n' >"$project/kendex.settings.toml"
    if [ "$state" != absent ]; then
      mkdir -p "$home/$library/commit-guards/scripts/lib"
      cp -R "$ROOT/skills/commit-guards/scripts/lib/." "$home/$library/commit-guards/scripts/lib/"
    fi
    if [ "$state" = partial ]; then
      native="${installed%/hooks/*}/skills/commit-guards/scripts/lib"
      mkdir -p "$native"
      printf 'return 1\n' >"$native/common.sh"
    fi
    # A damaged installed support file, including a missing nested import,
    # must report one advisory key rather than a raw shell diagnostic.
    case "$state" in
      return-two) printf 'return 2\n' >"$home/$library/commit-guards/scripts/lib/settings.sh" ;;
      exit-two) printf '%s\n' 'echo support-cause=installed-error >&2' 'exit 2' >"$home/$library/commit-guards/scripts/lib/common.sh" ;;
      nested-absent) rm "$home/$library/commit-guards/scripts/lib/paths.sh" ;;
    esac
    if [ "$state" = bad-setting ]; then
      printf '[env]\nUNRELATED = false\n' >"$project/kendex.settings.toml"
    fi
    payload=$(jq -nc --arg cwd "$project" '{cwd:$cwd,tool_input:{command:"systemd-run --user --scope -p MemoryMax=64M cargo test"}}')
    status=0
    env HOME="$home" "$BASH" "$installed" <<<"$payload" >/dev/null 2>"$ERR_FILE" || status=$?
    assert_eq "rc=$status first=$(first_line "$ERR_FILE")" "rc=$expected first=command-safety: $key" "$label installed reader"
    assert_eq "$([ -e "$marker" ] && echo ran || echo untouched)" untouched "$label project loader boundary"
    if [ "$state" = exit-two ]; then
      assert_eq "$(grep -c '^  support-cause=installed-error$' "$ERR_FILE")" 1 "$label replays cause"
    fi
    case "$state" in return-two | exit-two | nested-absent)
      assert_eq "$(grep -c '^command-safety: ' "$ERR_FILE")" 1 "$label warns once" ;;
    esac
  done <<'LAYOUTS'
claude-native|.claude/hooks|.claude/skills|present|2|refused=default-policy
pi-native|.pi/agent/kendex/hooks|.pi/agent/skills|present|2|refused=default-policy
pi-shared|.pi/agent/kendex/hooks|.agents/skills|present|2|refused=default-policy
pi-relocated-native|relocated/pi/agent/kendex/hooks|relocated/pi/agent/skills|present|2|refused=default-policy
pi-relocated-shared|relocated/pi/agent/kendex/hooks|.agents/skills|present|2|refused=default-policy
codex-native|.codex/hooks|.codex/skills|present|2|refused=default-policy
codex-shared|.codex/hooks|.agents/skills|present|2|refused=default-policy
codex-relocated-shared|relocated/codex/hooks|.agents/skills|present|2|refused=default-policy
gemini-native|.gemini/hooks|.gemini/skills|present|2|refused=default-policy
gemini-shared|.gemini/hooks|.agents/skills|present|2|refused=default-policy
copilot-native|.copilot/hooks|.copilot/skills|present|2|refused=default-policy
copilot-shared|.copilot/hooks|.agents/skills|present|2|refused=default-policy
copilot-relocated-shared|relocated/copilot/hooks|.agents/skills|present|2|refused=default-policy
partial-native|.codex/hooks|.agents/skills|partial|2|refused=default-policy
absent-global|.codex/hooks|.agents/skills|absent|0|settings=no-loader
bad-setting|.codex/hooks|.agents/skills|bad-setting|0|settings=unreadable
settings-return|.codex/hooks|.agents/skills|return-two|0|support=unreadable
common-exit|.codex/hooks|.agents/skills|exit-two|0|support=unreadable
nested-absent|.codex/hooks|.agents/skills|nested-absent|0|support=unreadable
LAYOUTS
}
global_reader_rows
skill_load_control global-reader "$HOOK" '*) lib="${HOME:+$HOME/.agents/skills/commit-guards/scripts/lib}"' \
  'lib=""' HOOK global_reader_rows 'pi-shared installed reader' 'codex-shared installed reader' 'gemini-shared installed reader' 'copilot-shared installed reader'
skill_load_control loader-boundary "$HOOK" '*) lib="${HOME:+$HOME/.agents/skills/commit-guards/scripts/lib}"' \
  'lib="$root/.agents/skills/commit-guards/scripts/lib"' HOOK global_reader_rows 'absent-global project loader boundary'
skill_load_control support-state "$HOOK" 'loading="$lib/common.sh"' 'loading=""' HOOK global_reader_rows 'common-exit installed reader' 'common-exit warns once'
skill_load_control support-cause "$HOOK" 'cause="$cause
  $detail"' 'cause=$loading' HOOK global_reader_rows 'common-exit replays cause'
failed=$((failed + FAIL))
passed=$((passed + PASS))
printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
