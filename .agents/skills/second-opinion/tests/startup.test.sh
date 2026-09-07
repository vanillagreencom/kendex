#!/usr/bin/env bash
# The script's startup, before any mode runs: the repository lookup from its
# own location (an install outside a repository degrades to the caller's
# environment; any other lookup failure refuses and quotes git), and the
# project settings load (a refused file ends the run naming the defect; a
# session-only key declared by a project file is refused, unless the caller
# exported it).
#
# A row is `label|world|argv|rc|out|err`. The world: where the skill's copy
# lives (`install:outside`, `install:repo`, `install:worktree-broken`), what
# PATH holds (`path:nogit`, `path:mountgit`), the project files
# (`settings:header`, `settings:cap`, `envlocal:cap`), and `env:NAME=value`
# for the caller's own environment. The argv is `probe` (an unparseable
# argument: reaching the option parser proves the lookup did not end the run)
# or `detect`. Every line of stderr is pinned, the install path aliased.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which would point every
# git call at the real repository instead of the row's; the harness markers
# would decide what a detect answers.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset CLAUDECODE CLAUDE_CODE CLAUDE_PROJECT_DIR CODEX_SANDBOX \
      CODEX_SANDBOX_NETWORK_DISABLED PI_CODING_AGENT_DIR OPENCODE \
      CURSOR_AGENT CURSOR_TRACE_ID
unset SECOND_OPINION_CURRENT_MODEL SECOND_OPINION_FOREGROUND_CAP
# TMPDIR can sit inside a checkout on a developer box; the ceiling stops the
# upward search so "outside a repository" is what an install outside one is.
export GIT_CEILING_DIRECTORIES="$TMP_ROOT"

PASS=0
FAIL=0
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

# A timeout behind any real one: a host without GNU timeout (a stock Mac)
# would add the runtime's warning to every row that reaches the parser.
mkdir -p "$TMP_ROOT/shim"
printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' >"$TMP_ROOT/shim/timeout"
chmod +x "$TMP_ROOT/shim/timeout"
export PATH="$PATH:$TMP_ROOT/shim"

# A PATH with the shell's own tools and no git, and one whose git answers
# with a mount-point boundary (a second mount is not portable, so the tool
# the script calls delivers the diagnostic).
mkdir -p "$TMP_ROOT/nogit" "$TMP_ROOT/mountgit"
for tool in bash env sed grep dirname cat mktemp timeout gtimeout; do
  resolved="$(command -v "$tool" 2>/dev/null)" || continue
  ln -sf "$resolved" "$TMP_ROOT/nogit/$tool"
  ln -sf "$resolved" "$TMP_ROOT/mountgit/$tool"
done
cat >"$TMP_ROOT/mountgit/git" <<'GITSH'
#!/usr/bin/env bash
printf 'fatal: not a git repository (or any parent up to mount point /mnt)\n' >&2
printf 'Stopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n' >&2
exit 128
GITSH
chmod +x "$TMP_ROOT/mountgit/git"

ROW="" INSTALL="" PROJ="" W_PATH="" W_ENV=()
word() {
  case "$1" in
    # no repository above the copy
    install:outside) INSTALL="$ROW/install"; PROJ="" ;;
    # the copy inside a repository of its own
    install:repo) INSTALL="$ROW/proj"; PROJ="$ROW/proj"; git init -q "$PROJ" ;;
    # a linked worktree whose marker points at a pruned main checkout: git
    # says "not a git repository" for a checkout that does carry settings
    install:worktree-broken)
      git init -q "$ROW/wtmain"
      git -C "$ROW/wtmain" config user.email test@example.com
      git -C "$ROW/wtmain" config user.name test
      printf 'x\n' >"$ROW/wtmain/f"
      git -C "$ROW/wtmain" add f
      git -C "$ROW/wtmain" -c commit.gpgsign=false commit -qm init
      git -C "$ROW/wtmain" worktree add -q -b wt "$ROW/wtlinked"
      rm -rf -- "${ROW:?}/wtmain/.git/worktrees"
      INSTALL="$ROW/wtlinked"; PROJ=""
      ;;
    path:nogit) W_PATH="$TMP_ROOT/nogit" ;;
    path:mountgit) W_PATH="$TMP_ROOT/mountgit" ;;
    # a settings file the loader refuses; one declaring the session-only key
    settings:*|envlocal:*) [[ -n "$PROJ" ]] || { echo "a settings word needs install:repo first" >&2; exit 2; }; word_settings "$1" ;;
    env:*) W_ENV+=("${1#env:}") ;;
    *) echo "UNKNOWN-WORD: $1" >&2; exit 2 ;;
  esac
}
word_settings() {
  case "$1" in
    settings:header) printf '[env] # comment\nSECOND_OPINION_CURRENT_MODEL = "codex"\n' >"$PROJ/kendex.settings.toml" ;;
    settings:cap) printf '[env]\nSECOND_OPINION_FOREGROUND_CAP = "1"\n' >"$PROJ/kendex.settings.toml" ;;
    envlocal:cap) printf 'export SAFE=1 SECOND_OPINION_FOREGROUND_CAP=1\n' >"$PROJ/.env.local" ;;
    *) echo "UNKNOWN-WORD: $1" >&2; exit 2 ;;
  esac
}

build() {
  local w
  ROW="$TMP_ROOT/$1"
  shift
  mkdir -p "$ROW"
  INSTALL="" PROJ="" W_PATH=""
  W_ENV=()
  for w in "$@"; do word "$w"; done
  [[ -n "$INSTALL" ]] || { echo "a row names no install" >&2; exit 2; }
  mkdir -p "$INSTALL/skills"
  cp -R "$SKILL_DIR" "$INSTALL/skills/second-opinion"
}

alias_text() {
  sed -e "s|$INSTALL/skills/second-opinion/scripts/second-opinion|<script>|g" -e "s|$INSTALL/skills/second-opinion/scripts|<scripts>|g" \
    -e "s|$INSTALL|<install>|g" -e "s|$TMP_ROOT|<root>|g" -e 's/<script>: line [0-9]*:/<script>: line *:/' \
    -e 's|git said: not a git repository: .*|git said: not a git repository: <gitdir>|' -e 's/;/\\;/g' | paste -s -d ';' -
}

run() {
  local rc=0 script="$INSTALL/skills/second-opinion/scripts/second-opinion" out err
  local -a argv env_args
  case "$1" in
    probe) argv=(--mode no-such-mode) ;;
    detect) argv=(detect) ;;
    *) echo "UNKNOWN-ARGV: $1" >&2; exit 2 ;;
  esac
  env_args=(LC_ALL=C)
  [[ -z "$W_PATH" ]] || env_args+=(PATH="$W_PATH")
  (env "${env_args[@]}" ${W_ENV[@]+"${W_ENV[@]}"} "$script" "${argv[@]}" >"$ROW/stdout" 2>"$ROW/stderr") || rc=$?
  out="$(alias_text <"$ROW/stdout")"
  err="$(alias_text <"$ROW/stderr")"
  printf 'rc=%s out=%s err=%s' "$rc" "${out:--}" "${err:--}"
}

err_text() {
  local word out=""
  for word in $1; do out="$out;$(err_word "$word")"; done
  printf '%s' "${out#;}"
}
err_word() {
  case "$1" in
    -) ;;
    parser) printf 'Error: unknown argument: no-such-mode' ;;
    # the lookup's refusal, quoting git's own line
    unresolved:nogit) printf 'second-opinion: could not resolve a repository at <scripts>;  git said: <script>: line *: git: command not found' ;;
    # git spells the unreadable gitdir by version ((null), or its path)
    unresolved:marker) printf 'second-opinion: could not resolve a repository at <scripts>;  git said: not a git repository: <gitdir>' ;;
    settings-header) printf '::error::<install>/kendex.settings.toml:1: unsupported table header shape (a header is a lone [name] on its own line, with no comment and no second bracket);second-opinion: refusing to run on a rejected settings load' ;;
    session-only) printf 'Error: project settings set session-only SECOND_OPINION_FOREGROUND_CAP\\; remove it there and pass --foreground or export it in this session' ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$1" ;;
  esac
}

run_table() {
  local title="$1" rows="$2" n=0 label world argv rc out err got row field
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    IFS='|' read -r label world argv rc out err <<<"$row"
    for field in "$label" "$world" "$argv" "$rc" "$out" "$err"; do
      [[ -n "$field" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    n=$((n + 1))
    # shellcheck disable=SC2086
    build "row-$n" $world
    got="$(run "$argv")"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [[ "${SECOND_OPINION_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    assert_eq "$got" "rc=$rc out=$out err=$(err_text "$err")" "$label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt 0 ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
}

run_table "the startup" "\
an install outside a repository has nothing to load and runs on to the parser|install:outside|probe|1|-|parser
no git on PATH: the lookup refuses above the parser, quoting git, nothing on stdout|install:outside path:nogit|probe|1|-|unresolved:nogit
a linked worktree whose marker points at a pruned checkout refuses the same way|install:worktree-broken|probe|1|-|unresolved:marker
a lookup stopped at a mount point is the absence of a repository: runs on to the parser|install:outside path:mountgit|probe|1|-|parser
a settings file the loader refuses ends the run naming the defect, not as an undeclared session|install:repo settings:header|detect|1|-|settings-header
a project settings file declaring the session-only foreground cap is refused|install:repo settings:cap|detect|1|-|session-only
an .env.local declaring it is refused the same way|install:repo envlocal:cap|detect|1|-|session-only
the caller's own export of the key outranks the project's: the run goes on to the parser|install:repo settings:cap env:SECOND_OPINION_FOREGROUND_CAP=1|probe|1|-|parser
"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
