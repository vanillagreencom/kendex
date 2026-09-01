#!/usr/bin/env bash
# Pins for configuration resolution (env > .env.local > .kendex/settings.toml
# > kendex.settings.toml > default 400; .env read by nothing) and for the
# fail-loud config errors: malformed excludes (reason is
# mandatory), malformed/unsorted/duplicated baseline, bad threshold. Config
# problems are exit 2, never a silent pass or a silent default.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SR="$SKILL_DIR/scripts/size-ratchet"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_CLASSES SIZE_RATCHET_DEFAULT_CLASSES SIZE_RATCHET_FROZEN_CLASSES SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE RATCHET_RAISE 2>/dev/null || true
# The shipped class list and frozen list are policy, pinned by
# shipped-defaults.test.sh. Every fixture here declares its own thresholds,
# so both start empty and a case that needs one sets it.
export SIZE_RATCHET_DEFAULT_CLASSES="" SIZE_RATCHET_FROZEN_CLASSES=""

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

new_repo() { # NAME
  R="$TMP/$1"
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

mkfile() { # PATH LINES
  mkdir -p "$R/$(dirname "$1")"
  awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) print "line " i }' >"$R/$1"
}

run_raw() { # [VAR=val ...] [-- script-args...] — run $SR in $R; sets OUT, RC
  local envs=() args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --)
        shift
        args=("$@")
        break
        ;;
      *) envs+=("$1") ;;
    esac
    shift
  done
  OUT=""
  RC=0
  OUT="$(cd "$R" && env ${envs[@]+"${envs[@]}"} "$SR" ${args[@]+"${args[@]}"} 2>&1)" || RC=$?
}

echo "=== threshold resolution: env > settings > default 400 ==="
new_repo thr
mkfile f.txt 20
git -C "$R" add -A

run_raw
[ "$RC" -eq 0 ] && case "$OUT" in *"threshold 400"*) true ;; *) false ;; esac \
  && ok "no env, no settings: 20 lines passes under the built-in default 400" \
  || bad "built-in default is 400" "rc=$RC out=$OUT"

# The default's exact boundary, both sides: at 400 is under it, 401 is over.
mkfile edge.txt 400
git -C "$R" add -A
run_raw
[ "$RC" -eq 0 ] && ok "a 400-line file passes the default (at the threshold is not over it)" \
  || bad "400 lines passes the default" "rc=$RC out=$OUT"

mkfile edge.txt 401
git -C "$R" add -A
run_raw
[ "$RC" -eq 1 ] && case "$OUT" in *"edge.txt — 401 lines > threshold 400 (default)"*) true ;; *) false ;; esac \
  && ok "a 401-line file is a new offender under the default — 400 is real, not vacuous" \
  || bad "401 lines fails the default" "rc=$RC out=$OUT"
rm "$R/edge.txt"
git -C "$R" add -A

printf '[env]\nSIZE_RATCHET_THRESHOLD = "15"\n' >"$R/kendex.settings.toml"
run_raw
[ "$RC" -eq 1 ] && case "$OUT" in *"threshold 15"*) true ;; *) false ;; esac \
  && ok "settings file overrides the default (20 > 15 fails; 400 would have passed)" \
  || bad "settings file overrides the default" "rc=$RC out=$OUT"

run_raw SIZE_RATCHET_THRESHOLD=25
[ "$RC" -eq 0 ] && ok "environment overrides the settings file (25 passes where settings' 15 failed)" \
  || bad "environment overrides the settings file" "rc=$RC out=$OUT"

echo "=== invalid thresholds are config errors ==="
run_raw SIZE_RATCHET_THRESHOLD=abc
[ "$RC" -eq 2 ] && ok "non-numeric threshold is exit 2" || bad "non-numeric threshold is exit 2" "rc=$RC out=$OUT"
run_raw SIZE_RATCHET_THRESHOLD=0
[ "$RC" -eq 2 ] && ok "zero threshold is exit 2" || bad "zero threshold is exit 2" "rc=$RC out=$OUT"
rm "$R/kendex.settings.toml"

echo "=== excludes: the reason column is mandatory ==="
new_repo exc
mkfile ok.txt 3
mkdir -p "$R/tools"
printf 'vendor/*\n' >"$R/tools/size-ratchet-excludes"
git -C "$R" add -A
run_raw SIZE_RATCHET_THRESHOLD=10
[ "$RC" -eq 2 ] && case "$OUT" in *"pattern<TAB>reason"*) true ;; *) false ;; esac \
  && ok "a pattern without a tab-separated reason is exit 2" \
  || bad "a pattern without a tab-separated reason is exit 2" "rc=$RC out=$OUT"

printf '# lockfiles are generated\n\nvendor/*\tvendored third-party code\n' >"$R/tools/size-ratchet-excludes"
git -C "$R" add -A
run_raw SIZE_RATCHET_THRESHOLD=10
[ "$RC" -eq 0 ] && ok "comments and blank lines in the excludes file are ignored (control)" \
  || bad "comments and blank lines are ignored" "rc=$RC out=$OUT"

echo "=== baseline hygiene is enforced, not repaired silently ==="
new_repo base
mkfile a.txt 15
mkfile b.txt 15
mkdir -p "$R/tools"

printf 'b.txt\t15\na.txt\t15\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_raw SIZE_RATCHET_THRESHOLD=10
[ "$RC" -eq 2 ] && case "$OUT" in *"LC_ALL=C sorted"*) true ;; *) false ;; esac \
  && ok "unsorted baseline is exit 2" || bad "unsorted baseline is exit 2" "rc=$RC out=$OUT"

printf 'a.txt\t15\na.txt\t20\nb.txt\t15\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_raw SIZE_RATCHET_THRESHOLD=10
[ "$RC" -eq 2 ] && case "$OUT" in *"duplicate"*) true ;; *) false ;; esac \
  && ok "duplicate baseline path is exit 2" || bad "duplicate baseline path is exit 2" "rc=$RC out=$OUT"

printf 'a.txt\tnot-a-number\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_raw SIZE_RATCHET_THRESHOLD=10
[ "$RC" -eq 2 ] && case "$OUT" in *"malformed row"*) true ;; *) false ;; esac \
  && ok "non-numeric baseline count is exit 2" || bad "non-numeric baseline count is exit 2" "rc=$RC out=$OUT"

printf 'a.txt 15\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_raw SIZE_RATCHET_THRESHOLD=10
[ "$RC" -eq 2 ] && ok "space-separated (tab-less) baseline row is exit 2" \
  || bad "space-separated baseline row is exit 2" "rc=$RC out=$OUT"

printf 'a.txt\t15\nb.txt\t15\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_raw SIZE_RATCHET_THRESHOLD=10
[ "$RC" -eq 0 ] && ok "well-formed sorted baseline passes (control for the hygiene gates)" \
  || bad "well-formed sorted baseline passes" "rc=$RC out=$OUT"

echo "=== usage errors ==="
run_raw SIZE_RATCHET_THRESHOLD=10 -- --no-such-flag || true
[ "$RC" -eq 2 ] && ok "unknown flag is exit 2" || bad "unknown flag is exit 2" "rc=$RC out=$OUT"

echo "=== env-file layering: .env.local > .kendex > settings; .env ignored ==="
new_repo layering
mkfile f.txt 20
git -C "$R" add -A
# A .env threshold is read by nothing: 20 lines passes under the built-in
# 400. Fails against a resolver that still reads the file (7 would fail it).
printf 'SIZE_RATCHET_THRESHOLD=7\n' > "$R/.env"
run_raw || true
[ "$RC" -eq 0 ] && case "$OUT" in *"threshold 400"*) true ;; *) false ;; esac \
  && ok "SIZE_RATCHET_THRESHOLD from .env is ignored; the default 400 stands" \
  || bad ".env is ignored" "rc=$RC out=$OUT"
printf '[env]\nSIZE_RATCHET_THRESHOLD = "9"\n' > "$R/kendex.settings.toml"
run_raw || true
case "$OUT" in *"threshold 9"*) ok "kendex.settings.toml applies while the .env value stays ignored" ;; *) bad "settings layering" "rc=$RC out=$OUT" ;; esac
mkdir -p "$R/.kendex"
printf '[env]\nSIZE_RATCHET_THRESHOLD = "10"\n' > "$R/.kendex/settings.toml"
run_raw || true
case "$OUT" in *"threshold 10"*) ok ".kendex/settings.toml beats kendex.settings.toml" ;; *) bad ".kendex layering" "rc=$RC out=$OUT" ;; esac
printf 'SIZE_RATCHET_THRESHOLD="11"\n' > "$R/.env.local"
run_raw || true
case "$OUT" in *"threshold 11"*) ok ".env.local beats the settings files (quotes stripped)" ;; *) bad ".env.local layering" "rc=$RC out=$OUT" ;; esac
printf 'export SIZE_RATCHET_THRESHOLD=13\n' > "$R/.env.local"
run_raw || true
case "$OUT" in *"threshold 13"*) ok "export-form dotenv assignment is recognized" ;; *) bad "export-form dotenv" "rc=$RC out=$OUT" ;; esac
printf 'SIZE_RATCHET_THRESHOLD="17" # ratchet\n' > "$R/.env.local"
run_raw || true
case "$OUT" in *"threshold 17"*) ok "double-quoted dotenv value with inline comment extracts the content" ;; *) bad "quoted+comment dotenv (.env.local)" "rc=$RC out=$OUT" ;; esac
printf 'SIZE_RATCHET_THRESHOLD="23" # say "ratchet"\n' > "$R/.env.local"
run_raw || true
case "$OUT" in *"threshold 23"*) ok "quote inside the trailing comment never leaks into the value" ;; *) bad "comment-quote dotenv (.env.local)" "rc=$RC out=$OUT" ;; esac
rm -f "$R/kendex.settings.toml" "$R/.kendex/settings.toml" "$R/.env"
printf "SIZE_RATCHET_THRESHOLD='19' # note\n" > "$R/.env.local"
run_raw || true
case "$OUT" in *"threshold 19"*) ok "single-quoted dotenv value with inline comment extracts the content" ;; *) bad "quoted+comment dotenv (single-quote)" "rc=$RC out=$OUT" ;; esac
printf "SIZE_RATCHET_THRESHOLD='29' # don't raise\n" > "$R/.env.local"
run_raw || true
case "$OUT" in *"threshold 29"*) ok "apostrophe in the trailing comment never leaks into a single-quoted value" ;; *) bad "comment-apostrophe dotenv" "rc=$RC out=$OUT" ;; esac
printf 'SIZE_RATCHET_THRESHOLD="17".5\n' > "$R/.env.local"
run_raw || true
if [ "$RC" -ne 0 ] && case "$OUT" in *"unsupported syntax"*) true ;; *) false ;; esac; then ok "adjacent segment after a quoted value fails loud, never truncates"; else bad "adjacent-segment dotenv" "rc=$RC out=$OUT"; fi
printf 'SIZE_RATCHET_THRESHOLD="17"#note\n' > "$R/.env.local"
run_raw || true
if [ "$RC" -ne 0 ] && case "$OUT" in *"unsupported syntax"*) true ;; *) false ;; esac; then ok "adjacent # after a quoted value is a segment, not a comment — fails loud"; else bad "adjacent-hash dotenv" "rc=$RC out=$OUT"; fi
rm -f "$R/.env.local"

# Headers decide which assignments load: `[env] # comment` passing as
# content hides the whole table behind the silent built-in 400. The nested
# file goes too — it answers first and would mask the root file entirely.
rm -rf "$R/.kendex"
printf '[env] # comment\nSIZE_RATCHET_THRESHOLD = "9"\n' > "$R/kendex.settings.toml"
run_raw || true
[ "$RC" -eq 2 ] && case "$OUT" in *"unsupported table header shape"*) true ;; *) false ;; esac \
  && ok "a commented [env] header is exit 2, not an invisible table" \
  || bad "commented [env] header is exit 2" "rc=$RC out=$OUT"

# "" names no file: consulting only it resolved every key to its built-in
# default with nothing said. /dev/null stays the one force-defaults handle.
printf '[env]\nSIZE_RATCHET_THRESHOLD = "9"\n' > "$R/kendex.settings.toml"
run_raw SIZE_RATCHET_SETTINGS_FILE= || true
case "$OUT" in *"threshold 9"*) ok "a SET-but-EMPTY settings-file override reads the default sources" ;; *) bad "set-but-empty override reads default sources" "rc=$RC out=$OUT" ;; esac

# The WHOLE [env] table is validated, not only the requested key —
# kendex-env.sh refuses these same files, so a per-key-only extractor
# would split the family contract.
printf '[env]\nUNRELATED = bare\nSIZE_RATCHET_THRESHOLD = "9"\n' > "$R/kendex.settings.toml"
run_raw || true
[ "$RC" -eq 2 ] && case "$OUT" in *"unsupported syntax for UNRELATED"*) true ;; *) false ;; esac \
  && ok "an unrelated non-contract assignment is exit 2" \
  || bad "unrelated malformed assignment is exit 2" "rc=$RC out=$OUT"

printf '[env]\nUNRELATED = "a"\nUNRELATED = "b"\nSIZE_RATCHET_THRESHOLD = "9"\n' > "$R/kendex.settings.toml"
run_raw || true
[ "$RC" -eq 2 ] && case "$OUT" in *"UNRELATED is assigned more than once"*) true ;; *) false ;; esac \
  && ok "an unrelated duplicated key is exit 2" \
  || bad "unrelated duplicated key is exit 2" "rc=$RC out=$OUT"

# kendex-env validates before its parent-env skip; an exported value must
# never let a broken committed file pass silently.
printf '[env]\nDUP = "a"\nDUP = "b"\n' > "$R/kendex.settings.toml"
run_raw SIZE_RATCHET_THRESHOLD=9 || true
[ "$RC" -eq 2 ] && case "$OUT" in *"assigned more than once"*) true ;; *) false ;; esac \
  && ok "an exported value does not mask a malformed settings file" \
  || bad "env override over malformed file" "rc=$RC out=$OUT"
printf '[env]\nSIZE_RATCHET_THRESHOLD = "9"\n' > "$R/kendex.settings.toml"

# ...and it must not mask a BROKEN .env.local either: the layer's
# usability is part of every resolution, same as the generic loader.
mkdir -p "$R/.env.local"
run_raw SIZE_RATCHET_THRESHOLD=9 || true
[ "$RC" -eq 2 ] && case "$OUT" in *"not a regular file"*) true ;; *) false ;; esac \
  && ok "an exported value does not mask a DIRECTORY at .env.local" \
  || bad "env override over broken .env.local" "rc=$RC out=$OUT"
rmdir "$R/.env.local"

echo "=== an EXISTING non-regular settings path never falls back to defaults ==="
# A directory fails -f exactly like an absent file, so the configured settings
# would be skipped with nothing said and the built-in 400 would decide.
new_repo nonregular
mkfile f.txt 20
git -C "$R" add -A
mkdir -p "$R/nonregular.dir"
run_raw SIZE_RATCHET_SETTINGS_FILE=nonregular.dir || true
[ "$RC" -eq 2 ] && case "$OUT" in *"not a regular file"*) true ;; *) false ;; esac \
  && ok "a DIRECTORY settings path is exit 2, not a silent built-in default" \
  || bad "a DIRECTORY settings path is exit 2" "rc=$RC out=$OUT"

# A symlink that does not resolve fails -e as well as -f, so an existence
# test alone never sees it — the same silent-defaults trap one shape over.
ln -s missing.toml "$R/dangling.settings.toml"
run_raw SIZE_RATCHET_SETTINGS_FILE=dangling.settings.toml || true
[ "$RC" -eq 2 ] && case "$OUT" in *"does not resolve"*) true ;; *) false ;; esac \
  && ok "a DANGLING symlink settings path is exit 2, not a silent built-in default" \
  || bad "a DANGLING symlink settings path is exit 2" "rc=$RC out=$OUT"

ln -s cycle-b.settings.toml "$R/cycle-a.settings.toml"
ln -s cycle-a.settings.toml "$R/cycle-b.settings.toml"
run_raw SIZE_RATCHET_SETTINGS_FILE=cycle-a.settings.toml || true
[ "$RC" -eq 2 ] && case "$OUT" in *"does not resolve"*) true ;; *) false ;; esac \
  && ok "a CYCLIC symlink settings path is exit 2, not a silent built-in default" \
  || bad "a CYCLIC symlink settings path is exit 2" "rc=$RC out=$OUT"

# A RESOLVING symlink is an ordinary install shape and must still read.
printf '[env]\nSIZE_RATCHET_THRESHOLD = "15"\n' >"$R/link-target.settings.toml"
ln -s link-target.settings.toml "$R/link.settings.toml"
run_raw SIZE_RATCHET_SETTINGS_FILE=link.settings.toml || true
[ "$RC" -eq 1 ] && case "$OUT" in *"threshold 15"*) true ;; *) false ;; esac \
  && ok "a RESOLVING symlink reads its target (control: 20 > 15 fails; 400 would have passed)" \
  || bad "a RESOLVING symlink reads its target (control)" "rc=$RC out=$OUT"

# Controls: the two shapes that MUST still resolve to the built-in default.
run_raw SIZE_RATCHET_SETTINGS_FILE=/dev/null || true
[ "$RC" -eq 0 ] && case "$OUT" in *"threshold 400"*) true ;; *) false ;; esac \
  && ok "/dev/null still forces the built-in default (control)" \
  || bad "/dev/null still forces the built-in default (control)" "rc=$RC out=$OUT"

run_raw SIZE_RATCHET_SETTINGS_FILE=absent.settings.toml || true
[ "$RC" -eq 0 ] && case "$OUT" in *"threshold 400"*) true ;; *) false ;; esac \
  && ok "an ABSENT plain file still falls back to the built-in default (control)" \
  || bad "an ABSENT plain file still falls back to the built-in default (control)" "rc=$RC out=$OUT"

echo "=== the /dev/null sentinel selects NO settings source, the dotenv layer included ==="
# It named only the settings file, so .env.local (read before it) kept
# deciding: a caller asking for built-in defaults got whatever the
# repository's env file said.
new_repo devnull
mkfile f.txt 10
git -C "$R" add -A
printf 'SIZE_RATCHET_THRESHOLD=6\n' >"$R/.env.local"
run_raw || true
[ "$RC" -eq 1 ] && case "$OUT" in *"threshold 6"*) true ;; *) false ;; esac \
  && ok "control: without the sentinel .env.local supplies 6" \
  || bad "devnull control (.env.local)" "rc=$RC out=$OUT"
run_raw SIZE_RATCHET_SETTINGS_FILE=/dev/null || true
[ "$RC" -eq 0 ] && case "$OUT" in *"threshold 400"*) true ;; *) false ;; esac \
  && ok "the sentinel skips .env.local (read BEFORE the settings file) too" \
  || bad "sentinel skips .env.local" "rc=$RC out=$OUT"

run_raw SIZE_RATCHET_SETTINGS_FILE=/dev/null SIZE_RATCHET_THRESHOLD=5 || true
[ "$RC" -eq 1 ] && case "$OUT" in *"threshold 5"*) true ;; *) false ;; esac \
  && ok "an explicit environment variable still wins over the sentinel" \
  || bad "sentinel vs environment" "rc=$RC out=$OUT"

echo "=== an EXISTING non-regular ENV-FILE source never falls through ==="
# .env.local is probed with -f like the settings file, so a directory or an
# unresolvable symlink there is skipped exactly like an absent one and a
# lower-precedence value silently decides.
new_repo nonregularenv
mkfile f.txt 20
git -C "$R" add -A
printf '[env]\nSIZE_RATCHET_THRESHOLD = "30"\n' >"$R/kendex.settings.toml"

mkdir -p "$R/.env.local"
run_raw || true
[ "$RC" -eq 2 ] && case "$OUT" in *".env.local: settings source exists but is not a regular file"*) true ;; *) false ;; esac \
  && ok "a DIRECTORY at .env.local is exit 2 (falling through would have read 30 and passed)" \
  || bad "a DIRECTORY at .env.local is exit 2" "rc=$RC out=$OUT"
rmdir "$R/.env.local"

ln -s missing.env "$R/.env.local"
run_raw || true
[ "$RC" -eq 2 ] && case "$OUT" in *".env.local: settings source is a symlink that does not resolve"*) true ;; *) false ;; esac \
  && ok "a DANGLING .env.local symlink is exit 2, not a silent skip" \
  || bad "a DANGLING .env.local symlink is exit 2" "rc=$RC out=$OUT"
rm -f "$R/.env.local"

run_raw || true
[ "$RC" -eq 0 ] && case "$OUT" in *"threshold 30"*) true ;; *) false ;; esac \
  && ok "control: with .env.local absent the settings file still supplies 30" \
  || bad "control: an absent env file falls through to the settings file" "rc=$RC out=$OUT"

echo "=== an UNREADABLE settings source fails loud, never falls through ==="
# grep exits 0/1 are measurements; anything else means the source could not
# be read, and continuing to a lower-precedence layer would silently
# resolve a different value. Every layer carries the same discipline.
if [ "$(id -u)" -eq 0 ]; then
  printf '  skip  unreadable-source pins need a non-root reader (chmod 000 cannot deny root)\n'
else
  new_repo unreadable
  mkfile f.txt 20
  git -C "$R" add -A

  printf '[env]\nSIZE_RATCHET_THRESHOLD = "30"\n' >"$R/kendex.settings.toml"
  printf 'SIZE_RATCHET_THRESHOLD=15\n' >"$R/.env.local"
  chmod 000 "$R/.env.local"
  run_raw || true
  [ "$RC" -eq 2 ] && case "$OUT" in *".env.local: unreadable while resolving a setting"*) true ;; *) false ;; esac \
    && ok "an unreadable .env.local is exit 2 (falling through would have read 30 and passed)" \
    || bad "an unreadable .env.local is exit 2" "rc=$RC out=$OUT"
  chmod 600 "$R/.env.local"
  run_raw || true
  [ "$RC" -eq 1 ] && case "$OUT" in *"threshold 15"*) true ;; *) false ;; esac \
    && ok "control: the same .env.local, readable, supplies 15 and the 20-line file fails" \
    || bad "control: readable .env.local supplies the value" "rc=$RC out=$OUT"
  rm -f "$R/.env.local"

  chmod 000 "$R/kendex.settings.toml"
  run_raw || true
  [ "$RC" -eq 2 ] && case "$OUT" in *"kendex.settings.toml: unreadable while resolving a setting"*) true ;; *) false ;; esac \
    && ok "an unreadable settings file is exit 2 (falling through would have read the built-in 400)" \
    || bad "an unreadable settings file is exit 2" "rc=$RC out=$OUT"
  chmod 600 "$R/kendex.settings.toml"
  run_raw || true
  [ "$RC" -eq 0 ] && case "$OUT" in *"threshold 30"*) true ;; *) false ;; esac \
    && ok "control: the same settings file, readable, supplies 30" \
    || bad "control: readable settings file supplies the value" "rc=$RC out=$OUT"
  rm -f "$R/kendex.settings.toml"

  printf 'SIZE_RATCHET_THRESHOLD=12\n' >"$R/.env.local"
  chmod 000 "$R/.env.local"
  run_raw || true
  [ "$RC" -eq 2 ] && case "$OUT" in *".env.local: unreadable while resolving a setting"*) true ;; *) false ;; esac \
    && ok "an unreadable .env.local is exit 2 (falling through would have read the built-in 400)" \
    || bad "an unreadable .env.local is exit 2" "rc=$RC out=$OUT"
  chmod 600 "$R/.env.local"
  run_raw || true
  [ "$RC" -eq 1 ] && case "$OUT" in *"threshold 12"*) true ;; *) false ;; esac \
    && ok "control: the same .env.local, readable, supplies 12 and the 20-line file fails" \
    || bad "control: readable .env.local supplies the value" "rc=$RC out=$OUT"
fi

echo "=== option-like configured paths ==="
new_repo optpath
mkfile f.txt 20
git -C "$R" add -A
run_raw SIZE_RATCHET_BASELINE=-b || true
if [ "$RC" -eq 2 ]; then ok "option-like baseline path refuses as config (no cut/sort option injection)"; else bad "option-like baseline path" "rc=$RC out=$OUT"; fi

echo "=== a supplied-but-empty path flag is an error, not the default ==="
# Testing the flag's VALUE alone made `--baseline=` and `--baseline ""`
# indistinguishable from an absent flag, so automation whose path came out of a
# bad substitution silently checked the repository's default baseline and
# passed. Whether the flag was supplied is now tracked apart from its value.
new_repo emptyflag
mkfile f.txt 20
mkfile huge.txt 405
mkdir -p "$R/tools"
# The DEFAULT baseline freezes huge.txt, so falling back to it exits 0 — the
# false pass this case exists to catch. A correct refusal is exit 2.
printf 'huge.txt\t405\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A

run_raw
[ "$RC" -eq 0 ] \
  && ok "control: the default baseline is present and passes, so a silent fallback would read as success" \
  || bad "control: default baseline passes" "rc=$RC out=$OUT"

for flag in --baseline --excludes; do
  run_raw -- "$flag" "" || true
  [ "$RC" -eq 2 ] && case "$OUT" in *"was given an empty path"*) true ;; *) false ;; esac \
    && ok "split form '$flag \"\"' exits 2 instead of falling back to the default" \
    || bad "split form '$flag \"\"' refuses" "rc=$RC out=$OUT"

  run_raw -- "$flag=" || true
  [ "$RC" -eq 2 ] && case "$OUT" in *"was given an empty path"*) true ;; *) false ;; esac \
    && ok "equals form '$flag=' exits 2 instead of falling back to the default" \
    || bad "equals form '$flag=' refuses" "rc=$RC out=$OUT"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
