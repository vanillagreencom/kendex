#!/usr/bin/env bash
# Tests for the block-unsafe-rm hook.
#
# Every refusal opens with `block-unsafe-rm: <key>=<value>`, and that line is
# the contract: the first-line table pins the key and the value of each
# condition beside its exit status, and the English under it is not asserted.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (a no-op hook, an always-block hook) run against these assertions.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/block-unsafe-rm.sh}"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)" || { echo 'block-unsafe-rm: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'block-unsafe-rm: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'block-unsafe-rm: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
ERR_FILE="$TMP_ROOT/stderr"
BASH_BIN="$(command -v bash)"

# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"
assert_contains() {
  if grep -qF -- "$2" "$ERR_FILE"; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        wanted: %s\n        in:\n%s\n' "$3" "$2" "$(cat "$ERR_FILE")"; fi
}

# The command reaches the hook JSON-encoded, exactly as the harness sends it.
# jq does the encoding rather than sed: a Bash tool call is routinely several
# lines, and a raw newline inside a JSON string is not JSON, so a sed-built
# fixture could not express the multi-line rows at all.
json_for() {
  jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'
}

run_hook() { # command -> rc, stderr in ERR_FILE
  set +e
  json_for "$1" | env TMPDIR=/home/method/dev/.scratch/agents TMP=/shared/tmp/// \
    TEMP='/shared/te(mp).+' AGENT_TMPDIR=/shared/agent HOME=/shared/home \
    "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE"
  rc=$?
  set -e
}

run_payload() { # raw-json -> rc, stderr in ERR_FILE
  set +e
  printf '%s' "$1" | env -u TMPDIR -u TMP -u TEMP -u AGENT_TMPDIR HOME="${PAYLOAD_HOME-}" \
    "$BASH_BIN" "$HOOK" >/dev/null 2>"$ERR_FILE"
  rc=$?
  set -e
}

# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

# The hook's dependency list, in the order it checks them: the shared table
# pins it as the value of the world that has none of them.
PAYLOAD_ADVISORY=1
PAYLOAD_TOOLS=jq,cat

# shellcheck source=lib/payload-rows.sh
. "$TEST_DIR/lib/payload-rows.sh"

shared_rows() {
  first_table 'incident guarded TMPDIR root|command|2|block-unsafe-rm: refused=shared-root|rm -rf -- "${TMPDIR:?}"
incident literal glob|command|2|block-unsafe-rm: refused=shared-root|rm -rf -- /home/method/dev/.scratch/agents/tmp.*
bare TMPDIR glob|command|2|block-unsafe-rm: refused=shared-root|rm -rf "$TMPDIR"/*
guarded HOME glob|command|2|block-unsafe-rm: refused=shared-root|rm -rf "${HOME:?}/"*
TMP alternative|command|2|block-unsafe-rm: refused=shared-root|rm -rf ${TMP:-x}
TEMP braced root|command|2|block-unsafe-rm: refused=shared-root|rm -rf ${TEMP}
bare HOME|command|2|block-unsafe-rm: refused=shared-root|rm -rf $HOME
operator AGENT_TMPDIR|command|2|block-unsafe-rm: refused=shared-root|rm -rf "${AGENT_TMPDIR:?empty}"
direct bracket glob|command|2|block-unsafe-rm: refused=shared-root|rm -rf "${TMPDIR:?}"/tmp.[ab]
direct question glob|command|2|block-unsafe-rm: refused=shared-root|rm -rf "$TMPDIR"/tmp.?
guarded dot segment glob|command|2|block-unsafe-rm: refused=shared-root|rm -rf "${TMPDIR:?}/./"*
guarded parent segment glob|command|2|block-unsafe-rm: refused=shared-root|rm -rf "${TMPDIR:?}/x/../"*
bare dot segment glob|command|2|block-unsafe-rm: refused=shared-root|rm -rf "$TMPDIR"/./*
bare parent segment glob|command|2|block-unsafe-rm: refused=shared-root|rm -rf "$TMPDIR"/x/../*
literal dot segment glob|command|2|block-unsafe-rm: refused=shared-root|rm -rf /shared/home/./*
literal parent segment glob|command|2|block-unsafe-rm: refused=shared-root|rm -rf /shared/home/x/../*
quoted literal parent segment|command|2|block-unsafe-rm: refused=shared-root|rm -rf "/shared/home/x/../tmp.AbC123"
dot segment at operand end|command|2|block-unsafe-rm: refused=shared-root|rm -rf /shared/home/private/.
parent segment at operand end|command|2|block-unsafe-rm: refused=shared-root|rm -rf "${HOME:?}/private/.."
literal root|command|2|block-unsafe-rm: refused=shared-root|rm -rf /shared/home
literal hidden glob|command|2|block-unsafe-rm: refused=shared-root|rm -rf /shared/home/.*
literal glob trailing slash|command|2|block-unsafe-rm: refused=shared-root|rm -rf /shared/home/tmp.*/
quoted literal root|command|2|block-unsafe-rm: refused=shared-root|rm -rf "/shared/home/"
later literal glob|command|2|block-unsafe-rm: refused=shared-root|rm -rf /literal/path /shared/agent/*
single quoted literal|command|2|block-unsafe-rm: refused=shared-root|rm -rf '\''/shared/home'\''
environment trailing slashes|command|2|block-unsafe-rm: refused=shared-root|rm -rf /shared/tmp/tmp.*
environment regex characters|command|2|block-unsafe-rm: refused=shared-root|rm -rf "/shared/te(mp).+"/*
nonrecursive shared root|command|2|block-unsafe-rm: refused=shared-root|rm /shared/home
private directory same call|command|0|-|d=$(mktemp -d); rm -rf -- "${d:?}"
longer TMPDIR name|command|0|-|rm -rf "${TMPDIRX:?}/x"
different HOME name|command|0|-|rm -rf "${MY_HOME:?}/x"
guarded named child|command|0|-|rm -rf "${TMPDIR:?}/tmp.AbC123"
literal named child|command|0|-|rm -rf /home/method/dev/.scratch/agents/tmp.AbC123
literal nested glob|command|0|-|rm -rf /shared/home/private/*
literal dotted child|command|0|-|rm -rf /shared/home/private./tmp.AbC123
literal hidden child|command|0|-|rm -rf /shared/home/.private/tmp.AbC123
guarded nested glob|command|0|-|rm -rf "${TMPDIR:?}/private"/*
literal sibling prefix|command|0|-|rm -rf /shared/home-other/*
literal regex mismatch|command|0|-|rm -rf /shared/tempX/tmp.*
redirection is not operand|command|0|-|rm -rf /literal/path > /shared/home
single quoted variable|command|0|-|rm -rf '\''${HOME:?}'\''
'
}
shared_rows
skill_load_control shared-variable "$HOOK" 'SHARED_RE="${RM_EDGE}rm${SKIP}${GAP}+${SHARED_ROOT}"' \
  "SHARED_RE='a^'" HOOK shared_rows 'incident guarded TMPDIR root'
skill_load_control shared-literal "$HOOK" '${literal_root}${literal_end}"' \
  "SHARED_RE='a^'" HOOK shared_rows 'incident literal glob'
skill_load_control shared-dot-segments "$HOOK" '${CROSSABLE}*)?"' \
  "SHARED_DOT='a^'" HOOK shared_rows 'guarded dot segment glob' \
  'guarded parent segment glob' 'literal dot segment glob' 'literal parent segment glob'

# Tool calls routinely quote cleanup source while rewriting another script.
# Literal boundaries and the closed Python string grammar prove data input.
data_body_rows() {
  first_table 'python replacement heredoc|command|0|-|python3 - <<'\''PY'\''\ns = '\''rm -rf "$scratch"'\''\ns.replace(s, "cleanup")\nPY
file writing heredoc|command|0|-|cat > tmp/helper.py <<'\''EOF'\''\ns = '\''rm -rf "$scratch"'\''\nEOF
python replacement inline|command|0|-|python3 -c '\''s = """rm -rf "$scratch"\n"""; print(s)'\''
literal double quoted program|command|0|-|python3 -c "s = '\''rm -rf /shared/home'\''"
python shared inline|command|0|-|python -c '\''s = "rm -rf $HOME"'\''
escaped delimiter|command|0|-|cat <<\\EOF\nrm -rf $X\nEOF
tab stripped delimiter|command|0|-|cat <<-'\''EOF'\''\n\trm -rf $X\n\tEOF
quoted heredoc marker|command|0|-|python3 -c '\''s = "<<EOF rm -rf $X"'\''
literal backticks in program|command|0|-|python3 -c '\''s = "`rm -rf $X`"'\''
literal backticks in heredoc|command|0|-|cat <<'\''EOF'\''\n`rm -rf $X`\nEOF
guarded shared root as data|command|0|-|cat <<'\''EOF'\''\nrm -rf "${HOME:?}"\nEOF
quoted data receiver|command|0|-|"python3" -c '\''s = "rm -rf $HOME"'\''
assigned string replacement|command|0|-|python3 -c '\''s = "rm -rf $HOME"; s = s.replace(s, "cleanup"); print(s)'\''
call names inside string|command|0|-|python3 -c '\''s = "rm -rf $HOME os.system eval exec __import__"'\''
'
}
executable_body_rows() {
  first_table 'node inline|command|2|block-unsafe-rm: refused=recursive-rm|node -e '\''const s = "rm -rf $X";'\''
ruby inline|command|2|block-unsafe-rm: refused=recursive-rm|ruby -e '\''s = "rm -rf $X"'\''
perl inline|command|2|block-unsafe-rm: refused=recursive-rm|perl -e '\''$s = "rm -rf $X";'\''
node heredoc|command|2|block-unsafe-rm: refused=shared-root|node <<"JS"\nconst s = '\''rm -rf $HOME'\'';\nJS
ruby heredoc|command|2|block-unsafe-rm: refused=recursive-rm|ruby <<'\''RB'\''\ns = "rm -rf $X"\nRB
perl heredoc|command|2|block-unsafe-rm: refused=recursive-rm|perl <<'\''PL'\''\n$s = "rm -rf $X";\nPL
real removal|command|2|block-unsafe-rm: refused=recursive-rm|rm -rf "$scratch/x"
shell inline|command|2|block-unsafe-rm: refused=recursive-rm|bash -c '\''rm -rf "$X/sub"'\''
eval inline|command|2|block-unsafe-rm: refused=recursive-rm|eval '\''rm -rf $X'\''
source inline|command|2|block-unsafe-rm: refused=recursive-rm|source <(echo '\''rm -rf $X'\'')
shell heredoc|command|2|block-unsafe-rm: refused=recursive-rm|bash <<'\''EOF'\''\nrm -rf "$X/sub"\nEOF
expanding data heredoc|command|2|block-unsafe-rm: refused=recursive-rm|cat <<EOF\n$(rm -rf "$X/sub")\nEOF
after data heredoc|command|2|block-unsafe-rm: refused=shared-root|python3 - <<'\''PY'\''\ns = "rm -rf $HOME"\nPY\nrm -rf "$X/sub"
unknown receiver heredoc|command|2|block-unsafe-rm: refused=recursive-rm|unrecognized-tool <<'\''EOF'\''\nrm -rf "$X/sub"\nEOF
quoted unknown receiver|command|2|block-unsafe-rm: refused=recursive-rm|"python\\3" <<'\''EOF'\''\nrm -rf $X\nEOF
carriage return in receiver|command|2|block-unsafe-rm: refused=recursive-rm|python3\r <<'\''EOF'\''\nrm -rf $X\nEOF
inline shell substitution|command|2|block-unsafe-rm: refused=recursive-rm|python3 -c "print('\''$(rm -rf $X)'\'')"
piped shell heredoc|command|2|block-unsafe-rm: refused=recursive-rm|cat <<'\''EOF'\'' | bash\nrm -rf $X\nEOF
inline program piped to shell|command|2|block-unsafe-rm: refused=recursive-rm|python3 -c '\''print("rm -rf $X")'\'' | bash
data redirected to shell|command|2|block-unsafe-rm: refused=recursive-rm|cat > >(bash) <<'\''EOF'\''\nrm -rf $X\nEOF
mixed heredocs|command|2|block-unsafe-rm: refused=shared-root|cat <<'\''A'\''; bash <<'\''B'\''\nrm -rf $X\nA\nrm -rf $HOME\nB
incomplete data heredoc|command|2|block-unsafe-rm: refused=recursive-rm|cat <<'\''EOF'\''\nrm -rf $X
combined redirect receiver|command|2|block-unsafe-rm: refused=shared-root|bash -s &>/dev/null python3 <<'\''EOF'\''\nrm -rf $HOME\nEOF
combined append receiver|command|2|block-unsafe-rm: refused=shared-root|bash -s \046>>/dev/null python3 <<'\''EOF'\''\nrm -rf $HOME\nEOF
backtick eval receiver|command|2|block-unsafe-rm: refused=shared-root|eval `\ncat <<'\''EOF'\''\nrm -rf "$HOME"\nEOF\n`
backtick shell receiver|command|2|block-unsafe-rm: refused=recursive-rm|cat `bash <<'\''EOF'\''\nrm -rf "$X/sub"\nEOF\n`
subshell input receiver|command|2|block-unsafe-rm: refused=shared-root|( bash; cat ) <<'\''EOF'\''\nrm -rf $HOME\nEOF
brace group input receiver|command|2|block-unsafe-rm: refused=shared-root|{ bash; cat; } <<'\''EOF'\''\nrm -rf $HOME\nEOF
data before unproved receiver|command|2|block-unsafe-rm: refused=shared-root|python3 -c '\''s = "rm -rf $X"'\''; bash -s &>/dev/null python3 <<'\''EOF'\''\nrm -rf $HOME\nEOF
python dollar quote boundary|command|2|block-unsafe-rm: refused=shared-root|python3 -c $\047a\134\047\047 ; rm -rf $HOME ; echo \134\047
node dollar quote boundary|command|2|block-unsafe-rm: refused=shared-root|node -e $\047a\134\047\047 ; rm -rf $HOME ; echo \134\047
ruby dollar quote boundary|command|2|block-unsafe-rm: refused=shared-root|ruby -e $\047a\134\047\047 ; rm -rf $HOME ; echo \134\047
perl dollar quote boundary|command|2|block-unsafe-rm: refused=shared-root|perl -e $\047a\134\047\047 ; rm -rf $HOME ; echo \134\047
quoted keyword receiver|command|2|block-unsafe-rm: refused=shared-root|"if" python3 <<'\''EOF'\''\nrm -rf $HOME\nEOF
quoted assignment receiver|command|2|block-unsafe-rm: refused=shared-root|"MODE=test" python3 <<'\''EOF'\''\nrm -rf $HOME\nEOF
option argument owns program flag|command|2|block-unsafe-rm: refused=shared-root|python3 -W -c '\''rm -rf $HOME'\''
option terminator owns program flag|command|2|block-unsafe-rm: refused=shared-root|python3 -- -c '\''rm -rf $HOME'\''
double quoted program|command|2|block-unsafe-rm: refused=recursive-rm|python3 -c "print('\''rm -rf $X'\'')"
multiple data bodies|command|2|block-unsafe-rm: refused=shared-root|cat <<'\''A'\'' <<'\''B'\''\nrm -rf $X\nA\nrm -rf $HOME\nB
escaped backticks in program|command|2|block-unsafe-rm: refused=recursive-rm|python3 -c "print('\''\\`rm -rf $X\\`'\'')"
assignment before data receiver|command|2|block-unsafe-rm: refused=shared-root|MODE=test python3 -c '\''s = "rm -rf $HOME"'\''
file then source|command|2|block-unsafe-rm: refused=shared-root|cat > cleanup.sh <<'\''EOF'\''\nrm -rf "$HOME"\nEOF\nsource cleanup.sh
inline exec inherits stdin|command|2|block-unsafe-rm: refused=shared-root|python3 -c '\''import os; os.execl("/bin/bash", "bash", "-s")'\'' <<'\''EOF'\''\nrm -rf "$HOME"\nEOF
file program inherits stdin|command|2|block-unsafe-rm: refused=shared-root|python3 helper.py <<'\''EOF'\''\nrm -rf "$HOME"\nEOF
nested parameter inline boundary|command|2|block-unsafe-rm: refused=shared-root|python3 -c "${code:-"#a'\''b"}"; rm -rf "$HOME"; echo \134\047; :
parameter fabricated heredoc|command|2|block-unsafe-rm: refused=shared-root|echo ${X:-a;cat <<'\''EOF'\''}\nrm -rf $HOME\nEOF}
quoted parameter fabricated heredoc|command|2|block-unsafe-rm: refused=shared-root|echo "${X:-"x;cat <<'\''EOF'\''"}"\nrm -rf $HOME\nEOF}
'
}
data_body_rows
executable_body_rows
skill_load_control body-raw-scan "$HOOK" 'command_regions() {' \
  '  return 0' HOOK data_body_rows \
  'python replacement heredoc' 'file writing heredoc' 'python replacement inline'
skill_load_control body-always-refuse "$HOOK" 'set -euo pipefail' \
  'exit 2' HOOK data_body_rows \
  'python replacement heredoc' 'file writing heredoc' 'python replacement inline' \
  'literal backticks in program' 'literal backticks in heredoc' \
  'guarded shared root as data'
skill_load_control body-always-allow "$HOOK" 'set -euo pipefail' \
  'exit 0' HOOK executable_body_rows \
  'real removal' 'shell inline' 'eval inline' 'source inline' 'shell heredoc' \
  'expanding data heredoc' 'after data heredoc' 'unknown receiver heredoc' \
  'combined redirect receiver' 'combined append receiver' \
  'backtick eval receiver' 'backtick shell receiver' \
  'subshell input receiver' 'brace group input receiver' 'data before unproved receiver' \
  'python dollar quote boundary' 'node dollar quote boundary' \
  'ruby dollar quote boundary' 'perl dollar quote boundary' \
  'quoted keyword receiver' 'quoted assignment receiver' \
  'option argument owns program flag' 'option terminator owns program flag' \
  'double quoted program' 'multiple data bodies' 'escaped backticks in program' \
  'assignment before data receiver' 'file then source' 'inline exec inherits stdin' \
  'file program inherits stdin' 'nested parameter inline boundary' \
  'parameter fabricated heredoc' 'quoted parameter fabricated heredoc'

# Bash tools also run real interpreter programs. Exercise both producers at
# the one classifier, then execute the refused program with a recording rm.
# The recorder is always first on PATH, even if an assertion fails, so these
# regressions cannot remove anything. Every row must reach that recorder.
mkdir -p "$TMP_ROOT/record-bin"
cat >"$TMP_ROOT/record-bin/rm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"${RM_RECORD:?}"
SH
chmod +x "$TMP_ROOT/record-bin/rm"
interpreter_body_rows() {
  local name reason program form command record="$TMP_ROOT/record-rm" execution
  command -v python3 >/dev/null || { echo 'interpreter-rows: missing=python3' >&2; return 1; }
  while IFS='|' read -r name reason program; do
    [ -n "$name" ] || continue
    for form in inline heredoc; do
      case "$form" in
        inline) command="python3 -c '$program'" ;;
        heredoc) command="python3 - <<'PY'"$'\n'"$program"$'\nPY' ;;
      esac
      run_hook "$command"
      assert_eq "rc=$rc first=$(first_line)" \
        "rc=2 first=block-unsafe-rm: refused=$reason" "$name $form refuses"
      : >"$record"
      execution=0
      env PATH="$TMP_ROOT/record-bin:$PATH" HOME="$TMP_ROOT/record-home" \
        RM_RECORD="$record" "$BASH_BIN" -c "$command" \
        </dev/null >"$TMP_ROOT/record-stdout" 2>"$TMP_ROOT/record-stderr" || execution=$?
      assert_eq "$execution" 0 "$name $form executes with recording rm"
      assert_eq "$(cat "$record")" $'-rf\n'"$TMP_ROOT/record-home" \
        "$name $form reaches recording rm"
    done
  done <<'ROWS'
os system|recursive-rm|import os; os.system("rm -rf $HOME")
subprocess run|recursive-rm|import subprocess; subprocess.run("rm -rf $HOME", shell=True, check=True)
os popen|recursive-rm|import os; os.popen("rm -rf $HOME").read()
os exec|recursive-rm|import os; os.execv("/bin/sh", ["sh", "-c", "rm -rf $HOME"])
os spawn|recursive-rm|import os; os.spawnvp(os.P_WAIT, "sh", ["sh", "-c", "rm -rf $HOME"])
pty spawn|recursive-rm|import pty; pty.spawn(["sh", "-c", "rm -rf $HOME"])
process alias|recursive-rm|from os import system as start; start("rm -rf $HOME")
arbitrary callable|shared-root|s = "rm -rf $HOME"; launch = __import__("os").system; launch(s)
dynamic eval|shared-root|s = "rm -rf $HOME"; eval("__import__(\"os\").system(s)")
dynamic exec|shared-root|s = "rm -rf $HOME"; exec("import os; os.system(s)")
dynamic import|shared-root|s = "rm -rf $HOME"; __import__("os").system(s)
dynamic getattr|shared-root|import os; s = "rm -rf $HOME"; getattr(os, "system")(s)
dynamic compile|shared-root|s = "rm -rf $HOME"; exec(compile("import os; os.system(s)", "inline", "exec"))
unproved string type|recursive-rm|from os import system as s; s("rm -rf $HOME")
unproved method|shared-root|s = "rm -rf $HOME"; s.format(__import__("os").system(s))
interpolated string|shared-root|import os; s = "rm -rf $HOME"; f"{os.system(s)}"
unproved expression|shared-root|s = "rm -rf $HOME"; (lambda: __import__("os").system(s))()
ROWS
}
interpreter_body_rows
skill_load_control interpreter-unproved "$HOOK" 'python_data_program() {' \
  '  return 0' HOOK interpreter_body_rows \
  'os system inline refuses' 'os system heredoc refuses' \
  'arbitrary callable inline refuses' 'dynamic eval inline refuses' \
  'dynamic exec heredoc refuses' 'dynamic import inline refuses' \
  'dynamic getattr heredoc refuses' 'dynamic compile inline refuses' \
  'unproved string type inline refuses' 'unproved method heredoc refuses' \
  'interpolated string inline refuses' 'unproved expression heredoc refuses'

# Unsupported interpreters keep the raw judge even for harmless programs.
# Executable representatives also prove the unchanged shell/refusal boundary;
# unavailable optional runtimes still have their payload refusal asserted.
other_interpreter_rows() {
  local name reason runtime command record="$TMP_ROOT/record-other" execution
  while IFS='|' read -r name reason runtime command; do
    [ -n "$name" ] || continue
    run_hook "$command"
    assert_eq "rc=$rc first=$(first_line)" \
      "rc=2 first=block-unsafe-rm: refused=$reason" "$name refuses"
    if ! command -v "$runtime" >/dev/null; then
      printf '  unavailable recording runtime: %s\n' "$runtime"
      continue
    fi
    : >"$record"
    execution=0
    env PATH="$TMP_ROOT/record-bin:$PATH" HOME="$TMP_ROOT/record-home" \
      RM_RECORD="$record" "$BASH_BIN" -c "$command" \
      </dev/null >"$TMP_ROOT/record-stdout" 2>"$TMP_ROOT/record-stderr" || execution=$?
    assert_eq "$execution" 0 "$name executes with recording rm"
    assert_eq "$(cat "$record")" $'-rf\n'"$TMP_ROOT/record-home" "$name reaches recording rm"
  done <<'ROWS'
shell shared removal|shared-root|bash|rm -rf $HOME
node process|recursive-rm|node|node -e 'require("child_process").execSync("rm -rf $HOME")'
perl process|recursive-rm|perl|perl -e '$HOME=$ENV{HOME}; system("rm -rf $HOME")'
ruby process|recursive-rm|ruby|ruby -e 'system("rm -rf $HOME")'
ROWS
}
other_interpreter_rows
skill_load_control other-interpreter-allow "$HOOK" 'set -euo pipefail' \
  'exit 0' HOOK other_interpreter_rows \
  'shell shared removal refuses' 'node process refuses' 'perl process refuses' 'ruby process refuses'

# Agents use git rm to remove tracked paths. These tool payloads are scanned,
# never run; a following plain rm must retain its own refusal.
git_rm_rows() {
  first_table 'git cached variable|command|0|-|git rm --cached "$f"
git directory variable|command|0|-|git -C repo rm -r "$d"
git shared variable|command|0|-|git rm -r "$TMPDIR"/*
git shared literal|command|0|-|git --no-pager -c core.quotePath=false rm /shared/home/*
git nested variable|command|2|block-unsafe-rm: refused=recursive-rm|git -C "$(rm -rf "$X")" rm tracked
git nested shared variable|command|2|block-unsafe-rm: refused=shared-root|git -C "$(rm -rf "$TMPDIR"/*; pwd)" rm tracked
git nested shared literal|command|2|block-unsafe-rm: refused=shared-root|git -C "$(rm -rf /shared/home/*; pwd)" rm tracked
git config nested variable|command|2|block-unsafe-rm: refused=recursive-rm|git -c "name=$(rm -rf "$X")" rm tracked
git directory nested read|command|0|-|git -C "$(pwd)" rm --cached "$f"
plain variable pair|command|2|block-unsafe-rm: refused=recursive-rm|rm -rf "$X"
sudo variable pair|command|2|block-unsafe-rm: refused=recursive-rm|sudo rm -rf $X
shared variable pair|command|2|block-unsafe-rm: refused=shared-root|rm -rf "$TMPDIR"/*
git then plain variable|command|2|block-unsafe-rm: refused=recursive-rm|git rm --cached "$f"; rm -rf "$X"
git then shared variable|command|2|block-unsafe-rm: refused=shared-root|git -C repo rm -r "$d" && rm -rf "$TMPDIR"/*
plain then git|command|2|block-unsafe-rm: refused=recursive-rm|rm -rf "$X"; git rm --cached "$f"
git newline plain|command|2|block-unsafe-rm: refused=recursive-rm|git rm --cached "$f"\nrm -rf "$X"
git verb separator plain|command|2|block-unsafe-rm: refused=recursive-rm|git rm; rm -rf "$X"
git repeated then plain|command|2|block-unsafe-rm: refused=recursive-rm|git rm --cached "$f"; git -C repo rm -r "$d"; rm -rf "$X"
git repeated then shared literal|command|2|block-unsafe-rm: refused=shared-root|git rm --cached "$f"; git -C repo rm -r "$d"; rm -rf /shared/home/*
'
}
git_rm_rows
skill_load_control git-rm-prefix "$HOOK" 'while [[ $COMMAND =~ $GIT_RM ]]; do' \
  '  break' HOOK git_rm_rows 'git cached variable' 'git directory variable' \
  'git shared variable' 'git shared literal'
skill_load_control git-rm-erased-options "$HOOK" '  COMMAND=${COMMAND/"${BASH_REMATCH[0]}"/"${git_prefix}__${git_suffix}"}' \
  '  COMMAND=${COMMAND/"${git_prefix}__${git_suffix}"/ }' HOOK git_rm_rows \
  'git nested variable' 'git nested shared variable' 'git nested shared literal' \
  'git config nested variable'

# Agents redirect cleanup output and copy descriptors in Bash tool calls.
# Each operator crosses its whole target before the scan resumes at operands.
redirection_rows() {
  local name operator crossed target tail gap spacing
  while read -r name operator crossed target tail; do
    for spacing in adjacent spaced; do
      gap=''; [ "$spacing" != spaced ] || gap=' '
      first_table "\
redirection $name $spacing variable|command|2|block-unsafe-rm: refused=shared-root|rm -rf /safe ${operator}${gap}${crossed} \"\${TMPDIR:?}\"${tail}
redirection $name $spacing literal|command|2|block-unsafe-rm: refused=shared-root|rm -rf /safe ${operator}${gap}${crossed} /shared/home/*${tail}
redirection $name $spacing empty variable|command|2|block-unsafe-rm: refused=recursive-rm|rm -rf /safe ${operator}${gap}${crossed} \$CACHE/file${tail}
redirection $name $spacing named child|command|0|-|rm -rf /safe ${operator}${gap}${crossed} \"\${TMPDIR:?}/tmp.AbC123\"${tail}
redirection $name $spacing safe target|command|0|-|rm -rf /safe ${operator}${gap}${target}${tail}
"
    done
  done <<'FORMS'
output > /dev/null /shared/home
numbered-output 2> /dev/null /shared/home
append >> /dev/null /shared/home
numbered-append 2>> /dev/null /shared/home
input < /dev/null /shared/home
read-write <> /dev/null /shared/home
clobber >| /dev/null /shared/home
combined-output &> /dev/null /shared/home
combined-append \046>> /dev/null /shared/home
copy-output >& 1 $FD
numbered-copy-output 2>& 1 $FD
copy-input <& 0 $FD
move-output 2>& 1- 1-
close-output 2>& - -
here-string <<< ignored "$HOME"
here-document << EOF EOF \nEOF
tab-here-document <<- EOF EOF \nEOF
named-descriptor \173log\175> /dev/null /shared/home
FORMS
  first_table 'redirection touching operand|command|2|block-unsafe-rm: refused=shared-root|rm -rf /safe>/dev/null "${TMPDIR:?}"
multiple redirections|command|2|block-unsafe-rm: refused=shared-root|rm -rf /safe > /dev/null 2>&1 /shared/home/*
quoted target with space|command|0|-|rm -rf /safe > "/log $HOME"
single quoted target with space|command|0|-|rm -rf /safe > '\''/log $HOME'\''
escaped space in target|command|0|-|rm -rf /safe > /log\\ $HOME
quoted target then protected operand|command|2|block-unsafe-rm: refused=shared-root|rm -rf /safe > "/log $HOME" "${TMPDIR:?}"
redirection semicolon boundary|command|0|-|rm -rf /safe 2>/dev/null; echo $HOME
redirection and boundary|command|0|-|rm -rf /safe 2>/dev/null && echo $HOME
redirection or boundary|command|0|-|rm -rf /safe 2>/dev/null || echo $HOME
redirection pipe boundary|command|0|-|rm -rf /safe 2>/dev/null | echo $HOME
redirection newline boundary|command|0|-|rm -rf /safe 2>/dev/null\necho $HOME
redirection later command refused|command|2|block-unsafe-rm: refused=shared-root|rm -rf /safe 2>/dev/null; rm -rf "${TMPDIR:?}"
'
}
redirection_rows
skill_load_control redirection-crossing "$HOOK" 'SKIP="(${GAP}+${WORD}|${GAP}*${REDIRECT}${GAP}*${WORD})*"' \
  'SKIP="(${GAP}+${WORD})*"' HOOK redirection_rows \
  'redirection numbered-output adjacent variable' 'redirection numbered-output adjacent literal'
skill_load_control redirection-target "$HOOK" 'SKIP="(${GAP}+${WORD}|${GAP}*${REDIRECT}${GAP}*${WORD})*"' \
  'SKIP="(${GAP}+${WORD}|${GAP}*${REDIRECT})*"' HOOK redirection_rows \
  'redirection output spaced safe target'
skill_load_control redirection-boundary "$HOOK" "ENDERS='&;|'" \
  "ENDERS='' #" HOOK redirection_rows 'redirection semicolon boundary' \
  'redirection and boundary' 'redirection or boundary' 'redirection pipe boundary'
skill_load_control redirection-newline "$HOOK" 'GAP="[${BLANK}]"' \
  'GAP="[${SPACE_ANY}]"' HOOK redirection_rows \
  'redirection newline boundary'
first_table 'unset and empty roots match no literal|payload|0|-|{"command":"rm -rf /home/method/dev/.scratch/agents /shared/tmp /shared/te(mp).+ /shared/agent /shared/home"}'
PAYLOAD_HOME=/
first_table 'filesystem root direct glob|payload|2|block-unsafe-rm: refused=shared-root|{"command":"rm -rf /tmp.*"}
filesystem root named child|payload|0|-|{"command":"rm -rf /tmp.AbC123"}'
unset PAYLOAD_HOME
run_hook 'rm -rf -- "${TMPDIR:?}"'
assert_contains "$ERR_FILE" 'd=$(mktemp -d)' 'shared-root remedy keeps the private directory'
assert_contains "$ERR_FILE" '"${d:?}" in the same shell call' 'shared-root remedy keeps cleanup in the creating call'
if grep -Fq -- '${NAME:?}' "$ERR_FILE"; then advice=unsafe; else advice=private; fi
assert_eq "$advice" private 'shared-root remedy does not suggest guarding the shared name'

echo "=== block-unsafe-rm: a variable-rooted operand is refused ==="
run_hook 'rm -rf $CACHE/$KEY';        assert_eq "$rc" 2 'a bare $NAME root is refused'
run_hook 'rm -r ${DIR}';              assert_eq "$rc" 2 'the braced form is refused'
run_hook 'rm -rf "$P/save"';          assert_eq "$rc" 2 'quotes do not stop an empty expansion'
run_hook 'rm -rf ""$X/sub';           assert_eq "$rc" 2 'an empty double-quote pair does not hide the root'
run_hook 'rm -rf "${P:-}/save"';      assert_eq "$rc" 2 '${P:-} can still expand empty and is refused'
run_hook 'rm -rf "${X+x:?}/save"';    assert_eq "$rc" 2 'an unset-guarded alternative whose text contains :? is refused'
run_hook 'rm -rf -- $X';              assert_eq "$rc" 2 'the -- separator does not make a variable root safe'
run_hook 'rm -rf $LOGS/*.log';        assert_eq "$rc" 2 'a glob in the operand does not disturb classification'
run_hook 'rm -rf $X > /var/tmp/log';  assert_eq "$rc" 2 'a redirection after the operand does not hide it'
# One rm invocation is wider than its first operand in both directions, and
# GNU rm accepts both shapes.
run_hook 'rm -rf /literal/path "$DIR/sub"'; assert_eq "$rc" 2 'a variable root in a LATER operand is refused'
run_hook 'rm $DIR/sub -rf';           assert_eq "$rc" 2 'a variable root before flags is refused'
run_hook "$(printf 'rm %s/sub -rf\necho done' '$DIR')"; assert_eq "$rc" 2 'a variable root is refused in a multiline command'
run_hook 'rm build -rf $X';           assert_eq "$rc" 2 'a literal operand before the flag does not hide a later variable root'

echo "=== block-unsafe-rm: the operand half of the predicate ==="
run_hook 'rm -rf -- "${P:?}/save"';   assert_eq "$rc" 0 '${P:?} cannot expand empty and passes'
run_hook 'rm -rf "${VAR1:?}/x"';      assert_eq "$rc" 0 'digits after the first identifier char pass'
run_hook "rm -rf '\$X'";              assert_eq "$rc" 0 'a single-quoted operand is a literal filename, not an expansion'
run_hook "rm -rf \$'/var/tmp/safe'";  assert_eq "$rc" 0 'an ANSI-C quoted operand is a literal, not a variable root'
run_hook 'rm -rf /var/tmp/x';         assert_eq "$rc" 0 'a literal absolute path passes'
run_hook 'rm -rf ./build';            assert_eq "$rc" 0 'a literal relative path passes'
run_hook 'rm -rf /var/tmp/safe > $LOG'; assert_eq "$rc" 0 'a variable redirection target is not the first operand'

echo "=== block-unsafe-rm: flags do not make a variable root safe ==="
run_hook 'rm -fr $X';                 assert_eq "$rc" 2 'clustered flags do not make a variable root safe'
run_hook 'rm -R $X';                  assert_eq "$rc" 2 'an uppercase flag does not make a variable root safe'
run_hook 'rm --recursive --force $X'; assert_eq "$rc" 2 'long flags do not make a variable root safe'
run_hook 'rm -f $X';                  assert_eq "$rc" 2 'a non-recursive rm on a variable is refused'
run_hook 'rm $X';                     assert_eq "$rc" 2 'an rm with no flag at all is refused'
run_hook 'rm --verbose "$X/f"';       assert_eq "$rc" 2 'a long flag does not hide a variable root'
run_hook 'rm --interactive $X';       assert_eq "$rc" 2 'an interactive rm is refused before the harness prompts'
first_table 'bare non-recursive operand|command|2|block-unsafe-rm: refused=recursive-rm|rm $VAR/x
quoted non-recursive glob|command|2|block-unsafe-rm: refused=recursive-rm|rm "$VAR"/*.txt
non-recursive operand after separator|command|2|block-unsafe-rm: refused=recursive-rm|rm -- $VAR/x
guarded non-recursive operand|command|0|-|rm "${VAR:?}/x"
literal non-recursive glob|command|0|-|rm /literal/root/*.txt
'

echo "=== block-unsafe-rm: where the sequence stands, and how far it reaches ==="
# The sequence counts wherever it stands, a compound command's keyword arm
# included. A hand-written list of those keywords was tried and every revision
# of it missed more members than it named, so one row stands for the whole
# class rather than one row per keyword.
run_hook 'if rm -rf "$X/sub"; then echo done; fi'; assert_eq "$rc" 2 'a keyword-prefixed rm is refused like any other'
run_hook "$(printf 'rm\t-rf\t%s' '$X')";        assert_eq "$rc" 2 'tabs separate the words as spaces do'
# A Bash tool call is routinely several lines, and bash's =~ anchors ^ at the
# start of the WHOLE command, so nothing but the rm's left edge admitting a
# newline reaches line two at all.
run_hook "$(printf 'cd /x\nrm -rf "%s/x"' '$D')"; assert_eq "$rc" 2 'an rm on the second line is reached'
run_hook "$(printf 'cd /x\nrm -rf /var/tmp/x')"; assert_eq "$rc" 0 'and a literal path on the second line still passes'
# A newline also ENDS the command before it, and so does a `;` — the words of
# the next command are not this rm's operands. Each pair differs only in
# whether that next command is itself a variable-rooted rm.
run_hook "$(printf 'rm -rf /var/tmp/x\ncat %s' '$F')";    assert_eq "$rc" 0 'a later line is a command of its own, not an operand of this rm'
run_hook "$(printf 'rm -rf /var/tmp/x\nrm -rf %s' '$F')"; assert_eq "$rc" 2 'and a variable-rooted rm on that later line is still refused'
run_hook 'rm -rf /var/tmp/x; echo $HOME';                 assert_eq "$rc" 0 'a semicolon ends it the same way'
run_hook 'rm -rf /var/tmp/x; rm -rf $HOME';               assert_eq "$rc" 2 'and the rm after it is judged on its own operands'
run_hook 'rm -rf /var/tmp/x & cat $F';                    assert_eq "$rc" 0 'an ampersand ends it too'
run_hook 'rm -rf /var/tmp/x | cat $F';                    assert_eq "$rc" 0 'and so does a pipe'
# The rm's left edge is a word boundary and the only thing keeping the letters
# rm inside a longer word out of the match.
run_hook 'confirm -rf $X';            assert_eq "$rc" 0 'a word merely ending in rm is not the verb'
run_hook 'ls -la';                    assert_eq "$rc" 0 'an unrelated command passes'

echo "=== block-unsafe-rm: the first line of every condition ==="
first_table "\
the refused shape is the value|command|2|block-unsafe-rm: refused=recursive-rm|rm -rf \$CACHE/\$KEY
a variable root before flags reaches the same value|command|2|block-unsafe-rm: refused=recursive-rm|rm \$DIR/sub -rf
an operand that cannot collapse says nothing|command|0|-|rm -rf -- \"\${P:?}/save\"
a payload that is not JSON is refused unread|payload|0|block-unsafe-rm: payload=invalid-json|not JSON
"
run_hook 'rm -rf $CACHE/$KEY'
assert_contains "$ERR_FILE" 'rm -- "${NAME:?}/file"' 'the guarded rewrite adds no delete flags'
assert_contains "$ERR_FILE" 'rm -- /absolute/literal/path' 'the literal rewrite adds no delete flags'
assert_contains "$ERR_FILE" 'rm -rf $CACHE/$KEY' 'the refusal quotes the command it judged'

first_table 'reported-adjacent-redirection|command|2|block-unsafe-rm: refused=shared-root|rm>/dev/null -rf "$HOME"'

payload_table "$HOOK" 'rm -rf $X/sub' 'rm -rf -- "${X:?}/sub"'

run_hook 'rm "-rf" "$X/sub"';         assert_eq "$rc" 2 'a quoted flag does not hide a variable root'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
