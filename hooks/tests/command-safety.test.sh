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
# HOOK_UNDER_TEST overrides the hook each fixture installs, so a must-fail
# control runs against these same assertions.
hook_source="${HOOK_UNDER_TEST:-$ROOT/hooks/command-safety.sh}"
scratch="$(mktemp -d)" || { echo 'command-safety-test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $scratch && ! -L $scratch ]] || { echo 'command-safety-test: scratch=not-a-directory' >&2; exit 1; }
scratch="$(cd -- "$scratch" && pwd -P)" || { echo 'command-safety-test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "$scratch"' EXIT
repo="$scratch/project"
prepare_project() { # the private repo and the hook source
mkdir -p "$repo/.claude/hooks" "$repo/.agents/skills/commit-guards/scripts"
git -C "$repo" init -q
git -C "$repo" config gc.auto 0
git -C "$repo" config maintenance.auto false
cp "$1" "$repo/.claude/hooks/command-safety.sh"
cp -R "$ROOT/skills/commit-guards/scripts/lib" "$repo/.agents/skills/commit-guards/scripts/lib"
}
prepare_project "$hook_source"
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

# A requested row must execute exactly once. Missing or duplicate selection
# cannot count as a mutant failure. Arrays are local to each row callback.
row_selected() {
  local i
  [ "${#selected_rows[@]}" -ne 0 ] || return 0
  for ((i=0; i<${#selected_rows[@]}; i++)); do
    if [ "${selected_rows[$i]}" = "$1" ]; then
      selected_seen[$i]=$(( ${selected_seen[$i]:-0} + 1 ))
      return 0
    fi
  done
  return 1
}
selection_complete() {
  local i
  for ((i=0; i<${#selected_rows[@]}; i++)); do
    if [ "${selected_seen[$i]:-0}" -ne 1 ]; then
      printf 'FAIL selection: row=%s executions=%s expected=1\n' "${selected_rows[$i]}" "${selected_seen[$i]:-0}"
      failed=$((failed + 1))
    fi
  done
}

default_rows() {
  local selected_rows=("$@") selected_seen=() unconfigured command_json label command
  for unconfigured in empty-env no-file; do
  case "$unconfigured" in
    empty-env) printf '[env]\n' >"$repo/kendex.settings.toml" ;;
    no-file) rm -f -- "$repo/kendex.settings.toml" ;;
  esac
  while IFS='|' read -r command_json label; do
    row_selected "$unconfigured: $label" || continue
    command="$(jq -nr "$command_json")" || exit 1
    check 2 "$command" "$unconfigured: the default refuses $label"
    assert_first 'command-safety: refused=default-policy' "$unconfigured: $label names the default policy"
  done <<'DEFAULT_REFUSES'
"systemd-run --user --scope -p MemoryMax=64M cargo test"|a bare MemoryMax
"systemd-run --user --scope -p MemoryHigh=512K cargo test"|a bare MemoryHigh
"systemd-run --user --scope -p MemoryMax=\"64M\" cargo test"|a quoted MemoryMax
DEFAULT_REFUSES
  if row_selected "$unconfigured: gigabyte-cap"; then
    check 0 'systemd-run --user --scope -p MemoryMax=2G cargo test' "$unconfigured: the default passes a gigabyte cap"
  fi
  if row_selected "$unconfigured: unrelated-command"; then
    check 0 'git status' "$unconfigured: the default passes an unrelated command"
  fi
done
  selection_complete
}

default_consistency() {
  local default_in_hook default_in_doc default_in_example
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
}

# A route row's seventh field is its oracle mark. The oracle runs that row's
# command in real bash, so the row proves that bash runs env there, not only
# the hook's model of it. The stub env first on PATH prints the marker only
# for a call with no operands; with operands it runs the real env, so a
# launcher env still reaches its target and no row prints the environment.
# The no-env control row, bash -c 'printf env', writes the word without
# running it, so it proves on every run that the oracle can answer no.
oracle_marker=command-safety-oracle-env-ran
oracle_bin="$scratch/oracle-bin"
oracle_cwd="$scratch/oracle-cwd"
oracle_real_env=$(command -v env) || { echo 'command-safety-test: oracle=no-real-env' >&2; exit 1; }
case "$oracle_real_env" in /*) ;; *) echo "command-safety-test: oracle=real-env-not-a-path value=$oracle_real_env" >&2; exit 1 ;; esac
mkdir -p "$oracle_bin" "$oracle_cwd"
printf '#!%s\n[ "$#" -ne 0 ] || { echo %s; exit 0; }\nexec %q "$@"\n' "$BASH" "$oracle_marker" "$oracle_real_env" >"$oracle_bin/env"
chmod +x "$oracle_bin/env"
oracle_runs_env() { # COMMAND: whether real bash runs env with no operands
  local out
  out=$(cd -- "$oracle_cwd" && PATH="$oracle_bin:$PATH" "$BASH" -c "$1" </dev/null 2>/dev/null) || :
  case $'\n'"$out"$'\n' in *$'\n'"$oracle_marker"$'\n'*) return 0 ;; esac
  return 1
}

# KEN-3813 expressly requires this remedy example as well as the keyed
# verdict. The remaining English is not pinned. Every command below stays
# fixture data submitted only to the hook, including all planted controls.
# A JSON escape keeps the coprocess data word out of the Bash syntax lint.
# Named-method rows use the Jarvis config command and lane-host-ssh settings
# lookups. Mapping methods, line-end aliases and executable xargs input cover
# the corresponding whole-object and downstream-receiver restrictions.
# The reported-public-selection-log row is attributed KEN-4584 command text;
# the hook classifies it without executing the command or opening its log.
# The Python replacement-source row models KEN-4586's attributed edit; its
# pathlib and environment text are submitted data, never executed here.
environment_rows() {
  local rows expected command_json label world payload payload_cwd status output
  local want first_key keyed want_keyed invalid shape_kind diagnostics_safe refusal reason before=$((passed + failed))
  local oracle oracle_ran oracle_command
  local selected_rows=("$@") selected_seen=()
  mkdir -p "$scratch/policy-tools"
  for tool in jq cat; do ln -sf "$(command -v "$tool")" "$scratch/policy-tools/$tool"; done
  rows=$(jq -sr --arg fixture_home "$scratch/private-home" --args '
    .[] | select(($ARGS.positional | length) == 0 or
      (.[2] as $label | $ARGS.positional | index($label))) |
    .[1] |= (if type == "array" then map(gsub("@PRIVATE_HOME@"; $fixture_home)) else gsub("@PRIVATE_HOME@"; $fixture_home) end) |
    [.[0], (.[1] | tojson), .[2], (.[3] // "project"), (.[4] // "environment-dump"), (.[5] // "-"), (.[6] // "-")] | @tsv
  ' "$@" <<'ENVIRONMENT_ROWS'
[2,"env","bare-env","project","environment-dump","-","runs-env"]
[0,"vgs_selected_rows=\"$(sed -n 's|^scripts/qml-smoke.sh --rows ||p' tmp/evidence-VGS-1998/final/selection.log)\"; [[ -n $vgs_selected_rows && $vgs_selected_rows != *$'\\n'* ]] || exit 2; bash /home/method/dev/vgshell/tmp/nested-slot.sh scripts/qml-smoke.sh --keep --rows \"$vgs_selected_rows\" > tmp/evidence-VGS-1998/final/qml.log 2>&1; vgs_check_status=$?; printf '%s\\n' \"$vgs_check_status\" > tmp/evidence-VGS-1998/final/qml.exit; exit \"$vgs_check_status\"","reported-public-selection-log"]
[2,"FABRICATED_VALUE=fixture-private-value-4519 cat ~/.fleet/env","private-tilde"]
[2,"cat @PRIVATE_HOME@/.fleet/env","private-inherited-home"]
[2,"cat $HOME/.fleet/env","private-textual-home"]
[2,"cat ${HOME}/.fleet/env","private-textual-braced-home"]
[2,"cat -- ~/.fleet/env","private-tilde-terminator"]
[2,"cat -- @PRIVATE_HOME@/.fleet/env","private-inherited-home-terminator"]
[2,"cat -- $HOME/.fleet/env","private-textual-home-terminator"]
[2,"cat -- ${HOME}/.fleet/env","private-textual-braced-home-terminator"]
[2,"cat < ~/.fleet/env","private-tilde-redirect"]
[2,"cat < @PRIVATE_HOME@/.fleet/env","private-inherited-home-redirect"]
[2,"cat < $HOME/.fleet/env","private-textual-home-redirect"]
[2,"cat < ${HOME}/.fleet/env","private-textual-braced-home-redirect"]
[2,"bash -c 'cat ~/.fleet/env'","private-tilde-shell"]
[2,"bash -c 'cat @PRIVATE_HOME@/.fleet/env'","private-inherited-home-shell"]
[2,"bash -c 'cat $HOME/.fleet/env'","private-textual-home-shell"]
[2,"bash -c 'cat ${HOME}/.fleet/env'","private-textual-braced-home-shell"]
[2,"bash -c 'cat < ${HOME}/.fleet/env'","private-shell-redirect"]
[2,["cat","~/.fleet/env"],"private-tilde-argv"]
[2,["cat","@PRIVATE_HOME@/.fleet/env"],"private-inherited-home-argv"]
[2,["cat","$HOME/.fleet/env"],"private-textual-home-argv"]
[2,["cat","${HOME}/.fleet/env"],"private-textual-braced-home-argv"]
[2,["bash","-c","cat ~/.fleet/env"],"private-shell-argv"]
[2,"command -p -- cat -- ~/.fleet/env","private-command-launcher"]
[2,"sudo -n -u fixture cat < ~/.fleet/env","private-sudo-launcher"]
[2,"env FIXTURE=fixture-private-value-4519 cat ~/.fleet/env","private-env-launcher"]
[2,"bash wrap.sh step cat ~/.fleet/env","private-forwarded-cat"]
[2,"cat ~/.fleet/env | grep '^NAME='","private-filter-remains-refused"]
[2,"cat ~/.fleet/env","private-outside-git","outside"]
[0,"cat examples/env scripts/lib/jarvis-env.sh","private-harmless-path-operands"]
[0,"HOME=/fabricated-other cat /fabricated-other/.fleet/env","private-submitted-home-is-not-inherited"]
[0,".agents/skills/orch/scripts/orch-env ORCH_LANE_PREFERENCE auto","private-named-setting"]
[0,"bash -c '.agents/skills/orch/scripts/orch-env ORCH_LANE_PREFERENCE auto'","private-named-setting-shell"]
[0,"bash scripts/lib/jarvis-env.sh DIR -- node FILE","operand-env-script"]
[0,"unset WAYLAND_DISPLAY DISPLAY HYPRLAND_INSTANCE_SIGNATURE\nbash scripts/lib/jarvis-env.sh tmp/package-repair-VGS-1735-standins -- node \"$PWD/tmp/package-repair-VGS-1735.js\" > tmp/package-repair-VGS-1735.log 2>&1\nruntime_status=$?\ncat tmp/package-repair-VGS-1735.log\nprintf 'runtime-1 exit=%s\\n' \"$runtime_status\"\nexit \"$runtime_status\"","operand-env-reported-command"]
[0,"bash wrapper.sh --path 'scripts/lib/jarvis-env.sh'","operand-env-quoted-path"]
[0,"bash scripts/lib/jarvis-export.sh DIR -- node FILE","operand-export-script"]
[0,"bash scripts/lib/jarvis-declare.sh DIR -- node FILE","operand-declare-script"]
[2,"command env","operand-command-env","project","environment-dump","-","runs-env"]
[2,"command printenv","operand-command-printenv"]
[2,"command export -p","operand-command-export"]
[2,"command declare -x","operand-command-declare"]
[2,"command systemctl --user show-environment","operand-command-systemctl"]
[2,"set \"${!NO_SUCH_PREFIX@}\"","copilot-set-indirect-name-spread-empty"]
[2,"eval \"$MAYBE_EMPTY\" 'env'","copilot-eval-empty-earlier-operand"]
[2,"eval :; then env -u \"$@\" MISSING; fi","copilot-suffix-env-empty-spread-shipped-eval"]
[2,"set \"$ONE\" \"$TWO\"","set-only-unknown-operands-retains-main-refusal"]
[2,"bash wrapper.sh set \"${!NO_SUCH_PREFIX@}\"","suffix-set-indirect-spread-retains-main-refusal"]
[2,"{ eval \"$MAYBE_EMPTY\" 'env'; }","grouped-evaluator-unproved-input"]
[2,"eval $PREFIX \"env\"","unquoted-evaluator-unproved-input"]
[2,"eval \"$PREFIX\" \"printenv NAME\"","unproved-evaluator-named-read-intended-refusal"]
[0,"eval \"$PREFIX\" \"printf done\"","unproved-evaluator-without-known-read"]
[2,"bash -c 'env -u \"$@\" __KEN_MISSING__'","nested-unset-unproved-option-operand"]
[2,"eval 'env --unset \"$@\" __KEN_MISSING__'","literal-evaluator-unproved-unset-operand"]
[2,"bash -c 'env -C \"$@\" .'","nested-chdir-unproved-option-operand"]
[2,"eval 'env --chdir \"$@\" .'","literal-evaluator-unproved-chdir-operand"]
[2,"bash wrapper.sh env -u \"$@\" __KEN_MISSING__","suffix-unset-unproved-option-operand"]
[2,"if :; then env -u \"$@\" __KEN_MISSING__; fi","conditional-unset-unproved-option-operand"]
[2,"bash -c 'command env -u \"$@\" __KEN_MISSING__'","forwarded-nested-unproved-option-operand"]
[0,"cat <<< 'env'\nprintf done","quoted-here-string-data"]
[0,"cat <<< \"$json\"","variable-here-string-data"]
[2,"cat <<< 'ordinary'\nenv","dump-after-single-quoted-here-string"]
[2,"cat <<< \"$json\"\nenv | sort","dump-after-double-quoted-here-string"]
[2,"cat <<<'ordinary'\nprintenv","dump-after-adjacent-here-string"]
[2,"printf '%s' $((1 << \"$n\"))\nenv","dump-after-arithmetic-shift"]
[0,"printf '%s' $((1 << \"$n\"))","arithmetic-shift-data"]
[2,"cat <<$'E\\x4fF'\ndata\nEOF\nenv","encoded-heredoc-delimiter","project","environment-dump","undecoded-ansi-escape"]
[2,"cat <<$'E\\117F'\ndata\nEOF\nprintenv","octal-heredoc-delimiter","project","environment-dump","undecoded-ansi-escape"]
[2,"bash <<'EOF'\nenv\nEOF","bash-quoted-heredoc-program"]
[2,"exec bash <<'EOF'\nenv\nEOF","exec-stdin-heredoc-program"]
[2,"time bash <<'EOF'\nenv\nEOF","time-stdin-heredoc-program"]
[2,"bash -c 'bash' <<'EOF'\nenv\nEOF","command-string-stdin-heredoc-program"]
[2,"eval 'bash' <<'EOF'\nenv\nEOF","eval-stdin-heredoc-program"]
[2,"cat <<'EOF' | bash -c 'bash'\nenv\nEOF","piped-command-string-stdin-heredoc-program"]
[2,"cat <<'EOF' | eval 'sh'\nprintenv\nEOF","piped-eval-stdin-heredoc-program"]
[2,"bash -c ':; bash' <<'EOF'\nenv\nEOF","later-command-string-stdin-program"]
[2,"bash wrapper.sh env NAME=value bash <<'EOF'\nenv\nEOF","wrapper-shell-stdin-heredoc-program"]
[2,"if :; then nohup bash <<'EOF'\nenv\nEOF\nfi","conditional-wrapper-stdin-program"]
[2,"cat <<'INPUT' | bash -c 'cat <<OUTPUT\n$(bash)\nOUTPUT'\nenv\nINPUT","nested-heredoc-expansion-inherits-input"]
[2,"sh <<'EOF'\nprintenv\nEOF","sh-quoted-heredoc-program"]
[2,"sh -s <<'EOF'\nenv\nEOF","sh-stdin-heredoc-program"]
[2,"command bash <<'EOF'\nenv\nEOF","forwarded-heredoc-program"]
[2,"env NAME=value bash <<'EOF'\nenv\nEOF","env-heredoc-program"]
[2,"sudo -u NAME sh <<'EOF'\nprintenv\nEOF","sudo-heredoc-program"]
[2,"cat <<'EOF' | bash\nenv\nEOF","piped-heredoc-program"]
[2,"cat <<'EOF' | exec bash\nenv\nEOF","piped-exec-heredoc-program"]
[2,"cat <<'EOF' | timeout 60 bash\nenv\nEOF","piped-timeout-heredoc-program"]
[2,"cat <<'EOF' | nice bash\nprintenv\nEOF","piped-nice-heredoc-program"]
[2,"cat <<'EOF' | sudo -s\nenv\nEOF","piped-sudo-shell-heredoc-program"]
[2,"cat <<'EOF' | xargs -I{} {}\nenv\nEOF","piped-xargs-heredoc-program"]
[2,"cat <<'EOF' | cat | exec bash\nenv\nEOF","indirect-piped-exec-heredoc-program"]
[0,"cat <<'EOF' | timeout 60 bash\nprintf done\nEOF","unproved-pipe-without-known-read"]
[2, "cat <<'EOF' \u007c& bash\nenv\nEOF", "copilot-merged-pipe-heredoc-program"]
[2, "cat <<'FIRST' 3<<SECOND \u007c& bash\nenv\nFIRST\nordinary\nSECOND", "mixed-body-merged-pipeline"]
[2, "cat 3<<FIRST <<'SECOND' \u007c& bash\nordinary\nFIRST\nprintenv\nSECOND", "reversed-mixed-body-merged-pipeline"]
[2, "{ cat <<'FIRST' 3<<SECOND \u007c& sh; }\nenv\nFIRST\nordinary\nSECOND", "mixed-body-merged-pipeline-group"]
[2, "cat <<'EOF' \u007c& bash; cat <<AUX\nenv\nEOF\nplain\nAUX", "merged-heredoc-cut-overwritten-by-later-unquoted-body"]
[2, "cat <<AUX; cat <<'EOF' \u007c& bash\nplain\nAUX\nenv\nEOF", "merged-heredoc-cut-overwritten-by-earlier-unquoted-body"]
[2, "cat <<'EOF' \u007c& bash\nenv\nEOF", "copilot-inline-merged-pipe-heredoc-program"]
[2, "{ cat <<'EOF' \u007c& command env NAME=value bash; }\nenv\nEOF", "grouped-merged-piped-heredoc-program"]
[2, "cat <<'EOF' \u007c& cat | sh -s\nprintenv\nEOF", "indirect-merged-piped-heredoc-program"]
[0, "cat <<'EOF' | cat\nenv\nEOF", "pipeline-heredoc-data-data"]
[0, "cat <<'EOF' | cat | cat\nenv\nEOF", "pipeline-heredoc-data-chain"]
[2, "bash -c 'cat | cat' <<'EOF'\nenv\nEOF", "inherited-pipeline-heredoc-retains-main-refusal"]
[2, "bash -c 'cat \u007c& cat' <<'EOF'\nenv\nEOF", "inherited-merged-pipeline-heredoc-retains-main-refusal"]
[2, "eval 'cat \u007c& cat' <<'EOF'\nenv\nEOF", "eval-inherited-pipeline-heredoc-retains-main-refusal"]
[0, "cat <<'EOF' | bash\nprintf done\nEOF", "pipeline-heredoc-without-known-read"]
[0, "cat <<'EOF' \u007c& bash\nprintf done\nEOF", "merged-pipeline-heredoc-without-known-read"]
[0,"cat <<'EOF' '\u007c&' > script.py\nif __name__ == \"__main__\":\n    options = 'set -euo pipefail'\n    launcher = \"env NAME=value command-name\"\n    print(options)\nEOF","quoted-operator-with-heredoc-remains-data"]
[2,"cat <<'EOF' | cat | sh -s\nprintenv\nEOF","indirect-piped-heredoc-program"]
[2,"{ cat <<'EOF' | command env NAME=value bash; }\nenv\nEOF","grouped-piped-heredoc-program"]
[2,"source /dev/stdin <<'EOF'\nenv\nEOF","sourced-heredoc-program","project","environment-dump","-","runs-env"]
[2,". /dev/stdin <<'EOF'\nprintenv\nEOF","dot-heredoc-program"]
[2,"bash <<< 'env'","shell-here-string-program","project","environment-dump","-","runs-env"]
[2,"cat <<< 'env' | sh","piped-here-string-program","project","environment-dump","-","runs-env"]
[0, "bash -c 'cat \u007c& cat' <<< 'printenv NAME'", "inherited-merged-here-string-main-refusal"]
[0,"bash <<'EOF'\nset -euo pipefail\nprintf done\nEOF","safe-heredoc-shell-program"]
[0,"bash <<'EOF'\nprintenv NAME\nEOF","named-heredoc-shell-program"]
[2,"bash <<'EOF'\nenv | grep NAME\nEOF","heredoc-program-filter-stays-unproved"]
[2,"bash 0<<'EOF'\nenv\nEOF","explicit-stdin-heredoc-program"]
[2,"bash <<'FIRST' 3<<'SECOND'\nenv\nFIRST\ndata\nSECOND","non-stdin-heredoc-keeps-stdin-program"]
[2,"bash <<'FIRST' <<'SECOND'\n'\nFIRST\nenv\nSECOND","shell-heredoc-bodies-have-independent-quotes"]
[2,"cat <<'EOF' | bash 3< other\nenv\nEOF","non-stdin-redirect-keeps-piped-program"]
[2,"bash /dev/stdin <<'EOF'\nenv\nEOF","shell-stdin-script-program"]
[2,"sh /proc/self/fd/0 <<'EOF'\nenv\nEOF","shell-proc-stdin-script-program"]
[2,"bash /dev/fd/0 <<'EOF'\nenv\nEOF","shell-fd-stdin-script-program"]
[2,"cat <<'EOF' | bash /dev/stdin\nenv\nEOF","piped-stdin-script-program"]
[2,"bash 3<<'EOF' 0<&3\nenv\nEOF","shell-duplicated-heredoc-program"]
[2,"sh 3<<'EOF' 0<&3-\nenv\nEOF","shell-moved-heredoc-program"]
[2,"bash /dev/fd/3 3<<'EOF'\nenv\nEOF","shell-descriptor-script-program"]
[2,"source /dev/stdin 3<<'EOF' 0<&3\nenv\nEOF","source-duplicated-heredoc-program"]
[2,". /dev/fd/3 3<<'EOF'\nprintenv\nEOF","source-descriptor-script-program"]
[2,"exec 3<<'EOF'\nenv\nEOF\nbash /dev/fd/3","carried-shell-descriptor-program"]
[2,"exec 3<<'EOF'\nprintenv\nEOF\n. /dev/fd/3","carried-source-descriptor-program"]
[2,"exec 3<<<'env'; bash /dev/fd/3","carried-here-string-descriptor-program","project","environment-dump","-","runs-env"]
[2,"exec 3<<'EOF'; bash /dev/fd/3\nenv\nEOF","carried-semicolon-descriptor-program"]
[2,"exec 3<<<'env' && bash /dev/fd/3","carried-conditional-descriptor-program"]
[2,"{ exec 3<<<'env'; bash /dev/fd/3; }","carried-grouped-descriptor-program"]
[2,"command exec 3<<<'env'; source /dev/fd/3","carried-forwarded-descriptor-program"]
[2,"builtin exec 3<<<'env'; . /dev/fd/3","carried-builtin-descriptor-program"]
[2,"NAME=value exec 3<<<'env'; bash /dev/fd/3","carried-assignment-descriptor-program"]
[0,"exec 3<<'EOF'\nprintenv NAME\nEOF\nbash /dev/fd/3","carried-named-read-retains-main-refusal"]
[0,"exec 3<<'EOF'\nenv NAME=value command-name\nEOF\nbash /dev/fd/3","carried-launcher-retains-main-refusal"]
[2,"exec 3<<'EOF'\n$'en\\166'\nEOF\nbash /dev/fd/3","carried-encoded-producer-retains-main-refusal","project","environment-dump","undecoded-ansi-escape"]
[2,"bash -c 'bash 0<&0' <<'EOF'\nenv\nEOF","command-string-stdin-self-duplicate"]
[2,"bash -c 'bash < /dev/stdin' <<'EOF'\nenv\nEOF","command-string-stdin-alias"]
[2,"bash -c 'bash < /proc/self/fd/0' <<'EOF'\nenv\nEOF","command-string-proc-stdin-alias"]
[2,"bash <<EOF; env","unread-shell-heredoc-body"]
[2,"bash -c 'bash' <<'EOF'; printenv","unread-command-string-heredoc-body"]
[2,"sh <<X && printenv","unread-conditional-heredoc-body"]
[2,"cat <<X | bash; env","unread-piped-heredoc-body"]
[2,"bash <<EOF; printf 'line\nbreak'; env","unread-heredoc-quoted-newline"]
[2,"bash <<EOF","unregistered-heredoc-final-word"]
[2,"env\ncat << << X\nbody\nX","dump-before-unregistered-heredoc-redirect"]
[2,"printenv\ncat <<- << X\nbody\nX","printenv-before-unregistered-heredoc-redirect"]
[2,"{ env; }\ncat << << X\nbody\nX","grouped-dump-before-unregistered-heredoc"]
[2,"bash -c 'env'\ncat << << X\nbody\nX","shell-string-before-unregistered-heredoc"]
[2,"cat <<FIRST <<'SECOND'\n$(env >&2)\nFIRST\ndata\nSECOND","mixed-heredoc-expansion"]
[2,"cat <<'FIRST' <<SECOND\ndata\nFIRST\n$(printenv >&2)\nSECOND","reversed-mixed-heredoc-expansion"]
[2,"cat <<FIRST <<'SECOND'\n'$(env >&2)'\nFIRST\ndata\nSECOND","unquoted-heredoc-single-quotes-expand"]
[2,"cat <<FIRST <<'SECOND'\n\\$(env)\nFIRST\n$(env)\nSECOND","mixed-heredoc-literal-data"]
[2,"cat <<EOF\nenv\nEOF","unquoted-heredoc-literal-word-data"]
[2,"cat <<$EOF\n$(env >&2)\n$EOF","unquoted-dollar-delimiter-expansion"]
[0,"cat <<\\$EOF\n$(env)\n$EOF","escaped-dollar-delimiter-data"]
[2,"{ bash -c 'env'; }","grouped-shell-command-string"]
[2,"{ sh -c 'env'; }","grouped-sh-command-string"]
[2,"exec bash -c 'env'","exec-shell-command-string"]
[2,"time bash -c 'env'","time-shell-command-string"]
[2,"{ eval 'env'; }","grouped-eval-command-string"]
[2,"if true; then sh -c 'printenv'; fi","conditional-shell-command-string"]
[2,"for ITEM in one; do eval 'env'; done","loop-eval-command-string"]
[2,"bash -c -- 'env'","shell-command-string-options-end"]
[2,"bash -c -e 'env'","shell-command-string-option-after-c"]
[2,"bash -c -o pipefail 'env'","shell-command-string-option-operand-after-c"]
[2,"bash -ec -u 'env'","shell-command-string-grouped-options"]
[2,"bash -co pipefail 'env'","shell-command-string-grouped-option-operand"]
[2,"bash -coo errexit pipefail 'env'","shell-command-string-multiple-option-operands","project","environment-dump","-","runs-env"]
[2,"bash -coO pipefail extglob 'env'","shell-command-string-mixed-option-operands"]
[2,"bash -c -oo errexit pipefail 'env'","shell-command-string-separate-multiple-operands"]
[2,"command env NAME=value bash -coo errexit pipefail 'env'","forwarded-shell-multiple-option-operands"]
[2,"bash wrapper.sh bash -coO pipefail extglob 'env'","suffix-shell-multiple-option-operands"]
[2,"exec bash -coO pipefail extglob 'env'","exec-shell-multiple-option-operands"]
[2,"bash -c \"bash -coo errexit pipefail 'env'\"","nested-shell-multiple-option-operands"]
[0,"bash -coo errexit pipefail 'printenv NAME'","multiple-operands-named-read-retains-main-refusal"]
[0,"bash -coo errexit pipefail 'printf done'","multiple-operands-without-known-read"]
[2,"bash -c -eo pipefail 'env'","shell-command-string-grouped-operand-after-c"]
[2,"bash -c +o pipefail 'env'","shell-command-string-positive-option-operand"]
[2,"bash -c -O extglob 'env'","shell-command-string-shopt-operand-after-c"]
[2,"{ command bash -c -o pipefail -- 'env'; }","forwarded-command-string-option-operand"]
[2,"bash -c -o pipefail \"sh -c -e 'env'\"","nested-command-string-option-operand"]
[0,"bash -c -e \"printf '%s' 'env'\"","shell-option-quoted-argument-data"]
[0,"bash -c -o pipefail -- 'printenv NAME'","shell-option-named-read"]
[0,"bash -co pipefail \"printf '%s' 'env'\"","shell-grouped-option-argument-data"]
[0,"bash -c 'set -euo pipefail; jq -r \".[].id\" \"$1\" | while IFS= read -r job_id; do gh api \"repos/vanillagreencom/fleet/actions/jobs/${job_id}/logs\" | awk \"/check: member|fail|FAIL|deadline|cancel|Cancel|Error/ {print}\" > \"tmp/notes/g140/1292-log-${job_id}.txt\"; done' _ tmp/notes/g140/1292-first-ten.json","fleet-literal-command-string-setup"]
[0,"bash -c 'set -e; printf done'","literal-source-set-option-on"]
[0,"bash -c 'set +x; printf done'","literal-source-set-option-off"]
[0,"bash -c 'set -- env printenv set; printf done'","literal-source-set-positional"]
[0,"eval 'set -euo' 'pipefail; printf done'","literal-eval-joined-setup"]
[0,"eval 'printenv' 'NAME'","literal-eval-joined-named-read"]
[2,"eval -- 'env'","literal-eval-option-terminator"]
[2,"bash -c 'set'","literal-source-bare-set"]
[2,"bash -c 'set \"$@\"'","literal-source-unknown-set-operands"]
[2,"bash -c 'set -e; env'","literal-source-setup-then-env"]
[2,"bash -c 'set -e; printenv'","literal-source-setup-then-printenv"]
[0,"bash \"$MODE\" -c 'set -e'","unproved-shell-option-before-setup"]
[2,["bash","-c","$'s\\x65t' -e"],"literal-source-encoded-setup-head","project","environment-dump","undecoded-ansi-escape"]
[2,"command bash -c -- 'env'","forwarded-command-string-options-end"]
[2,"env NAME=value bash -c -- 'env'","env-command-string-options-end"]
[2,"{ sudo -u NAME command bash -c -- 'env'; }","nested-forwarded-command-string"]
[2,"{ bash -o pipefail -c -- 'env'; }","nested-shell-option-operand"]
[2,"{ eval 'command env NAME=value printenv'; }","nested-eval-launcher"]
[0,"{ eval 'printenv' 'NAME'; }","eval-joined-named-read"]
[0,"{ eval \"printf '%s' 'env'\"; }","eval-quoted-argument-data"]
[2,"{ NAME=value 'env'; }","assignment-quoted-command-head"]
[2,"if NAME=value \"env\"; then :; fi","conditional-assignment-quoted-head"]
[2,"time 'env'","time-quoted-command-head"]
[2,"time -p 'env'","time-option-quoted-command-head"]
[2,"! NAME=value \"env\"","negated-assignment-quoted-head"]
[2,"while NAME=value 'env'; do :; done","loop-assignment-quoted-head"]
[2,"function f { NAME=value 'env'; }; f","function-assignment-quoted-head"]
[2,"case W in N) :;; esac; env","empty-case-stage-before-dump"]
[2,"for ITEM in one; do :; done\n\nenv","empty-newline-stage-before-dump"]
[0,"{ printf done; }\n\n","empty-trailing-stage-data"]
[2,"set $NAME","set-unquoted-variable-can-disappear"]
[2,"set ${LIST}","set-unquoted-braced-variable-can-disappear"]
[2,"set \"$@\"","set-quoted-spread-can-disappear"]
[2,"set \"${LIST[@]}\"","set-quoted-array-can-disappear"]
[2,"bash wrapper.sh set $NAME","suffix-set-variable-can-disappear"]
[0,"set -o \"$NAME\"","set-literal-option-stays-present"]
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
[0,"env PATH=\"$PATH\" git status","env-variable-assignment-launcher"]
[0,"env NAME=$VALUE printf hello","env-unquoted-variable-assignment-launcher"]
[0,"env -- NAME=$VALUE git status","env-variable-assignment-after-options"]
[0,"env --chdir=\"$PWD\" git status","env-variable-chdir-launcher"]
[0,"env --unset=$NAME git status","env-variable-unset-launcher"]
[0,"command env PATH=\"$PATH\" git status","command-env-variable-assignment-launcher"]
[0,"sudo env PATH=\"$PATH\" git status","sudo-env-variable-assignment-launcher"]
[2,"env PATH=\"$PATH\" printenv","env-variable-assignment-dump-target"]
[2,"env --chdir=\"$PWD\" printenv","env-variable-chdir-dump-target"]
[2,"env --unset=$NAME printenv","env-variable-unset-dump-target"]
[2,"env $'NAME=value' git status","env-dollar-assignment-stays-unproved"]
[2,"env $'--chdir=somewhere' git status","env-dollar-option-stays-unproved"]
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
[0,"bash wrapper.sh env NAME=value OTHER=value command-name args","wrapper-launcher"]
[0,"sh /workspace/tmp/waiter.ABC123/launch.sh /workspace/tmp/waiter.ABC123/wait .agents/skills/worktree/scripts/worktree push KEN-4156 --set-upstream","waiter-launch-worktree-set-upstream"]
[0,"bash wrapper.sh env NAME=value OTHER=value command-name args > out","wrapper-launcher-redirect"]
[0,"env -u NAME -u OTHER command-name args","unset-launcher"]
[0,"time env -u A -u B CMD ARGS > LOG","timed-unset-command-redirect"]
[0,"{ time env -u A -u B scripts/validate repo --changed SHA; } > LOG 2>&1; echo $? > EXIT","grouped-unset-command-recording"]
[0,"time env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE scripts/validate repo --changed db814e708e8a630b051a0c95f165e0c38cbfb6d7 > LOG","reported-timed-unset-validation"]
[2,"time env -u A -u B > LOG","timed-unset-without-command"]
[2,"{ time env -u A -u B; } > LOG 2>&1; echo $? > EXIT","grouped-unset-without-command"]
[2,"time env -u A -u B printenv > LOG","timed-unset-dump-command"]
[2,"{ time env -u A -u B printenv; } > LOG 2>&1; echo $? > EXIT","grouped-unset-dump-command"]
[2,"time env -u A -u B bash -c 'env' > LOG","timed-unset-shell-dump-command"]
[2,"time env -u A -u B CMD ARGS > LOG; env","dump-after-timed-unset-command"]
[2,"{ time env -u A -u B scripts/validate repo --changed SHA; } > LOG 2>&1; printenv > EXIT","dump-after-grouped-unset-command"]
[0,"bash wrapper.sh env -u NAME -u OTHER command-name args","wrapper-unset-launcher"]
[0,"bash wrapper.sh env -u env -u set command-name args > out","wrapper-unset-producer-operands"]
[0,"bash wrapper.sh env -i NAME=value command-name","wrapper-empty-launcher"]
[0,"bash wrapper.sh env --unset=NAME NAME=value command-name","wrapper-inline-unset-launcher"]
[0,"bash wrapper.sh env -- NAME=value command-name","wrapper-options-end-launcher"]
[2,"bash wrapper.sh env","wrapper-bare-env"]
[2,"bash wrapper.sh env > out","wrapper-bare-env-redirect"]
[2,"bash wrapper.sh env NAME=value","wrapper-assignment-only"]
[2,"env -u NAME","unset-without-program"]
[2,"bash wrapper.sh env -u NAME -u OTHER > out","wrapper-unset-without-program"]
[2,"bash wrapper.sh env --unset=NAME","wrapper-inline-unset-without-program"]
[2,"bash wrapper.sh env -0","wrapper-null-env"]
[2,"bash wrapper.sh env --null","wrapper-long-null-env"]
[2,"bash wrapper.sh env NAME=value printenv","wrapper-launcher-dump"]
[2,"bash wrapper.sh env NAME=value env","wrapper-launcher-env-chain"]
[0,"bash wrapper.sh 'env NAME=value command-name args'","wrapper-quoted-launcher-data"]
[0,"bash wrapper.sh \"env -u NAME -u OTHER command-name args\"","wrapper-quoted-unset-data"]
[0,"sh LAUNCH.sh WAIT env VAR=1 TOOL --test 'env -u A -u B VAR=1 bash test.sh' --build 'bash -n build.sh'","waiter-quoted-unset-command"]
[0,"sh LAUNCH.sh WAIT env VAR=1 TOOL --test 'unset A B; export VAR=1; exec bash test.sh' --build 'bash -n build.sh'","waiter-quoted-setup-command"]
[0,"env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE sh tmp/waiter.X/launch.sh bash -c 'scripts/validate logic --changed c18e; scripts/validate manifests --changed c18e; scripts/validate boundary --changed c18e; scripts/validate tools --changed c18e; scripts/validate repo --changed c18e'","outer-unset-waiter-literal-validation"]
[2,"sh LAUNCH.sh WAIT env VAR=1 TOOL --test 'env' --build 'bash -n build.sh'","waiter-quoted-env-dump"]
[2,"sh LAUNCH.sh WAIT env VAR=1 TOOL --test 'printenv' --build 'bash -n build.sh'","waiter-quoted-printenv-dump"]
[2,"sh LAUNCH.sh WAIT env VAR=1 TOOL --test 'unset A B; export VAR=1; exec bash test.sh; env'","waiter-quoted-setup-followed-by-dump"]
[2,"sh LAUNCH.sh WAIT env VAR=1 TOOL --test 'env -u A -u B VAR=1'","waiter-quoted-unset-without-program"]
[2,"sh LAUNCH.sh WAIT env VAR=1 TOOL --test 'env -u \"$@\" bash test.sh'","waiter-quoted-unproved-unset-operand"]
[0,"sh LAUNCH.sh WAIT env VAR=1 TOOL --test 'env -u A bash test.sh' > out","waiter-quoted-redirect-retains-refusal"]
[2,"sh LAUNCH.sh WAIT env VAR=1 TOOL --test \"env -u $NAME bash test.sh\"","waiter-expanded-command-retains-refusal"]
[2,"sh LAUNCH.sh WAIT env VAR=1 TOOL --test 'bash -c \"env\"'","waiter-quoted-nested-shell-dump"]
[2,"bash wrap.sh step cat \"/proc/self/environ\"","waiter-forwarded-cat-quoted-path"]
[2,"bash wrap.sh step systemctl --user 'show-environment'","waiter-forwarded-systemctl-quoted-verb"]
[2,"bash wrap.sh step 'cat' '/proc/self/environ'","waiter-forwarded-quoted-cat-and-path"]
[2,"bash wrap.sh step TOOL '/proc/self/environ'","waiter-forwarded-unresolved-proc-operand"]
[2,"bash wrap.sh step TOOL 'show-environment'","waiter-forwarded-unresolved-systemctl-operand"]
[0,"sh LAUNCH.sh WAIT 'env' VAR=1 TOOL --test 'env -u A -u B VAR=1 bash test.sh'","waiter-forwarded-quoted-env-head"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha db24bb747a1a55a77082dbdf1ec6f441542641c0 --test 'timeout 5 env' --build 'true' --mutate 'true'","waiter-unclassified-test-env"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha db24bb747a1a55a77082dbdf1ec6f441542641c0 --test 'timeout 5 printenv' --build 'true' --mutate 'true'","waiter-unclassified-test-printenv"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha db24bb747a1a55a77082dbdf1ec6f441542641c0 --test 'true' --build 'timeout 5 env' --mutate 'true'","waiter-unclassified-build-env"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha db24bb747a1a55a77082dbdf1ec6f441542641c0 --test 'true' --build 'timeout 5 printenv' --mutate 'true'","waiter-unclassified-build-printenv"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha db24bb747a1a55a77082dbdf1ec6f441542641c0 --test 'true' --build 'true' --mutate 'timeout 5 env'","waiter-unclassified-mutate-env"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha db24bb747a1a55a77082dbdf1ec6f441542641c0 --test 'true' --build 'true' --mutate 'timeout 5 printenv'","waiter-unclassified-mutate-printenv"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 84ecebaad618841f58f67d71a1da25c9034280f2 --test 'bash -c \"timeout 5 env\"' --build 'true' --mutate 'true'","waiter-recursive-test-bash-env"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 84ecebaad618841f58f67d71a1da25c9034280f2 --test 'bash -c \"timeout 5 printenv\"' --build 'true' --mutate 'true'","waiter-recursive-test-bash-printenv"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 84ecebaad618841f58f67d71a1da25c9034280f2 --test 'sh -c \"timeout 5 env\"' --build 'true' --mutate 'true'","waiter-recursive-test-sh-env"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 84ecebaad618841f58f67d71a1da25c9034280f2 --test 'sh -c \"timeout 5 printenv\"' --build 'true' --mutate 'true'","waiter-recursive-test-sh-printenv"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 84ecebaad618841f58f67d71a1da25c9034280f2 --test 'eval \"timeout 5 env\"' --build 'true' --mutate 'true'","waiter-recursive-test-eval-env"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 84ecebaad618841f58f67d71a1da25c9034280f2 --test 'eval \"timeout 5 printenv\"' --build 'true' --mutate 'true'","waiter-recursive-test-eval-printenv"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 84ecebaad618841f58f67d71a1da25c9034280f2 --test 'true' --build 'bash -c \"timeout 5 env\"' --mutate 'true'","waiter-recursive-build-bash-env"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 84ecebaad618841f58f67d71a1da25c9034280f2 --test 'true' --build 'bash -c \"timeout 5 printenv\"' --mutate 'true'","waiter-recursive-build-bash-printenv"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 84ecebaad618841f58f67d71a1da25c9034280f2 --test 'true' --build 'sh -c \"timeout 5 env\"' --mutate 'true'","waiter-recursive-build-sh-env"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 84ecebaad618841f58f67d71a1da25c9034280f2 --test 'true' --build 'sh -c \"timeout 5 printenv\"' --mutate 'true'","waiter-recursive-build-sh-printenv"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 84ecebaad618841f58f67d71a1da25c9034280f2 --test 'true' --build 'eval \"timeout 5 env\"' --mutate 'true'","waiter-recursive-build-eval-env"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 84ecebaad618841f58f67d71a1da25c9034280f2 --test 'true' --build 'eval \"timeout 5 printenv\"' --mutate 'true'","waiter-recursive-build-eval-printenv"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 84ecebaad618841f58f67d71a1da25c9034280f2 --test 'true' --build 'true' --mutate 'bash -c \"timeout 5 env\"'","waiter-recursive-mutate-bash-env"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 84ecebaad618841f58f67d71a1da25c9034280f2 --test 'true' --build 'true' --mutate 'bash -c \"timeout 5 printenv\"'","waiter-recursive-mutate-bash-printenv"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 84ecebaad618841f58f67d71a1da25c9034280f2 --test 'true' --build 'true' --mutate 'sh -c \"timeout 5 env\"'","waiter-recursive-mutate-sh-env"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 84ecebaad618841f58f67d71a1da25c9034280f2 --test 'true' --build 'true' --mutate 'sh -c \"timeout 5 printenv\"'","waiter-recursive-mutate-sh-printenv"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 84ecebaad618841f58f67d71a1da25c9034280f2 --test 'true' --build 'true' --mutate 'eval \"timeout 5 env\"'","waiter-recursive-mutate-eval-env"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 84ecebaad618841f58f67d71a1da25c9034280f2 --test 'true' --build 'true' --mutate 'eval \"timeout 5 printenv\"'","waiter-recursive-mutate-eval-printenv"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'bash -c \"eval \\\"timeout 5 env\\\"\"'","waiter-recursive-shell-eval-env"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'bash -c \"printf %s env\"'","waiter-recursive-command-data-refusal"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha d770931eece9b9256c8cce59e1aa4cb46d8f54c2 --test 'cat <<EOF\n$(xargs env)\nEOF' --build 'true' --mutate 'true'","waiter-registry-test-expand-xargs"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha d770931eece9b9256c8cce59e1aa4cb46d8f54c2 --test 'cat <<EOF\n$(timeout 5 env)\nEOF' --build 'true' --mutate 'true'","waiter-registry-test-expand-timeout"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha d770931eece9b9256c8cce59e1aa4cb46d8f54c2 --test 'bash <<EOF\ntimeout 5 env\nEOF' --build 'true' --mutate 'true'","waiter-registry-test-execute-body"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha d770931eece9b9256c8cce59e1aa4cb46d8f54c2 --test 'true' --build 'cat <<EOF\n$(xargs env)\nEOF' --mutate 'true'","waiter-registry-build-expand-xargs"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha d770931eece9b9256c8cce59e1aa4cb46d8f54c2 --test 'true' --build 'cat <<EOF\n$(timeout 5 env)\nEOF' --mutate 'true'","waiter-registry-build-expand-timeout"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha d770931eece9b9256c8cce59e1aa4cb46d8f54c2 --test 'true' --build 'bash <<EOF\ntimeout 5 env\nEOF' --mutate 'true'","waiter-registry-build-execute-body"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha d770931eece9b9256c8cce59e1aa4cb46d8f54c2 --test 'true' --build 'true' --mutate 'cat <<EOF\n$(xargs env)\nEOF'","waiter-registry-mutate-expand-xargs"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha d770931eece9b9256c8cce59e1aa4cb46d8f54c2 --test 'true' --build 'true' --mutate 'cat <<EOF\n$(timeout 5 env)\nEOF'","waiter-registry-mutate-expand-timeout"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha d770931eece9b9256c8cce59e1aa4cb46d8f54c2 --test 'true' --build 'true' --mutate 'bash <<EOF\ntimeout 5 env\nEOF'","waiter-registry-mutate-execute-body"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'cat <<EOF\n`xargs env`\nEOF'","waiter-registry-backticks"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'cat <<-EOF\n\t$(timeout 5 env)\n\tEOF'","waiter-registry-tabs"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'cat 0<<EOF\n$(xargs env)\nEOF'","waiter-registry-explicit-stdin"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'cat 3<<EOF\n$(xargs env)\nEOF'","waiter-registry-nonstdin-expansion"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'bash <<'\\''EOF'\\''\ntimeout 5 env\nEOF'","waiter-registry-quoted-body"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'bash <<\"EOF\"\ntimeout 5 env\nEOF'","waiter-registry-double-quoted-body"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'sh <<EOF\ntimeout 5 env\nEOF'","waiter-registry-sh-body"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'bash -s <<EOF\ntimeout 5 env\nEOF'","waiter-registry-shell-option-body"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'bash /dev/fd/3 3<<'\\''EOF'\\''\ntimeout 5 env\nEOF'","waiter-registry-nonstdin-body"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'source /dev/fd/3 3<<'\\''EOF'\\''\ntimeout 5 env\nEOF'","waiter-registry-source-descriptor"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'bash -c '\\''bash'\\'' <<'\\''EOF'\\''\ntimeout 5 env\nEOF'","waiter-registry-inherited-queue"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'bash -c \"bash -c bash\" <<'\\''EOF'\\''\ntimeout 5 env\nEOF'","waiter-registry-inherited-deep"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'eval '\\''bash'\\'' <<'\\''EOF'\\''\ntimeout 5 env\nEOF'","waiter-registry-inherited-eval"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'bash <<'\\''OUTER'\\''\nbash <<'\\''INNER'\\''\ntimeout 5 env\nINNER\nOUTER'","waiter-registry-nested-executable"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'bash <<'\\''OUTER'\\''\ncat <<INNER\n$(xargs env)\nINNER\nOUTER'","waiter-registry-nested-expansion"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'bash <<'\\''FIRST'\\'' 3<<SECOND\ntimeout 5 env\nFIRST\n$(xargs env)\nSECOND'","waiter-registry-multiple-bodies"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'bash -c '\\''eval bash'\\'' <<'\\''EOF'\\''\ntimeout 5 env\nEOF'","waiter-registry-queued-to-eval"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'bash -c '\\''cat <<EOF\n$(xargs env)\nEOF'\\'''","waiter-registry-queued-shell-source"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'eval '\\''cat <<EOF\n$(xargs env)\nEOF'\\'''","waiter-registry-queued-eval-source"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'cat <<'\\''EOF'\\''\n$(xargs env)\nEOF'","waiter-registry-quoted-cat-data"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'cat <<EOF\ntimeout 5 env\nEOF'","waiter-registry-unquoted-cat-data"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'cat <<\"EOF\"\n$(timeout 5 env)\nEOF'","waiter-registry-double-quoted-cat-data"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'python3 <<'\\''EOF'\\''\nprint('\\''timeout 5 env'\\'')\nEOF'","waiter-registry-python-data"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'bash <<'\\''EOF'\\''\nprintenv NAME\nEOF'","waiter-registry-named-shell-body"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'bash <<'\\''EOF'\\''\nset -o pipefail\nEOF'","waiter-registry-set-action-body"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'printenv NAME; cat <<'\\''EOF'\\''\nordinary text\nEOF'","waiter-registry-complete-source"]
[0,"sh LAUNCH.sh WAIT TOOL --test 'cat <<'\\''EOF'\\''\nordinary text\nEOF'","waiter-registry-plain-data"]
[0,"sh LAUNCH.sh WAIT TOOL --test 'cat <<< ordinary'","waiter-registry-plain-here-string"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 1716377973bdbe7474aff9de8e3d9591976156f9 --test 'xargs env' --build 'true' --mutate 'true'","waiter-result-test-xargs-env"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 1716377973bdbe7474aff9de8e3d9591976156f9 --test 'xargs printenv' --build 'true' --mutate 'true'","waiter-result-test-xargs-printenv"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 1716377973bdbe7474aff9de8e3d9591976156f9 --test 'grep -a . /proc/self/environ' --build 'true' --mutate 'true'","waiter-result-test-grep-proc"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 1716377973bdbe7474aff9de8e3d9591976156f9 --test 'bash -c \"xargs env\"' --build 'true' --mutate 'true'","waiter-result-test-shell-xargs"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 1716377973bdbe7474aff9de8e3d9591976156f9 --test 'printf unused | xargs -I{} env' --build 'true' --mutate 'true'","waiter-result-test-pipe-xargs"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 1716377973bdbe7474aff9de8e3d9591976156f9 --test 'true' --build 'xargs env' --mutate 'true'","waiter-result-build-xargs-env"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 1716377973bdbe7474aff9de8e3d9591976156f9 --test 'true' --build 'xargs printenv' --mutate 'true'","waiter-result-build-xargs-printenv"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 1716377973bdbe7474aff9de8e3d9591976156f9 --test 'true' --build 'grep -a . /proc/self/environ' --mutate 'true'","waiter-result-build-grep-proc"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 1716377973bdbe7474aff9de8e3d9591976156f9 --test 'true' --build 'bash -c \"xargs env\"' --mutate 'true'","waiter-result-build-shell-xargs"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 1716377973bdbe7474aff9de8e3d9591976156f9 --test 'true' --build 'printf unused | xargs -I{} env' --mutate 'true'","waiter-result-build-pipe-xargs"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 1716377973bdbe7474aff9de8e3d9591976156f9 --test 'true' --build 'true' --mutate 'xargs env'","waiter-result-mutate-xargs-env"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 1716377973bdbe7474aff9de8e3d9591976156f9 --test 'true' --build 'true' --mutate 'xargs printenv'","waiter-result-mutate-xargs-printenv"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 1716377973bdbe7474aff9de8e3d9591976156f9 --test 'true' --build 'true' --mutate 'grep -a . /proc/self/environ'","waiter-result-mutate-grep-proc"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 1716377973bdbe7474aff9de8e3d9591976156f9 --test 'true' --build 'true' --mutate 'bash -c \"xargs env\"'","waiter-result-mutate-shell-xargs"]
[2,"sh LAUNCH.sh WAIT .agents/skills/reviewer/scripts/mutation-stability --worktree REPO --sha 1716377973bdbe7474aff9de8e3d9591976156f9 --test 'true' --build 'true' --mutate 'printf unused | xargs -I{} env'","waiter-result-mutate-pipe-xargs"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'grep -a . < /proc/self/environ'","waiter-result-grep-redirect"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'cat env'","waiter-result-cat-unresolved"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'tr env x'","waiter-result-tr-unresolved"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'strings env'","waiter-result-strings-unresolved"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'systemctl status env'","waiter-result-systemctl-unresolved"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'declare'","waiter-result-declare-unresolved"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'typeset'","waiter-result-typeset-unresolved"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'command xargs env'","waiter-result-command-target"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'sudo -n xargs env'","waiter-result-sudo-target"]
[2,"sh LAUNCH.sh WAIT TOOL --test 'env VAR=1 xargs env'","waiter-result-assignment-target"]
[0,"sh LAUNCH.sh WAIT TOOL --test 'printenv NAME'","waiter-receipt-printenv-named"]
[0,"sh LAUNCH.sh WAIT TOOL --test 'printenv --help'","waiter-receipt-printenv-help"]
[0,"sh LAUNCH.sh WAIT TOOL --test 'export VAR=1'","waiter-receipt-export-assignment"]
[0,"sh LAUNCH.sh WAIT TOOL --test 'declare -p NAME'","waiter-receipt-declare-named"]
[0,"sh LAUNCH.sh WAIT TOOL --test 'typeset -p NAME'","waiter-receipt-typeset-named"]
[0,"sh LAUNCH.sh WAIT TOOL --test 'set -o pipefail'","waiter-receipt-set-action"]
[0,"sh LAUNCH.sh WAIT TOOL --test 'set -- env printenv set'","waiter-receipt-set-operands"]
[0,"bash wrapper.sh 'env'","wrapper-quoted-bare-env-data"]
[0,"{ printf '%s' 'env NAME=value command-name'; }","suffix-quoted-launcher-data"]
[0,"bash wrapper.sh set -o pipefail","wrapper-set-pipefail"]
[0,"bash wrapper.sh set -euo pipefail","wrapper-set-strict"]
[0,"bash wrapper.sh set +x","wrapper-set-option-off"]
[0,"bash wrapper.sh set -- args","wrapper-set-operands"]
[2,"bash wrapper.sh set -- env printenv set","wrapper-set-producer-operands"]
[2,"bash wrapper.sh printenv env set","wrapper-named-producer-operands"]
[0,"bash wrapper.sh 'set -euo pipefail'","wrapper-quoted-set-data"]
[0,"{ printf '%s\\n' start > receipt; set -o pipefail; command-name args | tee -a receipt; printf 'exit=%s\\n' \"$?\" >> receipt; }","strict-set-receipt"]
[2,"set > out","bare-set-redirect"]
[2,"bash wrapper.sh set","wrapper-bare-set"]
[2,"sh wrapper.sh set","sh-wrapper-bare-set"]
[2,"bash wrapper.sh set > out","wrapper-bare-set-redirect"]
[0,"true; echo set","list-set-echo-after-semicolon"]
[0,"cd DIR && .agents/skills/orch/scripts/workflow-state set oversee launch_queue '[]'","list-set-workflow-state-argument"]
[0,"tool set x; true","list-set-first-stage-argument"]
[2,"true; set","list-bare-set-after-semicolon"]
[2,"set; true","list-bare-set-first-stage"]
[2,"true && set","list-bare-set-after-and"]
[2,"true | set","list-bare-set-pipe-receiver"]
[0,"cat <<'EOF' > script.py\nif __name__ == \"__main__\":\n    options = 'set -euo pipefail'\n    launcher = \"env NAME=value command-name\"\n    print(options)\nEOF","quoted-heredoc-script"]
[0,"cat > tmp/capture-helper.sh <<'HELPER'\nshell_env=(env NAME=value)\n# process env and export are data in this file\nHELPER\npython3 - <<'PY'\nfrom pathlib import Path\nsummary = Path('tmp/completion-summary.md')\nfor line in Path('tmp/screenshot-index').read_text().splitlines():\n    summary.write_text(summary.read_text() + '- ' + line + '\\n')\nPY","written-helper-followed-python-body"]
[2,"cat >/dev/stdout <<'E' | xargs -I{} sh -c {}\nenv\nE","redirected-cat-body-piped-to-interpreter"]
[0,"cat > tmp/capture-helper.sh <<'HELPER'\nshell_env=(env NAME=value)\n# process env and export are data in this file\nHELPER\npython3 -c 'pass'","written-helper-followed-python-command-baseline"]
[0,"cat > tmp/completion-summary.md <<'SUMMARY'\n## Completion summary\n- The page opens each file named by the user.\nSUMMARY\npython3 - <<'PY'\nfrom pathlib import Path\nsummary = Path('tmp/completion-summary.md')\nfor line in Path('tmp/screenshot-index').read_text().splitlines():\n    summary.write_text(summary.read_text() + '- ' + line + '\\n')\nPY","completion-summary-followed-python-body-baseline"]
[0,"set -- \"$a\" \"$b\"","set-positional-reset-baseline"]
[0,"cat <<\"EOF\" > script.py\nset -euo pipefail\nenv -u NAME -u OTHER command-name\n$(env)\nEOF","double-quoted-heredoc-data"]
[0,"cat <<\\EOF\nenv\nEOF","escaped-heredoc-delimiter"]
[0,"cat <<E'OF'\nenv\nEOF","split-quoted-heredoc-delimiter"]
[2,"cat <<-'EOF'\n\tenv\n\tEOF","tab-stripped-quoted-heredoc"]
[2,"cat <<'FIRST' <<'SECOND'\nenv\nFIRST\nset\nSECOND","multiple-quoted-heredocs"]
[2,"cat <<'EOF' > out\nenv NAME=value command-name\nEOF\nenv","dump-after-quoted-heredoc"]
[2,"cat <<'EOF'\nset -euo pipefail\nEOF\nset > out","set-after-quoted-heredoc"]
[2,"cat <<'EOF'\nEOF-not-the-delimiter\nenv\nEOF\nprintenv","heredoc-delimiter-exact-match"]
[0,"{ bash wrapper.sh env NAME=value command-name; printf '%s' env; }","launcher-before-later-suffix-dump"]
[0,"{ bash wrapper.sh env NAME=value command-name | printf '%s' env; }","launcher-before-later-suffix-pipe-dump"]
[2,"bash wrapper.sh 'env NAME=value command-name' \"$(env)\"","quoted-wrapper-substitution-dump"]
[2,"{ \"env\"; }","suffix-quoted-command-head"]
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
[2,"bash -c 'env'","opaque-shell-program","project","environment-dump","-","runs-env"]
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
[2,"strings /proc/self/environ 2 > dump | grep NAME","numeric-spaced-output"]
[2,"strings /proc/self/environ '2'> dump | grep NAME","numeric-single-quoted-output"]
[2,"strings /proc/self/environ \"2\"> dump | grep NAME","numeric-double-quoted-output"]
[2,"strings /proc/self/environ \\2> dump | grep NAME","numeric-escaped-output"]
[2,"strings /proc/self/environ 2 >> dump | grep NAME","numeric-spaced-append"]
[2,"strings /proc/self/environ '2'>> dump | grep NAME","numeric-single-quoted-append"]
[2,"strings /proc/self/environ \"2\">> dump | grep NAME","numeric-double-quoted-append"]
[2,"strings /proc/self/environ \\2>> dump | grep NAME","numeric-escaped-append"]
[2,"strings /proc/self/environ 2 > dump | grep NAME","numeric-spaced-output-default","absent-policy"]
[2,"strings /proc/self/environ '2'> dump | grep NAME","numeric-single-quoted-output-default","absent-policy"]
[2,"strings /proc/self/environ \"2\"> dump | grep NAME","numeric-double-quoted-output-default","absent-policy"]
[2,"strings /proc/self/environ \\2> dump | grep NAME","numeric-escaped-output-default","absent-policy"]
[2,"strings /proc/self/environ 2 >> dump | grep NAME","numeric-spaced-append-default","absent-policy"]
[2,"strings /proc/self/environ '2'>> dump | grep NAME","numeric-single-quoted-append-default","absent-policy"]
[2,"strings /proc/self/environ \"2\">> dump | grep NAME","numeric-double-quoted-append-default","absent-policy"]
[2,"strings /proc/self/environ \\2>> dump | grep NAME","numeric-escaped-append-default","absent-policy"]
[0,"strings /proc/self/environ 2> dump | grep NAME","adjacent-stderr-output"]
[0,"strings /proc/self/environ 2>> dump | grep NAME","adjacent-stderr-append"]
[0,"strings /proc/self/environ 2>&1 | grep NAME","adjacent-stderr-duplication"]
[2,"strings /proc/self/environ 3> dump | grep NAME","explicit-other-output"]
[2,"strings /proc/self/environ 02> dump | grep NAME","nonexact-stderr-output"]
[2,"env >> dump | grep NAME","stdout-append"]
[2,"env &> dump | grep NAME","both-stream-output"]
[2,"env &\u003e> dump","both-stream-append"]
[2,"env <> file","read-write-input"]
[2,"env &\u003e> dump","both-stream-append-default","absent-policy"]
[2,"env <> file","read-write-input-default","absent-policy"]
[2,"env &\u003e> 2","numeric-append-target"]
[2,"env <> command-name","command-like-read-write-target"]
[2,"strings /proc/self/environ 2&\u003e> dump | grep NAME","numeric-before-both-stream-append"]
[2,"strings /proc/self/environ 2<> file | grep NAME","stderr-read-write-input"]
[2,"cat <> /proc/self/environ","read-write-proc-input"]
[2,"cat <> $'\\x2fproc/self/environ'","read-write-escaped-input","project","environment-dump","undecoded-ansi-escape"]
[2,"env | grep NAME <> other-file","read-write-filter-input"]
[0,"env NAME=value git status &\u003e> dump","launcher-both-stream-append"]
[0,"env NAME=value git status <> file","launcher-read-write-input"]
[0,"env 2 > dump","numeric-launcher-operand"]
[0,"env '2'> dump","quoted-numeric-launcher-operand"]
[0,"env 2&\u003e> dump","numeric-before-both-stream-launcher"]
[0,"printenv NAME 2 > dump","named-read-numeric-operand"]
[0,"cat <<'EOF' > script.py\nenv\nEOF","default-descriptor-body-data"]
[2,"cat 0<<'EOF' > script.py\nenv\nEOF","explicit-stdin-body-data"]
[2,"cat 3<<'EOF' > script.py\nenv\nEOF","explicit-other-body-data"]
[2,"bash 2<<'EOF'\nenv\nEOF","stderr-descriptor-body-program"]
[0,"cat <<'2'> script.py\nenv\n2","numeric-heredoc-delimiter"]
[2,"env 2>&1>dump | grep NAME","compact-duplicate-target-write"]
[2,"env 2>&1>>dump | grep NAME","compact-duplicate-target-append"]
[2,"env >&2>dump | grep NAME","compact-stdout-duplicate-target-write"]
[2,"env >&2>>dump | grep NAME","compact-stdout-duplicate-target-append"]
[2,"env >2>dump | grep NAME","compact-write-target-write"]
[2,"env >>2>dump | grep NAME","compact-append-target-write"]
[2,"env <2>dump | grep NAME","compact-input-target-write"]
[2,"env <&2>dump | grep NAME","compact-input-duplicate-target-write"]
[2,"env <>2>dump | grep NAME","compact-read-write-target-write"]
[2,"env &>2>dump | grep NAME","compact-both-stream-target-write"]
[2,"env &\u003e>2>dump | grep NAME","compact-both-stream-append-target-write"]
[2,"env <<<2>dump | grep NAME","compact-here-string-target-write"]
[2,"env 2>&1>dump | grep NAME","compact-duplicate-target-write-default","absent-policy"]
[2,"env >&2>>dump | grep NAME","compact-stdout-duplicate-target-append-default","absent-policy"]
[0,"env 2>2 2>>dump | grep NAME","numeric-target-boundary-stderr-append"]
[0,"env 2>>2 2>dump | grep NAME","numeric-target-boundary-stderr-write"]
[0,"env 2>&1 2>dump | grep NAME","duplicate-target-boundary-stderr-write"]
[0,"env 2>file 2>&1 | grep NAME","named-target-boundary-stderr-duplicate"]
[0,"printf ok 2>2; env 2>>dump | grep NAME","target-boundary-next-command-stderr"]
[2,"cat <<2>script.py\nenv\n2","compact-heredoc-target-write"]
[2,"cat <<-2>script.py\n\tenv\n\t2","compact-tab-heredoc-target-write"]
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
[2,"exec env","exec-dump","project","environment-dump","-","runs-env"]
[2,"exec -- env","exec-options-end-dump"]
[2,"function f { env; }; f","function-syntax-dump"]
[2,"function f { e'n'v; }; f","function-split-dump"]
[2,"function f { en\\\nv; }; f","function-continued-dump"]
[2,"function f { env | grep NAME; }; f","function-conservative-filter"]
[2,"coproc { env; }","coprocess-syntax-dump"]
[2,"coproc WORKER { printenv; }","named-coprocess-dump"]
[2,"coproc WORKER { env | grep NAME; }","coprocess-conservative-filter"]
[2,"time -p -- env","time-option-suffix-dump"]
[0,"time --unknown NAME env | grep NAME","time-unknown-suffix-dump"]
[0,"function f { :; printf '%s' env; }; f","unsupported-list-evidence"]
[0,"function f { : | printf '%s' env; }; f","unsupported-pipe-evidence"]
[2,"case WORD in NAME) env;; esac","case-syntax-dump"]
[2,"select ITEM in first; do env; done","select-syntax-dump"]
[0,"[[ env ]]","conditional-data-conservative"]
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
[0,"\"if\" env","quoted-control-word-is-an-executable"]
[0,"fun\\ction env","escaped-head-is-an-executable"]
[0,"/usr/bin/time env","pathname-basename-is-not-syntax"]
[0,"command function f env","launcher-target-is-not-syntax"]
[0,"env NAME=value function f env","env-target-is-not-syntax"]
[0,"# function f { env; }\ngit status","syntax-comment-data"]
[2,"{ env | grep NAME; }","brace-conservative-filter"]
[0,"for ITEM in env; do :; done","loop-data-conservative"]
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
[2,"'env'","single-quoted-producer"]
[2,"$'env'","ansi-dollar-producer"]
[2,"$\"env\"","locale-dollar-producer"]
[2,"e\"n\"v","double-fragment-producer"]
[2,"'e'\"n\"'v'","adjacent-ordinary-producer"]
[2,"e$'n'v","ansi-dollar-fragment-producer"]
[2,"e$\"n\"v","locale-dollar-fragment-producer"]
[2,"$'e'$\"n\"$'v'","adjacent-dollar-producer"]
[2,"e$''n$\"\"'v'","empty-dollar-fragment-producer"]
[2,"$'\\145\\156\\166'","ansi-octal-producer","project","environment-dump","undecoded-ansi-escape"]
[2,"$'\\x65\\x6e\\x76'","ansi-hex-producer","project","environment-dump","undecoded-ansi-escape"]
[2,"$'\\u0065\\u006e\\u0076'","ansi-unicode-producer","project","environment-dump","undecoded-ansi-escape"]
[2,"$'\\U00000065\\U0000006e\\U00000076'","ansi-long-unicode-producer","project","environment-dump","undecoded-ansi-escape"]
[2,"$'\\545'nv","ansi-byte-wrap-producer","project","environment-dump","undecoded-ansi-escape"]
[2,"$'env\\0ignored'","ansi-nul-producer","project","environment-dump","undecoded-ansi-escape"]
[2,"e$'\\0ignored'nv","ansi-nul-fragment-producer","project","environment-dump","undecoded-ansi-escape"]
[2,"$'\\x65'nv","ansi-encoded-fragment-producer","project","environment-dump","undecoded-ansi-escape"]
[2,"$'\\x65nv'","ansi-escaped-head","project","environment-dump","undecoded-ansi-escape","runs-env"]
[2,"$'\\cE'nv","ansi-control-head","project","environment-dump","undecoded-ansi-escape"]
[2,"$'en\\\\v'","ansi-backslash-head","project","environment-dump","undecoded-ansi-escape"]
[2,"$'g\\x69t' status","ansi-ordinary-escaped-head","project","environment-dump","undecoded-ansi-escape"]
[2,"$'e\\'nv'","ansi-escaped-quote-head","project","environment-dump","undecoded-ansi-escape"]
[2,"command $'\\x65nv'","ansi-forwarded-escaped-head","project","environment-dump","undecoded-ansi-escape","runs-env"]
[2,"{ $'\\x65nv'; }","ansi-brace-escaped-head","project","environment-dump","undecoded-ansi-escape"]
[2,"! $'\\x65nv'","ansi-negated-escaped-head","project","environment-dump","undecoded-ansi-escape"]
[2,"time $'\\x65nv'","ansi-timed-escaped-head","project","environment-dump","undecoded-ansi-escape"]
[2,"if true; then $'\\x65nv'; fi","ansi-conditional-escaped-head","project","environment-dump","undecoded-ansi-escape"]
[2,"while true; do $'\\x65nv'; done","ansi-loop-escaped-head","project","environment-dump","undecoded-ansi-escape"]
[2,"exec $'\\x65nv'","ansi-exec-escaped-head","project","environment-dump","undecoded-ansi-escape","runs-env"]
[2,"builtin $'\\x65nv'","ansi-builtin-escaped-head","project","environment-dump","undecoded-ansi-escape"]
[2,"$'exec' $'\\x65nv'","ansi-dollar-exec-escaped-head","project","environment-dump","undecoded-ansi-escape"]
[2,"command exec $'\\x65nv'","ansi-command-exec-escaped-head","project","environment-dump","undecoded-ansi-escape"]
[0,"{ printf '%s' $'\\x65nv'; }","ansi-escaped-data-in-opaque-suffix"]
[0,"$'printenv' NAME","ansi-named-read"]
[0,"$\"printenv\" NAME","locale-named-read"]
[2,"printenv $'NAME'","ansi-named-argument-stays-unproved"]
[2,"systemctl $'show-environment'","ansi-systemctl-producer-argument"]
[2,"systemctl $\"show-environment\"","locale-systemctl-producer-argument"]
[2,"systemctl --user $'show-\\x65nvironment'","ansi-systemctl-encoded-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"cat $'/proc/self/\\x65nviron'","ansi-cat-encoded-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"declare $'-\\160'","ansi-declare-encoded-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"typeset $'-\\x78'","ansi-typeset-encoded-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"printenv $'N\\x41ME'","ansi-printenv-encoded-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"export $'-\\160'","ansi-export-encoded-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"set $'\\x2de'","ansi-set-encoded-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"tr $'\\0' $'\\n'","ansi-tr-encoded-arguments","project","environment-dump","undecoded-ansi-escape"]
[2,"strings $'/proc/self/\\u0065nviron'","ansi-strings-encoded-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"xargs $'-\\060'","ansi-xargs-encoded-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"env $'N\\x41ME=value' git status","ansi-env-encoded-operand","project","environment-dump","undecoded-ansi-escape"]
[2,"systemctl $'show-\\U00000065nvironment'","ansi-long-unicode-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"systemctl $'show-\\545nvironment'","ansi-octal-wrap-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"systemctl $'show-environment\\0ignored'","ansi-nul-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"systemctl show-$'env\\0ignored'ironment","ansi-nul-fragment-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"systemctl $'\\cE'","ansi-control-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"systemctl $'\\q'","ansi-unknown-escape-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"systemctl $'\\x'","ansi-incomplete-escape-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"systemctl $'a\\tb'","ansi-simple-escape-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"systemctl $'show-\\x65'n\"viron\"'ment'","ansi-mixed-fragment-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"systemctl $'show-\\x65'\"$NAME\"","ansi-escape-before-variable-fragment","project","environment-dump","undecoded-ansi-escape"]
[2,"systemctl $'show-\\x65'$'nvironment'","ansi-escape-before-dollar-fragment","project","environment-dump","undecoded-ansi-escape"]
[2,"systemctl $'show-\\'environment'","ansi-escaped-apostrophe-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"command -p -- systemctl $'show-\\x65nvironment'","ansi-command-producer-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"sudo -u root -- cat $'/proc/self/\\x65nviron'","ansi-sudo-producer-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"env NAME=value declare $'-\\160'","ansi-env-producer-argument","project","environment-dump","undecoded-ansi-escape"]
[2,"systemctl $'show-\\x65nvironment' | grep NAME","ansi-argument-filter-stays-unproved","project","environment-dump","undecoded-ansi-escape"]
[2,"cat < $'/proc/self/\\x65nviron'","ansi-cat-encoded-input","project","environment-dump","undecoded-ansi-escape"]
[2,"tr '\\0' '\\n' < $'/proc/self/\\x65nviron' | grep NAME","ansi-tr-encoded-input","project","environment-dump","undecoded-ansi-escape"]
[2,"strings < $'/proc/self/\\x65nviron' | grep NAME","ansi-strings-encoded-input","project","environment-dump","undecoded-ansi-escape"]
[2,"xargs -0 < $'/proc/self/\\x65nviron'","ansi-xargs-encoded-input","project","environment-dump","undecoded-ansi-escape"]
[0,"printf $'a\\tb'","ansi-benign-printf-argument"]
[0,"printf '%s' < $'a\\tb'","ansi-ordinary-command-input"]
[0,"sudo -u $'r\\x6fot' git status","ansi-wrapper-option-is-not-producer-argument"]
[0,"systemctl \"$'show-\\x65nvironment'\"","ansi-opener-in-double-quoted-argument"]
[0,"systemctl '$'\\''show-\\x65nvironment'","ansi-opener-in-single-quoted-argument"]
[0,"systemctl \\$'show-\\x65nvironment'","ansi-escaped-dollar-argument"]
[0,["systemctl","$'show-\\x65nvironment'"],"ansi-array-argument-is-data"]
[0,["cat","$'/proc/self/\\x65nviron'"],"ansi-array-path-is-data"]
[0,["declare","$'-\\160'"],"ansi-array-flag-is-data"]
[0,"printf '%s' $'\\x65nv'","ansi-escaped-argument-data"]
[0,"printf '%s' $'$(env)'","ansi-substitution-text-is-data"]
[0,"\"en\\v\"","double-backslash-is-literal"]
[0,"'en\\v'","single-backslash-is-literal"]
[0,"\"$'env'\"","ansi-quote-text-in-double-quotes"]
[0,"'$\"env\"'","locale-quote-text-in-single-quotes"]
[0,"$\"en\\v\"","locale-backslash-is-literal"]
[0,"$NAME$'env'","earlier-unknown-dollar-fragment"]
[0,"$\"$NAME\"env","locale-substitution-stays-unknown"]
[2,"env | grep $'^NAME='","ansi-filter-stays-unproved"]
[2,"env | grep $\"^NAME=\"","locale-filter-stays-unproved"]
[2,"e'n'v","split-producer"]
[2,"en\\v","escaped-producer"]
[2,"printf '%s' ready # ignored text\nsystemctl --user show-environment","comment-boundary-producer"]
[0,"printf '%s' 'ordinary text $NAME `env` # | ; \\ data' \"ordinary text # | ;\"","quoted-span-markers-are-data"]
[0,"printf '%s' \"\" '' 'env'","empty-quotes-remain-data"]
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
[0,["$'env'"],"array-dollar-quote-is-data"]
[0,["$'\\x65nv'"],"array-dollar-escape-is-data"]
[0,["env","","printenv"],"array-empty-launcher-target"]
[2,["printenv","NAME\\cDATA"],"array-backslash-name-is-not-literal"]
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
[0,"if env --help; then :; fi","conservative-env-help"]
[0,"if env --version; then :; fi","conservative-env-version"]
[0,"if printenv --help; then :; fi","conservative-printenv-help"]
[0,"if sudo -g env true; then :; fi","conservative-sudo-group-operand"]
[0,"if TOKEN=env true; then :; fi","syntax-assignment-data"]
[0,"function env { :; }","syntax-function-name"]
[0,"coproc env { :; }","syntax-coproc-name"]
[0,"time --env true","time-option-data"]
[0,"if printf ok >env; then :; fi","redirect-target-data"]
[0,"if printf ok >/proc/self/environ; then :; fi","redirect-proc-output-data"]
[0,"if printf %s key=env; then :; fi","punctuated-argument-data"]
[0,"if cat ./env.txt; then :; fi","punctuated-path-data"]
[0,"if sudo -u env true; then :; fi","conservative-sudo-operand"]
[0,"env -S \"printenv PATH\"","split-string-named-read"]
[0,"env -S \"printf env\"","split-string-quoted-data"]
[0,"if export PATH; then :; fi","conservative-export-named"]
[0,"if declare PATH; then :; fi","conservative-declare-named"]
[0,"if typeset PATH; then :; fi","conservative-typeset-named"]
[0,"if printenv PATH; then :; fi","conservative-printenv-named"]
[2,"unknown > receipt <<'EOF'\nenv\nEOF","quoted-file-body-unknown-reader"]
[0,"cat <<'EOF'\nenv\nEOF","quoted-body-stdout-only"]
[2,"cat > receipt <<EOF\nenv\nEOF","unquoted-file-body-literal"]
[0,"bash <<'OUTER'\nbash wrapper.sh 'env NAME=value command-name args'\nOUTER","interpreted-quoted-data-retains-main-refusal"]
[0,"bash <<'OUTER'\ncat <<'EOF' > script.py\nif __name__ == \"__main__\":\n    options = 'set -euo pipefail'\n    launcher = \"env NAME=value command-name\"\n    print(options)\nEOF\nOUTER","interpreted-file-body-retains-main-refusal"]
[0,"bash <<'OUTER'\n{ printf '%s\\n' start > receipt; set -o pipefail; command-name args \u007c tee -a receipt; printf 'exit=%s\\n' \"$?\" >> receipt; }\nOUTER","interpreted-receipt-retains-main-refusal"]
[0,"bash $MODE 'env NAME=value command-name args'","wrapper-quoted-unproved-operand-main-refusal"]
[0,"bash wrapper.sh 'env NAME=value command-name args","wrapper-unterminated-quote-main-refusal"]
[0,"{ printf '%s\\n' start > receipt; set -o pipefail; command-name args \u007c tee -a receipt; printf 'exit=%s\\n' \"$?\" ; }","receipt-without-status-write-main-refusal"]
[0,"env bash --version","main-forwarded-shell-prefix"]
[0,"NAME=env time printf ok","main-assignment-before-reserved-head"]
[0,"cat <<'DATA'\nprintf env\nDATA","main-nonreader-body-argument"]
[2,"exec >receipt; declare","r12-exec-list-unnamed-declaration"]
[2,"builtin :; declare","r12-builtin-list-unnamed-declaration"]
[2,"command exec >receipt; declare","r12-command-exec-list-unnamed-declaration"]
[0,"exec >receipt; printf %s env","r12-exec-list-nonreader-argument"]
[0,"builtin :; printf %s env","r12-builtin-list-nonreader-argument"]
[0,"{ cat <<'DOC'\nprintf '%s\\n' env\nDOC\n}","r12-brace-stdout-body-main-refusal"]
[0,"{ bash <<'DOC'\nprintf '%s\\n' env\nDOC\n}","r12-brace-shell-body-main-refusal"]
[2,"{ bash <<'DOC'\ndeclare\nDOC\n}","r12-brace-shell-declaration-body-main-refusal"]
[2,"{ bash <<'DOC'\ntypeset\nDOC\n}","r12-brace-shell-typeset-body-main-refusal"]
[2,"if :; then bash <<'DOC'\ndeclare\nDOC\nfi","r12-if-shell-declaration-body-main-refusal"]
[2,"time bash <<'DOC'\ndeclare\nDOC","r12-time-shell-declaration-body-main-refusal"]
[2,"bash <<'DOC'; builtin :\ndeclare\nDOC\n","r12-body-after-later-header-wrapper"]
[2,"bash <<'DOC'\ndeclare\nDOC\nbuiltin :\n","r12-body-before-later-wrapper"]
[2,"bash <<EOF; script.sh","unread-shell-heredoc-body-without-marker"]
[0,"python3 - <<'PY'\nfrom pathlib import Path\np=Path('scripts/test-plugin-logic.js')\ntext=p.read_text(); lines=text.splitlines(keepends=True)\nfor i,line in enumerate(lines):\n    if '\"a description link to a plugin\\'s page\"' in line:\n        lines[i]=line.replace('null],', r'\"schema.a.link has unknown key \\\"pane\\\"\"],')\n    elif '\"a description link with both an address and a page\"' in line:\n        lines[i]=line.replace('\"schema.a.link must declare exactly one of url and pane\"', r'\"schema.a.link has unknown key \\\"pane\\\"\"')\n    elif '\"a description link with neither an address nor a page\"' in line:\n        lines[i]=line.replace('\"schema.a.link must declare exactly one of url and pane\"','\"schema.a.link.url must be an https address\"')\n    elif '\"a description link to a page that is no plugin id\"' in line or '\"a description link to a page that is not a string\"' in line:\n        lines[i]=''\n    elif '\"a status hint link to a plugin\\'s page\"' in line:\n        lines[i]=line.replace('\"status.a.link.pane needs a setting description\"', r'\"status.a.link has unknown key \\\"pane\\\"\"')\n    elif '\"a description link may name a page\"' in line:\n        lines[i]='    [\"a description link refuses the old pane key\", \\'var LINK_KEYS = [\"text\", \"url\"];\\', \\'var LINK_KEYS = [\"text\", \"url\", \"pane\"];\\'],\\n'\n    elif any(x in line for x in ['\"a description link declares no address beside its page\"','\"a description link declares an address or a page\"','\"only a description link names a page\"','\"a description link\\'s page is a plugin id\"','\"a description link\\'s page is a string\"']):\n        lines[i]=''\nassert ''.join(lines)!=text\np.write_text(''.join(lines))\nPY","ken-3998-allow-original-source-edit"]
[0,"python3 - <<'PY'\nfrom pathlib import Path\nimport struct\nr=Path('tmp/ui-shots/VG-563')\npaths=sorted(p for folder in ['after','after-consumers'] for p in (r/folder).rglob('*.png'))\nlines=[]\nfor p in paths:\n w,h=struct.unpack('>II',p.read_bytes()[16:24]); lines.append(f'- `{p}`: {w} \u00d7 {h}')\nPath('tmp/qa-after-inventory-VG-563.md').write_text('# After images available\\n\\n'+'\\n'.join(lines)+'\\n')\nprint('After completed-set images',len(paths))\nPY","ken-3998-allow-png-inventory"]
[0,"sh tmp/runtime-tests/launch.sh /home/method/dev/.worktrees/vgshell/vgs-1686/tmp/runtime-tests/tui env VGS_TEST_RUN=1 scripts/test-tui.sh","ken-3998-allow-launcher-report"]
[0,"sh /home/dev/dev/.worktrees/hyprtrade/ht-970/tmp/waiter.q9BEPa/launch.sh /home/dev/dev/.worktrees/hyprtrade/ht-970/tmp/waiter.q9BEPa/wait env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/copilot-wait 1034 --item HT-970","ken-3998-allow-waiter-report"]
[0,"python3 - <<PY\nfor name in ['NAME']:\n    print('env', name)\nPY","ken-3998-allow-unquoted-python-data"]
[0,"mkdir -p build && cat > build/x.py <<'PY'\nfor name in ['NAME']:\n    print('The printed run set passed.')\nPY\npython3 build/x.py","ken-3998-allow-file-write-and-run"]
[0,"cat > build/x.py <<'PY' && python3 build/x.py\nfor name in ['NAME']:\n    print('The printed run set passed.')\nPY","ken-3998-allow-file-write-inline-run"]
[0,"cat > build/control.py <<'PY'\nimport os, subprocess\nfor directory in ['build']:\n    subprocess.run(['python3', 'check.py'], env={'PATH': os.defpath, 'HOME': directory, 'VGS_TEST_RUN': '1'})\nPY\npython3 build/control.py && echo ok","ken-3998-allow-subprocess-environment-data"]
[0,"mkdir -p notes && cat > notes/brief.md <<'EOF'\nIf a command prints the environment, use a named variable.\nfor example: replace env, printenv, export -p, declare -x, /proc/*/environ and show-environment with named reads.\nEOF","ken-3998-allow-brief-data"]
[0,"sh tmp/waiter.KfIa0R/launch.sh tmp/waiter.KfIa0R/wait env -u GH_TOKEN .agents/skills/orch/scripts/queue-wait 610 180 2400 --json --no-guard --no-check-probe","vsys-queue-wait-named-unset"]
[2,"sh tmp/waiter.KfIa0R/launch.sh tmp/waiter.KfIa0R/wait env -u GH_TOKEN printenv","vsys-queue-wait-environment-output"]
[2,"sh tmp/waiter.KfIa0R/launch.sh tmp/waiter.KfIa0R/wait env -u GH_TOKEN .agents/skills/orch/scripts/queue-wait $(env)","vsys-queue-wait-executable-substitution"]
[2,"sh tmp/waiter.KfIa0R/launch.sh tmp/waiter.KfIa0R/wait env -u GH_TOKEN .agents/skills/orch/scripts/queue-wait `printenv`","vsys-queue-wait-executable-backtick"]
[2,"sh tmp/runtime-tests/launch.sh tmp/runtime-tests/tui env VGS_TEST_RUN=1 env","launcher-report-environment-output"]
[2,"sh tmp/runtime-tests/launch.sh tmp/runtime-tests/tui env VGS_TEST_RUN=1 scripts/test-tui.sh $(env)","launcher-report-executable-substitution"]
[2,"sh tmp/waiter.q9BEPa/launch.sh tmp/waiter.q9BEPa/wait env -u GH_REPO -u GITHUB_REPOSITORY env","documented-waiter-environment-output"]
[2,"sh tmp/waiter.q9BEPa/launch.sh tmp/waiter.q9BEPa/wait env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/copilot-wait $(printenv)","documented-waiter-executable-substitution"]
[2,"sh wrap.sh env","ken-3998-refuse-wrapper-no-program"]
[0,"receiver one two env -u NAME","ken-3998-refuse-ordinary-receiver-no-program"]
[0,"receiver one two env -i -u NAME --unset=OTHER -C build NAME=value program extra words > out","ken-3998-launcher-any-receiver-arity"]
[0,"receiver 'env' 'set' 'declare -x'","ken-3998-quoted-arguments-any-receiver"]
[0,"if :; then printf '%s' 'env set declare -x'; fi","ken-3998-compound-quoted-data"]
[2,"env | sort","ken-3998-refuse-sort"]
[2,"printenv > out","ken-3998-refuse-output-file"]
[2,"eval env","ken-3998-refuse-eval","project","environment-dump","-","runs-env"]
[2,"cd /tmp && env","ken-3998-refuse-list"]
[2,"echo \"$(env)\"","ken-3998-refuse-substitution"]
[2,"python3 - <<PY\nprint(\"\"\"$(env)\"\"\")\nPY","ken-3998-refuse-unquoted-python-substitution"]
[2,"python3 - <<PY\nprint(\"\"\"`env`\"\"\")\nPY","ken-3998-refuse-unquoted-python-backtick"]
[0,"cat <<'EOF' \u007c& cat\nenv\nEOF","ken-3998-merged-pipe-data"]
[0,"if :; then printf '%s' set; fi","ken-3998-compound-unquoted-set-data"]
[2,"if :; then declare; fi","ken-3998-compound-bare-declare"]
[2,"bash -c 'cat < input.txt' < /proc/$$/environ","proc-input-data-replaced-file"]
[2,"bash -c \"cat <<< 'env'\" < /proc/$$/environ","proc-input-data-replaced-here-string"]
[2,"bash -c 'cat 3<&- <&3' 3< /proc/$$/environ","proc-input-data-closed-descriptor"]
[2,"bash -c \"printf '%s' 'env'\" < /proc/$$/environ","proc-input-data-quoted-data"]
[2,"bash -c \"printf '%s' 'env' | cat\" < /proc/$$/environ","proc-input-data-pipeline-data"]
[2,"bash -c 'printf done' 3< /proc/$$/environ","proc-input-data-unused-descriptor"]
[2,"bash -c 'cat <&3' 3< /proc/$$/environ 3> out","proc-input-data-replaced-output"]
[2,"bash -c 'cat <&3' 3< /proc/$$/environ 3>> out","proc-input-data-replaced-append"]
[2,"bash -c 'cat /dev/fd/1 | cat' 1< /proc/$$/environ","proc-input-data-replaced-stdout-pipe"]
[2,"bash -c 'cat /dev/fd/2 \u007c& cat' 2< /proc/$$/environ","proc-input-data-replaced-merged-pipe"]
[2,"{ eval cat < /dev/null; } < /proc/self/environ","compound-replace-proc"]
[2,"bash -c '{ cat /proc/$$/fd/3; } 3</dev/null; :' 3< /proc/$$/environ","identity-pid-brace-replace"]
[2,"bash -c 'cat /proc/$BASH\u0050ID/fd/1 | cat >&2; :' 1< /proc/$$/environ","identity-bashpid-reader-output-pipe"]
[2,"bash -c '(cat /proc/$BASH\u0050ID/fd/3) 3</dev/null; :' 3< /proc/$$/environ","identity-bashpid-subshell-replace"]
[2,"bash -c 'printf done | cat /proc/$BASH\u0050ID/fd/0; :' < /proc/$$/environ","identity-bashpid-pipeline-input"]
[2,"bash -c '{ cat /proc/$BASH\u0050ID/fd/3; } 3</dev/null; :' 3< /proc/$$/environ","identity-bashpid-brace-replace"]
[2,"bash -c 'cat /proc/${BASH\u0050ID}/fd/1 | cat >&2; :' 1< /proc/$$/environ","identity-braced-bashpid-reader-output-pipe"]
[2,"bash -c '(cat /proc/${BASH\u0050ID}/fd/3) 3</dev/null; :' 3< /proc/$$/environ","identity-braced-bashpid-subshell-replace"]
[2,"bash -c 'printf done | cat /proc/${BASH\u0050ID}/fd/0; :' < /proc/$$/environ","identity-braced-bashpid-pipeline-input"]
[2,"bash -c '{ cat /proc/${BASH\u0050ID}/fd/3; } 3</dev/null; :' 3< /proc/$$/environ","identity-braced-bashpid-brace-replace"]
[2,"bash -c 'cat /dev/fd/3 3</dev/null; :' 3< /proc/$$/environ","identity-dev-replace"]
[2,"bash -c 'cat /dev/fd/3 3<&-; :' 3< /proc/$$/environ","identity-dev-close"]
[2,"bash -c 'cat /dev/fd/3 3<&4; :' 3< /proc/$$/environ 4</dev/null","identity-dev-plain-copy"]
[2,"bash -c 'cat 3</dev/null < /dev/fd/3; :' 3< /proc/$$/environ","identity-dev-selected-redirect"]
[2,"bash -c 'cat /proc/self/fd/3 3</dev/null; :' 3< /proc/$$/environ","identity-self-replace"]
[2,"bash -c 'cat /proc/self/fd/3 3<&-; :' 3< /proc/$$/environ","identity-self-close"]
[2,"bash -c 'cat /proc/self/fd/3 3<&4; :' 3< /proc/$$/environ 4</dev/null","identity-self-plain-copy"]
[2,"bash -c 'cat 3</dev/null < /proc/self/fd/3; :' 3< /proc/$$/environ","identity-self-selected-redirect"]
[2,"bash -c 'cat /proc/thread-self/fd/3 3</dev/null; :' 3< /proc/$$/environ","identity-thread-replace"]
[2,"bash -c 'cat /proc/thread-self/fd/3 3<&-; :' 3< /proc/$$/environ","identity-thread-close"]
[2,"bash -c 'cat /proc/thread-self/fd/3 3<&4; :' 3< /proc/$$/environ 4</dev/null","identity-thread-plain-copy"]
[2,"bash -c 'cat 3</dev/null < /proc/thread-self/fd/3; :' 3< /proc/$$/environ","identity-thread-selected-redirect"]
[2,"bash -c 'cat /proc/1/fd/3 3</dev/null; :' 3< /proc/$$/environ","identity-other-process"]
[2,"bash -c \"cat /proc/$BASH\u0050ID/fd/3\" 3< /proc/$$/environ","identity-bashpid-expanded-outer-data"]
[2,"bash -c \"cat /proc/${BASH\u0050ID}/fd/3\" 3< /proc/$$/environ","identity-braced-bashpid-expanded-outer-data"]
[2,"bash -c 'false || { cat /proc/$$/fd/3; } 3</dev/null; :' 3< /proc/$$/environ","identity-pid-or-incoming-brace"]
[2,"bash -c '{ cat /proc/$$/fd/3; } 3</dev/null || :; :' 3< /proc/$$/environ","identity-pid-or-outgoing-brace"]
[2,"bash -c ': && { cat /proc/$$/fd/3; } 3</dev/null; :' 3< /proc/$$/environ","identity-pid-and-incoming-brace"]
[2,"bash -c \"false || eval 'cat /proc/\\$\\$/fd/3' 3</dev/null; :\" 3< /proc/$$/environ","identity-pid-or-eval-replace"]
[2,"bash -c 'false || { cat /proc/$BASH\u0050ID/fd/3; } 3</dev/null; :' 3< /proc/$$/environ","identity-bashpid-or-incoming-brace"]
[2,"bash -c '{ cat /proc/$BASH\u0050ID/fd/3; } 3</dev/null || :; :' 3< /proc/$$/environ","identity-bashpid-or-outgoing-brace"]
[2,"bash -c ': && { cat /proc/$BASH\u0050ID/fd/3; } 3</dev/null; :' 3< /proc/$$/environ","identity-bashpid-and-incoming-brace"]
[2,"bash -c \"false || eval 'cat /proc/\\$BASH\u0050ID/fd/3' 3</dev/null; :\" 3< /proc/$$/environ","identity-bashpid-or-eval-replace"]
[2,"bash -c \"bash 3</dev/null <<'EOF'\ne\\\\\\\\nv\nEOF\n:\" 3< /proc/$$/environ","final-input-quoted-transform-data"]
[2,"bash -c \"cat 3</dev/null <<EOF\ne\\\\\\\\nv\nEOF\n:\" 3< /proc/$$/environ","final-input-unproved-transform-nonshell-data"]
[2,"bash -c \"cat '/proc/\\$\\$/fd/3'\" 3< /proc/$$/environ","proc-alias-literal-pid-data"]
[2,"bash -c \"cat '/proc/\\$BASH\u0050ID/fd/3'\" 3< /proc/$$/environ","proc-alias-literal-bashpid-data"]
[2,"bash -c 'cat /proc/1/fd/3' 3< /proc/$$/environ","proc-alias-other-process-data"]
[2,"bash -c \"cat /proc/$$/fd/3\" 3< /proc/$$/environ","proc-alias-expanded-outer-source-data"]
[2,"bash -c \"FD=3; cat '/proc/\\$\\$'/fd/\\$FD\" 3< /proc/$$/environ","proc-alias-literal-pid-expanded-fd-data"]
[2,"bash -c 'cat /proc/$$/fd/3 3</dev/null | cat; :' 3<<'EOF'\nenv\nEOF","identity-pid-body-forward-cat"]
[2,"bash -c 'cat /proc/$BASH\u0050ID/fd/3 3</dev/null | cat; :' 3<<'EOF'\nenv\nEOF","identity-bashpid-body-forward-cat"]
[2,"bash -c 'cat /proc/${BASH\u0050ID}/fd/3 3</dev/null | cat; :' 3<<'EOF'\nenv\nEOF","identity-braced-bashpid-body-forward-cat"]
[2,"bash -c 'cat /proc/$$/fd/$1 3</dev/null | cat' _ 3 3<<'EOF'\nenv\nEOF","final-input-unknown-body-data-control"]
[2,"bash -c 'cat /proc/$BASH\u0050ID/fd/$1 3</dev/null | bash 3</dev/null' _ 3 3<<'EOF'\nenv\nEOF","final-input-unknown-current-body-cleared-receiver"]
[2,"bash -c '{ cat /proc/$$/fd/3; } 3</proc/self/environ'","inner_source_candidate"]
[0,"env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE node <<'NODE'\nconst fs=require('node:fs');\nconst rows=fs.readFileSync('tmp/evidence-VGS-1869/readability-before-edit.log','utf8').trim().split('\\n').map(JSON.parse);\nconst minima=new Map();\nfor(const row of rows){const key=row.fg+'/'+row.bg;if(!minima.has(key)||row.ratio<minima.get(key).ratio)minima.set(key,row);}\nfs.writeFileSync('tmp/evidence-VGS-1869/readability-minima.json',JSON.stringify([...minima.values()],null,2)+'\\n');\nconsole.log(JSON.stringify([...minima.values()].map(({name,fg,bg,ratio,floor})=>({name,fg,bg,ratio,floor}))));\nNODE","receiver-node-incident"]
[0,"python - <<'PYTHON'\nexpected = {'name'}\nif set(['name']) != expected:\n    raise SystemExit('different keys')\nPYTHON","receiver-python-key-inventory"]
[0,"python3 - <<'PY'\nfrom pathlib import Path\npath = Path('scripts/test-rows.py')\nold = '''for name, value in os.environ.items():\n    print(name, value)\n'''\nnew = \"\"\"for name, value in os.environ.items():\n    assert name in expected\n\"\"\"\ntext = path.read_text()\nassert old in text\npath.write_text(text.replace(old, new))\nPY","receiver-python-replacement-source"]
[0,"large-replacement","receiver-python-replacement-deadline","deadline"]
[0,"python3 <<'PY'\nimport pathlib as paths, re, json, textwrap\nfrom pathlib import Path\ntext = 'os.environ'\nPY","receiver-python-data-module-imports"]
[2,"python3 -c 'import subprocess; subprocess.run([\"python3\", \"-c\", \"import os; print(os.environ)\"])'","receiver-python-subprocess-inline"]
[2,"python3 <<'PY'\nimport subprocess\nsubprocess.run(['python3', '-c', 'import os; print(os.environ)'])\nPY","receiver-python-subprocess-heredoc"]
[2,"python3 <<'PY'\nimport os\nos.system('python3 -c \"import os; print(os.environ)\"')\nPY","receiver-python-os-system"]
[2,"python3 <<'PY'\nfrom subprocess import run\nrun(['python3', '-c', 'import os; print(os.environ)'])\nPY","receiver-python-outside-from-import"]
[2,"python3 <<'PY'\nimport pathlib, subprocess as child\nchild.run(['python3', '-c', 'import os; print(os.environ)'])\nPY","receiver-python-outside-mixed-import"]
[2,"python3 <<'PY'\nimport pathlib\nreader = getattr(pathlib, 'Path')\ntext = 'os.environ'\nPY","receiver-python-dynamic-getattr"]
[2,"python3 <<'PY'\nmodule = sys.modules['subprocess']\ntext = 'os.environ'\nPY","receiver-python-dynamic-sys-modules"]
[2,"python3 <<'PY'\nmodule = __import__('subprocess')\ntext = 'os.environ'\nPY","receiver-python-dynamic-import"]
[2,"python3 <<'PY'\nmodule = importlib.import_module('subprocess')\ntext = 'os.environ'\nPY","receiver-python-dynamic-importlib"]
[2,"python3 <<'PY'\nscope = globals()\ntext = 'os.environ'\nPY","receiver-python-dynamic-globals"]
[2,"python3 <<'PY'\nscope = vars()\ntext = 'os.environ'\nPY","receiver-python-dynamic-vars"]
[0,"python3 - <<'PY'\nold = 'for name, value in os.environ.items():'\nnew = \"print(\\\"os.environ\\\", 'os.environ')\"\nPY","receiver-python-ordinary-quoted-source"]
[2,"python3 <<'PY'\ntext = '''for name, value in os.environ.items():'''\nimport os\nfor name, value in os.environ.items():\n    print(name, value)\nPY","receiver-python-quoted-then-executed"]
[2,"python3 <<'PY'\nimport os\nprint(f'{os.environ}')\nPY","receiver-python-formatted-string"]
[2,"python3 <<'PY'\ntext = r'os.environ'\nPY","receiver-python-prefixed-string-unproved"]
[2,"python3 <<'PY'\ntext = '''os.environ\nPY","receiver-python-unclosed-string-unproved"]
[2,"python3 <<'PY'\nexec('import os; print(os.environ)')\nPY","receiver-python-exec-string"]
[2,"python3 <<'PY'\nimport os\nprint(eval('os.environ'))\nPY","receiver-python-eval-string"]
[2,"python3 <<'PY'\nimport os\ncode = compile('print(os.environ)', 'fixture', 'exec')\nPY","receiver-python-compile-string"]
[2,"python3 <<'PY'\n# 'os.environ' remains conservative comment evidence\npass\nPY","receiver-python-comment-evidence"]
[2,"python <<'CODE'\nimport os; print(os.environ)\nCODE","receiver-python-heredoc-whole-0"]
[2,"python <<'CODE'\nimport os; print(dict(os.environ))\nCODE","receiver-python-heredoc-whole-1"]
[0,"python <<'CODE'\nprint(set(['env']))\nCODE","receiver-python-heredoc-safe"]
[0,"python <<'CODE'\nimport os; print(os.environ['HOME'])\nCODE","receiver-python-heredoc-named"]
[2,"python -c 'import os; print(os.environ)'","receiver-python-inline-whole-0"]
[2,"python -c 'import os; print(dict(os.environ))'","receiver-python-inline-whole-1"]
[0,"python -c 'print(set(['\\''env'\\'']))'","receiver-python-inline-safe"]
[0,"python -c 'import os; print(os.environ['\\''HOME'\\''])'","receiver-python-inline-named"]
[2,"python <<CODE\nimport os; print(os.environ)\nCODE","receiver-python-unquoted-whole-0"]
[2,"python <<CODE\nimport os; print(dict(os.environ))\nCODE","receiver-python-unquoted-whole-1"]
[0,"python <<CODE\nprint(set(['env']))\nCODE","receiver-python-unquoted-safe"]
[0,"python <<CODE\nimport os; print(os.environ['HOME'])\nCODE","receiver-python-unquoted-named"]
[2,"python3 <<'CODE'\nimport os; print(os.environ)\nCODE","receiver-python3-heredoc-whole-0"]
[0,"python3 <<'CODE'\nprint(set(['env']))\nCODE","receiver-python3-heredoc-safe"]
[0,"python3 <<'CODE'\nimport os; print(os.environ['HOME'])\nCODE","receiver-python3-heredoc-named"]
[2,"python3 -c 'import os; print(os.environ)'","receiver-python3-inline-whole-0"]
[0,"python3 -c 'print(set(['\\''env'\\'']))'","receiver-python3-inline-safe"]
[0,"python3 -c 'import os; print(os.environ['\\''HOME'\\''])'","receiver-python3-inline-named"]
[2,"python3 <<CODE\nimport os; print(os.environ)\nCODE","receiver-python3-unquoted-whole-0"]
[0,"python3 <<CODE\nprint(set(['env']))\nCODE","receiver-python3-unquoted-safe"]
[0,"python3 <<CODE\nimport os; print(os.environ['HOME'])\nCODE","receiver-python3-unquoted-named"]
[2,"node <<'CODE'\nconsole.log(JSON.stringify(process.env))\nCODE","receiver-node-heredoc-whole-0"]
[0,"node <<'CODE'\nconst env=new Set(); env.add('set'); console.log(env)\nCODE","receiver-node-heredoc-safe"]
[0,"node <<'CODE'\nconsole.log(process.env.HOME)\nCODE","receiver-node-heredoc-named"]
[2,"node -e 'console.log(JSON.stringify(process.env))'","receiver-node-inline-whole-0"]
[0,"node -e 'const env=new Set(); env.add('\\''set'\\''); console.log(env)'","receiver-node-inline-safe"]
[0,"node -e 'console.log(process.env.HOME)'","receiver-node-inline-named"]
[2,"node <<CODE\nconsole.log(JSON.stringify(process.env))\nCODE","receiver-node-unquoted-whole-0"]
[0,"node <<CODE\nconst env=new Set(); env.add('set'); console.log(env)\nCODE","receiver-node-unquoted-safe"]
[0,"node <<CODE\nconsole.log(process.env.HOME)\nCODE","receiver-node-unquoted-named"]
[2,"ruby <<'CODE'\nputs ENV.to_h\nCODE","receiver-ruby-heredoc-whole-0"]
[2,"ruby <<'CODE'\nENV.each { |k,v| puts v }\nCODE","receiver-ruby-heredoc-whole-1"]
[0,"ruby <<'CODE'\nenv = [1].to_set; puts env\nCODE","receiver-ruby-heredoc-safe"]
[0,"ruby <<'CODE'\nputs ENV['HOME']\nCODE","receiver-ruby-heredoc-named"]
[2,"ruby -e 'puts ENV.to_h'","receiver-ruby-inline-whole-0"]
[2,"ruby -e 'ENV.each { |k,v| puts v }'","receiver-ruby-inline-whole-1"]
[0,"ruby -e 'env = [1].to_set; puts env'","receiver-ruby-inline-safe"]
[0,"ruby -e 'puts ENV['\\''HOME'\\'']'","receiver-ruby-inline-named"]
[2,"ruby <<CODE\nputs ENV.to_h\nCODE","receiver-ruby-unquoted-whole-0"]
[2,"ruby <<CODE\nENV.each { |k,v| puts v }\nCODE","receiver-ruby-unquoted-whole-1"]
[0,"ruby <<CODE\nenv = [1].to_set; puts env\nCODE","receiver-ruby-unquoted-safe"]
[0,"ruby <<CODE\nputs ENV['HOME']\nCODE","receiver-ruby-unquoted-named"]
[2,"perl <<'CODE'\nprint %ENV;\nCODE","receiver-perl-heredoc-whole-0"]
[0,"perl <<'CODE'\nmy $env = 'set'; print $env;\nCODE","receiver-perl-heredoc-safe"]
[0,"perl <<'CODE'\nprint $ENV{'HOME'};\nCODE","receiver-perl-heredoc-named"]
[2,"perl -e 'print %ENV;'","receiver-perl-inline-whole-0"]
[0,"perl -e 'my $env = '\\''set'\\''; print $env;'","receiver-perl-inline-safe"]
[0,"perl -e 'print $ENV{'\\''HOME'\\''};'","receiver-perl-inline-named"]
[2,"perl <<CODE\nprint %ENV;\nCODE","receiver-perl-unquoted-whole-0"]
[0,"perl <<CODE\nmy \\$env = 'set'; print \\$env;\nCODE","receiver-perl-unquoted-safe"]
[0,"perl <<CODE\nprint \\$ENV{'HOME'};\nCODE","receiver-perl-unquoted-named"]
[2,"unknown <<'CODE'\nset([1])\nCODE","receiver-unknown-conservative"]
[0,"cat > tmp/helper.sh <<'HELPER'\nshell_env=(env NAME=value)\nHELPER\nunknown <<'DATA'\nordinary\nDATA","receiver-unknown-after-file-data"]
[2,"node <<CODE\nconsole.log('$(env)')\nCODE","receiver-node-shell-expansion"]
[0,"python3 -c 'import json,os; print(json.dumps({k:os.environ.get(k,\"\") for k in (\"JARVIS_CONTROL_HOST\",\"JARVIS_LOG_DIR\",\"JARVIS_WAKE_SETTLE_SECS\")}))'","receiver-jarvis-config-named-method"]
[0,"python3 <<'CODE'\nimport json,os; print(json.dumps({k:os.environ.get(k,\"\") for k in (\"JARVIS_CONTROL_HOST\",\"JARVIS_LOG_DIR\",\"JARVIS_WAKE_SETTLE_SECS\")}))\nCODE","receiver-jarvis-heredoc-named-method"]
[0,"python -c 'import os; print(os.environ.get('\"'\"'HOME'\"'\"'))'","receiver-python-inline-named-get"]
[0,"python -c 'import os; print(os.environ.pop('\"'\"'HOME'\"'\"'))'","receiver-python-inline-named-pop"]
[0,"python -c 'import os; print(os.environ.setdefault('\"'\"'HOME'\"'\"'))'","receiver-python-inline-named-setdefault"]
[0,"python -c 'import os; print(os.environ.__getitem__('\"'\"'HOME'\"'\"'))'","receiver-python-inline-named-__getitem__"]
[0,"python -c 'import os; print(os.environ.__contains__('\"'\"'HOME'\"'\"'))'","receiver-python-inline-named-__contains__"]
[2,"python -c 'import os; print(os.environ.items())'","receiver-python-inline-mapping-items"]
[2,"python -c 'import os; print(os.environ.keys())'","receiver-python-inline-mapping-keys"]
[2,"python -c 'import os; print(os.environ.values())'","receiver-python-inline-mapping-values"]
[2,"python -c 'import os; print(os.environ.copy())'","receiver-python-inline-mapping-copy"]
[2,"python -c 'import os; print(os.environ.popitem())'","receiver-python-inline-mapping-popitem"]
[0,"python -c 'import os; print(os.environ.get(\"LANE_HOST_SSH_INVENTORY\", \"\")); print(os.environ.get(\"LANE_HOST_SSH_SOURCE\", os.getcwd()))'","receiver-python-inline-lane-host-named-methods"]
[2,"python -c 'import os\ne = os.environ\nfor k in e: print(k, e[k])'","receiver-python-inline-whole-line-end"]
[2,"python -c 'import os; home = os.environ.get('\"'\"'HOME'\"'\"')\ne = os.environ\nfor k in e: print(k, e[k])'","receiver-python-inline-named-then-whole"]
[0,"python -c 'print(os.environment)'","receiver-python-inline-identifier-suffix"]
[0,"python <<'CODE'\nimport os; print(os.environ.get('HOME'))\nCODE","receiver-python-heredoc-named-get"]
[0,"python <<'CODE'\nimport os; print(os.environ.pop('HOME'))\nCODE","receiver-python-heredoc-named-pop"]
[0,"python <<'CODE'\nimport os; print(os.environ.setdefault('HOME'))\nCODE","receiver-python-heredoc-named-setdefault"]
[0,"python <<'CODE'\nimport os; print(os.environ.__getitem__('HOME'))\nCODE","receiver-python-heredoc-named-__getitem__"]
[0,"python <<'CODE'\nimport os; print(os.environ.__contains__('HOME'))\nCODE","receiver-python-heredoc-named-__contains__"]
[2,"python <<'CODE'\nimport os; print(os.environ.items())\nCODE","receiver-python-heredoc-mapping-items"]
[2,"python <<'CODE'\nimport os; print(os.environ.keys())\nCODE","receiver-python-heredoc-mapping-keys"]
[2,"python <<'CODE'\nimport os; print(os.environ.values())\nCODE","receiver-python-heredoc-mapping-values"]
[2,"python <<'CODE'\nimport os; print(os.environ.copy())\nCODE","receiver-python-heredoc-mapping-copy"]
[2,"python <<'CODE'\nimport os; print(os.environ.popitem())\nCODE","receiver-python-heredoc-mapping-popitem"]
[0,"python <<'CODE'\nimport os; print(os.environ.get(\"LANE_HOST_SSH_INVENTORY\", \"\")); print(os.environ.get(\"LANE_HOST_SSH_SOURCE\", os.getcwd()))\nCODE","receiver-python-heredoc-lane-host-named-methods"]
[2,"python <<'CODE'\nimport os\ne = os.environ\nfor k in e: print(k, e[k])\nCODE","receiver-python-heredoc-whole-line-end"]
[2,"python <<'CODE'\nimport os; home = os.environ.get('HOME')\ne = os.environ\nfor k in e: print(k, e[k])\nCODE","receiver-python-heredoc-named-then-whole"]
[0,"python <<'CODE'\nprint(os.environment)\nCODE","receiver-python-heredoc-identifier-suffix"]
[0,"python3 -c 'import os; print(os.environ.get('\"'\"'HOME'\"'\"'))'","receiver-python3-inline-named-get"]
[0,"python3 -c 'import os; print(os.environ.pop('\"'\"'HOME'\"'\"'))'","receiver-python3-inline-named-pop"]
[0,"python3 -c 'import os; print(os.environ.setdefault('\"'\"'HOME'\"'\"'))'","receiver-python3-inline-named-setdefault"]
[0,"python3 -c 'import os; print(os.environ.__getitem__('\"'\"'HOME'\"'\"'))'","receiver-python3-inline-named-__getitem__"]
[0,"python3 -c 'import os; print(os.environ.__contains__('\"'\"'HOME'\"'\"'))'","receiver-python3-inline-named-__contains__"]
[2,"python3 -c 'import os; print(os.environ.items())'","receiver-python3-inline-mapping-items"]
[2,"python3 -c 'import os; print(os.environ.keys())'","receiver-python3-inline-mapping-keys"]
[2,"python3 -c 'import os; print(os.environ.values())'","receiver-python3-inline-mapping-values"]
[2,"python3 -c 'import os; print(os.environ.copy())'","receiver-python3-inline-mapping-copy"]
[2,"python3 -c 'import os; print(os.environ.popitem())'","receiver-python3-inline-mapping-popitem"]
[0,"python3 -c 'import os; print(os.environ.get(\"LANE_HOST_SSH_INVENTORY\", \"\")); print(os.environ.get(\"LANE_HOST_SSH_SOURCE\", os.getcwd()))'","receiver-python3-inline-lane-host-named-methods"]
[2,"python3 -c 'import os\ne = os.environ\nfor k in e: print(k, e[k])'","receiver-python3-inline-whole-line-end"]
[2,"python3 -c 'import os; home = os.environ.get('\"'\"'HOME'\"'\"')\ne = os.environ\nfor k in e: print(k, e[k])'","receiver-python3-inline-named-then-whole"]
[0,"python3 -c 'print(os.environment)'","receiver-python3-inline-identifier-suffix"]
[0,"python3 <<'CODE'\nimport os; print(os.environ.get('HOME'))\nCODE","receiver-python3-heredoc-named-get"]
[0,"python3 <<'CODE'\nimport os; print(os.environ.pop('HOME'))\nCODE","receiver-python3-heredoc-named-pop"]
[0,"python3 <<'CODE'\nimport os; print(os.environ.setdefault('HOME'))\nCODE","receiver-python3-heredoc-named-setdefault"]
[0,"python3 <<'CODE'\nimport os; print(os.environ.__getitem__('HOME'))\nCODE","receiver-python3-heredoc-named-__getitem__"]
[0,"python3 <<'CODE'\nimport os; print(os.environ.__contains__('HOME'))\nCODE","receiver-python3-heredoc-named-__contains__"]
[2,"python3 <<'CODE'\nimport os; print(os.environ.items())\nCODE","receiver-python3-heredoc-mapping-items"]
[2,"python3 <<'CODE'\nimport os; print(os.environ.keys())\nCODE","receiver-python3-heredoc-mapping-keys"]
[2,"python3 <<'CODE'\nimport os; print(os.environ.values())\nCODE","receiver-python3-heredoc-mapping-values"]
[2,"python3 <<'CODE'\nimport os; print(os.environ.copy())\nCODE","receiver-python3-heredoc-mapping-copy"]
[2,"python3 <<'CODE'\nimport os; print(os.environ.popitem())\nCODE","receiver-python3-heredoc-mapping-popitem"]
[0,"python3 <<'CODE'\nimport os; print(os.environ.get(\"LANE_HOST_SSH_INVENTORY\", \"\")); print(os.environ.get(\"LANE_HOST_SSH_SOURCE\", os.getcwd()))\nCODE","receiver-python3-heredoc-lane-host-named-methods"]
[2,"python3 <<'CODE'\nimport os\ne = os.environ\nfor k in e: print(k, e[k])\nCODE","receiver-python3-heredoc-whole-line-end"]
[2,"python3 <<'CODE'\nimport os; home = os.environ.get('HOME')\ne = os.environ\nfor k in e: print(k, e[k])\nCODE","receiver-python3-heredoc-named-then-whole"]
[0,"python3 <<'CODE'\nprint(os.environment)\nCODE","receiver-python3-heredoc-identifier-suffix"]
[2,"node -e 'const e = process.env\nfor (const k in e) console.log(k, e[k])'","receiver-node-inline-whole-line-end"]
[2,"node -e 'const home = process.env.HOME;\nconst e = process.env\nfor (const k in e) console.log(k, e[k])'","receiver-node-inline-named-then-whole"]
[0,"node -e 'const home = process.env.HOME\nconsole.log(home)'","receiver-node-inline-named-line-end"]
[2,"node <<'CODE'\nconst e = process.env\nfor (const k in e) console.log(k, e[k])\nCODE","receiver-node-heredoc-whole-line-end"]
[2,"node <<'CODE'\nconst home = process.env.HOME;\nconst e = process.env\nfor (const k in e) console.log(k, e[k])\nCODE","receiver-node-heredoc-named-then-whole"]
[0,"node <<'CODE'\nconst home = process.env.HOME\nconsole.log(home)\nCODE","receiver-node-heredoc-named-line-end"]
[2,"node <<'CODE' | xargs -I{} sh -c {}\nconsole.log('env')\nCODE","receiver-node-unknown-downstream"]
[2,"python <<'CODE' | xargs -I{} sh -c {}\nprint('env')\nCODE","receiver-python-unknown-downstream"]
[2,"ruby <<'CODE' | xargs -I{} sh -c {}\nputs('env')\nCODE","receiver-ruby-unknown-downstream"]
[2,"perl <<'CODE' | xargs -I{} sh -c {}\nprint('env');\nCODE","receiver-perl-unknown-downstream"]
[2,"node <<'CODE' | cat | xargs -I{} sh -c {}\nconsole.log('env')\nCODE","receiver-indirect-unknown-downstream"]
[2,"xargs -I{} sh -c {} <<'CODE' | node\nenv\nCODE","receiver-unknown-before-interpreter"]
[0,"python <<'CODE' | node\nprint('const env = new Set();')\nCODE","receiver-interpreter-only-pipeline"]
[0,"node <<'JS'; unknown <<'DATA'\nconst env = new Set();\nJS\nordinary\nDATA","receiver-independent-unknown-body"]
[2,"{ python3; } <<'EOF'\nimport os; print(os.environ)\nEOF","opaque-input-interpreter-dump"]
[2,"exec 3<<'EOF'\nimport os; print(os.environ)\nEOF\npython3 /dev/fd/3","exec-descriptor-interpreter-dump"]
[2,"grep -a . < /proc/self/environ","proc-input-other-reader"]
[2,"while read -r l; do echo \"$l\"; done < /proc/self/environ","proc-input-loop-reader"]
[2,"declare","bare-declare"]
[2,"typeset","bare-typeset"]
[2,"env -u \"$@\" NAME","env-unset-expanded-operand"]
[0,"while read -r l; do echo \"$l\"; done <<'EOF'\nRelease notes: env and printenv stay data in this prose.\nEOF","loop-heredoc-prose"]
[0,"for q in 'environment dump' 'printenv'; do .agents/skills/decider/scripts/decisions search \"$q\"; done","for-loop-quoted-search-words"]
[0,"for f in hooks/*.sh; do wc -l \"$f\"; done; grep -n 'export' hooks/command-safety.sh","for-loop-then-export-pattern"]
[0,"sh LAUNCH.sh WAIT TOOL --test 'tool env.sh'","waiter-quoted-env-path-data"]
[0,"sh LAUNCH.sh WAIT TOOL --test 'tool --set-upstream'","waiter-quoted-set-option-data"]
[2,"sh LAUNCH.sh WAIT TOOL --test \"cd $DIR && env\"","waiter-expanded-string-dump"]
[2,"bash wrapper.sh TOOL --test \"cd $DIR && cat ~/.fleet/env\"","private-waiter-expanded-string-read"]
[2,"sh -c '\"$@\"' _ env","shell-string-positional-dump"]
[2,"sh -c 'exec \"$@\"' _ cat ~/.fleet/env","private-shell-string-positional-read"]
[2,"source wrapper.sh env","source-operand-dump"]
[0,"bash -c '\"$@\"' _ npm test","shell-string-positional-launch"]
[0,". ./wrapper.sh env -i A=b cmd","source-operand-empty-launcher"]
[2,"bash \"$MODE\" 'printenv; true'","shell-expanded-option-string-dump"]
[2,"bash -\"$FLAGS\" 'env'","shell-expanded-option-cluster-dump"]
[2,"set --; eval \"$@\" -- env","eval-empty-spread-separator-dump"]
[2,"eval \"$@\" -- env","eval-spread-separator-dump"]
[2,"declare --","declare-options-end"]
[2,"declare -g","declare-global-scope"]
[2,"typeset --","typeset-options-end"]
[2,"builtin declare --","builtin-declare-options-end"]
[2,"builtin declare \"$@\"","builtin-declare-expanded-operand"]
[2,"typeset $NAME","typeset-unquoted-expansion"]
[0,"declare FOO=\"$x\"","declare-assignment-quoted-expansion"]
[0,"typeset FOO=\"$1\"","typeset-assignment-quoted-expansion"]
[2,"declare -g \"$name\"","declare-global-quoted-name"]
[2,"x=-p; export \"$x\"","export-quoted-option-expansion"]
[2,"declare \"$opt\"","declare-quoted-expansion"]
[0,"declare FOO=$x","declare-assignment-unquoted-expansion"]
[0,"export PATH=$HOME/bin:$PATH","export-assignment-unquoted-expansion"]
[0,"export PATH=\"$HOME/bin:$PATH\"","export-assignment-quoted-expansion"]
[0,"declare -g NAME=1","declare-global-named"]
[2,"cat <<'EOF' | exec python3\nimport os; print(os.environ)\nEOF","opaque-piped-input-interpreter-dump"]
[2,"env -S 'sh -c \"$0\"' printenv","env-split-string-positional-dump"]
[2,"sh -c '$0' 'export -p'","shell-string-zero-operand-dump"]
[2,"sh -c 'eval \"$0\"' 'env | cat'","shell-string-eval-zero-operand-dump"]
[2,"env -S 'sh -c' 'export -p'","env-split-string-operand-dump"]
[2,"bash -c $'echo hi\\n'","ansi-shell-string-escape","project","environment-dump","undecoded-ansi-escape"]
[2,"eval $'echo\\thi'","ansi-eval-escape","project","environment-dump","undecoded-ansi-escape"]
[2,"bash wrapper.sh $'\\x6cs'","ansi-forwarded-escape","project","environment-dump","undecoded-ansi-escape"]
[2,"bash -coo errexit pipefail $'\\x65nv'","ansi-shell-multiple-option-operands","project","environment-dump","undecoded-ansi-escape","runs-env"]
[2,"eval 'true;' $'\\x65nv'","ansi-eval-joined-source","project","environment-dump","undecoded-ansi-escape","runs-env"]
[2,"eval \"$x\" $'env'","eval-empty-word-dollar-quoted-dump","project","environment-dump","-","runs-env"]
[2,"eval \"$@\" $'env'","eval-empty-spread-dollar-quoted-dump","project","environment-dump","-","runs-env"]
[2,"eval \"$x\" $'printenv'","eval-empty-word-dollar-quoted-printenv"]
[2,"eval \"$x\" $\"env\"","eval-empty-word-locale-quoted-dump","project","environment-dump","-","runs-env"]
[2,"eval \"$x\" e$'nv'","eval-empty-word-dollar-quoted-fragment-dump","project","environment-dump","-","runs-env"]
[2,"eval \"$x\" env \"$y\" $'foo'","eval-expanding-option-dollar-quoted-operand"]
[2,"eval \"$x\" env \"$y\" foo","eval-expanding-option-literal-operand"]
[2,"bash <<< $'\\x65nv'","ansi-shell-here-string","project","environment-dump","undecoded-ansi-escape","runs-env"]
[2,"cat <<< $'\\x65nv' | bash","ansi-piped-here-string","project","environment-dump","undecoded-ansi-escape","runs-env"]
[2,"exec 3<<< $'\\x65nv'; bash /dev/fd/3","ansi-carried-here-string-descriptor","project","environment-dump","undecoded-ansi-escape","runs-env"]
[2,"source /dev/stdin <<< $'\\x65nv'","ansi-sourced-here-string","project","environment-dump","undecoded-ansi-escape","runs-env"]
[2,"while read -r a b; do :; done <<< $'x 1\\ny 2'","ansi-loop-here-string-drop","project","environment-dump","undecoded-ansi-escape"]
[2,"{ cat; } <<< $'a\\tb'","ansi-grouped-here-string-drop","project","environment-dump","undecoded-ansi-escape"]
[0,"bash -c 'printf env'","oracle-control-printf-env","project","environment-dump","-","no-env"]
ENVIRONMENT_ROWS
  ) || exit 1
  while IFS=$'\t' read -r expected command_json label world refusal reason oracle; do
    [ -n "$expected" ] || continue
    printf -v command_json '%b' "$command_json"
    row_selected "$label" || continue
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
    if [ "$world" = deadline ]; then
      # The measured source-edit workload is data submitted to the hook.
      # Verify its retained size and literal contents before timing it.
      command_json=$(python3 - <<'PY'
import ast
import json

old = ''.join('setting_%04d = os.environ.get("DISPLAY", "")\n' % i for i in range(800))
new = ''.join('setting_%04d = os.environ.get("TERM", "")\n' % i for i in range(800))
body = "from pathlib import Path\npath = Path('scripts/settings.py')\nold = '''" + old + "'''\nnew = '''" + new + "'''\ntext = path.read_text()\nassert old in text\npath.write_text(text.replace(old, new))\n"
tree = ast.parse(body)
assert len(body.encode()) == 69769
assert body.count('os.environ.get(') == 1600
assert sum(isinstance(n, ast.Constant) and n.value in (old, new) for n in ast.walk(tree)) == 2
print(json.dumps("python3 - <<'PY'\n" + body + '\nPY'))
PY
      ) || exit 1
    fi
    payload=$(jq -nc --argjson submitted "$command_json" --arg cwd "$payload_cwd" --argjson invalid "$invalid" --arg shape "$shape_kind" '
      {cwd:(if $invalid then 42 else $cwd end)} +
      (if $shape == "cmd" then {tool_input:{cmd:$submitted}}
       elif $shape == "copilot" then {toolArgs:{command:$submitted}}
       elif $shape == "copilot-string" then {toolArgs:({command:$submitted} | tojson)}
       elif $shape == "top" then {command:$submitted}
       else {tool_input:{command:$submitted}} end)') || exit 1
    status=0
    if [ "$world" = deadline ]; then
      printf '%s' "$payload" >"$scratch/deadline-payload"
      output=$(python3 - "$BASH" "$hook" "$scratch/deadline-payload" "$scratch/deadline-seconds" 2>"$scratch/stderr" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

with open(sys.argv[3], 'rb') as payload:
    start = time.monotonic()
    process = subprocess.Popen(sys.argv[1:3], stdin=payload, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
    try:
        out, err = process.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        sys.exit(124)
Path(sys.argv[4]).write_text(str(time.monotonic() - start))
sys.stdout.buffer.write(out)
sys.stderr.buffer.write(err)
sys.exit(process.returncode)
PY
      ) || status=$?
      if [ "$status" -ne 124 ] && [ -f "$scratch/deadline-seconds" ]; then
        printf 'measure replacement-hook seconds=%s deadline=10 source-bytes=69769 named-reads=1600\n' "$(cat "$scratch/deadline-seconds")"
      fi
    elif [ "$world" = missing-policy-tools ]; then
      output=$(env "PATH=$scratch/policy-tools" "$BASH" "$hook" <<<"$payload" 2>"$scratch/stderr") || status=$?
    elif [[ $label == 'environment: private-'* ]]; then
      output=$(env "HOME=$scratch/private-home" "$BASH" "$hook" <<<"$payload" 2>"$scratch/stderr") || status=$?
    else
      output=$("$BASH" "$hook" <<<"$payload" 2>"$scratch/stderr") || status=$?
    fi
    [ "$world" != absent-loader ] || mv "$scratch/environment-loader" "$repo/.agents/skills/commit-guards/scripts/lib"
    first_key=$(first_line "$scratch/stderr")
    diagnostics_safe=1
    if grep -F -- fixture-private-value-4519 "$scratch/stderr" >/dev/null; then diagnostics_safe=""; fi
    want=-; [ "$expected" -ne 2 ] || want="command-safety: refused=$refusal"
    # A row's reason is the keyed line under the refusal; a row without one
    # holds the refusal line alone.
    keyed=$(keyed_block "$scratch/stderr" command-safety)
    want_keyed=""; [ "$expected" -ne 2 ] || want_keyed="refused=$refusal"
    [ "$reason" = - ] || want_keyed="$want_keyed;reason=$reason"
    if [ "$status" -eq "$expected" ] && [ "$first_key" = "$want" ] && [ "$keyed" = "$want_keyed" ] &&
       [ -z "$output" ] && [ -n "$diagnostics_safe" ]; then
      printf 'PASS %s\n' "$label"; passed=$((passed + 1))
    else
      printf 'FAIL %s: exit=%s expected=%s first=%s expected-first=%s keyed=%s expected-keyed=%s stdout=[%s]\n' "$label" "$status" "$expected" "$first_key" "$want" "$keyed" "$want_keyed" "$output"
      failed=$((failed + 1))
    fi
    if [ "$expected" -eq 2 ] && [ "$refusal" = environment-dump ] && [ "$reason" = - ]; then
      if grep -F -- "systemctl --user show-environment | grep '^NAME='" "$scratch/stderr" >/dev/null; then
        passed=$((passed + 1))
      else
        printf 'FAIL %s remedy: missing required filtered form\n' "$label"; failed=$((failed + 1))
      fi
    fi
    if [ "$oracle" != - ]; then
      if ! oracle_command=$(jq -enr --argjson submitted "$command_json" '$submitted | strings'); then
        oracle_ran=unreadable
      elif oracle_runs_env "$oracle_command"; then
        oracle_ran=runs-env
      else
        oracle_ran=no-env
      fi
      if [ "$oracle_ran" = "$oracle" ]; then
        printf 'PASS %s oracle\n' "$label"; passed=$((passed + 1))
      else
        printf 'FAIL %s oracle: bash %s, expected %s\n' "$label" "$oracle_ran" "$oracle"; failed=$((failed + 1))
      fi
    fi
  done <<<"$rows"
  selection_complete
  [ "$((passed + failed))" -gt "$before" ] || { echo 'FAIL environment table has no rows'; failed=$((failed + 1)); }
  settings
}
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  for rendered in .claude/hooks/command-safety.sh .codex/hooks/command-safety.sh .github/hooks/command-safety.sh .pi/kendex/hooks/command-safety.sh; do
    if cmp -s -- "$hook_source" "$ROOT/$rendered"; then
      printf 'PASS render matches source: %s\n' "$rendered"; passed=$((passed + 1))
    else
      printf 'FAIL render differs from source: %s\n' "$rendered"; failed=$((failed + 1))
    fi
  done
fi
if [ "${1:-}" = --environment-rows ]; then
  shift
  environment_rows "$@"
  printf '%s passed, %s failed\n' "$passed" "$failed"
  [ "$failed" -eq 0 ]
  exit
fi
environment_rows

if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  environment_controls="$(mktemp -d)" || { echo 'command-safety-test: control-scratch=mktemp-failed' >&2; exit 1; }
  [[ -d $environment_controls && ! -L $environment_controls ]] || { echo 'command-safety-test: control-scratch=not-a-directory' >&2; exit 1; }
  environment_controls="$(cd -- "$environment_controls" && pwd -P)" || { echo 'command-safety-test: control-scratch=resolve-failed' >&2; exit 1; }
  trap 'rm -rf -- "$scratch" "${environment_controls:?}"' EXIT
  planted=""
  while IFS='|' read -r defect failed_row; do
    if [ "$defect" = empty-copies ]; then
      case "$BASH_VERSION" in 3.2*) ;; *) continue ;; esac
    fi
    if [ "$defect" != "$planted" ]; then
    planted=$defect
    mutant="$environment_controls/environment-$defect.sh"
    awk -v defect="$defect" '
      function swap(from, to, at) {
        at = index($0, from)
        if (at) { $0 = substr($0, 1, at - 1) to substr($0, at + length(from)); changed++ }
      }
      defect == "no-check" { swap("if environment_dump \"$command_kind\"; then", "if false; then") }
      defect == "private-path" { swap("environment_private_path() {", "environment_private_path() { return 1") }
      defect == "main-evidence-cut" { swap("[[ ! $evidence =~ $opaque_re ]] || return 0", ":") }
      defect == "operand-word-boundary" { swap("(^|[^A-Za-z0-9_.-])(env|printenv|export|declare|typeset|show-environment)([^A-Za-z0-9_.-]|$)", "(^|[^A-Za-z0-9_])(env|printenv|export|declare|typeset|show-environment)([^A-Za-z0-9_]|$)") }
      defect == "unclassified-head-only" { swap("if [ -z \"$stdin_program\" ] && environment_main_evidence \"${args[@]}\"; then mode=dump-unknown; fi", "if [ -z \"$stdin_program\" ] && environment_main_evidence \"${args[$program_pos]}\"; then mode=dump-unknown; fi") }
      defect == "producer-implicit-clean" && $0 == "    mode=other" { swap("mode=other", "mode=clean") }
      defect == "forwarded-registry-cut" { swap("[ -n \"$forwarded_argument\" ] && [ \"${#heredocs[@]}\" -gt 0 ] &&", "false &&") }
      defect == "recursive-context-loss" { swap("[ -z \"${forwarded_argument:-}\" ] || context=forwarded", ":") }
      defect == "set-word-boundary" { swap("(^|[^A-Za-z0-9_-])set([^A-Za-z0-9_-]|$)", "(^|[^A-Za-z0-9_])set([^A-Za-z0-9_]|$)") }
      defect == "exec-context" { swap("program=opaque; compound=1", "program=exec") }
      defect == "quoted-data-cut" { swap("if [ \"$1\" = shell ] && [ -z \"${2:-}$incoming_sources\" ] &&", "if false &&") }
      defect == "quoted-launcher-cut" { swap("{ [ -n \"$script_string\" ] || [ \"$candidate\" -gt \"$((script_pos + 1))\" ]; } && [ -z \"$output\" ]", "false") }
      defect == "file-body-retained" { swap("[ \"$data_source\" = \" $doc\" ]; then continue; fi", "[ \"$data_source\" = \" $doc\" ]; then :; fi") }
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
      defect == "env-terminator" { swap("options_ended=1; pos=$((pos + 1)); continue ;;", "pos=$((pos + 1)); break ;;") }
      defect == "grep-record-flags" { swap("^-[EFq]+$", "^-[EFazq]+$") }
      defect == "nul-records" && $0 == "    case \"${decisions[$stage]}\" in" {
        print "    [ \"${decisions[$stage]}\" != dump-nul ] || decisions[stage]=dump-lines"; changed++
      }
      defect == "unproved-records" { swap("unrouted | dump-unknown) return 0 ;;", "unrouted) return 0 ;; dump-unknown) continue ;;") }
      defect == "syntax-routing" { swap("[ -z \"$syntax_head\" ] || compound=1", ":") }
      defect == "suffix-quotes" { swap("[ \"$program_pos\" = 0 ] && [ \"${stage_kinds[$candidate]}\" = literal ] &&", "false &&") }
      defect == "quoted-heredoc" && /^              for \(\(doc=0;/ { swap("doc<${#heredocs[@]}", "doc<0") }
      defect == "heredoc-resume" { swap("heredoc_bodies[doc]=$body", "heredoc_bodies[doc]=$body; i=$text_length") }
      defect == "unset-operand" && $0 == "                pos=$((pos + 2)) ;;" { swap("pos=$((pos + 2))", "pos=$((pos + 1))") }
      defect == "head-basename" && $0 == "    value=${args[$cursor]}" { swap("value=${args[$cursor]}", "value=${args[$cursor]##*/}") }
      defect == "quoted-head" && $0 == "    if [ \"${arg_kinds[$cursor]}\" = literal ] && [ -n \"${arg_unquoted[$cursor]}\" ]; then" {
        swap("[ -n \"${arg_unquoted[$cursor]}\" ]", "true")
      }
      defect == "array-head" { swap("if [ \"$1\" = argv ]; then pos=0; return; fi", "if [ \"$1\" = argv ]; then for ((cursor=0; cursor<${#args[@]}; cursor++)); do arg_unquoted[cursor]=1; done; fi") }
      defect == "here-string" { swap("then c=\047<<<\047", "then c=\047<<\047") }
      defect == "delimiter-proof" { swap("[ \"$kind\" != ansi-escaped ] || { dump_reason=undecoded-ansi-escape; return 0; }", "[ \"$kind\" != ansi-escaped ] || return 1") }
      defect == "heredoc-program" { swap("[ -n \"${stage_stdin[$stage]}\" ] || data_source=", "data_source=") }
      defect == "body-evidence" { swap("[ -n \"${heredoc_bodies[$doc]+present}\" ] || return 0", "[ -n \"${heredoc_bodies[$doc]+present}\" ] || :") }
      defect == "descriptor-body" { swap("doc=${body_ids[$((j - 1))]:-}", "[ -z \"$fd\" ] || continue; doc=${body_ids[$((j - 1))]:-}") }
      defect == "heredoc-pipe" { swap("data_source=\"$data_source$piped_source\"", "data_source=\"$data_source\"") }
      defect == "missing-identifier-cut" { swap("doc=${body_ids[$((j - 1))]:-}", "doc=${body_ids[$((j - 1))]}") }
      defect == "body-separation" { swap("local command_text=${literal_inputs[$doc]}", "local command_text=${literal_inputs[0]}${literal_inputs[$doc]}") }
      defect == "empty-copies" { swap("stage_args=(${args[@]+\"${args[@]}\"})", "stage_args=(\"${args[@]}\")") }
      defect == "set-unknown" { swap("then mode=dump-unknown; else mode=dump-lines; fi", "then mode=other; else mode=dump-lines; fi") }
      defect == "set-literal-proof" && /^        for \(\(j=pos;/ { swap("[ \"${arg_kinds[$j]}\" != literal ] || named=1", "named=1") }
      defect == "literal-span" { swap("word=$word$span", "word=$word") }
      defect == "comment-boundary" { swap("i=$((i + ${#comment_span}))", "i=$text_length") }
      defect == "array-decoding" { swap("read -r -d $'\''\\t'\'' argument ||", "read -d $'\''\\t'\'' argument ||") }
      defect == "no-dollar-opener" && $0 == "          case \"$next\" in" {
        print; getline
        swap("            \"'\''\" | '\''\"'\'')", "            dollar-opener-disabled)")
      }
      defect == "escaped-head-pass" { swap("[ \"${arg_kinds[$pos]}\" != ansi-escaped ] || { mode=dump-unknown; dump_reason=undecoded-ansi-escape; return; }", "[ \"${arg_kinds[$pos]}\" != ansi-escaped ] || arg_kinds[pos]=unknown") }
      defect == "env-literal-operands" { swap("case \"${arg_kinds[$pos]}\" in dollar-literal | ansi-escaped) break ;; esac", "[ \"${arg_kinds[$pos]}\" = literal ] || break") }
      defect == "systemctl-literal-argument" { swap("[ \"${args[$j]}\" != show-environment ] || mode=dump-lines", "[ \"${arg_kinds[$j]}\" != literal ] || [ \"${args[$j]}\" != show-environment ] || mode=dump-lines") }
      defect == "escaped-argument-pass" { swap("[ \"${arg_kinds[$j]}\" != ansi-escaped ] || { mode=dump-unknown; dump_reason=undecoded-ansi-escape; return; }", "[ \"${arg_kinds[$j]}\" != ansi-escaped ] || :") }
      defect == "escaped-input-pass" { swap("[ -z \"$input_escaped\" ] || { mode=dump-unknown; dump_reason=undecoded-ansi-escape; return; }", "[ -z \"$input_escaped\" ] || :") }
      defect == "receiver-classification" && $0 == "  environment_receiver \"$program\"" { swap("  environment_receiver \"$program\"", "  receiver=unknown; receiver_pattern=; receiver_option=") }
      defect == "receiver-evidence" { swap("while [[ $remaining =~ $receiver_pattern ]]; do", "while [[ $remaining =~ a^ ]]; do") }
      defect == "receiver-python-quoted-source" { swap("if [ -z \"$uncertain\" ]; then remaining=$executable; fi", "if [ -z \"$uncertain\" ]; then remaining=$2; fi") }
      defect == "receiver-named-method" { swap("(get|pop|setdefault|__getitem__|__contains__)", "(get-disabled|pop|setdefault|__getitem__|__contains__)") }
      defect == "receiver-line-boundary" { swap("if [[ $remaining =~ ^[A-Za-z0-9_]+ ]]; then", "if [[ $remaining =~ ^[[:space:]]*[A-Za-z0-9_]+ ]]; then") }
      defect == "receiver-body-forwarding" { swap("fallback_sources=\"$fallback_sources $doc\"", ":") }
      defect == "literal-source-veto" && $0 == "  environment_queue \"$source\" \"$source_kind\"" { print "  if environment_main_evidence \"$source\"; then mode=dump-unknown; return; fi"; changed++ }
      defect == "forwarded-candidates-cut" { swap("for ((candidate=script_pos+1;", "for ((candidate=${#stage_args[@]};") }
      defect == "producer-other" && $0 == "    mode=other" { print; print "    return"; changed++; next }
      defect == "strict-env-ignore" { swap("-i | --ignore-environment) pos=$((pos + 1)) ;;", "-i | --ignore-environment) mode=dump-unknown; return ;;") }
      defect == "suffix-scan" { swap("[ -z \"$syntax_head\" ] || compound=1", "[ -z \"$syntax_head\" ] || { compound=1; suffix_scan=1; }; [ -z \"${suffix_scan:-}\" ] || ! environment_main_evidence \"${args[@]}\" || return 0") }
      defect == "opaque-input-refusal" && $0 == "    opaque)" { print; print "      [ -z \"$data_source\" ] || { mode=dump-unknown; return; }"; changed++; next }
      defect == "eval-separator" { swap("!= --:literal ] || cursor=$((cursor + 1))", "!= --:literal ] || :") }
      defect == "unset-expanded-operand" { swap("[ \"${arg_kinds[$((pos + 1))]:-}\" = literal ] || { mode=dump-unknown; return; }", ":") }
      defect == "proc-input-reader" { swap("*) [ -z \"$proc\" ] || mode=dump-unknown ;;", "*) ;;") }
      defect == "bare-declaration" { swap("[ -z \"$listing\" ] || mode=dump-lines", ":") }
      defect == "opaque-input-interpreter" { swap("for language in python node ruby perl; do", "for language in; do") }
      defect == "expanded-command-string" { swap("[ \"$producer_end\" -le 1 ]; then", "[ \"$producer_end\" -eq 1 ]; then") }
      defect == "string-positional-operands" && $0 == "        script_operand=$cursor" { swap("script_operand=$cursor", "[ -n \"$wants_string\" ] || script_operand=$cursor") }
      defect == "source-operands" { swap("[ \"$pos\" -ge \"${#args[@]}\" ] || script_operand=$pos", ":") }
      defect == "expanded-option-string" { swap("environment_queue \"${args[$((cursor + 1))]}\"", ":") }
      defect == "declaration-listing" { swap("[[ $value =~ ^(--|-[gI]+)$ ]] || listing=\"\"", "listing=\"\"") }
      defect == "escape-reason" { swap("\"$dump_reason\"", "-") }
      defect == "string-zero-operand" { swap("{ [ -n \"$script_string\" ] ||", "{ false ||") }
      defect == "declaration-naming" { swap("*) [[ ! $value =~ $declared_re ]] || named=1 ;;", "*) ;;") }
      { print }
      END { if (changed != 1) exit 1 }
    ' "$hook_source" >"$mutant" || exit 1
    if cmp -s -- "$hook_source" "$mutant"; then echo "FAIL environment control $defect changed no bytes"; exit 1; fi
    fi
    row_label=${failed_row#FAIL environment: }; row_label=${row_label%%: exit=*}
    control_status=0
    if [ "$defect" = literal-source-veto ] || [ "$defect" = private-path ]; then
      env "HOOK_UNDER_TEST=$mutant" "$BASH" "${BASH_SOURCE[0]}" --environment-rows "$row_label" \
        >"$scratch/environment-$defect.log" 2>&1 || control_status=$?
    else
    (
      passed=0; failed=0
      cp -- "$mutant" "$hook"
      environment_rows "$row_label"
      [ "$failed" -eq 0 ]
    ) >"$scratch/environment-$defect.log" 2>&1 || control_status=$?
    cp -- "$hook_source" "$hook"
    fi
    if [ "$control_status" -eq 1 ] && grep -F -- "$failed_row" "$scratch/environment-$defect.log" >/dev/null; then
      printf 'PASS environment control %s rejects its planted rule failure\n' "$defect"; passed=$((passed + 1))
    else
      printf 'FAIL environment control %s: exit=%s missing=%s\n' "$defect" "$control_status" "$failed_row"; failed=$((failed + 1))
    fi
  done <<'ENVIRONMENT_CONTROLS'
private-path|FAIL environment: private-tilde: exit=0 expected=2
receiver-named-method|FAIL environment: receiver-jarvis-config-named-method: exit=2 expected=0
receiver-named-method|FAIL environment: receiver-jarvis-heredoc-named-method: exit=2 expected=0
receiver-line-boundary|FAIL environment: receiver-python-heredoc-whole-line-end: exit=0 expected=2
receiver-line-boundary|FAIL environment: receiver-node-heredoc-whole-line-end: exit=0 expected=2
receiver-body-forwarding|FAIL environment: receiver-node-unknown-downstream: exit=0 expected=2
receiver-body-forwarding|FAIL environment: receiver-unknown-before-interpreter: exit=0 expected=2
receiver-classification|FAIL environment: receiver-python-key-inventory: exit=2 expected=0
receiver-evidence|FAIL environment: receiver-python-heredoc-whole-0: exit=0 expected=2
receiver-python-quoted-source|FAIL environment: receiver-python-replacement-source: exit=2 expected=0
receiver-evidence|FAIL environment: receiver-python-heredoc-whole-1: exit=0 expected=2
receiver-evidence|FAIL environment: receiver-python3-heredoc-whole-0: exit=0 expected=2
receiver-evidence|FAIL environment: receiver-node-heredoc-whole-0: exit=0 expected=2
receiver-evidence|FAIL environment: receiver-ruby-heredoc-whole-0: exit=0 expected=2
receiver-evidence|FAIL environment: receiver-ruby-heredoc-whole-1: exit=0 expected=2
receiver-evidence|FAIL environment: receiver-perl-heredoc-whole-0: exit=0 expected=2
literal-source-veto|FAIL environment: fleet-literal-command-string-setup: exit=2 expected=0
quoted-data-cut|FAIL environment: quoted-body-stdout-only: exit=2 expected=0
quoted-data-cut|FAIL environment: escaped-heredoc-delimiter: exit=2 expected=0
no-check|FAIL environment: incident: exit=0 expected=2
no-check|FAIL environment: bare-env: exit=0 expected=2
no-check|FAIL environment: bare-printenv: exit=0 expected=2
no-check|FAIL environment: export-list: exit=0 expected=2
no-check|FAIL environment: declare-export: exit=0 expected=2
no-check|FAIL environment: operand-command-env: exit=0 expected=2
no-check|FAIL environment: operand-command-printenv: exit=0 expected=2
no-check|FAIL environment: operand-command-export: exit=0 expected=2
no-check|FAIL environment: operand-command-declare: exit=0 expected=2
no-check|FAIL environment: operand-command-systemctl: exit=0 expected=2
no-check|FAIL environment: piped-here-string-program: exit=0 expected=2
no-check|FAIL environment: shell-heredoc-bodies-have-independent-quotes: exit=0 expected=2
no-check|FAIL environment: unregistered-heredoc-final-word: exit=0 expected=2
no-check|FAIL environment: unquoted-heredoc-single-quotes-expand: exit=0 expected=2
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
syntax-routing|FAIL environment: brace-conservative-filter: exit=0 expected=2
here-string|FAIL environment: quoted-here-string-data: exit=2 expected=0
delimiter-proof|FAIL environment: encoded-heredoc-delimiter: exit=0 expected=2
heredoc-program|FAIL environment: shell-heredoc-bodies-have-independent-quotes: exit=0 expected=2
body-evidence|FAIL environment: unread-shell-heredoc-body-without-marker: exit=0 expected=2
descriptor-body|FAIL environment: shell-duplicated-heredoc-program: exit=0 expected=2
heredoc-pipe|FAIL environment: piped-here-string-program: exit=0 expected=2
missing-identifier-cut|FAIL environment: dump-before-unregistered-heredoc-redirect: exit=0 expected=2
body-separation|FAIL environment: shell-heredoc-bodies-have-independent-quotes: exit=0 expected=2
empty-copies|FAIL environment: empty-case-stage-before-dump: exit=0 expected=2
set-unknown|FAIL environment: set-unquoted-variable-can-disappear: exit=0 expected=2
set-literal-proof|FAIL environment: copilot-set-indirect-name-spread-empty: exit=0 expected=2
no-check|FAIL environment: waiter-quoted-env-dump: exit=0 expected=2
no-check|FAIL environment: waiter-quoted-printenv-dump: exit=0 expected=2
unclassified-head-only|FAIL environment: waiter-unclassified-test-env: exit=0 expected=2
recursive-context-loss|FAIL environment: waiter-recursive-test-bash-env: exit=0 expected=2
forwarded-registry-cut|FAIL environment: waiter-registry-test-expand-xargs: exit=0 expected=2
forwarded-registry-cut|FAIL environment: waiter-registry-test-expand-timeout: exit=0 expected=2
forwarded-registry-cut|FAIL environment: waiter-registry-test-execute-body: exit=0 expected=2
producer-implicit-clean|FAIL environment: waiter-result-test-xargs-env: exit=0 expected=2
suffix-quotes|FAIL environment: wrapper-quoted-bare-env-data: exit=2 expected=0
quoted-heredoc|FAIL environment: quoted-heredoc-script: exit=2 expected=0
quoted-heredoc|FAIL environment: double-quoted-heredoc-data: exit=2 expected=0
file-body-retained|FAIL environment: receiver-unknown-after-file-data: exit=2 expected=0
heredoc-resume|FAIL environment: dump-after-quoted-heredoc: exit=0 expected=2
unset-operand|FAIL environment: unset-without-program: exit=0 expected=2
head-basename|FAIL environment: pathname-basename-is-not-syntax: exit=2 expected=0
quoted-head|FAIL environment: quoted-control-word-is-an-executable: exit=2 expected=0
array-head|FAIL environment: array-function-is-an-executable: exit=2 expected=0
literal-span|FAIL environment: bare-env: exit=0 expected=2
literal-span|FAIL environment: single-quoted-producer: exit=0 expected=2
literal-span|FAIL environment: quoted-producer: exit=0 expected=2
comment-boundary|FAIL environment: comment-boundary-producer: exit=0 expected=2
array-decoding|FAIL environment: array-backslash-name-is-not-literal: exit=0 expected=2
no-dollar-opener|FAIL environment: ansi-dollar-producer: exit=0 expected=2
no-dollar-opener|FAIL environment: locale-dollar-producer: exit=0 expected=2
escaped-head-pass|FAIL environment: ansi-escaped-head: exit=0 expected=2
env-literal-operands|FAIL environment: env-variable-assignment-launcher: exit=2 expected=0
env-literal-operands|FAIL environment: env-variable-chdir-launcher: exit=2 expected=0
env-literal-operands|FAIL environment: env-variable-unset-launcher: exit=2 expected=0
systemctl-literal-argument|FAIL environment: ansi-systemctl-producer-argument: exit=0 expected=2
escaped-argument-pass|FAIL environment: ansi-systemctl-encoded-argument: exit=0 expected=2
escaped-input-pass|FAIL environment: ansi-cat-encoded-input: exit=0 expected=2
receiver-body-forwarding|FAIL environment: unquoted-file-body-literal: exit=0 expected=2
exec-context|FAIL environment: ansi-exec-escaped-head: exit=0 expected=2
exec-context|FAIL environment: ansi-builtin-escaped-head: exit=0 expected=2
forwarded-candidates-cut|FAIL environment: private-forwarded-cat: exit=0 expected=2
forwarded-candidates-cut|FAIL environment: sh-wrapper-bare-set: exit=0 expected=2
quoted-launcher-cut|FAIL environment: waiter-recursive-test-bash-env: exit=0 expected=2
main-evidence-cut|FAIL environment: waiter-unclassified-test-env: exit=0 expected=2
operand-word-boundary|FAIL environment: waiter-quoted-env-path-data: exit=2 expected=0
set-word-boundary|FAIL environment: waiter-quoted-set-option-data: exit=2 expected=0
producer-other|FAIL environment: opaque-shell-filter: exit=0 expected=2
producer-other|FAIL environment: bare-declare: exit=0 expected=2
producer-other|FAIL environment: bare-typeset: exit=0 expected=2
producer-other|FAIL environment: env-unset-expanded-operand: exit=0 expected=2
producer-other|FAIL environment: exec-descriptor-interpreter-dump: exit=0 expected=2
strict-env-ignore|FAIL environment: wrapper-empty-launcher: exit=2 expected=0
suffix-scan|FAIL environment: suffix-quoted-launcher-data: exit=2 expected=0
suffix-scan|FAIL environment: time-unknown-suffix-dump: exit=2 expected=0
suffix-scan|FAIL environment: unsupported-list-evidence: exit=2 expected=0
suffix-scan|FAIL environment: unsupported-pipe-evidence: exit=2 expected=0
suffix-scan|FAIL environment: conditional-data-conservative: exit=2 expected=0
suffix-scan|FAIL environment: loop-data-conservative: exit=2 expected=0
suffix-scan|FAIL environment: conservative-sudo-group-operand: exit=2 expected=0
suffix-scan|FAIL environment: syntax-assignment-data: exit=2 expected=0
suffix-scan|FAIL environment: syntax-function-name: exit=2 expected=0
suffix-scan|FAIL environment: syntax-coproc-name: exit=2 expected=0
suffix-scan|FAIL environment: punctuated-argument-data: exit=2 expected=0
suffix-scan|FAIL environment: conservative-sudo-operand: exit=2 expected=0
suffix-scan|FAIL environment: ken-3998-compound-quoted-data: exit=2 expected=0
suffix-scan|FAIL environment: ken-3998-compound-unquoted-set-data: exit=2 expected=0
suffix-scan|FAIL environment: for-loop-quoted-search-words: exit=2 expected=0
suffix-scan|FAIL environment: for-loop-then-export-pattern: exit=2 expected=0
opaque-input-refusal|FAIL environment: loop-heredoc-prose: exit=2 expected=0
eval-separator|FAIL environment: literal-eval-option-terminator: exit=0 expected=2
unset-expanded-operand|FAIL environment: nested-unset-unproved-option-operand: exit=0 expected=2
proc-input-reader|FAIL environment: inner_source_candidate: exit=0 expected=2
bare-declaration|FAIL environment: ken-3998-compound-bare-declare: exit=0 expected=2
opaque-input-interpreter|FAIL environment: opaque-input-interpreter-dump: exit=0 expected=2
opaque-input-interpreter|FAIL environment: opaque-piped-input-interpreter-dump: exit=0 expected=2
expanded-command-string|FAIL environment: waiter-expanded-command-retains-refusal: exit=0 expected=2
expanded-command-string|FAIL environment: waiter-expanded-string-dump: exit=0 expected=2
string-positional-operands|FAIL environment: shell-string-positional-dump: exit=0 expected=2
source-operands|FAIL environment: source-operand-dump: exit=0 expected=2
expanded-option-string|FAIL environment: shell-expanded-option-string-dump: exit=0 expected=2
declaration-listing|FAIL environment: declare-options-end: exit=0 expected=2
declaration-listing|FAIL environment: builtin-declare-options-end: exit=0 expected=2
escape-reason|FAIL environment: ansi-shell-string-escape: exit=2 expected=2
string-zero-operand|FAIL environment: shell-string-zero-operand-dump: exit=0 expected=2
string-zero-operand|FAIL environment: shell-string-eval-zero-operand-dump: exit=0 expected=2
string-zero-operand|FAIL environment: env-split-string-operand-dump: exit=0 expected=2
declaration-naming|FAIL environment: declare-assignment-quoted-expansion: exit=2 expected=0
declaration-naming|FAIL environment: declare-assignment-unquoted-expansion: exit=2 expected=0
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
default_rows
# The default is written three times: the hook applies it, the commit-guards
# example declares it for the app's Customize tab, and the doc prints it.
# Each copy is read from its own file, the example through the settings
# loader the hook uses.
default_consistency
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
shape_rows() {
  local selected_rows=("$@") selected_seen=() expected want_first filter label
before=$((passed + failed))
while IFS='|' read -r expected want_first filter label; do
  [ -n "$expected" ] || continue
  [ "$want_first" != - ] || want_first='-'
  row_selected "$label" || continue
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
  selection_complete
}
shape_rows
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
policy_control_rows() { # defect and its private mutated source
  local repo="$scratch/policy-$1" hook hook_source="$2"
  prepare_project "$2"
  hook="$repo/.claude/hooks/command-safety.sh"
  settings
  case "$1" in
    no-default | default-key) default_rows 'empty-env: a bare MemoryMax';
      [ "$1" != no-default ] || default_rows 'no-file: a bare MemoryMax' ;;
    no-quote) default_rows 'empty-env: a quoted MemoryMax' 'no-file: a quoted MemoryMax'; default_consistency ;;
    unit-g) default_rows 'empty-env: gigabyte-cap' 'no-file: gigabyte-cap' ;;
    no-cwd-fallback) shape_rows 'a denied command without cwd uses the caller policy' ;;
    *) printf 'FAIL policy control: unknown defect=%s\n' "$1"; failed=$((failed + 1)) ;;
  esac
}
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
      (
        passed=0; failed=0
        policy_control_rows "$defect" "$mutant"
        [ "$failed" -eq 0 ]
      ) >"$scratch/$defect.log" 2>&1 || control_status=$?
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
  local selected_rows=("$@") selected_seen=() failed=0 before=$((PASS + FAIL))
  while IFS='|' read -r label hook_dir library state expected key; do
    row_selected "$label" || continue
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
  [ "$((PASS + FAIL))" -gt "$before" ] || { echo "  FAIL  reader table has no rows"; FAIL=$((FAIL + 1)); }
  selection_complete
  FAIL=$((FAIL + failed))
}
global_reader_rows
reader_control_rows() { global_reader_rows "${reader_control_labels[@]}"; }
reader_control_labels=(pi-shared codex-shared gemini-shared copilot-shared)
skill_load_control global-reader "$HOOK" '*) lib="${HOME:+$HOME/.agents/skills/commit-guards/scripts/lib}"' \
  'lib=""' HOOK reader_control_rows 'pi-shared installed reader' 'codex-shared installed reader' 'gemini-shared installed reader' 'copilot-shared installed reader'
reader_control_labels=(absent-global)
skill_load_control loader-boundary "$HOOK" '*) lib="${HOME:+$HOME/.agents/skills/commit-guards/scripts/lib}"' \
  'lib="$root/.agents/skills/commit-guards/scripts/lib"' HOOK reader_control_rows 'absent-global project loader boundary'
reader_control_labels=(common-exit)
skill_load_control support-state "$HOOK" 'loading="$lib/common.sh"' 'loading=""' HOOK reader_control_rows 'common-exit installed reader' 'common-exit warns once'
skill_load_control support-cause "$HOOK" 'cause="$cause
  $detail"' 'cause=$loading' HOOK reader_control_rows 'common-exit replays cause'
failed=$((failed + FAIL))
passed=$((passed + PASS))
printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
