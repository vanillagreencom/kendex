#!/usr/bin/env bash
# Pins for the REPOINTED verdict: a commit that points SIZE_RATCHET_BASELINE
# somewhere else. These live apart from ratchet-directions.test.sh because
# they are one concept with its own fixtures, and because that file reached
# its size class. Both files run the same binary against the same helpers.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SR="$SKILL_DIR/scripts/size-ratchet"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hermetic: a leaked setting would mask every case below.
unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_CLASSES SIZE_RATCHET_DEFAULT_CLASSES SIZE_RATCHET_FROZEN_CLASSES SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE RATCHET_RAISE 2>/dev/null || true
export SIZE_RATCHET_DEFAULT_CLASSES="" SIZE_RATCHET_FROZEN_CLASSES=""

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

new_repo() { # NAME — fresh fixture repo in $R
  R="$TMP/$1"
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

mkfile() { # PATH LINES — file of LINES lines under $R
  mkdir -p "$R/$(dirname "$1")"
  awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) print "line " i }' >"$R/$1"
}

# The same run as the directions suite: threshold 10, `*.test.*` frozen, and
# RAISE=1 declaring the raise the way a commit does.
run_frozen() { # [args...]
  OUT=""
  RC=0
  OUT="$(cd "$R" && SIZE_RATCHET_THRESHOLD=10 SIZE_RATCHET_FROZEN_CLASSES='*.test.*' RATCHET_RAISE="${RAISE:-}" "$SR" "$@" 2>&1)" || RC=$?
}

settings_baseline() { # PATH — the fixture's committed settings name it
  printf '[env]\nSIZE_RATCHET_BASELINE = "%s"\n' "$1" >"$R/kendex.settings.toml"
}
relocating_repo() { # NAME PATH LINES ROWLINES — HEAD's rows at tools/a.tsv
  new_repo "$1"
  mkdir -p "$R/tools"
  mkfile "$2" "$3"
  printf '%s\t%s\n' "$2" "$4" >"$R/tools/a.tsv"
  settings_baseline tools/a.tsv
  git -C "$R" add -A
  git -C "$R" commit -q -m "seed: a baselined offender, baseline at tools/a.tsv"
}

echo "=== a commit that REPOINTS the baseline, old file left tracked, is refused ==="
# COPY the rows to a new path instead of moving them and the old file stays
# tracked with its rows, so nothing lost a row set and the move scan above
# names nothing — while the raise gate reads HEAD at the NEW path, finds no
# rows, and judges none. That is exit 0 with a frozen row raised, so the shape
# is refused on its own.
copy_repoint() { # PATH ROWLINES — rows COPIED to tools/b.tsv; tools/a.tsv stays
  printf '%s\t%s\n' "$1" "$2" >"$R/tools/b.tsv"
  settings_baseline tools/b.tsv
  git -C "$R" add -A
}
relocating_repo copyfrozen x.test.txt 15 15
mkfile x.test.txt 20
copy_repoint x.test.txt 20
RAISE=1 run_frozen
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline repointed and rewritten: tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "a frozen row raised across a copy-and-repoint is refused, declaration and all" \
  || bad "a frozen raise across a copy-and-repoint is refused" "rc=$RC out=$OUT"
# The premise of the whole case: this is NOT the move above. The old baseline
# is still tracked, still holding its rows, so nothing lost a row set.
[ "$(git -C "$R" show :tools/a.tsv)" = "$(printf 'x.test.txt\t15')" ] \
  && ok "and the old baseline really is still tracked with its rows, so no move was named" \
  || bad "the old baseline is still tracked with its rows" "$(git -C "$R" show :tools/a.tsv)"
case "$OUT" in *"repoint the baseline in a commit that changes nothing else"*) ok "and the refusal says what to do instead" ;; *) bad "the repoint refusal names its remedy" "$OUT" ;; esac
# The open class takes the same refusal, declared or not: across a repoint
# there is nothing to compare, so no declaration can carry it.
relocating_repo copyopen plain.txt 15 15
mkfile plain.txt 20
copy_repoint plain.txt 20
run_frozen
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline repointed and rewritten: tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "an unfrozen row raised across a copy-and-repoint is refused undeclared" \
  || bad "an unfrozen raise across a copy-and-repoint is refused undeclared" "rc=$RC out=$OUT"
RAISE=1 run_frozen
[ "$RC" -eq 1 ] && ok "and the declaration does not carry it, where in place it would" \
  || bad "the declaration does not carry a raise across a copy-and-repoint" "rc=$RC out=$OUT"
# The staged lane reads the index, and a commit is what it judges.
relocating_repo copystaged s.test.txt 15 15
mkfile s.test.txt 20
copy_repoint s.test.txt 20
RAISE=1 run_frozen --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline repointed and rewritten: tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "the staged lane refuses the same copy-and-repoint" \
  || bad "the staged lane refuses the same copy-and-repoint" "rc=$RC out=$OUT"
# A copy that carries the rows unchanged passes: those bytes are HEAD's own
# rows, so no row rose to reach them.
relocating_repo copyunchanged x.test.txt 15 15
copy_repoint x.test.txt 15
run_frozen
[ "$RC" -eq 0 ] && ok "control: a copy-and-repoint that carries the rows unchanged passes" \
  || bad "a copy-and-repoint carrying the rows unchanged passes" "rc=$RC out=$OUT"
# The control that the refusal is about the REPOINT and not about any new
# row-shaped file: the same raise, the same second file, the setting left
# alone. That is an ordinary in-place raise and must report as one.
relocating_repo copynorepoint x.test.txt 15 15
mkfile x.test.txt 20
printf 'x.test.txt\t20\n' >"$R/tools/b.tsv"
printf 'x.test.txt\t20\n' >"$R/tools/a.tsv"
git -C "$R" add -A
RAISE=1 run_frozen
[ "$RC" -eq 1 ] && case "$OUT" in *"frozen baseline row raised: x.test.txt — row 15 -> 20 lines"*) true ;; *) false ;; esac \
  && ok "control: the same raise without the repoint is judged in place, not refused as one" \
  || bad "the same raise without the repoint is judged in place" "rc=$RC out=$OUT"
# The boundary this refusal accepts: it cannot ask which file HEAD's settings
# named, so a first baseline introduced beside an UNRELATED row-shaped file
# reads as a repoint and is refused. Fail-closed, and the remedy carries it.
new_repo copyunrelatedrows
mkdir -p "$R/tools"
mkfile x.test.txt 5
printf 'counts/thing\t3\n' >"$R/data.tsv"
git -C "$R" add -A
git -C "$R" commit -q -m "seed: no baseline, one unrelated row-shaped file"
mkfile x.test.txt 15
printf 'x.test.txt\t15\n' >"$R/tools/b.tsv"
settings_baseline tools/b.tsv
git -C "$R" add -A
run_frozen
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline repointed and rewritten: tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "a row set HEAD holds elsewhere makes a first baseline read as a repoint, and it fails closed" \
  || bad "an unrelated HEAD row set makes a first baseline fail closed" "rc=$RC out=$OUT"
# Matching just any blob HEAD carries proves nothing about the rows being
# replaced. Here an UNRELATED tracked file already holds the raised rows byte
# for byte, so an escape asking "is this some HEAD blob?" answers yes and
# launders the very raise this refuses. Two row sets at HEAD is ambiguous, and
# ambiguity fails closed.
new_repo copycollision
mkdir -p "$R/tools"
mkfile x.test.txt 15
printf 'x.test.txt\t15\n' >"$R/tools/a.tsv"
printf 'x.test.txt\t20\n' >"$R/data.tsv"
settings_baseline tools/a.tsv
git -C "$R" add -A
git -C "$R" commit -q -m "seed: baseline row 15, and an unrelated row set already holding 20"
mkfile x.test.txt 20
printf 'x.test.txt\t20\n' >"$R/tools/b.tsv"
settings_baseline tools/b.tsv
git -C "$R" add -A
# The premise: the candidate really is byte-identical to a blob HEAD carries.
[ "$(git -C "$R" show :tools/b.tsv)" = "$(git -C "$R" show HEAD:data.tsv)" ] \
  && ok "the candidate is byte-identical to an unrelated blob HEAD carries, which is the trap" \
  || bad "the candidate matches an unrelated HEAD blob" "$(git -C "$R" show :tools/b.tsv)"
RAISE=1 run_frozen
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline repointed and rewritten: tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "a candidate matching an unrelated HEAD blob does not escape the refusal" \
  || bad "a candidate matching an unrelated HEAD blob does not escape" "rc=$RC out=$OUT"

# The resolver honours `./x`, `sub/../x` and `a/b/../../x` as the same source
# (lib/settings.sh, sr_settings_normalize_path), and git records none of them.
# A refusal comparing the raw spelling against the index sees no settings
# change at all, so a repoint through an alias walks straight past it.
#
# --staged, because that is the lane staged-scope.test.sh pins these spellings
# in: it resolves a source through the INDEX by normalized path, so a spelling
# whose intermediate directory does not exist still names the committed file.
run_aliased() { # SETTINGS-FILE-SPELLING
  OUT=""
  RC=0
  OUT="$(cd "$R" && SIZE_RATCHET_THRESHOLD=10 SIZE_RATCHET_FROZEN_CLASSES='*.test.*' \
    SIZE_RATCHET_SETTINGS_FILE="$1" RATCHET_RAISE=1 "$SR" --staged 2>&1)" || RC=$?
}
relocating_repo copyaliased x.test.txt 15 15
mkfile x.test.txt 20
copy_repoint x.test.txt 20
for spelling in "./kendex.settings.toml" "sub/../kendex.settings.toml" "a/b/../../kendex.settings.toml"; do
  run_aliased "$spelling"
  [ "$RC" -eq 1 ] && case "$OUT" in *"baseline repointed and rewritten: tools/b.tsv"*) true ;; *) false ;; esac \
    && ok "a repoint named through '$spelling' is still refused" \
    || bad "a repoint named through '$spelling' is refused" "rc=$RC out=$OUT"
  # …and the spelling really was the source that answered: the run resolved
  # its baseline THROUGH that file, so the refusal is about the same repoint
  # and not a settings read that quietly fell back to the built-in default.
  case "$OUT" in *"baseline tools/b.tsv"*) ok "and '$spelling' is the source the run actually read" ;; *) bad "'$spelling' is the source the run read" "$OUT" ;; esac
done
# The control that the canonical spelling was never the thing being tested.
run_aliased "kendex.settings.toml"
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline repointed and rewritten: tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "control: the canonical spelling is refused the same way" \
  || bad "control: the canonical spelling is refused" "rc=$RC out=$OUT"

# Narrowing the HEAD scan with `git grep -I` let a consumer's .gitattributes
# decide which files are text: `*.tsv binary` hid the baseline, the scan saw
# no row set, the refusal took its bootstrap arm, and the repoint landed.
relocating_repo copybinaryattr x.test.txt 15 15
printf '*.tsv binary\n' >"$R/.gitattributes"
git -C "$R" add -A
git -C "$R" commit -q -m "the baseline, now marked binary"
case "$(git -C "$R" check-attr binary -- tools/a.tsv)" in
  *"binary: set"*) ok "the fixture really does mark the baseline binary, which is the premise" ;;
  *) bad "the fixture marks the baseline binary" "$(git -C "$R" check-attr binary -- tools/a.tsv)" ;;
esac
mkfile x.test.txt 20
copy_repoint x.test.txt 20
RAISE=1 run_frozen --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline repointed and rewritten: tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "a baseline marked binary is still found by the HEAD scan" \
  || bad "a baseline marked binary is still found by the HEAD scan" "rc=$RC out=$OUT"


# A repoint onto a destination that ALREADY carried rows of its own. Nothing
# is deleted, so no row set disappears and the move scan names nothing; and
# because the destination has rows, the raise gate has a reference — a
# STRANGER'S. HEAD's real baseline said 15, the destination's own row said 20,
# and the raise read as grandfathered at exit 0.
new_repo repointpreexisting
mkdir -p "$R/tools"
mkfile x.test.txt 15
printf 'x.test.txt\t15\n' >"$R/tools/a.tsv"
printf 'x.test.txt\t20\n' >"$R/tools/b.tsv"
settings_baseline tools/a.tsv
git -C "$R" add -A
git -C "$R" commit -q -m "seed: active baseline a.tsv=15, an unrelated b.tsv=20 beside it"
mkfile x.test.txt 20
settings_baseline tools/b.tsv
git -C "$R" add -A
# The premise, and what separates this from the relocpreexisting case in the
# directions suite: the old baseline is NOT deleted, so baseline_moved has
# nothing to name and this verdict is the only thing standing between the
# commit and a laundered raise.
[ "$(git -C "$R" show :tools/a.tsv)" = "$(printf 'x.test.txt\t15')" ] \
  && ok "the old baseline is still tracked and unchanged, so no move is named" \
  || bad "the old baseline is still tracked and unchanged" "$(git -C "$R" show :tools/a.tsv)"
RAISE=1 run_frozen --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline repointed and rewritten: tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "a repoint onto a destination that already carried rows is refused" \
  || bad "a repoint onto a pre-existing destination is refused" "rc=$RC out=$OUT"
# …and the worktree lane says the same of the same tree.
RAISE=1 run_frozen
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline repointed and rewritten: tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "and the worktree lane refuses it too" \
  || bad "the worktree lane refuses a pre-existing destination" "rc=$RC out=$OUT"
# The control that rows at the configured path are still an ORDINARY run: the
# same settings file touched, the baseline left where it is, the frozen row
# raised in place. That must read as a raise, not as a repoint.
relocating_repo repointinplace x.test.txt 15 15
mkfile x.test.txt 20
printf 'x.test.txt\t20\n' >"$R/tools/a.tsv"
settings_baseline tools/a.tsv
printf '[env]\nSIZE_RATCHET_BASELINE = "tools/a.tsv"\n# touched\n' >"$R/kendex.settings.toml"
git -C "$R" add -A
RAISE=1 run_frozen
[ "$RC" -eq 1 ] && case "$OUT" in *"frozen baseline row raised: x.test.txt — row 15 -> 20 lines"*) true ;; *) false ;; esac \
  && ok "control: a settings touch with the baseline still in place is an ordinary raise" \
  || bad "control: rows at the configured path stay an ordinary raise" "rc=$RC out=$OUT"


# count_nonempty_lines exits loudly when grep cannot read a file, but that exit
# ends only the command substitution it runs in. The outer shell survives with
# an EMPTY capture, and a test reading that capture directly takes its false
# arm — which is the arm that skips the repoint check. An unreadable file would
# have waved through the very commit this suite exists to refuse.
#
# No CLI input reaches that line with an unreadable file: $TMP/moved.tsv is
# written by the script into its own mktemp directory moments before the read,
# and a caller's unreadable baseline is refused earlier by validate_baseline_rows.
# So the failure is injected where a permission or I/O error would land — a grep
# on PATH that fails for moved.tsv alone and defers to the real grep for
# everything else. The script under test is the shipped one, unmodified, and
# moved.tsv is read at exactly one place in it.
mkdir -p "$TMP/shim"
cat >"$TMP/shim/grep" <<'SHIM'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    */moved.tsv) echo "grep: $a: Permission denied" >&2; exit 2 ;;
  esac
done
exec "$SR_REAL_GREP" "$@"
SHIM
chmod +x "$TMP/shim/grep"
REAL_GREP="$(command -v grep)"
# A copy-and-repoint raising a frozen row: refused when the count is trusted,
# and silently admitted when a failed count reads as zero.
relocating_repo repointcountguard x.test.txt 15 15
mkfile x.test.txt 20
copy_repoint x.test.txt 20
OUT=""
RC=0
OUT="$(cd "$R" && PATH="$TMP/shim:$PATH" SR_REAL_GREP="$REAL_GREP" \
  SIZE_RATCHET_THRESHOLD=10 SIZE_RATCHET_FROZEN_CLASSES='*.test.*' RATCHET_RAISE=1 \
  "$SR" --staged 2>&1)" || RC=$?
# The injection really happened: the shim's own line proves grep failed, so a
# green result here cannot come from the failure never being induced.
case "$OUT" in *"moved.tsv: Permission denied"*) ok "the injected read failure really fired at the guarded count" ;; *) bad "the injected read failure fired" "$OUT" ;; esac
[ "$RC" -eq 2 ] && case "$OUT" in *"could not count what the move scan reported"*) true ;; *) false ;; esac \
  && ok "a count that cannot be read exits loudly instead of skipping the repoint check" \
  || bad "an unreadable count exits loudly" "rc=$RC out=$OUT"
# The control that the shim is what did it: the same tree, the same run, no
# shim on PATH, reaches the ordinary refusal.
RAISE=1 run_frozen --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline repointed and rewritten: tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "control: without the shim the same tree gets the ordinary refusal" \
  || bad "control: the same tree without the shim is refused normally" "rc=$RC out=$OUT"


# The same swallowed exit one level down. blob_is_row_set counts the lines of
# each candidate HEAD blob; an unguarded count answers "not a row set" for a
# file it never read, count_head_row_sets takes that with `|| continue`, and
# HEAD's real baseline drops out. The count falls from one to zero, the repoint
# check takes its BOOTSTRAP arm, and the commit passes.
#
# $TMP/rowish.blob is written and read at exactly one place in the script, so
# failing grep for that name alone lands on the guarded site and nowhere else.
# It is reused across loop iterations, which does not matter here: the first
# unreadable candidate is the one that has to be loud.
mkdir -p "$TMP/shim2"
cat >"$TMP/shim2/grep" <<'SHIM'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    */rowish.blob) echo "grep: $a: Permission denied" >&2; exit 2 ;;
  esac
done
exec "$SR_REAL_GREP" "$@"
SHIM
chmod +x "$TMP/shim2/grep"
REAL_GREP2="$(command -v grep)"
relocating_repo repointrowsetguard x.test.txt 15 15
mkfile x.test.txt 20
copy_repoint x.test.txt 20
OUT=""
RC=0
OUT="$(cd "$R" && PATH="$TMP/shim2:$PATH" SR_REAL_GREP="$REAL_GREP2" \
  SIZE_RATCHET_THRESHOLD=10 SIZE_RATCHET_FROZEN_CLASSES='*.test.*' RATCHET_RAISE=1 \
  "$SR" --staged 2>&1)" || RC=$?
case "$OUT" in *"rowish.blob: Permission denied"*) ok "the injected read failure really fired inside the row-set scan" ;; *) bad "the injected read failure fired in the row-set scan" "$OUT" ;; esac
[ "$RC" -eq 2 ] && case "$OUT" in *"to tell whether it holds baseline rows"*) true ;; *) false ;; esac \
  && ok "a candidate blob that cannot be counted exits loudly instead of dropping out" \
  || bad "an uncountable candidate blob exits loudly" "rc=$RC out=$OUT"
# The control that the shim is what did it, and that this tree is otherwise a
# refusal rather than a pass — so the red above is the guard, not the fixture.
RAISE=1 run_frozen --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline repointed and rewritten: tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "control: without the shim the same tree gets the ordinary refusal" \
  || bad "control: the row-set tree without the shim is refused normally" "rc=$RC out=$OUT"


# A SYMLINKED settings source. The match against changed paths is lexical, so
# it names the LINK while the resolver reads through to the target: a commit
# rewriting the target changed the effective settings, matched nothing here,
# and the repoint sailed past at exit 0.
#
# All four spellings run against ONE tree. A lone symlink case would prove
# nothing — the two direct arms are what show a refusal is about the symlink
# and not about the fixture.
symlink_repo() { # NAME — copy-and-repoint raising a frozen row, settings at
                 # config/settings.toml with a settings-link beside it
  new_repo "$1"
  mkdir -p "$R/tools" "$R/config"
  mkfile x.test.txt 15
  printf 'x.test.txt\t15\n' >"$R/tools/a.tsv"
  printf '[env]\nSIZE_RATCHET_BASELINE = "tools/a.tsv"\n' >"$R/config/settings.toml"
  ( cd "$R" && ln -sf config/settings.toml settings-link )
  git -C "$R" add -A
  git -C "$R" commit -q -m "seed: settings at config/settings.toml, a settings-link beside it"
  mkfile x.test.txt 20
  printf 'x.test.txt\t20\n' >"$R/tools/b.tsv"
  printf '[env]\nSIZE_RATCHET_BASELINE = "tools/b.tsv"\n' >"$R/config/settings.toml"
  git -C "$R" add -A
}
run_source() { # SETTINGS-FILE-SPELLING [lane args...]
  local spelling="$1"; shift
  OUT=""
  RC=0
  OUT="$(cd "$R" && SIZE_RATCHET_SETTINGS_FILE="$spelling" SIZE_RATCHET_THRESHOLD=10 \
    SIZE_RATCHET_FROZEN_CLASSES='*.test.*' RATCHET_RAISE=1 "$SR" "$@" 2>&1)" || RC=$?
}
# The premise: settings-link really is a symlink whose target is the file the
# commit rewrites, so the lexical name and the effective file differ.
symlink_repo symdirectrel
[ -L "$R/settings-link" ] && [ "$(readlink "$R/settings-link")" = "config/settings.toml" ] \
  && ok "the fixture's settings-link really points at the file the commit rewrites" \
  || bad "settings-link points at config/settings.toml" "$(readlink "$R/settings-link" 2>&1)"
run_source "config/settings.toml" --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline repointed and rewritten: tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "control: the direct relative spelling is refused" \
  || bad "control: direct relative spelling refused" "rc=$RC out=$OUT"
symlink_repo symdirectabs
run_source "$R/config/settings.toml" --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline repointed and rewritten: tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "control: the direct absolute spelling is refused" \
  || bad "control: direct absolute spelling refused" "rc=$RC out=$OUT"
symlink_repo symrel
run_source "settings-link" --staged
[ "$RC" -ne 0 ] \
  && ok "the relative symlink spelling is refused" \
  || bad "the relative symlink spelling is refused" "rc=$RC out=$OUT"
symlink_repo symabs
run_source "$R/settings-link" --staged
[ "$RC" -ne 0 ] && case "$OUT" in *"baseline repointed and rewritten: tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "the absolute symlink spelling is refused, where it used to pass" \
  || bad "the absolute symlink spelling is refused" "rc=$RC out=$OUT"
# The worktree lane has no tracked-symlink refusal in front of it, so every
# symlinked source reaches this check there — including the DEFAULT name.
symlink_repo symrelwork
run_source "settings-link"
[ "$RC" -ne 0 ] \
  && ok "and the worktree lane refuses the relative symlink too" \
  || bad "the worktree lane refuses a relative symlink source" "rc=$RC out=$OUT"
new_repo symdefault
mkdir -p "$R/tools" "$R/config"
mkfile x.test.txt 15
printf 'x.test.txt\t15\n' >"$R/tools/a.tsv"
printf '[env]\nSIZE_RATCHET_BASELINE = "tools/a.tsv"\n' >"$R/config/settings.toml"
( cd "$R" && ln -sf config/settings.toml kendex.settings.toml )
git -C "$R" add -A
git -C "$R" commit -q -m "seed: the DEFAULT settings name is itself a symlink"
mkfile x.test.txt 20
printf 'x.test.txt\t20\n' >"$R/tools/b.tsv"
printf '[env]\nSIZE_RATCHET_BASELINE = "tools/b.tsv"\n' >"$R/config/settings.toml"
git -C "$R" add -A
RAISE=1 run_frozen
[ "$RC" -ne 0 ] \
  && ok "a symlinked DEFAULT source is refused in the worktree lane, with no override set" \
  || bad "a symlinked default source is refused in the worktree lane" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
