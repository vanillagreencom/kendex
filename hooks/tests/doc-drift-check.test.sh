#!/usr/bin/env bash
# doc-drift-check: an advisory Stop hook. Every changed non-markdown path is
# matched against the nearest tracked non-root AGENTS.md above it and every
# topic file whose Covers entry reaches it; a covering doc left unchanged is
# named once on stdout as a lone {systemMessage} object, the notice Claude
# Code shows. The changed set is read against the branch's merge-base with
# the default branch, or the working tree alone where no base applies. The
# hook always exits 0; a failed discovery command says so on stderr instead
# of judging what it could not read.
#
# A row is `label|<columns>`; each table names its columns in order:
#   world    the row's repository, built fresh by `build` from these words:
#            `repo` (on main, no remote), `clone` (of a fresh repository, on
#            feat, origin/HEAD -> origin/main) or `norepo` (a bare directory)
#            first; then the sealed additions and branch moves `build` lists;
#            `subdir` runs the hook from ui/; `break:<cmd>` puts a git whose
#            <cmd> dies (or a dying sed) first on PATH
#   change   the row's edits in order, from the words `change` lists;
#            `stage` and `commit` take everything; `stopped` runs one Stop
#            first; `-` for none
#   payload  the Stop payload: `stop`, `active` (stop_hook_active true) or
#            `raw` (not JSON); tables without the column feed `stop`
#   rc       the exit status
#   out      stdout reduced: `-` when empty; otherwise the notice's docs, each
#            as `<doc>(<changed path>)`, sorted and joined by `,`; a stdout
#            that is not a lone {systemMessage} object renders as
#            `malformed:` and the text
#   judged   the notice's Compared line with the arm-shared prefixes (`every
#            change since <sha>, ` and `the working tree alone: `) removed;
#            `-` without a notice. The clause is wording, but each is emitted
#            by exactly one base-selection arm and the hook has no other
#            observable for the base it chose
#   stale    the notice's own first line, `doc-drift-check: stale=<count>`;
#            `-` without a notice
#   err      every stderr line by kind, in order, joined by `;`: the keyed
#            first line of each report (`git=<subcommand>` for a failed probe,
#            `exit=<n>` for the trap's) with the hook's name removed, a
#            `fixture:` line (the broken command's own stderr, passed through)
#            verbatim, and `git` once for each run of git's own words, which
#            are not pinned; `-` when empty. The English under a keyed line is
#            not read
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would configure the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "$TEST_DIR/.." && pwd)/doc-drift-check.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
PASS=0
FAIL=0
ROW=0

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$label" "$want" "$got"
  fi
}

# Fixture git runs under the throwaway HOME so the caller's own git
# configuration cannot decide what a fixture repository does.
fgit() {
  env HOME="$TMP_ROOT" git "$@"
}

# A repository on a branch named main with no remote: a root AGENTS.md
# (covers nothing), crates/core with its own AGENTS.md, a topic covering
# crates/core, and ui/ under no doc at all.
seed_repo() { # DIR
  mkdir -p "$1/crates/core/src" "$1/docs/architecture" "$1/ui/src"
  fgit init -q "$1"
  fgit -C "$1" symbolic-ref HEAD refs/heads/main
  fgit -C "$1" config user.email t@example.com
  fgit -C "$1" config user.name t
  printf '# root\n' >"$1/AGENTS.md"
  printf '# core\n' >"$1/crates/core/AGENTS.md"
  printf '# Core\n\nCovers: crates/core\n' >"$1/docs/architecture/core.md"
  printf 'pub fn a() {}\n' >"$1/crates/core/src/lib.rs"
  printf 'export const a = 1;\n' >"$1/ui/src/app.ts"
  fgit -C "$1" add -A
  fgit -C "$1" commit -q -m init
}

# A world addition is sealed in a commit: an untracked topic is itself a
# changed doc, and a changed doc is never named.
seal() {
  fgit -C "$REPO" add -A
  fgit -C "$REPO" commit -q -m seal
}

# A PATH directory whose git dies on subcommand $1 with `fixture: $1 failed`
# the way a broken index or unreadable refs would, or whose sed dies on
# every call.
broken() { # COMMAND
  local dir="$REPO.bin" real
  mkdir -p "$dir"
  if [[ "$1" == sed ]]; then
    printf '#!/usr/bin/env bash\necho "fixture: sed failed" >&2\nexit 19\n' >"$dir/sed"
    chmod +x "$dir/sed"
  else
    real="$(command -v git)"
    cat >"$dir/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "$1" ]; then
    echo "fixture: $1 failed" >&2
    exit 128
  fi
done
exec "$real" "\$@"
EOF
    chmod +x "$dir/git"
  fi
  printf '%s' "$dir"
}

build() { # WORLD — the row's repository, its run directory and PATH
  local word
  ROW=$((ROW + 1))
  REPO="$TMP_ROOT/row$ROW"
  RUN_DIR="$REPO"
  RUN_PATH="$PATH"
  for word in $1; do
    case "$word" in
      repo) seed_repo "$REPO" ;;
      clone)
        seed_repo "$REPO.up"
        fgit clone -q -- "$REPO.up" "$REPO"
        fgit -C "$REPO" config user.email t@example.com
        fgit -C "$REPO" config user.name t
        fgit -C "$REPO" checkout -q -b feat
        ;;
      norepo) mkdir -p "$REPO" ;;
      nodocs) fgit -C "$REPO" rm -q crates/core/AGENTS.md docs/architecture/core.md; seal ;;
      crates-agents) printf '# crates\n' >"$REPO/crates/AGENTS.md"; seal ;;
      ignore-target) printf 'target/\n' >"$REPO/.gitignore"; seal ;;
      ui-topic)
        mkdir -p "$REPO/ui/lib"
        printf '# UI\n\nCovers: ui/src/, crates/core,ui/lib\n' >"$REPO/docs/architecture/ui.md"
        seal
        ;;
      selected-topic)
        mkdir -p "$REPO/crates/eval/src"
        printf '# Selected paths\n\nCovers: ui/src/app.ts, crates/*/src/eval*.rs\n' >"$REPO/docs/architecture/selected.md"
        printf 'pub fn score() {}\n' >"$REPO/crates/eval/src/eval_score.rs"
        seal
        ;;
      file-topic) printf '# Selected path\n\nCovers: ui/src/app.ts\n' >"$REPO/docs/architecture/selected.md"; seal ;;
      root-topic) printf '# All\n\nCovers: . ./ /\n' >"$REPO/docs/architecture/all.md"; seal ;;
      with-master) fgit -C "$REPO" branch master ;;
      master) fgit -C "$REPO" branch -m main master ;;
      trunk) fgit -C "$REPO" branch -m main trunk ;;
      on-main) fgit -C "$REPO" checkout -q main ;;
      on-feat) fgit -C "$REPO" checkout -q -b feat ;;
      orphan) fgit -C "$REPO" checkout -q --orphan lone ;;
      subdir) RUN_DIR="$REPO/ui" ;;
      badconfig) printf 'this is not a config line\n' >"$REPO/.git/config" ;;
      break:*) RUN_PATH="$(broken "${word#break:}"):$PATH" ;;
      *) printf 'an unknown world word builds nothing: %s\n' "$word" >&2; exit 1 ;;
    esac
  done
}

change() { # WORDS — the row's edits, in order
  local word
  for word in $1; do
    case "$word" in
      -) ;;
      code) printf 'pub fn more() {}\n' >>"$REPO/crates/core/src/lib.rs" ;;
      agents) printf 'more\n' >>"$REPO/crates/core/AGENTS.md" ;;
      topic) printf 'more\n' >>"$REPO/docs/architecture/core.md" ;;
      md) printf 'more\n' >>"$REPO/crates/core/README.md"; printf 'note\n' >"$REPO/crates/core/NOTES.md" ;;
      new) printf 'pub fn added() {}\n' >"$REPO/crates/core/src/added.rs" ;;
      unicode) printf 'pub fn b() {}\n' >"$REPO/crates/core/src/über.rs" ;;
      ui) printf 'export const b = 2;\n' >>"$REPO/ui/src/app.ts" ;;
      other) printf 'export const other = 2;\n' >"$REPO/ui/src/app.tsx" ;;
      lib) printf 'export const c = 3;\n' >"$REPO/ui/lib/c.ts" ;;
      top) printf 'x\n' >"$REPO/top.rs" ;;
      target) mkdir -p "$REPO/crates/core/target"; printf 'fn generated() {}\n' >"$REPO/crates/core/target/generated.rs" ;;
      eval) printf 'pub fn more() {}\n' >>"$REPO/crates/eval/src/eval_score.rs" ;;
      stage) fgit -C "$REPO" add -A ;;
      commit) fgit -C "$REPO" add -A; fgit -C "$REPO" commit -q -m step ;;
      stopped) run stop ;;
      *) printf 'an unknown change word changes nothing: %s\n' "$word" >&2; exit 1 ;;
    esac
  done
}

run() { # PAYLOAD — sets RC and MESSAGE (the systemMessage, empty when stdout is not the notice object)
  local payload
  case "$1" in
    stop) payload='{"session_id":"s1","hook_event_name":"Stop","stop_hook_active":false}' ;;
    active) payload='{"session_id":"s1","hook_event_name":"Stop","stop_hook_active":true}' ;;
    raw) payload='not json' ;;
    *) printf 'an unknown payload word runs nothing: %s\n' "$1" >&2; exit 1 ;;
  esac
  RC=0
  (cd "$RUN_DIR" && env HOME="$TMP_ROOT" PATH="$RUN_PATH" bash "$HOOK" <<<"$payload" \
    >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr") || RC=$?
  MESSAGE=""
  # Slurped, so a second JSON value on stdout (which jq -e alone would read
  # through, answering for the last) leaves MESSAGE empty and the row malformed.
  if [[ -s "$TMP_ROOT/stdout" ]] && jq -es 'length == 1 and (.[0] | type == "object" and keys == ["systemMessage"] and (.systemMessage | type == "string" and length > 0))' \
    <"$TMP_ROOT/stdout" >/dev/null 2>&1; then
    MESSAGE="$(jq -rs '.[0].systemMessage' <"$TMP_ROOT/stdout")"
  fi
}

out_text() {
  local line doc path out=""
  [[ -s "$TMP_ROOT/stdout" ]] || { printf -- '-'; return; }
  [[ "$MESSAGE" != "" ]] || { printf 'malformed:%s' "$(paste -s -d ';' - <"$TMP_ROOT/stdout")"; return; }
  while IFS= read -r line; do
    case "$line" in
      "  "*" changed)")
        line="${line#  }"
        doc="${line%% (*}"
        path="${line#* (}"
        out="$out$doc(${path% changed)})"$'\n'
        ;;
    esac
  done <<<"$MESSAGE"
  printf '%s' "$out" | LC_ALL=C sort | paste -s -d ',' -
}

judged_text() {
  [[ "$MESSAGE" != "" ]] || { printf -- '-'; return; }
  printf '%s\n' "$MESSAGE" | sed -n 's/^Compared //p' |
    sed -E 's/^every change since [0-9a-f]{40}, //; s/^the working tree alone: //'
}

err_text() {
  local line out=""
  [[ -s "$TMP_ROOT/stderr" ]] || { printf -- '-'; return; }
  while IFS= read -r line; do
    case "$line" in
      "doc-drift-check: "*) out="$out;${line#doc-drift-check: }" ;;
      "notice unavailable"*) ;;
      fixture:*) out="$out;$line" ;;
      *) [[ "$out" == *";git" ]] || out="$out;git" ;;
    esac
  done <"$TMP_ROOT/stderr"
  printf '%s' "${out#;}"
}

stale_text() {
  [[ "$MESSAGE" != "" ]] || { printf -- '-'; return; }
  printf '%s' "${MESSAGE%%$'\n'*}"
}

run_table() { # TITLE COLUMNS ROWS
  local title="$1" cols="$2" rows="$3" row label col i got want before=$((PASS + FAIL))
  local -a fields
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r -a fields <<<"$row"
    label="${fields[0]:-}"
    i=1
    for col in $cols; do
      [[ "${fields[$i]:-}" != "" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
      i=$((i + 1))
    done
    [[ "$label" != "" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    WORLD="" CHANGE="-" PAYLOAD="stop" want=""
    i=1
    for col in $cols; do
      case "$col" in
        world) WORLD="${fields[$i]}" ;;
        change) CHANGE="${fields[$i]}" ;;
        payload) PAYLOAD="${fields[$i]}" ;;
        rc | out | judged | stale | err) want="$want $col=${fields[$i]}" ;;
        *) printf 'an unknown column asserts nothing: %s\n' "$col" >&2; exit 1 ;;
      esac
      i=$((i + 1))
    done
    build "$WORLD"
    change "$CHANGE"
    run "$PAYLOAD"
    got=""
    for col in $cols; do
      case "$col" in
        rc) got="$got rc=$RC" ;;
        out) got="$got out=$(out_text)" ;;
        judged) got="$got judged=$(judged_text)" ;;
        stale) got="$got stale=$(stale_text)" ;;
        err) got="$got err=$(err_text)" ;;
      esac
    done
    # A rendering aid for writing rows; the run is refused after the loop.
    if [[ "${HOOKS_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$label" "${got# }"
      continue
    fi
    assert_eq "${got# }" "${want# }" "$label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
}

CORE_DOCS='crates/core/AGENTS.md(crates/core/src/lib.rs),docs/architecture/core.md(crates/core/src/lib.rs)'

run_table "coverage: which unchanged docs a changed path names" "world change out" "\
a clean tree names nothing|repo|-|-
code under a directory no doc covers|repo nodocs|code|-
the nearest AGENTS.md and the covering topic, each with the path, never the root AGENTS.md|repo|code|$CORE_DOCS
a changed nearest AGENTS.md is not named|repo|code agents|-
a changed topic is not named|repo|code topic|-
a staged topic change counts as changed|repo|code topic stage|-
a changed nearer AGENTS.md passes despite an unchanged farther one|repo crates-agents|code agents|-
the farther AGENTS.md is never named|repo crates-agents|code|$CORE_DOCS
a markdown-only change names nothing|repo|md|-
an untracked new file is a change, named by its path|repo|new|crates/core/AGENTS.md(crates/core/src/added.rs),docs/architecture/core.md(crates/core/src/added.rs)
a staged new file is a change, named by its path|repo|new stage|crates/core/AGENTS.md(crates/core/src/added.rs),docs/architecture/core.md(crates/core/src/added.rs)
code under no doc at all names nothing|repo|ui top|-
an untracked new file from a subdirectory is named by its repository path|repo subdir|new|crates/core/AGENTS.md(crates/core/src/added.rs),docs/architecture/core.md(crates/core/src/added.rs)
an ignored path is not a change|repo ignore-target|target|-
a trailing-slash entry covers the directory|repo ui-topic|ui|docs/architecture/ui.md(ui/src/app.ts)
a comma-joined entry covers the directory|repo ui-topic|lib|docs/architecture/ui.md(ui/lib/c.ts)
a second topic naming the same directory is named beside the first|repo ui-topic|code|$CORE_DOCS,docs/architecture/ui.md(crates/core/src/lib.rs)
an exact file entry reaches its topic|repo selected-topic|ui|docs/architecture/selected.md(ui/src/app.ts)
a glob entry reaches its topic, * crossing /|repo selected-topic|eval|docs/architecture/selected.md(crates/eval/src/eval_score.rs)
a topic two paths reach is named once, with the first path|repo selected-topic|ui eval|docs/architecture/selected.md(crates/eval/src/eval_score.rs)
an exact file entry does not cover a sibling sharing its prefix|repo file-topic|other|-
root entries cover nothing|repo root-topic|ui|-
a non-ASCII path is code and keeps its bytes|repo|unicode|crates/core/AGENTS.md(crates/core/src/über.rs),docs/architecture/core.md(crates/core/src/über.rs)
"

run_table "base selection: what the branch is compared against" "world change out judged" "\
a committed change on a branch is judged against origin/HEAD|clone|code commit|$CORE_DOCS|the merge-base with origin/main
an uncommitted doc change beside the committed code passes|clone|code commit agents|-|-
a doc committed beside the code passes|clone|code agents commit|-|-
a doc committed earlier on the branch passes|clone|topic commit code commit|-|-
a commit on the default branch is not a change|clone on-main|code commit|-|-
a working-tree change on the default branch is judged alone|clone on-main|code commit code|$CORE_DOCS|main is the default branch
without origin/HEAD a local main is the base|repo on-feat|code commit|$CORE_DOCS|the merge-base with main
main outranks master|repo with-master on-feat|code commit|$CORE_DOCS|the merge-base with main
without main a local master is the base|repo master on-feat|code commit|$CORE_DOCS|the merge-base with master
with no default branch a commit is not a change|repo trunk on-feat|code commit|-|-
with no default branch the working tree is judged alone|repo trunk on-feat|code commit code|$CORE_DOCS|no origin/HEAD, main or master to compare against
a commit sharing no history with the default is not a change|repo orphan|code commit|-|-
a branch sharing no history is judged on its working tree|repo orphan|code commit code|$CORE_DOCS|HEAD shares no history with main
"

run_table "every Stop reports independently" "world change payload rc out err" "\
a repeated stop with stop_hook_active reports the same notice again|repo|code stopped|active|0|$CORE_DOCS|-
a payload that is not JSON does not stop the notice|repo|code|raw|0|$CORE_DOCS|-
"

run_table "a failed discovery command is advisory" "world change rc out err" "\
a dying command cannot hold the stop and is reported|repo break:sed|code|0|-|fixture: sed failed;exit=19
a directory that is not a repository|norepo|-|0|-|git=rev-parse;git
unreadable repository metadata|repo badconfig|code|0|-|git=rev-parse;git
an unreadable changed set is not an empty one|repo break:ls-files|code|0|-|git=ls-files;fixture: ls-files failed
a merge-base git cannot answer is not judged as the working tree|clone break:merge-base|code commit|0|-|git=merge-base;fixture: merge-base failed
a default-branch probe git cannot answer is not read as absent|clone break:symbolic-ref|code commit|0|-|git=symbolic-ref;fixture: symbolic-ref failed
"

run_table "the notice's own first line counts what it names" "world change stale" "\
two covering docs are a count of two|repo|code|doc-drift-check: stale=2
one covering doc is a count of one|repo ui-topic|ui|doc-drift-check: stale=1
nothing unchanged and covered writes no notice at all|repo|-|-
"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
