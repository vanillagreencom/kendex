#!/usr/bin/env bash
# doc-drift-check: a Stop hook that blocks once per stale-document set. Every
# changed non-markdown path is matched against the nearest tracked non-root
# AGENTS.md above it and every topic file whose Covers entry reaches it; a
# covering doc left unchanged is named once on stderr with exit 2, the channel
# the harness gives Claude, and stdout stays empty. The set is recorded under
# `<git common dir>/kendex/doc-drift/<session_id>-<digest>`, so a later stop
# naming that same set passes and a set that differs blocks once more. The
# changed set is read against the branch's merge-base with the default branch,
# or the working tree alone where no base applies. A payload, git state or
# marker the hook cannot read or write is refused, never passed.
#
# A row is `label|<columns>`; each table names its columns in order:
#   world    the row's repository, built fresh by `build` from these words:
#            `repo` (on main, no remote), `clone` (of a fresh repository, on
#            feat, origin/HEAD -> origin/main) or `norepo` (a bare directory)
#            first; then the sealed additions and branch moves `build` lists;
#            `subdir` runs the hook from ui/; `break:<cmd>` puts a git whose
#            <cmd> dies (or a dying sed, jq or cat) first on PATH; `nopath`
#            runs with an empty PATH; `sealed-marker` leaves the marker's
#            parent directory unwritable
#   change   the row's edits in order, from the words `change` lists;
#            `stage` and `commit` take everything; `stopped` runs one Stop
#            first and `stopped-active` one with stop_hook_active; `-` for none
#   payload  the Stop payload: `stop`, `stop2` (a second session), `active`
#            (stop_hook_active true), `noid` (no session_id) or `raw` (not
#            JSON); tables without the column feed `stop`
#   rc       the exit status
#   out      the documents the refusal names, each as `<doc>(<changed path>)`,
#            sorted and joined by `,`; `-` when it names none. Anything on
#            stdout renders as `stdout:` and the text, since the hook writes
#            there at no time
#   base     the refusal's `doc-drift-check: base=` value: the ref the hook
#            compared against, or `default-branch`, `none` or `unrelated` for
#            the three ways it is left the working tree alone; `-` without a
#            refusal
#   stale    the refusal's own first line, `doc-drift-check: stale=<count>`;
#            `-` without a refusal
#   err      the keyed first line of each report in order, joined by `;`, with
#            the hook's name removed; a `marker=` value renders as
#            `marker=<path>`, pinning that the marker is reported rather than
#            which path it was; a `fixture:` line (the broken command's own
#            stderr, replayed under the key) verbatim; `-` when stderr is
#            empty. The English under a keyed line is not read, and neither is
#            a cause no fixture pinned
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (a hook that exits 0 where it refuses, one that skips the marker, one keyed
# on the session alone) can be run against these same assertions.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would configure the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/doc-drift-check.sh}"
TMP_ROOT="$(mktemp -d)"
# A row that leaves a directory unwritable is cleaned up by restoring the mode
# first; rm cannot unlink what a read-only parent holds.
trap 'chmod -R u+rwx -- "${TMP_ROOT:?}" 2>/dev/null || :; rm -rf -- "${TMP_ROOT:?}"' EXIT
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
# the way a broken index or unreadable refs would, or whose sed, jq or cat
# dies on every call.
broken() { # COMMAND
  local dir="$REPO.bin" real
  mkdir -p "$dir"
  case "$1" in
    sed | jq | cat)
      printf '#!/usr/bin/env bash\necho "fixture: %s failed" >&2\nexit 19\n' "$1" >"$dir/$1"
      chmod +x "$dir/$1"
      ;;
    *)
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
      ;;
  esac
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
      nodocs)
        fgit -C "$REPO" rm -q crates/core/AGENTS.md docs/architecture/core.md
        seal
        ;;
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
      sealed-marker) mkdir -p "$REPO/.git/kendex"; chmod 500 "$REPO/.git/kendex" ;;
      nopath) mkdir -p "$REPO.empty"; RUN_PATH="$REPO.empty" ;;
      payload-tools-only)
        # The two commands the hook may call before it reads the payload, and
        # nothing else: the row asks what a discovery-only absence does.
        mkdir -p "$REPO.only"
        ln -sf -- "$(command -v jq)" "$REPO.only/jq"
        ln -sf -- "$(command -v cat)" "$REPO.only/cat"
        RUN_PATH="$REPO.only"
        ;;
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
      revert-code) fgit -C "$REPO" checkout -q -- crates/core/src/lib.rs ;;
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
      stopped-active) run active ;;
      *) printf 'an unknown change word changes nothing: %s\n' "$word" >&2; exit 1 ;;
    esac
  done
}

run() { # PAYLOAD — sets RC and MESSAGE (the hook's stderr)
  local payload
  case "$1" in
    stop) payload='{"session_id":"s1","hook_event_name":"Stop","stop_hook_active":false}' ;;
    stop2) payload='{"session_id":"s2","hook_event_name":"Stop","stop_hook_active":false}' ;;
    active) payload='{"session_id":"s1","hook_event_name":"Stop","stop_hook_active":true}' ;;
    noid) payload='{"hook_event_name":"Stop","stop_hook_active":false}' ;;
    raw) payload='not json' ;;
    *) printf 'an unknown payload word runs nothing: %s\n' "$1" >&2; exit 1 ;;
  esac
  RC=0
  # $BASH, not the name: the `nopath` row leaves no PATH to resolve it on.
  (cd "$RUN_DIR" && env HOME="$TMP_ROOT" PATH="$RUN_PATH" "$BASH" "$HOOK" <<<"$payload" \
    >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr") || RC=$?
  MESSAGE="$(cat "$TMP_ROOT/stderr")"
}

out_text() {
  local line doc path out=""
  [[ ! -s "$TMP_ROOT/stdout" ]] || { printf 'stdout:%s' "$(paste -s -d ';' - <"$TMP_ROOT/stdout")"; return; }
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
  [[ "$out" != "" ]] || { printf -- '-'; return; }
  printf '%s' "$out" | LC_ALL=C sort | paste -s -d ',' -
}

# The refusal opens with two keyed lines, `stale=` then `base=`, so this reads
# line 2 rather than searching for the key: a base line further down would not
# be the contract.
base_text() {
  case "$MESSAGE" in
    "doc-drift-check: stale="*) ;;
    *) printf -- '-'; return ;;
  esac
  printf '%s\n' "$MESSAGE" | sed -n '2s/^doc-drift-check: base=//p'
}

err_text() {
  local line out=""
  [[ -s "$TMP_ROOT/stderr" ]] || { printf -- '-'; return; }
  while IFS= read -r line; do
    case "$line" in
      "doc-drift-check: marker="*) out="$out;marker=<path>" ;;
      "doc-drift-check: "*) out="$out;${line#doc-drift-check: }" ;;
      fixture:*) out="$out;$line" ;;
    esac
  done <"$TMP_ROOT/stderr"
  printf '%s' "${out#;}"
}

stale_text() {
  case "$MESSAGE" in
    "doc-drift-check: stale="*) printf '%s' "${MESSAGE%%$'\n'*}" ;;
    *) printf -- '-' ;;
  esac
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
        rc | out | base | stale | err) want="$want $col=${fields[$i]}" ;;
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
        base) got="$got base=$(base_text)" ;;
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
CORE_AND_UI="$CORE_DOCS,docs/architecture/ui.md(crates/core/src/lib.rs)"

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
a second topic naming the same directory is named beside the first|repo ui-topic|code|$CORE_AND_UI
an exact file entry reaches its topic|repo selected-topic|ui|docs/architecture/selected.md(ui/src/app.ts)
a glob entry reaches its topic, * crossing /|repo selected-topic|eval|docs/architecture/selected.md(crates/eval/src/eval_score.rs)
a topic two paths reach is named once, with the first path|repo selected-topic|ui eval|docs/architecture/selected.md(crates/eval/src/eval_score.rs)
an exact file entry does not cover a sibling sharing its prefix|repo file-topic|other|-
root entries cover nothing|repo root-topic|ui|-
a non-ASCII path is code and keeps its bytes|repo|unicode|crates/core/AGENTS.md(crates/core/src/über.rs),docs/architecture/core.md(crates/core/src/über.rs)
"

run_table "base selection: what the branch is compared against" "world change rc out base" "\
a committed change on a branch is judged against origin/HEAD|clone|code commit|2|$CORE_DOCS|origin/main
an uncommitted doc change beside the committed code passes|clone|code commit agents|0|-|-
a doc committed beside the code passes|clone|code agents commit|0|-|-
a doc committed earlier on the branch passes|clone|topic commit code commit|0|-|-
a commit on the default branch is not a change|clone on-main|code commit|0|-|-
a working-tree change on the default branch is judged alone|clone on-main|code commit code|2|$CORE_DOCS|default-branch
without origin/HEAD a local main is the base|repo on-feat|code commit|2|$CORE_DOCS|main
main outranks master|repo with-master on-feat|code commit|2|$CORE_DOCS|main
without main a local master is the base|repo master on-feat|code commit|2|$CORE_DOCS|master
with no default branch a commit is not a change|repo trunk on-feat|code commit|0|-|-
with no default branch the working tree is judged alone|repo trunk on-feat|code commit code|2|$CORE_DOCS|none
a commit sharing no history with the default is not a change|repo orphan|code commit|0|-|-
a branch sharing no history is judged on its working tree|repo orphan|code commit code|2|$CORE_DOCS|unrelated
"

run_table "a set is named once per session" "world change payload rc out" "\
the same set on a later stop passes|repo|code stopped|stop|0|-
stop_hook_active passes|repo|code|active|0|-
an active stop records nothing, so the set still blocks|repo|code stopped-active|stop|2|$CORE_DOCS
another session is told the same set|repo|code stopped|stop2|2|$CORE_DOCS
a set that gained a document blocks again|repo ui-topic|ui stopped code|stop|2|$CORE_AND_UI
a set named earlier passes after another set intervened|repo ui-topic|ui stopped code stopped revert-code|stop|0|-
"

run_table "a state the hook cannot read or a marker it cannot write is refused" "world change payload rc out err" "\
a dying command cannot be read as an empty change set, and its words follow the key|repo break:sed|code|stop|2|-|exit=19;fixture: sed failed
a directory that is not a repository|norepo|-|stop|2|-|git=rev-parse
unreadable repository metadata|repo badconfig|code|stop|2|-|git=rev-parse
an unreadable changed set is not an empty one|repo break:ls-files|code|stop|2|-|git=ls-files;fixture: ls-files failed
a merge-base git cannot answer is not judged as the working tree|clone break:merge-base|code commit|stop|2|-|git=merge-base;fixture: merge-base failed
a default-branch probe git cannot answer is not read as absent|clone break:symbolic-ref|code commit|stop|2|-|git=symbolic-ref;fixture: symbolic-ref failed
a payload that cannot be read|repo break:cat|code|stop|2|-|payload=unreadable;fixture: cat failed
a payload that is not JSON|repo|code|raw|2|-|payload=invalid-json
a jq that cannot answer for the payload, with its own words below|repo break:jq|code|stop|2|-|payload=invalid-json;fixture: jq failed
a payload carrying no session id|repo|code|noid|2|-|session-id=invalid
a marker that cannot be recorded|repo sealed-marker|code|stop|2|-|marker=<path>
no command the hook runs on PATH names the payload readers alone|repo nopath|code|stop|2|-|missing-tools=jq,cat
only the payload readers on PATH names the rest|repo payload-tools-only|code|stop|2|-|missing-tools=git,sed,sort,tr,dirname,grep,mkdir,sha256sum
"

run_table "which absence still refuses the retry stop_hook_active passes" "world change payload rc err" "\
a discovery command missing on an active stop passes|repo payload-tools-only|code|active|0|-
a payload reader missing refuses the active stop too, the flag being in the payload it cannot read|repo nopath|code|active|2|missing-tools=jq,cat
"

run_table "a state the hook cannot read is refused only where a set is named" "world change payload rc err" "\
a clean tree with no session id in the payload passes|repo|-|noid|0|-
a clean tree whose marker directory is unwritable passes|repo sealed-marker|-|stop|0|-
a markdown-only change with no session id passes|repo|md|noid|0|-
"

run_table "the refusal's own first line counts what it names" "world change rc stale" "\
two covering docs are a count of two|repo|code|2|doc-drift-check: stale=2
one covering doc is a count of one|repo ui-topic|ui|2|doc-drift-check: stale=1
nothing unchanged and covered is not refused|repo|-|0|-
"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
