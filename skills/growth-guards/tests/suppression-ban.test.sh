#!/usr/bin/env bash
# Pins for scripts/suppression-ban: every blanket lane fires with its legal
# per-line counterpart proven to pass, the bare-allow ratchet fails in all
# directions (new, grow, loose, stale), --update tightens only, baseline
# hygiene is enforced, and a broken scan is a collection error — never a
# pass.
#
# Suppression pragmas appear verbatim in fixtures below: the check is
# pathspec-scoped to language extensions, so this .sh file is never
# scanned by it.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SB="$SKILL_DIR/scripts/suppression-ban"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset GROWTH_GUARDS_SUPPRESSION_EXCLUDES GROWTH_GUARDS_SUPPRESSION_BASELINE GROWTH_GUARDS_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

new_repo() { # NAME
  R="$TMP/$1"
  mkdir -p -- "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

run_sb() { # [args...] — run in $R; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$SB" "$@" 2>&1)" || RC=$?
}

echo "=== control: a clean multi-language repo passes ==="
new_repo clean
printf 'fn main() {}\n' >"$R/ok.rs"
printf 'x = 1\n' >"$R/ok.py"
printf 'const x = 1;\n' >"$R/ok.ts"
printf 'package main\n' >"$R/ok.go"
git -C "$R" add -A
run_sb
[ "$RC" -eq 0 ] && case "$OUT" in *"suppression-ban: OK"*) true ;; *) false ;; esac \
  && ok "clean repo passes" || bad "clean repo passes" "rc=$RC out=$OUT"

echo "=== rust: module-wide inner allow fails; per-item forms stay legal ==="
printf '#![allow(dead_code)]\nfn main() {}\n' >"$R/ok.rs"
git -C "$R" add -A
run_sb
[ "$RC" -eq 1 ] && case "$OUT" in *"module-wide rust allow: ok.rs:1:"*) true ;; *) false ;; esac \
  && ok "a crate/module-wide inner allow fails, naming file:line" \
  || bad "module-wide inner allow fails" "rc=$RC out=$OUT"
case "$OUT" in *"annotate the surviving sites per line with a stated reason"*) ok "diagnostic carries the remediation" ;; *) bad "diagnostic carries the remediation" "$OUT" ;; esac

printf '#[allow(clippy::too_many_arguments)]\nfn f() {}\n' >"$R/ok.rs"
git -C "$R" add -A
run_sb
[ "$RC" -eq 0 ] && ok "a per-item outer attribute for a named lint passes" \
  || bad "per-item outer attribute passes" "rc=$RC out=$OUT"

printf '#[allow(dead_code, reason = "kept for the public API surface")]\nfn f() {}\n' >"$R/ok.rs"
git -C "$R" add -A
run_sb
[ "$RC" -eq 0 ] && ok "a dead_code allow WITH a stated reason passes (the reasoned form is the legal one)" \
  || bad "reasoned dead_code allow passes" "rc=$RC out=$OUT"

echo "=== rust ratchet: compound and spaced bare allows count; a reason anywhere exempts ==="
printf '#[allow(dead_code, unused_variables)]\nfn f() {}\n#[allow( dead_code )]\nfn g() {}\n#[allow(clippy::too_many_arguments , dead_code)]\nfn h() {}\n' >"$R/ok.rs"
git -C "$R" add -A
run_sb
[ "$RC" -eq 1 ] && case "$OUT" in *"new bare allow: ok.rs — 3 reasonless"*) true ;; *) false ;; esac \
  && ok "compound, spaced, and lint-path-compound bare allows each count once (3 reasonless)" \
  || bad "compound/spaced bare allows count" "rc=$RC out=$OUT"
printf '#[allow(dead_code, unused_variables, reason = "both kept for the trait surface")]\nfn f() {}\n' >"$R/ok.rs"
git -C "$R" add -A
run_sb
[ "$RC" -eq 0 ] && ok "a compound allow carrying a reason stays exempt" \
  || bad "compound allow with a reason is exempt" "rc=$RC out=$OUT"

echo "=== rust ratchet: bare allows fail as NEW without a baseline row ==="
printf '#[allow(dead_code)]\nfn f() {}\n#[allow(unused_variables)]\nfn g() {}\n' >"$R/ok.rs"
git -C "$R" add -A
run_sb
[ "$RC" -eq 1 ] && case "$OUT" in *"new bare allow: ok.rs — 2 reasonless"*) true ;; *) false ;; esac \
  && ok "bare dead_code/unused allows fail as NEW with their count" \
  || bad "bare allows fail as NEW" "rc=$RC out=$OUT"
case "$OUT" in *"hand-added baseline row in this diff"*) ok "NEW diagnostic names the freeze remedy" ;; *) bad "NEW diagnostic names the freeze remedy" "$OUT" ;; esac

echo "=== rust ratchet: a baseline row freezes the count; every direction fires ==="
mkdir -p -- "$R/tools"
printf 'ok.rs\t2\n' >"$R/tools/suppression-baseline.tsv"
git -C "$R" add -A
run_sb
[ "$RC" -eq 0 ] && ok "the frozen count at exactly its row passes" || bad "frozen count passes" "rc=$RC out=$OUT"

printf '#[allow(dead_code)]\nfn f() {}\n#[allow(unused_variables)]\nfn g() {}\n#[allow(unused)]\nfn h() {}\n' >"$R/ok.rs"
git -C "$R" add -A
run_sb
[ "$RC" -eq 1 ] && case "$OUT" in *"bare allows grew: ok.rs — 3 attribute(s) > baseline 2"*) true ;; *) false ;; esac \
  && ok "growth past the row fails (GROW)" || bad "growth past the row fails" "rc=$RC out=$OUT"

printf '#[allow(dead_code)]\nfn f() {}\n' >"$R/ok.rs"
git -C "$R" add -A
run_sb
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline looser than reality: ok.rs — baseline 2 > actual 1"*) true ;; *) false ;; esac \
  && ok "a loose row fails (LOOSE) — slack is a failure, not headroom" \
  || bad "loose row fails" "rc=$RC out=$OUT"

run_sb --update
[ "$RC" -eq 0 ] && [ "$(cat "$R/tools/suppression-baseline.tsv")" = "$(printf 'ok.rs\t1')" ] \
  && ok "--update tightens 2 -> 1 and the re-check passes" \
  || bad "--update tightens 2 -> 1" "rc=$RC row=$(cat "$R/tools/suppression-baseline.tsv") out=$OUT"

printf 'fn f() {}\n' >"$R/ok.rs"
git -C "$R" add -A
run_sb
[ "$RC" -eq 1 ] && case "$OUT" in *"stale baseline row: ok.rs"*) true ;; *) false ;; esac \
  && ok "a row with no bare allows left fails (STALE)" || bad "stale row fails" "rc=$RC out=$OUT"
run_sb --update
[ "$RC" -eq 0 ] && [ ! -s "$R/tools/suppression-baseline.tsv" ] \
  && ok "--update drops the stale row" || bad "--update drops the stale row" "rc=$RC out=$OUT"

echo "=== --update never raises: a grown count keeps its row and keeps failing ==="
printf '#[allow(dead_code)]\nfn f() {}\n#[allow(dead_code)]\nfn g() {}\n' >"$R/ok.rs"
printf 'ok.rs\t1\n' >"$R/tools/suppression-baseline.tsv"
git -C "$R" add tools/suppression-baseline.tsv
git -C "$R" add -A
run_sb --update
[ "$RC" -eq 1 ] && [ "$(cat "$R/tools/suppression-baseline.tsv")" = "$(printf 'ok.rs\t1')" ] \
  && case "$OUT" in *"growth is a hand-edit, never --update"*) true ;; *) false ;; esac \
  && ok "--update keeps the grown row at 1 and still exits 1" \
  || bad "--update never raises a row" "rc=$RC row=$(cat "$R/tools/suppression-baseline.tsv") out=$OUT"
printf 'fn f() {}\n' >"$R/ok.rs"
rm "$R/tools/suppression-baseline.tsv"
git -C "$R" add -A

echo "=== python: file-level noqa fails; per-line with codes passes ==="
printf '# ruff: noqa\nx = 1\n' >"$R/ok.py"
git -C "$R" add -A
run_sb
[ "$RC" -eq 1 ] && case "$OUT" in *"file-level noqa: ok.py:1:"*) true ;; *) false ;; esac \
  && ok "a file-level ruff noqa fails" || bad "file-level ruff noqa fails" "rc=$RC out=$OUT"
printf '# flake8: noqa\nx = 1\n' >"$R/ok.py"
git -C "$R" add -A
run_sb
[ "$RC" -eq 1 ] && ok "a file-level flake8 noqa fails" || bad "file-level flake8 noqa fails" "rc=$RC out=$OUT"
printf 'import os  # noqa: F401 -- re-exported for the package API\n' >"$R/ok.py"
git -C "$R" add -A
run_sb
[ "$RC" -eq 0 ] && ok "a per-line noqa naming its code passes" || bad "per-line noqa with codes passes" "rc=$RC out=$OUT"

echo "=== eslint: the bare block form fails; named rules pass ==="
printf '/* eslint-disable */\nconst x = 1;\n' >"$R/ok.ts"
git -C "$R" add -A
run_sb
[ "$RC" -eq 1 ] && case "$OUT" in *"blanket eslint-disable: ok.ts:1:"*) true ;; *) false ;; esac \
  && ok "the bare eslint-disable block fails" || bad "bare eslint-disable fails" "rc=$RC out=$OUT"
printf '/* eslint-disable no-console -- CLI entry point logs by design */\nconsole.log(1);\n' >"$R/ok.ts"
git -C "$R" add -A
run_sb
[ "$RC" -eq 0 ] && ok "eslint-disable naming its rule passes" || bad "named eslint-disable passes" "rc=$RC out=$OUT"

echo "=== go: bare nolint and nolint:all fail; a named linter passes ==="
printf 'package main //nolint:all\n' >"$R/ok.go"
git -C "$R" add -A
run_sb
[ "$RC" -eq 1 ] && case "$OUT" in *"blanket nolint: ok.go:1:"*) true ;; *) false ;; esac \
  && ok "nolint:all fails" || bad "nolint:all fails" "rc=$RC out=$OUT"
printf 'package main //nolint\n' >"$R/ok.go"
git -C "$R" add -A
run_sb
[ "$RC" -eq 1 ] && ok "bare nolint (no linter named) fails" || bad "bare nolint fails" "rc=$RC out=$OUT"
printf 'package main //nolint:gosec // fixture path is test-local\n' >"$R/ok.go"
git -C "$R" add -A
run_sb
[ "$RC" -eq 0 ] && ok "nolint naming its linter with a reason passes" || bad "named nolint passes" "rc=$RC out=$OUT"

echo "=== biome: file scope, unscoped regions, and rule-less forms fail; the full rule path passes ==="
printf '// biome-ignore-all lint/style/noVar: legacy file\nvar x = 1;\n' >"$R/ok.ts"
git -C "$R" add -A
run_sb
[ "$RC" -eq 1 ] && case "$OUT" in *"file-wide biome-ignore-all: ok.ts:1:"*) true ;; *) false ;; esac \
  && ok "biome-ignore-all fails even fully qualified — file scope is the offense" \
  || bad "biome-ignore-all fails" "rc=$RC out=$OUT"
printf '/* biome-ignore-all lint: legacy sheet */\nbody { color: red; }\n' >"$R/ok.css"
git -C "$R" add -A
run_sb
[ "$RC" -eq 1 ] && case "$OUT" in *"file-wide biome-ignore-all: ok.css:1:"*) true ;; *) false ;; esac \
  && ok "biome scans beyond the JS family: the css file-wide form fails" \
  || bad "css biome-ignore-all fails" "rc=$RC out=$OUT"
printf 'body { color: red; }\n' >"$R/ok.css"

printf '// biome-ignore-start\nconst y = 1;\n' >"$R/ok.ts"
git -C "$R" add -A
run_sb
[ "$RC" -eq 1 ] && case "$OUT" in *"unscoped biome-ignore-start: ok.ts:1:"*) true ;; *) false ;; esac \
  && ok "a bare biome-ignore-start (no rule path) fails" || bad "bare biome-ignore-start fails" "rc=$RC out=$OUT"
printf '/* biome-ignore-start */\nconst y = 1;\n' >"$R/ok.ts"
git -C "$R" add -A
run_sb
[ "$RC" -eq 1 ] && case "$OUT" in *"unscoped biome-ignore-start: ok.ts:1:"*) true ;; *) false ;; esac \
  && ok "the block-comment bare start fails too" || bad "block-comment bare start fails" "rc=$RC out=$OUT"
printf '// biome-ignore-start lint: sweep\nconst y = 1;\n' >"$R/ok.ts"
git -C "$R" add -A
run_sb
[ "$RC" -eq 1 ] && case "$OUT" in *"unscoped biome-ignore-start: ok.ts:1:"*) true ;; *) false ;; esac \
  && ok "a category-only start (lint, no rule path) fails" || bad "category-only start fails" "rc=$RC out=$OUT"
printf '// biome-ignore-start lint/suspicious: sweep\nconst y = 1;\n' >"$R/ok.ts"
git -C "$R" add -A
run_sb
[ "$RC" -eq 1 ] && ok "a group-only start (no rule) fails" || bad "group-only start fails" "rc=$RC out=$OUT"
printf '// biome-ignore-start lint/suspicious/noExplicitAny: generated block\nconst z: any = 1;\n// biome-ignore-end\n' >"$R/ok.ts"
git -C "$R" add -A
run_sb
[ "$RC" -eq 0 ] && ok "a region scoped to its full rule path (and its end marker) passes" \
  || bad "rule-scoped region passes" "rc=$RC out=$OUT"

printf 'debugger; // biome-ignore lint: hush\n' >"$R/ok.ts"
git -C "$R" add -A
run_sb
[ "$RC" -eq 1 ] && case "$OUT" in *"blanket biome-ignore: ok.ts:1:"*) true ;; *) false ;; esac \
  && ok "the category-wide per-line form (lint, no group, no rule) fails" \
  || bad "category-wide biome-ignore fails" "rc=$RC out=$OUT"
case "$OUT" in *"name the full rule path"*) ok "diagnostic carries the full-rule-path remedy" ;; *) bad "diagnostic carries the full-rule-path remedy" "$OUT" ;; esac
printf 'debugger; // biome-ignore lint/suspicious: hush\n' >"$R/ok.ts"
git -C "$R" add -A
run_sb
[ "$RC" -eq 1 ] && ok "the group-wide per-line form (group, no rule) fails" \
  || bad "group-wide biome-ignore fails" "rc=$RC out=$OUT"
printf 'const a: any = 1; // biome-ignore lint/suspicious/noExplicitAny: third-party shape\n' >"$R/ok.ts"
git -C "$R" add -A
run_sb
[ "$RC" -eq 0 ] && ok "the per-line form naming its full rule path with a reason passes" \
  || bad "fully qualified per-line biome-ignore passes" "rc=$RC out=$OUT"
printf 'Prose naming biome-ignore-all or biome-ignore lint: shapes never fires.\n' >"$R/NOTES.md"
git -C "$R" add -A
run_sb
[ "$RC" -eq 0 ] && ok "prose quoting the biome directives never fires (pathspec scope)" \
  || bad "prose mention does not fire" "rc=$RC out=$OUT"

echo "=== excludes: vendored trees, reason mandatory ==="
new_repo exc
mkdir -p -- "$R/vendor" "$R/tools"
printf '#![allow(dead_code)]\nfn v() {}\n' >"$R/vendor/lib.rs"
git -C "$R" add -A
run_sb
[ "$RC" -eq 1 ] && ok "control: the vendored blanket allow fails without an excludes row" \
  || bad "control: vendored blanket fails without excludes" "rc=$RC out=$OUT"
printf 'vendor/*\tvendored third-party code\n' >"$R/tools/suppression-ban-excludes"
git -C "$R" add -A
run_sb
[ "$RC" -eq 0 ] && ok "the excludes row silences the vendored tree (blanket and ratchet)" \
  || bad "excludes row silences the vendored tree" "rc=$RC out=$OUT"
printf 'vendor/*\n' >"$R/tools/suppression-ban-excludes"
git -C "$R" add -A
run_sb
[ "$RC" -eq 2 ] && ok "a pattern without a reason is exit 2" || bad "pattern without a reason is exit 2" "rc=$RC out=$OUT"

echo "=== the baseline comes from the index, like the scan ==="
new_repo indexed-baseline
mkdir -p -- "$R/tools"
printf '#[allow(dead_code)]\nfn f() {}\n' >"$R/ok.rs"
printf 'ok.rs\t1\n' >"$R/tools/suppression-baseline.tsv"
git -C "$R" add -A
git -C "$R" commit -q -m seed
printf '#[allow(dead_code)]\n#[allow(unused)]\nfn f() {}\n' >"$R/ok.rs"
git -C "$R" add ok.rs
# Raised on disk only: the commit still carries the row of 1.
printf 'ok.rs\t2\n' >"$R/tools/suppression-baseline.tsv"
run_sb
[ "$RC" -eq 1 ] && ok "an unstaged baseline bump does not authorize staged growth" \
  || bad "unstaged baseline bump rejected" "rc=$RC out=$OUT"
git -C "$R" add tools/suppression-baseline.tsv
run_sb
[ "$RC" -eq 0 ] && ok "control: staging the row alongside the growth passes" \
  || bad "staged baseline row passes" "rc=$RC out=$OUT"
git -C "$R" commit -q -m "chore: freeze"
git -C "$R" rm -q --cached tools/suppression-baseline.tsv
printf 'ok.rs\t2\n' >"$R/tools/suppression-baseline.tsv"
run_sb
[ "$RC" -eq 1 ] && ok "a baseline staged for deletion freezes nothing" \
  || bad "staged baseline deletion" "rc=$RC out=$OUT"

new_repo update-unstaged
mkdir -p -- "$R/tools"
printf '#[allow(dead_code)]\n#[allow(unused)]\nfn f() {}\n' >"$R/ok.rs"
printf '#[allow(dead_code)]\nfn g() {}\n' >"$R/also.rs"
printf 'ok.rs\t2\n' >"$R/tools/suppression-baseline.tsv"
git -C "$R" add -A
git -C "$R" commit -q -m seed
# An unstaged row for a file that IS still counted: --update rewrites the
# worktree file, so it has to read the worktree file, or the row vanishes and
# its file becomes a new violation.
printf 'also.rs\t1\nok.rs\t2\n' >"$R/tools/suppression-baseline.tsv"
run_sb --update
[ "$RC" -eq 0 ] && ok "--update preserves an unstaged row for a still-counted file" \
  || bad "--update preserves unstaged rows" "rc=$RC row=$(cat "$R/tools/suppression-baseline.tsv") out=$OUT"
case "$(cat "$R/tools/suppression-baseline.tsv")" in
  *also.rs*) ok "and the row is still in the file it rewrote" ;;
  *) bad "unstaged row survives --update" "got: $(cat "$R/tools/suppression-baseline.tsv")" ;;
esac

echo "=== baseline hygiene is enforced, not repaired silently ==="
new_repo hygiene
printf '#[allow(dead_code)]\nfn f() {}\n' >"$R/a.rs"
printf '#[allow(dead_code)]\nfn f() {}\n' >"$R/b.rs"
mkdir -p -- "$R/tools"
printf 'b.rs\t1\na.rs\t1\n' >"$R/tools/suppression-baseline.tsv"
git -C "$R" add -A
run_sb
[ "$RC" -eq 2 ] && case "$OUT" in *"LC_ALL=C sorted"*) true ;; *) false ;; esac \
  && ok "unsorted baseline is exit 2" || bad "unsorted baseline is exit 2" "rc=$RC out=$OUT"
printf 'a.rs\t1\na.rs\t2\nb.rs\t1\n' >"$R/tools/suppression-baseline.tsv"
git -C "$R" add tools/suppression-baseline.tsv
run_sb
[ "$RC" -eq 2 ] && case "$OUT" in *"duplicate"*) true ;; *) false ;; esac \
  && ok "duplicate baseline path is exit 2" || bad "duplicate baseline path is exit 2" "rc=$RC out=$OUT"
printf 'a.rs\tnope\n' >"$R/tools/suppression-baseline.tsv"
git -C "$R" add tools/suppression-baseline.tsv
run_sb
[ "$RC" -eq 2 ] && case "$OUT" in *"malformed row"*) true ;; *) false ;; esac \
  && ok "non-numeric baseline count is exit 2" || bad "non-numeric count is exit 2" "rc=$RC out=$OUT"
printf 'a.rs\t1\nb.rs\t1\n' >"$R/tools/suppression-baseline.tsv"
git -C "$R" add tools/suppression-baseline.tsv
run_sb
[ "$RC" -eq 0 ] && ok "well-formed sorted baseline passes (control for the hygiene gates)" \
  || bad "well-formed baseline passes" "rc=$RC out=$OUT"

echo "=== fail-closed: a broken scan terminates, never passes ==="
REAL_GIT="$(command -v git)"
GIT_SHIM="$TMP/git-shim"
mkdir -p "$GIT_SHIM"
cat >"$GIT_SHIM/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "grep" ]; then
    echo "git grep: simulated execution failure" >&2
    exit 128
  fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GIT_SHIM/git"
OUT="$(cd "$R" && PATH="$GIT_SHIM:$PATH" "$SB" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"git grep failed"*) true ;; *) false ;; esac \
  && ok "a git grep execution failure is a collection error: exit 2" \
  || bad "a git grep execution failure is a collection error" "rc=$RC out=$OUT"
case "$OUT" in *"suppression-ban: OK"*) bad "no OK verdict may accompany a broken scan" "$OUT" ;; *) ok "no OK verdict accompanies the broken scan" ;; esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
