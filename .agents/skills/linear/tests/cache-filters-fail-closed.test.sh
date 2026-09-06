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
# This locks in:
#   A. `issues list --team X` returns only that team's issues.
#   B. `--assignee` and `--created-since` refuse, each naming itself.
#   C. `labels list --team=X` refuses, the spelling the live twin rejects with
#      "Unknown option"; the space form still filters.
#   D. `cycles list` refuses an unknown flag instead of returning every cycle.
#   E. An unfiltered listing is unaffected by the fail-closed arms.
#   F. `--team ""` refuses instead of degrading to an unfiltered list.
#   G. `--team` standing last answers with the file's JSON error shape, not a
#      bash unbound-variable abort under set -u.
#   H. `--team X --cycle current` resolves the keyword inside X's cycles, not
#      against whichever team started a cycle most recently.
#
# Every refusal is matched on the whole "Unknown flag for cache <command>: <flag>"
# prefix, not the shared two words: the three call sites pass their own command
# name and noun into one helper and can be wrong independently.
#
# `issues list --team=X` is NOT asserted here: it already reached the
# fail-closed arm before this change (the deleted arm named `--team`, not
# `--team=`), and `cache-issues-no-project.test.sh` § C owns that arm.
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

run_issues() { cd "$TMP_ROOT" && bash "$LINEAR" cache issues list "$@"; }
run_labels() { cd "$TMP_ROOT" && bash "$LINEAR" cache labels list "$@"; }
run_cycles() { cd "$TMP_ROOT" && bash "$LINEAR" cache cycles list "$@"; }

# A refusal is written to stderr, and run_output captures only the subject's
# stdout — redirecting at the run_output call would merge the harness's stderr,
# not the subject's. The merge belongs inside the subject.
msg_issues() { run_issues "$@" 2>&1; }
msg_labels() { run_labels "$@" 2>&1; }
msg_cycles() { run_cycles "$@" 2>&1; }

ids() { jq -r '[.[].id] | sort | join(",")' <<<"$1"; }
names() { jq -r '[.[].name] | sort | join(",")' <<<"$1"; }

# --- A: issues list --team filters -------------------------------------------
outA="$(run_issues --team KEN --max --format=compact 2>/dev/null)"
assert_eq "A: --team KEN returns exactly KEN's issues" \
  "$(ids "$outA")" "KEN-1"

# --- B: the two filters the cache does not implement refuse -------------------
run_output assignee_out assignee_rc msg_issues --assignee alice --max --format=ids
assert_ne "B: --assignee does not exit 0" "$assignee_rc" 0
assert_contains "B: --assignee is refused, named as itself on the issues command" \
  "$assignee_out" "Unknown flag for cache issues list: --assignee"

run_output created_out created_rc msg_issues --created-since 1d --max --format=ids
assert_ne "B: --created-since does not exit 0" "$created_rc" 0
assert_contains "B: --created-since is refused, named as itself on the issues command" \
  "$created_out" "Unknown flag for cache issues list: --created-since"

# --- C: labels list refuses the inline spelling, filters on the space form ----
run_output labels_inline_out labels_inline_rc msg_labels --team=KEN
assert_ne "C: labels --team=KEN does not exit 0" "$labels_inline_rc" 0
assert_contains "C: labels --team=KEN is refused, named as itself on the labels command" \
  "$labels_inline_out" "Unknown flag for cache labels list: --team=KEN"
assert_eq "C: labels --team KEN, the space form, still filters" \
  "$(names "$(run_labels --team KEN 2>/dev/null)")" "ken-label"

# --- D: cycles list refuses an unknown flag ----------------------------------
run_output cycles_out cycles_rc msg_cycles --bogus x
assert_ne "D: cycles --bogus does not exit 0" "$cycles_rc" 0
assert_contains "D: cycles --bogus is refused, named as itself on the cycles command" \
  "$cycles_out" "Unknown flag for cache cycles list: --bogus"

# --- E: unfiltered listings are unaffected -----------------------------------
assert_eq "E: an unfiltered issues list still returns every team's issues" \
  "$(printf '%s\n' "$(run_issues --max --format=ids 2>/dev/null)" | sort | tr '\n' ',')" \
  "KEN-1,OTH-1,"
assert_eq "E: an unfiltered labels list still returns every team's labels" \
  "$(names "$(run_labels 2>/dev/null)")" "ken-label,other-label"
assert_eq "E: an unfiltered cycles list still returns every team's cycles" \
  "$(names "$(run_cycles 2>/dev/null)")" "ken-cycle,other-cycle"

# --- F: a given-but-empty team refuses, on every command that takes the flag --
# Reached by a workflow interpolating --team "$LINEAR_TEAM" with nothing in it.
# All three listings are checked: one command refusing while its siblings return
# the workspace is the same fail-open shape, one function over.
run_output empty_out empty_rc msg_issues --team "" --max --format=ids
assert_ne "F: --team with an empty value does not exit 0" "$empty_rc" 0
assert_jq "F: --team with an empty value refuses instead of returning every team" \
  "$empty_out" '.error | test("--team requires a non-empty team name")'

run_output empty_labels_out empty_labels_rc msg_labels --team ""
assert_ne "F: labels --team with an empty value does not exit 0" "$empty_labels_rc" 0
assert_jq "F: labels --team with an empty value refuses too" \
  "$empty_labels_out" '.error | test("--team requires a non-empty team name")'

run_output empty_cycles_out empty_cycles_rc msg_cycles --team ""
assert_ne "F: cycles --team with an empty value does not exit 0" "$empty_cycles_rc" 0
assert_jq "F: cycles --team with an empty value refuses too" \
  "$empty_cycles_out" '.error | test("--team requires a non-empty team name")'

# The inline spelling cycles accepts is normalized onto the space arm, so the
# same guard reaches it rather than a second binding it could be missing from.
run_output empty_inline_out empty_inline_rc msg_cycles --team=
assert_ne "F: cycles --team= with an empty value does not exit 0" "$empty_inline_rc" 0
assert_jq "F: cycles --team= with an empty value refuses too" \
  "$empty_inline_out" '.error | test("--team requires a non-empty team name")'

# --- G: --team standing last answers in the file's error shape ----------------
run_output last_out last_rc msg_issues --max --format=ids --team
assert_ne "G: a valueless --team does not exit 0" "$last_rc" 0
assert_jq "G: a valueless --team answers with a JSON error, not a bash abort" \
  "$last_out" '.error | test("--team requires a value")'

run_output last_labels_out last_labels_rc msg_labels --team
assert_ne "G: a valueless labels --team does not exit 0" "$last_labels_rc" 0
assert_jq "G: a valueless labels --team answers with a JSON error too" \
  "$last_labels_out" '.error | test("--team requires a value")'

run_output last_cycles_out last_cycles_rc msg_cycles --team
assert_ne "G: a valueless cycles --team does not exit 0" "$last_cycles_rc" 0
assert_jq "G: a valueless cycles --team answers with a JSON error too" \
  "$last_cycles_out" '.error | test("--team requires a value")'

# --- H: the cycle keyword resolves inside the requested team ------------------
# OTHER's cycle starts later, so a team-blind resolution picks it and this
# returns nothing at rc 0 — a silently empty answer to a well-formed request,
# while `cycles list --team KEN --type current` names KEN's cycle off the same
# file.
outH="$(run_issues --team KEN --cycle current --max --format=ids 2>/dev/null)"
assert_eq "H: --team KEN --cycle current resolves KEN's cycle, not OTHER's" \
  "$(printf '%s\n' "$outH" | sort | tr '\n' ',')" "KEN-1,"
