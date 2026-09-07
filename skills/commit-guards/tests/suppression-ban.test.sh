#!/usr/bin/env bash
# Pins for scripts/suppression-ban: every blanket lane fires with its legal
# per-line counterpart proven to pass, the bare-allow ratchet fails in every
# direction (new, grow, loose, stale), --update tightens only, baseline
# hygiene is enforced, the baseline is read from the index like the scan,
# the render inventory (.kendex-generated.json, the one check that loads
# it) excludes its exact paths, and a carrier the sniff skips is named once
# and qualifies the verdict.
# Two tables. The first builds one tracked file per row from the row's own
# content; the second runs a fixture function per row for the cases that
# need a baseline, a commit or more than one file. Each pins the exit
# status with every line printed, and a --update row pins the baseline the
# run leaves behind. The index readers this family shares — the per-carrier
# count among them — are pinned once, in lane-readers.test.sh.
#
# Suppression pragmas appear verbatim in rows: the check is pathspec-scoped
# to language extensions, so this .sh file is never scanned by it.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SB="$SKILL_DIR/scripts/suppression-ban"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
unset COMMIT_GUARDS_SUPPRESSION_EXCLUDES COMMIT_GUARDS_SUPPRESSION_BASELINE COMMIT_GUARDS_SETTINGS_FILE 2>/dev/null || true

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
  out="$(cd "$R" && env ${envs[@]+"${envs[@]}"} "$SB" $2 2>&1)" || rc=$?
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}
# The baseline the run left behind: its rows joined by '~', or absent.
baseline() { [ -e "$R/$BASE" ] && printf 'baseline=%s' "$(LC_ALL=C paste -sd '~' -- "$R/$BASE")" || printf 'baseline=absent'; }

# Fixture vocabulary. Every fixture builds its own repository; a name used
# twice is refused. The generated-paths inventory is empty and tracked.
repo() { # NAME
  R="$TMP/$1"
  [ ! -e "$R" ] || { echo "harness: fixture $1 already exists" >&2; exit 2; }
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  printf '[]\n' >"$R/.kendex-generated.json"
  git -C "$R" add .kendex-generated.json
}
put() { mkdir -p "$R/$(dirname "$1")"; printf '%b' "$2" >"$R/$1"; } # PATH CONTENT (printf %b)
stage() { git -C "$R" add -A; }
commit() { git -C "$R" commit -qm "${1:-seed}"; } # [MESSAGE]
file() { repo "$1"; put "$2" "$3"; stage; } # NAME PATH CONTENT — one tracked file
BASE=tools/suppression-baseline.tsv
EXCL=tools/suppression-ban-excludes
base() { put "$BASE" "$1"; stage; } # ROWS — the baseline, staged
DEAD='#[allow(dead_code)]\n'
UNUSED='#[allow(unused)]\n'
UNUSED_VARS='#[allow(unused_variables)]\n'
BLANKET='#![allow(dead_code)]\n'

# The lines the check prints, as functions of what a row put in.
OK="suppression-ban: OK — no blanket suppressions, bare allows within baseline $BASE"
hit() { printf 'suppression-ban FAIL %s: %s:%s:%s;  remedies: %s' "$1" "$2" "$3" "$4" "$5"; } # LANE PATH LINE CONTENT REMEDY
summary() { printf 'suppression-ban: %s violation(s) — %s blanket, %s ratchet (baseline %s)' "$(($2 + $3))" "$2" "$3" "${1:-$BASE}"; } # [BASELINE] BLANKET RATCHET
new() { printf 'suppression-ban FAIL new bare allow: %s — %s reasonless allow(dead_code)/allow(unused) attribute(s), no baseline row;  remedies: state a reason on each attribute or fix the code; freezing a legacy count is a hand-added baseline row in this diff with justification' "$1" "$2"; } # PATH COUNT
grow() { printf 'suppression-ban FAIL bare allows grew: %s — %s attribute(s) > baseline %s;  remedies: state a reason on each new attribute or fix the code; raising the row is a hand-edit in this diff with justification' "$1" "$2" "$3"; } # PATH COUNT BASE
loose() { printf 'suppression-ban FAIL baseline looser than reality: %s — baseline %s > actual %s; the ratchet only moves down;  remedy: run suppression-ban --update to tighten the row' "$1" "$2" "$3"; } # PATH BASE COUNT
stale() { printf 'suppression-ban FAIL stale baseline row: %s — no bare allows remain (or the file left the tracked, non-excluded set); the row (%s) must go;  remedy: run suppression-ban --update to drop the row' "$1" "$2"; } # PATH BASE
skip() { printf 'suppression-ban: not measured: %s — binary content, not text' "$1"; } # PATH
unread() { printf '; %s matched path(s) not measured' "$1"; } # COUNT
ERR="::error::suppression-ban: "
r_rust() { printf 'delete the module-wide attribute and fix the findings, or annotate the surviving sites per line with a stated reason; vendored trees belong in %s with a reason' "${1:-$EXCL}"; } # [EXCLUDES]
R_RUST="$(r_rust)"
R_NOQA="drop the file-level directive; a per-line noqa naming its specific codes stays legal"
R_ESLINT="name the rules being disabled (and why), or fix the findings; the bare block form turns the linter off wholesale"
R_NOLINT="name the linter per line (nolint:lintname with the reason alongside), or fix the finding"
R_ALL="delete the file-wide directive and suppress per line with the full rule path and a reason (biome-ignore lint/<group>/<rule>: why), or fix the findings"
R_START="scope the region to one rule (biome-ignore-start lint/<group>/<rule>: why, closed by biome-ignore-end), or fix the findings; a start without a full rule path suppresses everything until the end marker"
R_IGNORE="name the full rule path (biome-ignore lint/<group>/<rule>: why); the bare lint or group form silences every rule beneath it"

# The first table: label | path | content | env | args | expect.
run_files() {
  local row label path content env args expect n=0
  for row in "$@"; do
    IFS='|' read -r label path content env args expect <<<"$row"
    [ -n "$expect" ] || { echo "harness: row has fewer than six fields: $row" >&2; exit 2; }
    n=$((n + 1))
    file "f-$SECTION-$n" "$path" "$content"
    assert_eq "$label" "$expect" "$(run "$env" "$args")"
  done
}
# The second: label | fixture | env | args | expect | state (the baseline
# after the run, or - when the row does not read it).
run_rows() {
  local row label fx env args expect state
  for row in "$@"; do
    IFS='|' read -r label fx env args expect state <<<"$row"
    [ -n "$state" ] || { echo "harness: row has fewer than six fields: $row" >&2; exit 2; }
    R=""
    "$fx"
    assert_eq "$label" "$expect" "$(run "$env" "$args")"
    [ "$state" = "-" ] || assert_eq "$label — the baseline left behind" "$state" "$(baseline)"
  done
}

SECTION=blanket
echo "=== every blanket lane fires, naming the lane and the line; its legal per-line counterpart passes ==="
run_files \
  "a clean file passes|ok.rs|fn main() {}\n|||rc=0 $OK" \
  "a crate-wide inner allow fails, naming the lane, file, line and the line itself, with the remedy|ok.rs|$BLANKET"'fn main() {}\n'"|||rc=1 $(hit 'module-wide rust allow' ok.rs 1 '#![allow(dead_code)]' "$R_RUST");$(summary '' 1 0)" \
  "an inner allow indented inside a module block fails at its own line|ok.rs|mod m {\n    #![allow(unused)]\n    fn f() {}\n}\n|||rc=1 $(hit 'module-wide rust allow' ok.rs 2 '    #![allow(unused)]' "$R_RUST");$(summary '' 1 0)" \
  "a per-item outer attribute for a named lint passes|ok.rs|#[allow(clippy::too_many_arguments)]\nfn f() {}\n|||rc=0 $OK" \
  "a dead_code allow with a stated reason passes: the reasoned form is the legal one|ok.rs|#[allow(dead_code, reason = \"kept for the public API surface\")]\nfn f() {}\n|||rc=0 $OK" \
  "a file-level ruff noqa fails|ok.py|# ruff: noqa\nx = 1\n|||rc=1 $(hit 'file-level noqa' ok.py 1 '# ruff: noqa' "$R_NOQA");$(summary '' 1 0)" \
  "a file-level flake8 noqa fails|ok.py|# flake8: noqa\nx = 1\n|||rc=1 $(hit 'file-level noqa' ok.py 1 '# flake8: noqa' "$R_NOQA");$(summary '' 1 0)" \
  "a per-line noqa naming its code passes|ok.py|import os  # noqa: F401 -- re-exported for the package API\n|||rc=0 $OK" \
  "the bare eslint-disable block fails|ok.ts|/* eslint-disable */\nconst x = 1;\n|||rc=1 $(hit 'blanket eslint-disable' ok.ts 1 '/* eslint-disable */' "$R_ESLINT");$(summary '' 1 0)" \
  "eslint-disable naming its rule passes|ok.ts|/* eslint-disable no-console -- CLI entry point logs by design */\nconsole.log(1);\n|||rc=0 $OK" \
  "nolint:all fails|ok.go|package main //nolint:all\n|||rc=1 $(hit 'blanket nolint' ok.go 1 'package main //nolint:all' "$R_NOLINT");$(summary '' 1 0)" \
  "a bare nolint fails|ok.go|package main //nolint\n|||rc=1 $(hit 'blanket nolint' ok.go 1 'package main //nolint' "$R_NOLINT");$(summary '' 1 0)" \
  "nolint naming its linter with a reason passes|ok.go|package main //nolint:gosec // fixture path is test-local\n|||rc=0 $OK" \
  "biome-ignore-all fails even fully qualified: file scope is the offense|ok.ts|// biome-ignore-all lint/style/noVar: legacy file\nvar x = 1;\n|||rc=1 $(hit 'file-wide biome-ignore-all' ok.ts 1 '// biome-ignore-all lint/style/noVar: legacy file' "$R_ALL");$(summary '' 1 0)" \
  "biome scans beyond the JS family: the css file-wide form fails|ok.css|/* biome-ignore-all lint: legacy sheet */\nbody { color: red; }\n|||rc=1 $(hit 'file-wide biome-ignore-all' ok.css 1 '/* biome-ignore-all lint: legacy sheet */' "$R_ALL");$(summary '' 1 0)" \
  "a longer word beginning with the directive is not it|ok.ts|// biome-ignore-allowed: a note, not a directive\nconst w = 1;\n|||rc=0 $OK" \
  "a bare biome-ignore-start fails|ok.ts|// biome-ignore-start\nconst y = 1;\n|||rc=1 $(hit 'unscoped biome-ignore-start' ok.ts 1 '// biome-ignore-start' "$R_START");$(summary '' 1 0)" \
  "the block-comment bare start fails too|ok.ts|/* biome-ignore-start */\nconst y = 1;\n|||rc=1 $(hit 'unscoped biome-ignore-start' ok.ts 1 '/* biome-ignore-start */' "$R_START");$(summary '' 1 0)" \
  "a category-only start fails|ok.ts|// biome-ignore-start lint: sweep\nconst y = 1;\n|||rc=1 $(hit 'unscoped biome-ignore-start' ok.ts 1 '// biome-ignore-start lint: sweep' "$R_START");$(summary '' 1 0)" \
  "a group-only start fails|ok.ts|// biome-ignore-start lint/suspicious: sweep\nconst y = 1;\n|||rc=1 $(hit 'unscoped biome-ignore-start' ok.ts 1 '// biome-ignore-start lint/suspicious: sweep' "$R_START");$(summary '' 1 0)" \
  "a region scoped to its full rule path with its end marker passes|ok.ts|// biome-ignore-start lint/suspicious/noExplicitAny: generated block\nconst z: any = 1;\n// biome-ignore-end\n|||rc=0 $OK" \
  "the category-wide per-line form fails, with the full-rule-path remedy|ok.ts|debugger; // biome-ignore lint: hush\n|||rc=1 $(hit 'blanket biome-ignore' ok.ts 1 'debugger; // biome-ignore lint: hush' "$R_IGNORE");$(summary '' 1 0)" \
  "the group-wide per-line form fails|ok.ts|debugger; // biome-ignore lint/suspicious: hush\n|||rc=1 $(hit 'blanket biome-ignore' ok.ts 1 'debugger; // biome-ignore lint/suspicious: hush' "$R_IGNORE");$(summary '' 1 0)" \
  "the per-line form naming its full rule path with a reason passes|ok.ts|const a: any = 1; // biome-ignore lint/suspicious/noExplicitAny: third-party shape\n|||rc=0 $OK" \
  "prose quoting the biome directives never fires: pathspec scope|NOTES.md|Prose naming biome-ignore-all or biome-ignore lint: shapes never fires.\n|||rc=0 $OK"

SECTION=ratchet
echo "=== the bare-allow ratchet: compound and spaced forms count once each, a reason anywhere exempts, and every direction fires ==="
run_files \
  "compound, spaced and lint-path-compound bare allows, the bare lint first or last, each count once, as NEW without a row|ok.rs|#[allow(dead_code, unused_variables)]\nfn f() {}\n#[allow( dead_code )]\nfn g() {}\n#[allow(clippy::too_many_arguments , dead_code)]\nfn h() {}\n#[allow(unused, clippy::needless_return)]\nfn i() {}\n|||rc=1 $(new ok.rs 4);$(summary '' 0 1)" \
  "a compound allow carrying a reason stays exempt|ok.rs|#[allow(dead_code, unused_variables, reason = \"both kept for the trait surface\")]\nfn f() {}\n|||rc=0 $OK" \
  "bare dead_code and unused allows fail as NEW with their count and the freeze remedy|ok.rs|${DEAD}fn f() {}\n${UNUSED_VARS}fn g() {}\n|||rc=1 $(new ok.rs 2);$(summary '' 0 1)"
two() { file "$1" ok.rs "${DEAD}fn f() {}\n${UNUSED_VARS}fn g() {}\n"; base 'ok.rs\t2\n'; } # NAME — two bare allows frozen at 2
fx_frozen() { two frozen; }
fx_grow() { two grow; put ok.rs "${DEAD}fn f() {}\n${UNUSED_VARS}fn g() {}\n${UNUSED}fn h() {}\n"; stage; }
fx_loose() { two loose; put ok.rs "${DEAD}fn f() {}\n"; stage; }
fx_loose_update() { two loose-update; put ok.rs "${DEAD}fn f() {}\n"; stage; }
fx_stale() { two stale; put ok.rs 'fn f() {}\n'; stage; }
fx_stale_update() { two stale-update; put ok.rs 'fn f() {}\n'; stage; }
fx_grown_update() { file grown-update ok.rs "${DEAD}fn f() {}\n${DEAD}fn g() {}\n"; base 'ok.rs\t1\n'; }
fx_no_baseline_update() { file no-baseline-update ok.rs 'fn f() {}\n'; }
run_rows \
  "the frozen count at exactly its row passes|fx_frozen|||rc=0 $OK|-" \
  "growth past the row fails (GROW)|fx_grow|||rc=1 $(grow ok.rs 3 2);$(summary '' 0 1)|-" \
  "a loose row fails (LOOSE): slack is a failure, not headroom|fx_loose|||rc=1 $(loose ok.rs 2 1);$(summary '' 0 1)|-" \
  "--update tightens 2 to 1, names it, and the re-check passes|fx_loose_update||--update|rc=0 tightened: ok.rs 2 -> 1;suppression-ban --update: baseline tightened at $BASE (1 row(s));$OK|baseline=ok.rs	1" \
  "a row with no bare allows left fails (STALE)|fx_stale|||rc=1 $(stale ok.rs 2);$(summary '' 0 1)|-" \
  "--update drops the stale row, names it, and leaves an empty baseline|fx_stale_update||--update|rc=0 removed: ok.rs (row 2);suppression-ban --update: baseline tightened at $BASE (0 row(s));$OK|baseline=" \
  "--update never raises: a grown count keeps its row, says why, and still fails|fx_grown_update||--update|rc=1 kept (grew 2 > 1 — growth is a hand-edit, never --update): ok.rs;suppression-ban --update: baseline tightened at $BASE (1 row(s));$(grow ok.rs 2 1);$(summary '' 0 1)|baseline=ok.rs	1" \
  "--update with no baseline writes nothing and says so|fx_no_baseline_update||--update|rc=0 suppression-ban --update: no baseline at $BASE and --update never adds rows; nothing written;$OK|baseline=absent"

SECTION=excludes
echo "=== excludes: a vendored tree is silenced with a reason, for the blanket lanes and the ratchet ==="
vendored() { file "$1" vendor/lib.rs "${BLANKET}${DEAD}fn v() {}\n"; } # NAME
fx_vendored() { vendored vendored; }
fx_vendored_row() { vendored vendored-row; put "$EXCL" 'vendor/*\tvendored third-party code\n'; stage; }
fx_vendored_no_reason() { vendored vendored-no-reason; put "$EXCL" 'vendor/*\n'; stage; }
fx_vendored_alt() { vendored vendored-alt; put alt 'vendor/*\tvendored third-party code\n'; stage; }
fx_vendored_alt_flag() { vendored vendored-alt-flag; put alt 'vendor/*\tvendored third-party code\n'; stage; }
fx_vendored_alt_miss() { vendored vendored-alt-miss; put alt 'other/*\tnot this tree\n'; stage; }
fx_flag_bare_excludes() { file flag-bare-excludes ok.rs 'fn f() {}\n'; }
fx_flag_bare_baseline() { file flag-bare-baseline ok.rs 'fn f() {}\n'; }
fx_flag_baseline_eq() { file flag-baseline-eq ok.rs "${DEAD}fn f() {}\n"; put alt.tsv 'ok.rs\t1\n'; stage; }
fx_flag_unknown() { file flag-unknown ok.rs 'fn f() {}\n'; }
fx_flag_baseline() { file flag-baseline ok.rs "${DEAD}fn f() {}\n"; put alt.tsv 'ok.rs\t1\n'; stage; }
fx_flag_baseline_env() { file flag-baseline-env ok.rs "${DEAD}fn f() {}\n"; put alt.tsv 'ok.rs\t1\n'; stage; }
run_rows \
  "control: the vendored blanket allow and its bare allow fail without a row|fx_vendored|||rc=1 $(hit 'module-wide rust allow' vendor/lib.rs 1 '#![allow(dead_code)]' "$R_RUST");$(new vendor/lib.rs 1);$(summary '' 1 1)|-" \
  "the row silences the vendored tree for the blanket lanes and the ratchet|fx_vendored_row|||rc=0 $OK|-" \
  "a row without a reason is a config error naming the line|fx_vendored_no_reason|||rc=2 ${ERR}$EXCL:1: expected 'pattern<TAB>reason' (every exclusion carries its justification)|-" \
  "the list path resolves through the environment key|fx_vendored_alt|COMMIT_GUARDS_SUPPRESSION_EXCLUDES=alt||rc=0 $OK|-" \
  "--excludes names the same list|fx_vendored_alt_flag||--excludes alt|rc=0 $OK|-" \
  "--excludes=FILE is the same flag, and the rust remedy names the list in force|fx_vendored_alt_miss||--excludes=alt|rc=1 $(hit 'module-wide rust allow' vendor/lib.rs 1 '#![allow(dead_code)]' "$(r_rust alt)");$(new vendor/lib.rs 1);$(summary '' 1 1)|-" \
  "a bare --excludes is a config error|fx_flag_bare_excludes||--excludes|rc=2 ${ERR}--excludes requires a path|-" \
  "a bare --baseline is a config error|fx_flag_bare_baseline||--baseline|rc=2 ${ERR}--baseline requires a path|-" \
  "--baseline=FILE is the same flag|fx_flag_baseline_eq||--baseline=alt.tsv|rc=0 suppression-ban: OK — no blanket suppressions, bare allows within baseline alt.tsv|-" \
  "an unknown argument is a config error quoting it|fx_flag_unknown||--no-such-flag|rc=2 ${ERR}unknown argument '--no-such-flag' (see --help)|-" \
  "--baseline names the baseline, and the verdict names it|fx_flag_baseline||--baseline alt.tsv|rc=0 suppression-ban: OK — no blanket suppressions, bare allows within baseline alt.tsv|-" \
  "the baseline path resolves through the environment key too|fx_flag_baseline_env|COMMIT_GUARDS_SUPPRESSION_BASELINE=alt.tsv||rc=0 suppression-ban: OK — no blanket suppressions, bare allows within baseline alt.tsv|-"

SECTION=inventory
echo "=== the render inventory excludes its exact paths for every lane, read from the index like the scan; a carve row beats it ==="
INV=.agents/skills/rendered/lib.rs
INV_HIT="$(hit 'module-wide rust allow' "$INV" 1 '#![allow(dead_code)]' "$R_RUST");$(new "$INV" 1);$(summary '' 1 1)"
ERR_INV="::error::generated paths: cannot read .kendex-generated.json; jq is required; install or refresh kendex at the Git repository root in the main checkout and stage the inventory with the renders"
# A render carrying a blanket allow and a bare allow, named by the inventory.
inv() { file "$1" "$INV" "${BLANKET}${DEAD}fn v() {}\n"; put .kendex-generated.json "[\"$INV\"]\n"; stage; } # NAME
fx_inv() { inv inv; }
fx_inv_owned() { inv inv-owned; put .agents/skills/owned/lib.rs "${BLANKET}fn o() {}\n"; stage; }
fx_inv_hook() { inv inv-hook; put .agents/hooks/check.py '# ruff: noqa\nx = 1\n'; stage; }
fx_inv_literal() { inv inv-literal; put .kendex-generated.json '[".agents/skills/rendered/*"]\n'; stage; }
fx_inv_suffix() { inv inv-suffix; put lib.rs "${BLANKET}fn l() {}\n"; stage; }
fx_inv_carve() { inv inv-carve; put "$EXCL" '!.agents/skills/rendered/*\tmeasure this render explicitly\n'; stage; }
fx_inv_unstaged() { inv inv-unstaged; commit; put .kendex-generated.json '[]\n'; }
fx_inv_staged() { inv inv-staged; commit; put .kendex-generated.json '[]\n'; stage; }
fx_inv_deleted() { inv inv-deleted; commit; git -C "$R" rm -q --cached .kendex-generated.json; }
fx_inv_untracked() { inv inv-untracked; git -C "$R" rm -q --cached .kendex-generated.json; }
none() { inv "$1"; git -C "$R" rm -q --cached .kendex-generated.json; rm -- "$R/.kendex-generated.json"; } # NAME
fx_inv_none() { none inv-none; }
fx_inv_none_clean() { none inv-none-clean; put "$INV" 'fn v() {}\n'; stage; }
badinv() { file "$1" ok.rs 'fn f() {}\n'; put .kendex-generated.json "$2"; stage; } # NAME JSON
fx_inv_object() { badinv inv-object '{}\n'; }
fx_inv_two() { badinv inv-two '[] []\n'; }
fx_inv_empty_path() { badinv inv-empty-path '[""]\n'; }
fx_inv_newline() { badinv inv-newline '["a\\nb"]\n'; }
fx_inv_nul() { badinv inv-nul '["a\\u0000b"]\n'; }
fx_inv_number() { badinv inv-number '[1]\n'; }
run_rows \
  "the inventoried render is left out of the blanket lanes and the ratchet|fx_inv|||rc=0 $OK|-" \
  "an in-place skill source beside it is scanned: the inventory names renders only|fx_inv_owned|||rc=1 $(hit 'module-wide rust allow' .agents/skills/owned/lib.rs 1 '#![allow(dead_code)]' "$R_RUST");$(summary '' 1 0)|-" \
  "the adopt hook home is scanned too, whatever the language|fx_inv_hook|||rc=1 $(hit 'file-level noqa' .agents/hooks/check.py 1 '# ruff: noqa' "$R_NOQA");$(summary '' 1 0)|-" \
  "an inventory entry is a literal path, never a glob|fx_inv_literal|||rc=1 $INV_HIT|-" \
  "an entry names one file, not a file sharing its name elsewhere|fx_inv_suffix|||rc=1 $(hit 'module-wide rust allow' lib.rs 1 '#![allow(dead_code)]' "$R_RUST");$(summary '' 1 0)|-" \
  "a '!' row in the excludes carves the render back into the scan|fx_inv_carve|||rc=1 $INV_HIT|-" \
  "an unstaged emptying of the inventory changes nothing: the index copy governs|fx_inv_unstaged|||rc=0 $OK|-" \
  "the staged emptying exposes the render|fx_inv_staged|||rc=1 $INV_HIT|-" \
  "an inventory staged for deletion excludes nothing, whatever the work tree holds|fx_inv_deleted|||rc=1 $INV_HIT|-" \
  "a never-tracked inventory on disk is all there is, and governs|fx_inv_untracked|||rc=0 $OK|-" \
  "no inventory anywhere excludes nothing: an all-in-place project has no renders|fx_inv_none|||rc=1 $INV_HIT|-" \
  "control: with no inventory a clean render passes|fx_inv_none_clean|||rc=0 $OK|-" \
  "an object is refused: the writer emits an array|fx_inv_object|||rc=2 jq: error (at <stdin>:1): expected an array of paths without newline or NUL;$ERR_INV|-" \
  "two documents are refused|fx_inv_two|||rc=2 jq: error (at <stdin>:1): expected one inventory;$ERR_INV|-" \
  "an empty path is refused|fx_inv_empty_path|||rc=2 jq: error (at <stdin>:1): expected an array of paths without newline or NUL;$ERR_INV|-" \
  "a path carrying a newline is refused|fx_inv_newline|||rc=2 jq: error (at <stdin>:1): expected an array of paths without newline or NUL;$ERR_INV|-" \
  "a path carrying a NUL is refused|fx_inv_nul|||rc=2 jq: error (at <stdin>:1): expected an array of paths without newline or NUL;$ERR_INV|-" \
  "a non-string entry is refused|fx_inv_number|||rc=2 jq: error (at <stdin>:1): expected an array of paths without newline or NUL;$ERR_INV|-"

SECTION=index
echo "=== the baseline comes from the index, like the scan; --update reads the work tree it rewrites ==="
committed() { file "$1" ok.rs "${DEAD}fn f() {}\n"; base 'ok.rs\t1\n'; commit; put ok.rs "${DEAD}${UNUSED}fn f() {}\n"; git -C "$R" add ok.rs; put "$BASE" 'ok.rs\t2\n'; } # NAME — growth staged, the row raised on disk only
fx_bump_unstaged() { committed bump-unstaged; }
fx_bump_staged() { committed bump-staged; git -C "$R" add "$BASE"; }
fx_deleted() { committed deleted; git -C "$R" add "$BASE"; commit freeze; git -C "$R" rm -q --cached "$BASE"; put "$BASE" 'ok.rs\t2\n'; }
fx_update_unstaged() { file update-unstaged ok.rs "${DEAD}${UNUSED}fn f() {}\n"; put also.rs "${DEAD}fn g() {}\n"; base 'ok.rs\t2\n'; commit; put "$BASE" 'also.rs\t1\nok.rs\t2\n'; }
sparse() { file "$1" ok.rs "${DEAD}fn f() {}\n"; base 'ok.rs\t1\n'; commit; rm -- "$R/$BASE"; } # NAME — tracked, absent from the work tree
fx_sparse() { sparse sparse; }
fx_sparse_update() { sparse sparse-update; }
odd() { file "$1" ok.rs 'fn f() {}\n'; put "$2" 'fn g() {}\n'; stage; } # NAME PATH — a second tracked .rs path
fx_tab_path() { odd tab-path $'a\tb.rs'; }
fx_colon_path() { odd colon-path a:b.rs; put a:b.rs "${DEAD}fn g() {}\n"; stage; }
fx_newline_path() { odd newline-path $'a\nb.rs'; }
run_rows \
  "a tracked .rs path carrying a tab is refused by name before the count|fx_tab_path|||rc=2 ${ERR}tracked path contains a tab, unrepresentable in the baseline TSV; rename the file: 'a	b.rs'|-" \
  "a path carrying a colon is counted under its whole name|fx_colon_path|||rc=1 $(new a:b.rs 1);$(summary '' 0 1)|-" \
  "a tracked .rs path carrying a newline is refused by name|fx_newline_path|||rc=2 ${ERR}tracked path contains a newline, unrepresentable in line-oriented records; rename the file: 'a;b.rs'|-" \
  "an unstaged baseline bump does not authorize staged growth|fx_bump_unstaged|||rc=1 $(grow ok.rs 2 1);$(summary '' 0 1)|-" \
  "control: staging the row alongside the growth passes|fx_bump_staged|||rc=0 $OK|-" \
  "a baseline staged for deletion freezes nothing, whatever the work tree holds|fx_deleted|||rc=1 $(new ok.rs 2);$(summary '' 0 1)|-" \
  "--update preserves an unstaged row for a still-counted file, since it rewrites the work-tree file it read|fx_update_unstaged||--update|rc=0 suppression-ban --update: baseline tightened at $BASE (2 row(s));$OK|baseline=also.rs	1~ok.rs	2" \
  "a tracked baseline absent from the work tree (a sparse checkout) is read from the index, not degraded to empty|fx_sparse|||rc=0 $OK|-" \
  "and --update refuses to rewrite it, naming the way to materialize it|fx_sparse_update||--update|rc=2 ${ERR}--update cannot rewrite an index-only baseline (sparse checkout omits $BASE); materialize it with: git update-index --no-skip-worktree -- $BASE && git checkout-index -- $BASE, then rerun|baseline=absent"

SECTION=hygiene
echo "=== baseline hygiene is enforced, not repaired silently ==="
pair() { file "$1" a.rs "${DEAD}fn f() {}\n"; put b.rs "${DEAD}fn f() {}\n"; base "$2"; } # NAME ROWS
fx_unsorted() { pair unsorted 'b.rs\t1\na.rs\t1\n'; }
fx_unsorted_update() { pair unsorted-update 'b.rs\t1\na.rs\t1\n'; }
fx_duplicate() { pair duplicate 'a.rs\t1\na.rs\t2\nb.rs\t1\n'; }
fx_word() { pair word 'a.rs\tnope\n'; }
fx_zero() { pair zero 'a.rs\t0\nb.rs\t1\n'; }
fx_no_tab() { pair no-tab 'a.rs 1\nb.rs\t1\n'; }
fx_well_formed() { pair well-formed 'a.rs\t1\nb.rs\t1\n'; }
run_rows \
  "an unsorted baseline is a config error naming the sort|fx_unsorted|||rc=2 ${ERR}$BASE: rows must be LC_ALL=C sorted (LC_ALL=C sort -o $BASE $BASE)|-" \
  "--update judges the work-tree baseline it would rewrite by the same rule, and writes nothing|fx_unsorted_update||--update|rc=2 ${ERR}$BASE: rows must be LC_ALL=C sorted (LC_ALL=C sort -o $BASE $BASE)|baseline=b.rs	1~a.rs	1" \
  "a duplicate path is a config error naming it|fx_duplicate|||rc=2 a.rs;${ERR}$BASE: duplicate path row(s) above|-" \
  "a non-numeric count is a malformed row, named with its line|fx_word|||rc=2 1:a.rs	nope;${ERR}$BASE: malformed row(s) above (expected 'path<TAB>count' with a positive count)|-" \
  "a zero count is malformed too: a row is a positive count or no row|fx_zero|||rc=2 1:a.rs	0;${ERR}$BASE: malformed row(s) above (expected 'path<TAB>count' with a positive count)|-" \
  "a row without its tab is malformed|fx_no_tab|||rc=2 1:a.rs 1;${ERR}$BASE: malformed row(s) above (expected 'path<TAB>count' with a positive count)|-" \
  "control: a well-formed sorted baseline passes|fx_well_formed|||rc=0 $OK|-"

SECTION=unmeasured
echo "=== a carrier the sniff skips is named once, counted once, and qualifies the verdict ==="
# A .rs path whose bytes carry the module-wide pragma at column 0 and a NUL
# in git's leading window: the listing forces text, so the path IS matched
# and reaches the content sniff, which is what keeps it out of the count.
fx_skipped() { file skipped ok.rs 'fn main() {}\n'; put blob.rs "\\0000\n${BLANKET}fn f() {}\n"; stage; }
fx_skipped_beside() { file skipped-beside ok.rs 'fn main() {}\n'; put blob.rs "\\0000\n${BLANKET}fn f() {}\n"; put blanket.rs "${BLANKET}fn g() {}\n"; stage; }
fx_skipped_control() { file skipped-control ok.rs 'fn main() {}\n'; put blob.rs "\n${BLANKET}fn f() {}\n"; stage; }
# The same unreadable blob reaches two of this check's scans: the module-wide
# pragma matches the blanket lane's listing and the bare attribute the
# bare-allow carrier listing. The verdict counts paths.
fx_skipped_twice() { file skipped-twice ok.rs 'fn main() {}\n'; put blob.rs "\\0000\n${BLANKET}${DEAD}fn x() {}\n"; stage; }
run_rows \
  "a clean verdict names the skipped carrier and says how many went unmeasured|fx_skipped|||rc=0 $(skip blob.rs);$OK$(unread 1)|-" \
  "a violation verdict carries the same qualifier|fx_skipped_beside|||rc=1 $(skip blob.rs);$(hit 'module-wide rust allow' blanket.rs 1 '#![allow(dead_code)]' "$R_RUST");$(summary '' 1 0)$(unread 1)|-" \
  "control: the same bytes without a NUL are read, fire on their own line, and nothing is unmeasured|fx_skipped_control|||rc=1 $(hit 'module-wide rust allow' blob.rs 2 '#![allow(dead_code)]' "$R_RUST");$(summary '' 1 0)|-" \
  "a path skipped by two lanes is named once and counted once|fx_skipped_twice|||rc=0 $(skip blob.rs);$OK$(unread 1)|-"

echo "=== the usage is answered ==="
repo help
assert_eq "--help prints the usage and exits 0" "rc=0 usage: suppression-ban [--update] [--baseline FILE] [--excludes FILE]" "$(run "" --help | cut -d';' -f1)"
assert_eq "-h is the same flag" "$(run "" --help)" "$(run "" -h)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
