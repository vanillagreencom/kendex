#!/usr/bin/env bash
# Pins for scripts/prose, the history-reference scan over agent-loaded
# markdown: a calendar date or an issue number in a scoped file fails naming
# file:line and the remedy, ordinary wording and decision IDs pass, the path
# list is the harness-loaded names (the architecture docs join under
# COMMIT_GUARDS_MD_SCOPE=all), replaceable and validated, the markdown
# excludes carve paths out, and a scoped path that is not markdown is named
# rather than counted clean. Two tables: one line of SKILL.md judged, and
# the runs over a built repository. A row runs the scan once and pins the
# exit status with every line printed, so the hit, its line, the remedy,
# the counts and the path list shown are one pin. The index readers this
# family shares are index-reads.test.sh and lane-readers.test.sh.
set -euo pipefail
# No globbing: a row's ARGS column is word-split into the scan's arguments.
set -f
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
PROSE="$SKILL_DIR/scripts/prose"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# Hermetic: a leaked setting would mask every row below.
unset COMMIT_GUARDS_PROSE_PATHS COMMIT_GUARDS_MD_EXCLUDES COMMIT_GUARDS_MD_SCOPE COMMIT_GUARDS_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}

# One line for a run in the row's repository: the exit status, then every
# line printed, in order, joined by ';'. ENVS is a comma-separated list of
# assignments; ARGS are passed through.
R=""
run() { # ENVS ARGS
  local envs=() rc=0 out=""
  [ -z "$1" ] || IFS=',' read -ra envs <<<"$1"
  # shellcheck disable=SC2086
  out="$(cd "$R" && env ${envs[@]+"${envs[@]}"} "$PROSE" $2 2>&1)" || rc=$?
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}

# Fixture vocabulary. Every fixture builds its own repository and stages
# what it wrote; a name used twice is refused.
repo() { # NAME
  R="$TMP/$1"
  [ ! -e "$R" ] || { echo "harness: fixture $1 already exists" >&2; exit 2; }
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}
put() { mkdir -p "$R/$(dirname "$1")"; printf '%b' "$2" >"$R/$1"; git -C "$R" add -A; } # PATH CONTENT (printf %b), staged
SEEDED='Seeded 2026-08-12.\n'

# The lines the scan prints, as functions of what a row put in.
PATHS_CORE="SKILL.md */SKILL.md AGENTS.md */AGENTS.md CLAUDE.md */CLAUDE.md workflows/*.md */workflows/*.md agents/*.md */agents/*.md"
PATHS_ALL="$PATHS_CORE docs/architecture/*.md"
REMEDY="  remedies: state the rule that holds now and delete the story; the date and the issue number belong in the commit that made the change"
ERR="::error::prose: "
hit() { printf 'prose FAIL history reference: %s:%s:%s;%s' "$1" "$2" "$3" "$REMEDY"; } # PATH LINE TEXT
skip() { printf 'prose: not measured: %s — %s' "$1" "$2"; } # PATH REASON
unmeasured() { printf '; %s matched path(s) not measured' "$1"; } # N
clean() { printf 'prose: OK — no history references in %s scanned file(s)%s' "$1" "${2-}"; } # SCANNED [UNMEASURED]
failed() { printf 'prose: %s history reference(s) in %s scanned file(s) — paths %s%s' "$1" "$2" "${3:-$PATHS_CORE}" "${4-}"; } # HITS SCANNED [PATHS] [UNMEASURED]
nomatch() { printf 'prose: OK — no tracked file matches COMMIT_GUARDS_PROSE_PATHS (%s)' "$1"; } # PATHS
NONE="prose: OK — nothing measurable to scan"

# Table one: SKILL.md holds LINE in a fresh repository, scanned under the
# default scope.
ROW=0
line_rows() { # label | line | expect
  local row label line expect
  for row in "$@"; do
    IFS='|' read -r label line expect <<<"$row"
    ROW=$((ROW + 1))
    R=""
    repo "line-$ROW"
    put SKILL.md "$line\n"
    assert_eq "$label" "$expect" "$(run '' '')"
  done
}

echo "=== a date or an issue number fails naming file:line and the remedy; ordinary wording passes ==="
line_rows \
  "control: agent-loaded markdown with no history passes, and the verdict says how many files it read|Run the installer from the repository root.|rc=0 $(clean 1)" \
  "a calendar date fails, naming file:line, carrying the remedy, counting hits and files, and showing the path list|The ratchet baseline was seeded 2026-08-12.|rc=1 $(hit SKILL.md 1 'The ratchet baseline was seeded 2026-08-12.');$(failed 1 1)" \
  "ordinary wording passes: previously|The previously saved value stays available.|rc=0 $(clean 1)" \
  "ordinary wording passes: no longer|The lock is no longer held after return.|rc=0 $(clean 1)" \
  "ordinary wording passes: incident|The incident handler writes a report.|rc=0 $(clean 1)" \
  "ordinary wording passes: existing, reverted|The existing code handles a reverted transaction.|rc=0 $(clean 1)" \
  "ordinary wording passes: timestamp, at the time|The timestamp records the value at the time of the read.|rc=0 $(clean 1)" \
  "a three-digit issue number fails|Closed by #228 upstream.|rc=1 $(hit SKILL.md 1 'Closed by #228 upstream.');$(failed 1 1)" \
  "a four-digit reference glued to a filename fails|See spec.md#1204 for the shape.|rc=1 $(hit SKILL.md 1 'See spec.md#1204 for the shape.');$(failed 1 1)" \
  "a five-digit run and a two-digit run both pass|The colour token is #12345 and the port is #12.|rc=0 $(clean 1)" \
  "a CSS hex colour opening with digits is not an issue reference|Swatches #123abc, #1234ab, #0088cc and #3366ff are colours.|rc=0 $(clean 1)" \
  "all-digit shorthand still fails: #900 is also how issue 900 is written|The brand red is #900 and the accent is #369.|rc=1 $(hit SKILL.md 1 'The brand red is #900 and the accent is #369.');$(failed 1 1)" \
  "control: a reference followed by punctuation or a space still fails, one hit per line|Landed in #1204) and #228, per #999.|rc=1 $(hit SKILL.md 1 'Landed in #1204) and #228, per #999.');$(failed 1 1)" \
  "a reference ending its line still fails|Landed in #1204|rc=1 $(hit SKILL.md 1 'Landed in #1204');$(failed 1 1)" \
  "ordinary wording passes: a bare year and a year-month|The 2026 roadmap and the 2026-08 window.|rc=0 $(clean 1)" \
  "an ATX heading whose text is a number, to the end of the line, is not an issue reference|#### 1204|rc=0 $(clean 1)" \
  "a decision ID, a code-span D042 § Context and a four-digit ID all pass|Decided in D042; the reason is in \`D042 § Context\`, and D1234 is the same kind.|rc=0 $(clean 1)" \
  "control: the same digits after '#' are still an issue reference|Decided in #042.|rc=1 $(hit SKILL.md 1 'Decided in #042.');$(failed 1 1)" \
  "two hits on two lines are two lines and one count each|First 2026-08-12.\nSecond #228.|rc=1 $(hit SKILL.md 1 'First 2026-08-12.');$(hit SKILL.md 2 'Second #228.');$(failed 2 1)"

# Table two: FIXTURE (a function and its words) builds the repository; the
# scan runs with ARGS under ENVS.
run_rows() { # label | fixture | envs | args | expect
  local row label fx envs args expect words
  for row in "$@"; do
    IFS='|' read -r label fx envs args expect <<<"$row"
    R=""
    read -ra words <<<"$fx"
    "${words[@]}"
    assert_eq "$label" "$expect" "$(run "$envs" "$args")"
  done
}

echo "=== scope: each default name is scanned, the architecture docs under scope all, and nothing else ==="
SCOPED="SKILL.md AGENTS.md CLAUDE.md skills/dev/SKILL.md skills/dev/AGENTS.md skills/dev/CLAUDE.md workflows/ship.md skills/dev/workflows/ship.md agents/rust.md .claude/agents/rust.md"
ARCH="docs/architecture/overview.md docs/architecture/topic.md"
UNSCOPED="README.md CHECKS.md docs/design.md CHANGELOG.md skills/dev/references/api.md notes/workflows.md"
UNSCOPED_GLOBS="README.md CHECKS.md docs/*.md CHANGELOG.md skills/dev/references/*.md notes/*.md"
UNSCOPED_SORTED="CHANGELOG.md CHECKS.md README.md docs/design.md notes/workflows.md skills/dev/references/api.md" # index order
scoped() { repo "scoped-${1//\//_}"; put "$1" "$SEEDED"; } # PATH — the one tracked file, seeded
fx_arch() { repo "$1"; put SKILL.md 'clean\n'; put docs/architecture/overview.md "$SEEDED"; }
fx_unscoped() { # NAME — every scoped path clean, every unscoped one seeded
  local f
  repo "$1"
  for f in $SCOPED; do put "$f" 'clean\n'; done
  for f in $UNSCOPED; do put "$f" 'Seeded 2026-08-12, reverted in #1204.\n'; done
}
rows=()
for f in $SCOPED; do
  rows+=("$f is in the default scope|scoped $f|COMMIT_GUARDS_MD_SCOPE=all||rc=1 $(hit "$f" 1 'Seeded 2026-08-12.');$(failed 1 1 "$PATHS_ALL")")
done
for f in $ARCH; do
  rows+=("$f is in the scope-all list|scoped $f|COMMIT_GUARDS_MD_SCOPE=all||rc=1 $(hit "$f" 1 'Seeded 2026-08-12.');$(failed 1 1 "$PATHS_ALL")")
done
run_rows "${rows[@]}" \
  "under COMMIT_GUARDS_MD_SCOPE=touched the architecture docs are not yet in scope|fx_arch arch-touched|||rc=0 $(clean 1)" \
  "control: under scope all the same file fails|fx_arch arch-all|COMMIT_GUARDS_MD_SCOPE=all||rc=1 $(hit docs/architecture/overview.md 1 'Seeded 2026-08-12.');$(failed 1 2 "$PATHS_ALL")" \
  "README, CHECKS, docs, CHANGELOG, references and a workflows-named file keep their history, with the ten scoped files still read|fx_unscoped unscoped|||rc=0 $(clean 10)" \
  "control: the same six files fail once a path list names them|fx_unscoped unscoped-named|COMMIT_GUARDS_PROSE_PATHS=$UNSCOPED_GLOBS||rc=1 $(for f in $UNSCOPED_SORTED; do hit "$f" 1 'Seeded 2026-08-12, reverted in #1204.'; printf ';'; done)$(failed 6 6 "$UNSCOPED_GLOBS")" \
  "an unknown scope is exit 2, quoting it|fx_arch scope-unknown|COMMIT_GUARDS_MD_SCOPE=sometimes||rc=2 ${ERR}COMMIT_GUARDS_MD_SCOPE must be 'touched' or 'all', got 'sometimes'"

echo "=== the markdown excludes list carves a vendored skill out ==="
vendored() { repo "$1"; put SKILL.md 'clean\n'; put .agents/skills/vendored/SKILL.md "$SEEDED"; }
fx_excluded() { vendored excluded; put tools/md-excludes '.agents/skills/vendored/**\tthird-party skill pinned by hash\n'; }
run_rows \
  "control: a vendored skill is scanned before it is excluded|vendored vendored-scanned|||rc=1 $(hit .agents/skills/vendored/SKILL.md 1 'Seeded 2026-08-12.');$(failed 1 2)" \
  "an excludes row carves the vendored skill out of the prose scan|fx_excluded|||rc=0 $(clean 1)"

echo "=== COMMIT_GUARDS_PROSE_PATHS replaces the list, and is validated ==="
override() { repo "$1"; put SKILL.md "$SEEDED"; put docs/design.md "$SEEDED"; }
fx_settings() { override settings; put kendex.settings.toml '[env]\nCOMMIT_GUARDS_PROSE_PATHS = "docs/*.md"\n'; }
run_rows \
  "control: the default list catches SKILL.md and leaves docs/design.md alone|override default|||rc=1 $(hit SKILL.md 1 'Seeded 2026-08-12.');$(failed 1 1)" \
  "the override replaces the list: docs/design.md fails and SKILL.md is no longer scanned|override env|COMMIT_GUARDS_PROSE_PATHS=docs/*.md||rc=1 $(hit docs/design.md 1 'Seeded 2026-08-12.');$(failed 1 1 'docs/*.md')" \
  "the same override resolves from kendex.settings.toml [env]|fx_settings|||rc=1 $(hit docs/design.md 1 'Seeded 2026-08-12.');$(failed 1 1 'docs/*.md')" \
  "a list matching no tracked file passes naming the list, and scans nothing|override nomatch|COMMIT_GUARDS_PROSE_PATHS=no/such/*.md||rc=0 $(nomatch 'no/such/*.md')" \
  "an empty path list is exit 2|override empty|COMMIT_GUARDS_PROSE_PATHS= ||rc=2 ${ERR}COMMIT_GUARDS_PROSE_PATHS names no path — name at least one, or drop this check from COMMIT_GUARDS_CHECKS" \
  "an absolute path is exit 2|override absolute|COMMIT_GUARDS_PROSE_PATHS=/etc/SKILL.md||rc=2 ${ERR}prose path must be repo-root-relative, got absolute: /etc/SKILL.md" \
  "a path escaping the repository is exit 2|override escaping|COMMIT_GUARDS_PROSE_PATHS=../outside/*.md||rc=2 ${ERR}prose path escapes the repository or normalizes empty: ../outside/*.md" \
  "an unknown flag is exit 2, quoting it|override unknown-flag||--no-such-flag|rc=2 ${ERR}unknown argument '--no-such-flag' (see --help)"
assert_eq "--help prints usage at exit 0" "rc=0 usage: prose" "$(run '' --help | LC_ALL=C cut -d';' -f1)"
assert_eq "--help documents the scope-all list as the default" "(default $PATHS_ALL)" "$(run '' --help | LC_ALL=C sed -n 's/.*(\(default SKILL.md[^)]*\)).*/(\1)/p')"

echo "=== a configured path that is not markdown is named, never counted clean ==="
fx_regular() { repo regular; put notes/target.md "$SEEDED"; put skills/dev/SKILL.md "$SEEDED"; }
fx_symlink() { repo "$1"; put notes/target.md "$SEEDED"; mkdir -p "$R/skills/dev"; ln -s ../../notes/target.md "$R/skills/dev/SKILL.md"; git -C "$R" add -A; } # NAME
# Two scoped links chained to one tracked file: a root CLAUDE.md linking to
# AGENTS.md, and a .claude/CLAUDE.md linking back to the root.
chain() { repo "$1"; put AGENTS.md "$2"; ln -s AGENTS.md "$R/CLAUDE.md"; mkdir -p "$R/.claude"; ln -s ../CLAUDE.md "$R/.claude/CLAUDE.md"; git -C "$R" add -A; } # NAME AGENTS-CONTENT
fx_chain_clean() { chain chain-clean 'clean\n'; }
fx_chain_seeded() { chain chain-seeded "$SEEDED"; }
fx_gitlink() { # a gitlink at a scoped path: mode 160000 carries a commit id, not markdown
  repo gitlink
  put SKILL.md 'clean\n'
  git -C "$R" commit -qm base
  git -C "$R" update-index --add --cacheinfo "160000,$(git -C "$R" rev-parse HEAD),vendor/AGENTS.md"
}
fx_binary() { repo binary; put AGENTS.md 'lead\0000Seeded 2026-08-12.\n'; }
fx_index_both() { repo "$1"; put workflows/a.md 'clean\n'; put workflows/b.md "$SEEDED"; }
fx_index_glob() { fx_index_both index-glob; rm "$R/workflows/b.md"; } # b.md still in the index, gone from the checkout
run_rows \
  "control: the same content as a REGULAR file at the scoped path fails|fx_regular|||rc=1 $(hit skills/dev/SKILL.md 1 'Seeded 2026-08-12.');$(failed 1 1)" \
  "a scoped symlink is named as unmeasured and counted apart: no clean verdict, no 'nothing matched' line|fx_symlink symlink|||rc=0 $(skip skills/dev/SKILL.md 'tracked as a symlink, not markdown');$NONE$(unmeasured 1)" \
  "a repo whose CLAUDE.md links to AGENTS.md and back exits 0, naming both links|fx_chain_clean|||rc=0 $(skip .claude/CLAUDE.md 'tracked as a symlink, not markdown');$(skip CLAUDE.md 'tracked as a symlink, not markdown');$(clean 1 "$(unmeasured 2)")" \
  "control: a reference in the file the links point at still fails, naming it|fx_chain_seeded|||rc=1 $(skip .claude/CLAUDE.md 'tracked as a symlink, not markdown');$(skip CLAUDE.md 'tracked as a symlink, not markdown');$(hit AGENTS.md 1 'Seeded 2026-08-12.');$(failed 1 1 "$PATHS_CORE" "$(unmeasured 2)")" \
  "a gitlink at a scoped path is named as unmeasured, not read as markdown|fx_gitlink|||rc=0 $(skip vendor/AGENTS.md 'tracked as a submodule gitlink, not markdown');$(clean 1 "$(unmeasured 1)")" \
  "a binary blob at a scoped path is named as unmeasured, with no clean file count over it|fx_binary|||rc=0 $(skip AGENTS.md 'binary content, not markdown');$NONE$(unmeasured 1)" \
  "control: both tracked workflows are scanned while both sit in the work tree|fx_index_both index-both|||rc=1 $(hit workflows/b.md 1 'Seeded 2026-08-12.');$(failed 1 2)" \
  "a tracked file absent from the work tree is still scanned: the glob is matched against the index|fx_index_glob|||rc=1 $(hit workflows/b.md 1 'Seeded 2026-08-12.');$(failed 1 2)"
# The premises the rows above rest on. The symlink skip: `git grep --cached`
# finds nothing at all in a symlink index entry, spending no status and no
# stderr on it. The index glob: b.md really is gone from the work tree while
# the index still names it.
fx_symlink symlink-premise
assert_eq "fixture: a bare --cached grep over the symlink entry finds nothing" "rc=1 mode=120000" \
  "$(cd "$R" && git grep --cached -n -I -E '2026' -- skills/dev/SKILL.md >/dev/null 2>&1; printf 'rc=%s mode=%s' "$?" "$(git ls-files -s skills/dev/SKILL.md | cut -d' ' -f1)")"
R="$TMP/index-glob"
assert_eq "fixture: workflows/b.md is absent from the work tree and still in the index" "work-tree=absent index=workflows/b.md" \
  "$(printf 'work-tree=%s index=%s' "$([ -e "$R/workflows/b.md" ] && echo present || echo absent)" "$(git -C "$R" ls-files workflows/b.md)")"

echo "=== the skill's own shipped markdown does not trip the lane ==="
fx_shipped() { # NAME — the four shipped documents
  local doc
  repo "$1"
  mkdir -p "$R/skills/commit-guards"
  for doc in SKILL.md README.md CHECKS.md DEVELOPMENT.md; do
    cp "$SKILL_DIR/$doc" "$R/skills/commit-guards/$doc"
  done
  git -C "$R" add -A
}
fx_shipped_planted() { fx_shipped shipped-planted; put skills/commit-guards/workflows/ship.md "$SEEDED"; }
run_rows \
  "the shipped SKILL.md scans clean beside its unscanned siblings|fx_shipped shipped|||rc=0 $(clean 1)" \
  "control: a planted reference fails while the shipped SKILL.md stays unnamed|fx_shipped_planted|||rc=1 $(hit skills/commit-guards/workflows/ship.md 1 'Seeded 2026-08-12.');$(failed 1 2)"
R="$TMP/shipped"
assert_eq "fixture: the four shipped documents are tracked beside each other" "4" "$(git -C "$R" ls-files | wc -l | tr -d ' ')"

echo "=== the shared glob loader refuses a caller running without set -f ==="
COMMON="$SKILL_DIR/scripts/lib/common.sh"
probe() { # FLAG — the loader called from a shell with pathname expansion set by FLAG
  local rc=0 out=""
  out="$(cd "$R" && GG_CHECK=probe bash -c 'set -euo pipefail; set '"$1"'f; . "$1"; gg_load_path_globs "*.md" probe PROBE_KEY; printf %s "$GG_PATH_GLOBS"' _ "$COMMON" 2>&1)" || rc=$?
  printf 'rc=%s %s' "$rc" "$out"
}
assert_eq "the loader exits 2 when the caller left pathname expansion on" "rc=2 ${ERR/prose/probe}gg_load_path_globs: pathname expansion is on; the caller must run under 'set -f' or the configured globs resolve against the work tree instead of matching the index" "$(probe +)"
assert_eq "control: under set -f the same call loads the glob unexpanded" "rc=0 *.md" "$(probe -)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
