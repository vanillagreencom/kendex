# Shared fixtures for the install-git-hooks suites: an isolated consumer
# repository with the skill installed where a consumer has it, the four
# ways these tests invoke the installer, the pass/fail tally, and the row
# table the reshaped suites run.
#
# TMP, TMPDIR and the git isolation come from lib/harness.bash, which each
# suite sources itself rather than reaching it through this file: the
# adoption test reads that line out of every suite, and a transitive source
# would turn a line it can read into a chain it has to follow.

SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
INSTALL="$SKILL_DIR/scripts/install-git-hooks"
# Outside the namespace new_repo allocates fixtures from: a fixture named for
# the template would satisfy the build guard below and be copied into the skill
# slot as a git repository, with nothing checking the shape.
GG_SKILL_TEMPLATE="$TMP/.templates/commit-guards"

unset COMMIT_GUARDS_CHECKS COMMIT_GUARDS_PRE_COMMIT_LOCAL COMMIT_GUARDS_SETTINGS_FILE \
  COMMIT_GUARDS_COMMIT_TYPES DOC_LIMITS_CLASSES DOC_LIMITS_DEFAULT_CLASSES DOC_LIMITS_EXCLUDES DOC_LIMITS_SETTINGS_FILE 2>/dev/null || true

# Marker words are assembled from split tokens so this file never contains a
# marker shape itself — the kendex repo runs todo-ban over its own tree.
TD="TO""DO"
FX="FIX""ME"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

# A consumer project carries its skills under .agents/skills, and the
# installer it runs is the one installed THERE — so the tests exercise the
# same path resolution a consumer gets, and can take the tree away again.
new_repo() { # NAME -> repo path on stdout
  local r="$TMP/$1"
  # A name used twice would link the doc-limits skill into the real skill
  # directory of the checkout under test, so a reuse is refused outright.
  [ ! -e "$r" ] || { echo "harness: fixture $1 already exists" >&2; exit 2; }
  mkdir -p "$r/.agents/skills"
  git -C "$r" -c init.defaultBranch=main init -q
  git -C "$r" config user.email test@example.com
  git -C "$r" config user.name test
  printf '[]\n' >"$r/.kendex-generated.json"
  git -C "$r" add .kendex-generated.json
  # A real directory, the shape a project install has: path resolution and
  # the shared-worktree check both key on where the copy physically is.
  #
  # The copy is cloned from a template built once per suite, with tests/ cut:
  # that subtree is more than half the skill and nothing a consumer install
  # reaches, and these suites build dozens of fixtures.
  if [ ! -d "$GG_SKILL_TEMPLATE" ]; then
    mkdir -p "$(dirname "$GG_SKILL_TEMPLATE")"
    cp -R "$SKILL_DIR" "$GG_SKILL_TEMPLATE"
    rm -rf -- "${GG_SKILL_TEMPLATE:?}/tests"
  fi
  cp -R "$GG_SKILL_TEMPLATE" "$r/.agents/skills/commit-guards"
  ln -s "$SKILL_DIR/../doc-limits" "$r/.agents/skills/doc-limits"
  printf '%s' "$r"
}

install_in() { # REPO — sets OUT and RC
  local installer="$1/.agents/skills/commit-guards/scripts/install-git-hooks"
  [ -x "$installer" ] || installer="$INSTALL"
  OUT=""
  RC=0
  OUT="$("$installer" --repo "$1" 2>&1)" || RC=$?
}

commit_in() { # REPO MSG — sets OUT and RC
  OUT=""
  RC=0
  OUT="$(git -C "$1" commit -m "$2" 2>&1)" || RC=$?
}

check_in() { # REPO — sets OUT and RC
  local installer="$1/.agents/skills/commit-guards/scripts/install-git-hooks"
  [ -x "$installer" ] || installer="$INSTALL"
  OUT=""
  RC=0
  OUT="$("$installer" --repo "$1" --check 2>&1)" || RC=$?
}

# A core.hooksPath directory wired by hand to this skill's entry points —
# the shape that really does gate and that `--check` declines to judge.
wire_hooks_dir() { # REPO DIR
  local scripts="$1/.agents/skills/commit-guards/scripts"
  mkdir -p "$2"
  printf '#!/bin/sh\nexec %s/pre-commit "$@"\n' "$scripts" >"$2/pre-commit"
  printf '#!/bin/sh\nexec %s/commit-msg "$1"\n' "$scripts" >"$2/commit-msg"
  chmod +x "$2/pre-commit" "$2/commit-msg"
}

# The table the reshaped suites share: a row builds its own repository, runs
# one action in it and reads back the exit status with every line this
# package prints, then the hooks directory as one line. Sourcing this builds
# one reference install, whose delegate lines and helper every row is
# measured against.
# Bash 5.2 reads '&' and a backslash in a substitution's replacement as
# operators; the serializer below writes backslashes into one, so the
# replacement is taken literally on every Bash, as 3.2 takes it.
shopt -u patsub_replacement 2>/dev/null || true

ROOT="$TMP"
# Every hook's permission bits are read back, and a file the installer
# creates gets the caller's mask; fixed here so the rows are the same on
# every host.
umask 022

assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}

# The repository a row built, and the checkout it commits from when that is
# not the repository itself. The installer resolves paths physically and
# the fixtures spell them as given, so both spellings of each root are
# aliased, the physical one first because the logical one can be its suffix
# (macOS keeps TMPDIR under a /var symlink to /private/var).
R=""
R_PHYS=""
W=""
ROOT_PHYS="$(cd -- "$ROOT" && pwd -P)"

aliased() { # TEXT -> the text with the row's repository and the scratch root aliased
  local s="$1"
  if [ -n "$R" ]; then
    s="${s//"$R_PHYS"/<repo>}"
    s="${s//"$R"/<repo>}"
  fi
  s="${s//"$ROOT_PHYS"/<root>}"
  printf '%s' "${s//"$ROOT"/<root>}"
}

# The lines this package puts in front of a committer: the installer's
# summary and refusals, the helper's failure, the delegate's own message,
# the chain's and the message gate's verdicts, git's own refusal to run a
# hook, and the lines the fixtures' foreign hooks and repo-local entries
# print. The lanes' own lines — the step announcements, each check's
# findings, the sibling gates' reports — are their suites' contract and are
# dropped here.
KEEP='^(commit-guards git hooks: |::warning::install-git-hooks: |::error::|kendex-guards: |commit-guards: hook helper |pre-commit: |commit-msg: OK|commit-msg FAIL|foreign: |local: |fatal: |error: )'

# One line for a run inside the row's repository: the exit status, then
# every kept line in order joined by ';'. ENVS is a comma-separated list of
# assignments. ACTION is install, check or uninstall (the installer the
# repository carries, every line kept), commit (a real `git commit -m ARG`
# from the checkout, the kept lines only) or hook (the pre-commit shim run
# from the repository root, the way git runs it, the kept lines only).
run() { # ENVS ACTION ARG
  local envs=() rc=0 out="" installer="" filtered=1 dir="" target="$R"
  [ -z "$1" ] || IFS=',' read -ra envs <<<"$1"
  # An action ending in -wt runs the installer the other checkout carries
  # (a linked worktree, or a second project in the repository), against it.
  case "$2" in *-wt) target="$W" ;; esac
  installer="$target/.agents/skills/commit-guards/scripts/install-git-hooks"
  [ -x "$installer" ] || installer="$INSTALL"
  # A commit runs from the checkout's physical path, the ordinary layout:
  # reached through a symlink, the helper drops the main-checkout root it
  # cannot vouch for and its search line changes, which is the scope
  # suite's subject, not this one's.
  dir="$(cd -- "${W:-$R}" && pwd -P)"
  case "$2" in
    install | install-wt)
      filtered=0
      out="$(env ${envs[@]+"${envs[@]}"} "$installer" --repo "$target" 2>&1)" || rc=$?
      ;;
    check | check-wt)
      # ARG carries any further installer arguments, word-split.
      filtered=0
      # shellcheck disable=SC2086
      out="$(env ${envs[@]+"${envs[@]}"} "$installer" --repo "$target" --check $3 2>&1)" || rc=$?
      ;;
    uninstall)
      filtered=0
      out="$(env ${envs[@]+"${envs[@]}"} "$installer" --repo "$R" --uninstall 2>&1)" || rc=$?
      ;;
    commit)
      out="$(env ${envs[@]+"${envs[@]}"} git -C "$dir" commit -m "$3" 2>&1)" || rc=$?
      ;;
    hook)
      out="$(cd -- "$dir" && env ${envs[@]+"${envs[@]}"} .git/hooks/pre-commit 2>&1)" || rc=$?
      ;;
    *)
      echo "harness: unknown action $2" >&2
      exit 2
      ;;
  esac
  if [ "$filtered" -eq 1 ] && [ -n "$out" ]; then
    out="$(printf '%s\n' "$out" | LC_ALL=C grep -E "$KEEP" || true)"
  fi
  out="$(aliased "$out")"
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}

# A hook file as one token: absent, dir, other, symlink-><target>[<content>],
# or <permission bits>:<content> for a regular file, the bits as ls prints
# them, since a hook git runs as somebody else needs more than the owner's.
# Content is every line joined by '~' with the two delegate lines and the
# created marker aliased and <noeol> when the last byte is not a newline; a
# helper whose every line but the baked scripts directory is the one the
# reference install wrote reads as ours[<that line's value>].
JOIN='~'
BS='\'
content() { # FILE
  local raw="" tail="" line3=""
  raw="$(cat -- "$1" 2>/dev/null && printf x)" || { printf 'unreadable'; return 0; }
  raw="${raw%x}"
  case "$raw" in
    *$'\n') raw="${raw%$'\n'}" ;;
    *) tail='<noeol>' ;;
  esac
  # The comparison runs inside a command substitution, which strips every
  # trailing newline, so a helper carrying blank lines after its program is
  # kept off this path and rendered whole instead.
  case "$raw" in
    *$'\n') ;;
    *)
      if [ "$(printf '%s\n' "$raw" | sed 3d)" = "$REF_HELPER" ]; then
        line3="$(printf '%s\n' "$raw" | sed -n 3p)"
        printf 'ours[%s]%s' "$(aliased "${line3#installed_scripts=}")" "$tail"
        return 0
      fi
      ;;
  esac
  raw="${raw//"$PRE_LINE"/@PRE@}"
  raw="${raw//"$MSG_LINE"/@MSG@}"
  raw="${raw//"$CREATED"/@CREATED@}"
  # Injective: a backslash and the join character in the file are escaped
  # before newlines become the join character, so a line holding one cannot
  # read as a line boundary. The replacements are unquoted: Bash 3.2 keeps
  # the quotes of a quoted one as literal bytes, and a literal '~' there is
  # the caller's home.
  raw="${raw//"$BS"/$BS$BS}"
  raw="${raw//"$JOIN"/$BS$JOIN}"
  printf '%s%s' "$(aliased "${raw//$'\n'/$JOIN}")" "$tail"
}

shape() { # PATH
  local p="$1" mode=""
  if [ -L "$p" ]; then
    printf 'symlink->%s' "$(aliased "$(readlink "$p")")"
    if [ -f "$p" ]; then printf '[%s]' "$(content "$p")"; else printf '[dangling]'; fi
    return 0
  fi
  [ -e "$p" ] || { printf 'absent'; return 0; }
  [ -d "$p" ] && { printf 'dir'; return 0; }
  [ -f "$p" ] || { printf 'other'; return 0; }
  mode="$(ls -ld -- "$p")"
  printf '%s:%s' "${mode:1:9}" "$(content "$p")"
}

# The hooks directory as one line: the helper, the two shims, every other
# entry git did not put there (a consumer's hook, or a temporary file an
# install left behind), and core.hooksPath.
state() {
  local f="" name="" hp="" hooks="$R/.git/hooks"
  [ -d "$R/.git" ] || hooks="$R/hooks"
  printf 'helper=%s pre-commit=%s commit-msg=%s' \
    "$(shape "$hooks/kendex-guards")" "$(shape "$hooks/pre-commit")" "$(shape "$hooks/commit-msg")"
  for f in "$hooks"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    name="${f##*/}"
    case "$name" in *.sample | kendex-guards | pre-commit | commit-msg) continue ;; esac
    printf ' +%s=%s' "$name" "$(shape "$f")"
  done
  if hp="$(git -C "$R" config --get core.hooksPath 2>/dev/null && printf x)"; then
    hp="${hp%x}"
    printf " hooksPath='%s'" "$(aliased "${hp%$'\n'}")"
  else
    printf ' hooksPath=<unset>'
  fi
}

# Fixture vocabulary. Every fixture builds its own repository; a seed commit
# that fails is recorded and asserted once at the end, because a row over an
# unseeded repository can pass for the wrong reason.
SEEDS_FAILED=""
armed() { R="$(new_repo "$1")"; "$R/.agents/skills/commit-guards/scripts/install-git-hooks" --repo "$R" >/dev/null 2>&1 || true; }
stage() { printf '%b' "$2" >"$R/$1"; git -C "$R" add -- "$1"; }
stage_marker() { stage b.py "# $TD: finish this\n"; }
seed() { git -C "$R" commit -q -m "feat: seed" >/dev/null 2>&1 || SEEDS_FAILED="$SEEDS_FAILED ${R##*/}"; }
foreign() { printf '%b' "$2" >"$R/.git/hooks/$1"; chmod +x "$R/.git/hooks/$1"; }
settings() { stage kendex.settings.toml "[env]\n$1\n"; }
# A fixture's edit to a hook is asserted to have changed the file: a sed
# whose pattern matches nothing leaves the fresh install in place, and every
# row over it then passes on the unedited guard.
edit() { # FILE SED-EXPRESSION
  local before="" after=""
  before="$(cat -- "$1")"
  sed -i.bak "$2" "$1"
  rm -f -- "$1.bak"
  after="$(cat -- "$1")"
  [ "$before" != "$after" ] || bad "fixture: ${R##*/}: the edit to ${1##*/} took" "sed matched nothing"
}
local_entry() { mkdir -p "$R/tools"; stage tools/local-check "$1"; chmod +x "$R/tools/local-check"; settings 'COMMIT_GUARDS_PRE_COMMIT_LOCAL = "tools/local-check"'; }

# The reference install: the delegate lines the shims carry, pinned once as
# the grammar every armed repository is measured against, and the helper
# every fixture's helper is compared to.
armed reference
R_PHYS="$(cd -- "$R" && pwd -P)"
PRE_LINE="$(sed -n 2p "$R/.git/hooks/pre-commit")"
MSG_LINE="$(sed -n 2p "$R/.git/hooks/commit-msg")"
CREATED="# kendex-guards-hook created this file"
REF_HELPER="$(sed 3d "$R/.git/hooks/kendex-guards")"

ARMED="commit-guards git hooks: pre-commit and commit-msg armed in <repo>/.git/hooks"
INCOMPLETE="commit-guards git hooks: incomplete — see the warnings above (<repo>/.git/hooks)"
REMOVAL_INCOMPLETE="commit-guards git hooks: removal incomplete — see the warnings above (<repo>/.git/hooks)"
NOT_INSTALLED="commit-guards git hooks: NOT installed — could not write <repo>/.git/hooks/kendex-guards"
REMOVED_BOTH="commit-guards git hooks: removed from pre-commit commit-msg in <repo>/.git/hooks"
NOTHING="commit-guards git hooks: nothing to remove in <repo>/.git/hooks"
WARN="::warning::install-git-hooks:"
X=rwxr-xr-x
RW=rw-r--r--
OURS="$X:ours['<repo>/.agents/skills/commit-guards/scripts']"
SHIM_PRE="$X:#!/bin/sh~@PRE@~@CREATED@"
SHIM_MSG="$X:#!/bin/sh~@MSG@~@CREATED@"
FRESH="helper=$OURS pre-commit=$SHIM_PRE commit-msg=$SHIM_MSG hooksPath=<unset>"
CHAIN_OK="pre-commit: OK — staged guard chain clean"
MSG_OK="commit-msg: OK — conventional header:"
BLOCKED="pre-commit: violations — commit blocked; see the failures above"
NO_HELPER="commit-guards: hook helper .git/hooks/kendex-guards is missing or not executable; commit blocked (reinstall: kendex guard install)"
NO_SCRIPT="kendex-guards: no executable commit-guards pre-commit script at <repo>/.agents/skills/commit-guards/scripts, nor under <repo> or <repo> (project '', roots .agents/skills .claude/skills .cursor/skills .gemini/skills .github/skills .opencode/skills skills)"
# The plumbing rows run one check: the batch's composition is not their
# subject and every check has its own suite.
ONE="COMMIT_GUARDS_CHECKS=todo-ban"


# A fixture that takes something away from the scratch root (a directory's
# permissions) sets UNDO to the command that gives it back, run once the
# row has been read.
UNDO=""
run_rows() { # label | fixture | env | action | arg | expect | state
  local row label fx env action arg expect want_state
  for row in "$@"; do
    IFS='|' read -r label fx env action arg expect want_state <<<"$row"
    R=""
    W=""
    UNDO=""
    "$fx"
    R_PHYS="$(cd -- "$R" && pwd -P)"
    assert_eq "$label" "$expect" "$(run "$env" "$action" "$arg")"
    [ -z "$want_state" ] || assert_eq "$label: the hooks directory" "$want_state" "$(state)"
    [ -z "$UNDO" ] || eval "$UNDO"
  done
}
