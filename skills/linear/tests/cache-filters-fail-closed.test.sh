#!/usr/bin/env bash
# cache-query filters are honored or refused, never accepted and ignored (KEN-1173).
#
# `cache_list_issues` carried `--team | --assignee | --created-since) shift 2 ;;`
# in the same case statement as its own fail-closed arm, which the arm's comment
# said existed to catch exactly that. All three flags were accepted at rc 0 and
# did nothing: on a cache holding more than one team, a request that named one
# got the whole workspace back with nothing in the output naming the scope.
# `cache_list_labels` and `cache_list_cycles` ended their loops with
# `*) shift ;;` and had no fail-closed arm at all, so every spelling their arms
# did not name — `--team=X` on labels, an outright unknown flag on cycles — was
# swallowed the same way. Both of those live twins refuse the same input;
# `--assignee` and `--created-since` are real filters on the live issues path,
# and the cache refuses them because it does not implement them.
#
# One table over the three listings. A row names the command, its arguments
# and what came back, rendered as one line: the exit status, the sorted names
# or identifiers of a listing that answered, then stderr whole, so a refusal is
# pinned on its entire line (the three call sites pass their own command name
# and noun into one helper and can be wrong independently) and a listing on
# exactly the rows it returned.
#
# `issues list --team=X` is NOT asserted here: it already reached the
# fail-closed arm before this change (the deleted arm named `--team`, not
# `--team=`), and `cache-issues-no-project.test.sh` § C owns that arm. Two
# more surfaces the table leaves out are owned elsewhere: the value the cycles
# `--team=X` normalisation forwards (cache-cycles-team-filter.test.sh) and the
# resolved `--cycle` keyword applied as a predicate
# (cache-date-comparison-utc.test.sh).
#
# Fully offline — pure cache read, no curl needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

# GIT_DIR outranks -C, so where it is inherited `git -C "$TMP_ROOT" init` below
# re-inits the ambient repository and leaves no fixture repo at all. All four go
# together, which is the house rule in .claude/CLAUDE.md.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/.cache/linear"
# common.sh resolves PROJECT_ROOT through git rev-parse, so the fixture needs a
# repository of its own for that to land inside this scratch root.
git -C "$TMP_ROOT" init -q -b main
if [[ ! -d "$TMP_ROOT/.git" ]]; then
  assert_stop "the fixture repository is the one git init created" \
    "no repository at $TMP_ROOT/.git: a git environment variable redirected git init"
fi

# This root's own cache is the subject, so it replaces the assert lib's default
# sandbox — still scratch, so the exit verdict's containment check holds.
export LINEAR_CACHE_ROOT="$TMP_ROOT"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
LINEAR="$TMP_ROOT/.agents/skills/linear/scripts/linear.sh"

cat >"$TMP_ROOT/.cache/linear/meta.json" <<'JSON'
{"synced_at":"2026-07-17T00:00:00+00:00"}
JSON

# Two teams in every file, which is what makes a filter that does nothing
# detectable: one team's rows coming back is indistinguishable from an
# unfiltered read on a single-team fixture. Each issue sits in its own team's
# cycle, and OTHER's cycle starts later, so it is the one a team-blind
# `--cycle current` resolves to.
cat >"$TMP_ROOT/.cache/linear/issues.json" <<'JSON'
[
  {"id":"uuid-ken-1","identifier":"KEN-1","title":"ken issue",
   "state":{"name":"Todo","type":"unstarted"},"assignee":{"name":"alice"},
   "labels":{"nodes":[]},"project":null,"team":{"name":"KEN"},
   "cycle":{"id":"uuid-ken","name":"ken-cycle","number":1},
   "createdAt":"2026-07-16T00:00:00.000Z","updatedAt":"2026-07-16T00:00:00.000Z",
   "archivedAt":null,"trashed":false},
  {"id":"uuid-oth-1","identifier":"OTH-1","title":"other issue",
   "state":{"name":"Todo","type":"unstarted"},"assignee":{"name":"bob"},
   "labels":{"nodes":[]},"project":null,"team":{"name":"OTHER"},
   "cycle":{"id":"uuid-other","name":"other-cycle","number":1},
   "createdAt":"2026-07-16T00:00:00.000Z","updatedAt":"2026-07-16T00:00:00.000Z",
   "archivedAt":null,"trashed":false}
]
JSON

cat >"$TMP_ROOT/.cache/linear/labels.json" <<'JSON'
[
  {"id":"uuid-label-ken","name":"ken-label","color":"#000000","description":"",
   "isGroup":false,"team":{"name":"KEN"},"parent":null},
  {"id":"uuid-label-oth","name":"other-label","color":"#000000","description":"",
   "isGroup":false,"team":{"name":"OTHER"},"parent":null}
]
JSON

cat >"$TMP_ROOT/.cache/linear/cycles.json" <<'JSON'
[
  {"id":"uuid-ken","number":1,"name":"ken-cycle","startsAt":"2026-06-01T00:00:00.000Z",
   "endsAt":"2026-06-15T00:00:00.000Z","progress":0.4,"team":{"name":"KEN"}},
  {"id":"uuid-other","number":1,"name":"other-cycle","startsAt":"2026-06-10T00:00:00.000Z",
   "endsAt":"2026-06-24T00:00:00.000Z","progress":0.2,"team":{"name":"OTHER"}}
]
JSON

# --- the renderer -------------------------------------------------------------
# run COMMAND ARGS... — `cache COMMAND list ARGS`, as one line: the status, the
# listing as its sorted identifiers or names in brackets (a JSON array on
# stdout; the `ids` format prints one identifier per line), then stderr whole.
run() {
  local cmd="$1" rc=0 out err listing
  shift
  (cd "$TMP_ROOT" && bash "$LINEAR" cache "$cmd" list "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err") || rc=$?
  err="$(paste -sd';' "$TMP_ROOT/err")"
  if listing="$(jq -er 'if type == "array" then [.[] | .identifier // .name] | sort | join(",") else empty end' "$TMP_ROOT/out" 2>/dev/null)"; then
    out="[$listing]"
  else
    out="[$(sort "$TMP_ROOT/out" | paste -sd, -)]"
  fi
  printf 'rc=%s %s%s' "$rc" "$out" "${err:+ $err}"
}

# --- the expected lines --------------------------------------------------------
# unknown COMMAND NOUN FLAG   the unknown-flag refusal for that listing
# empty                        the given-but-empty team refusal
# novalue                      the missing-value refusal, in the JSON shape
# list IDS                     a listing that answered with exactly IDS
expected() {
  case "$1" in
  unknown) printf 'rc=1 [] {"error":"Unknown flag for cache %s: %s. A filter the cache cannot honor must fail, not silently return every %s. Run '"'"'cache %s --help'"'"'."}' "$2 list" "$4" "$3" "$2 list" ;;
  empty) printf 'rc=1 [] {"error": "--team requires a non-empty team name: an empty value would return every team, not the one named"}' ;;
  novalue) printf 'rc=1 [] {"error":"--team requires a value"}' ;;
  list) printf 'rc=0 [%s]' "${2:-}" ;;
  esac
}

# --- the table ------------------------------------------------------------------
# label|command|args|expect
# `--team X` on issues resolves the keyword `current` inside X's cycles; OTHER's
# cycle starts later, so a team-blind resolution picks it and answers []. The
# unfiltered rows are what the fail-closed arms must leave alone. `issues list
# --team=X` is not here: cache-issues-no-project.test.sh owns that arm.
ROWS='
A: --team KEN returns exactly KEN issues|issues|--team KEN --max --format=ids|list KEN-1
B: --assignee is refused, named as itself on the issues command|issues|--assignee alice --max --format=ids|unknown issues issue --assignee
B: --created-since is refused, named as itself on the issues command|issues|--created-since 1d --max --format=ids|unknown issues issue --created-since
C: labels --team=KEN is refused, named as itself on the labels command|labels|--team=KEN|unknown labels label --team=KEN
C: labels --team KEN, the space form, still filters|labels|--team KEN|list ken-label
D: cycles --bogus is refused, named as itself on the cycles command|cycles|--bogus x|unknown cycles cycle --bogus
E: an unfiltered issues list still returns every team|issues|--max --format=ids|list KEN-1,OTH-1
E: an unfiltered labels list still returns every team|labels||list ken-label,other-label
E: an unfiltered cycles list still returns every team|cycles||list ken-cycle,other-cycle
F: --team with an empty value refuses instead of returning every team|issues|--team "" --max --format=ids|empty
F: labels --team with an empty value refuses too|labels|--team ""|empty
F: cycles --team with an empty value refuses too|cycles|--team ""|empty
F: cycles --team= with an empty value refuses too|cycles|--team=|empty
G: a valueless --team answers with a JSON error, not a bash abort|issues|--max --format=ids --team|novalue
G: a valueless labels --team answers with a JSON error too|labels|--team|novalue
G: a valueless cycles --team answers with a JSON error too|cycles|--team|novalue
G: --team followed by another flag is a missing value, not a team named --max|issues|--team --max --format=ids|novalue
H: --team KEN --cycle current resolves KEN cycle, not OTHER|issues|--team KEN --cycle current --max --format=ids|list KEN-1
'

while IFS='|' read -r label cmd args spec; do
  [ -n "$label$cmd$args$spec" ] || continue
  eval "set -- $args"
  # shellcheck disable=SC2086  # the spec's fields are its words
  assert_eq "$label" "$(run "$cmd" "$@")" "$(expected $spec)"
done <<<"$ROWS"
