#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SR="$TEST_DIR/../scripts/size-ratchet"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_CLASSES SIZE_RATCHET_DEFAULT_CLASSES SIZE_RATCHET_FROZEN_CLASSES SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE RATCHET_RAISE 2>/dev/null || true
export SIZE_RATCHET_THRESHOLD=10 SIZE_RATCHET_DEFAULT_CLASSES=""

new_repo() {
  R="$TMP/$1"
  mkdir -p "$R/tools"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

mkfile() {
  awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) print "line " i }' >"$R/$1"
}

run_check() {
  local mode="$1" declaration="$2" frozen="$3"
  local envs=("RATCHET_RAISE=$declaration" "SIZE_RATCHET_FROZEN_CLASSES=$frozen") args=()
  case "$SETTINGS_MODE" in
    explicit) envs+=("SIZE_RATCHET_SETTINGS_FILE=$SETTINGS_FILE") ;;
    envvar) envs+=("SIZE_RATCHET_BASELINE=tools/active.tsv") ;;
    flag) args+=(--baseline tools/active.tsv) ;;
  esac
  [ -z "$mode" ] || args+=("$mode")
  RC=0
  OUT="$(cd "$R" && env "${envs[@]}" "$SR" ${args[@]+"${args[@]}"} 2>&1)" || RC=$?
}

FAIL=0
while IFS='|' read -r label mode declaration frozen dormant source expect_rc expect_text expect_ref; do
  [ -n "$label" ] || continue
  new_repo "$label"
  if [ -n "$frozen" ]; then path=big.test.txt; else path=big.txt; fi
  mkfile "$path" 15
  printf '%s\t15\n' "$path" >"$R/tools/active.tsv"
  if [ "$dormant" = yes ]; then printf '%s\t20\n' "$path" >"$R/tools/target.tsv"; fi
  SETTINGS_MODE=implicit
  case "$source" in
    nested) SETTINGS_FILE=.kendex/settings.toml ;;
    explicit) SETTINGS_FILE=policy/settings.toml; SETTINGS_MODE=explicit ;;
    # The same explicit source, never committed: it is a candidate only, so
    # the key it assigns has no historical form and the run refuses rather
    # than judge the candidate against a HEAD that never carried the value.
    # explicit-default above is the control — the identical source committed,
    # which must resolve and catch the raise instead of refusing.
    candidate-explicit)
      SETTINGS_FILE=policy/settings.toml
      SETTINGS_MODE=explicit
      printf 'policy/settings.toml\n' >"$R/.gitignore"
      ;;
    envlocal) SETTINGS_FILE=.env.local ;;
    tracked-link)
      SETTINGS_FILE=policy/settings.toml
      mkdir -p "$R/policy"
      ln -s policy/settings.toml "$R/kendex.settings.toml"
      ;;
    # The settings file is reached through a symlinked PARENT: HEAD carries
    # no entry at the complete path, so the lookup cannot be performed at
    # all and must refuse rather than report the source absent.
    parent-link)
      SETTINGS_FILE=.kendex/settings.toml
      mkdir -p "$R/config"
      ln -s config "$R/.kendex"
      ;;
    # Its must-fail control: the same real .kendex directory, carrying no
    # settings.toml, so the ancestor walk crosses a real tree and must still
    # earn the absent sentinel — the root file then answers and catches the
    # raise. A refusal that over-fires on a tree reds here; one that fires
    # unconditionally reds on nested-default above.
    parent-real)
      SETTINGS_FILE=kendex.settings.toml
      mkdir -p "$R/.kendex"
      printf 'not settings\n' >"$R/.kendex/notes.txt"
      ;;
    flag | envvar)
      SETTINGS_FILE=kendex.settings.toml
      SETTINGS_MODE="$source"
      printf '%s\t30\n' "$path" >"$R/tools/other.tsv"
      ;;
    untracked-envlocal)
      SETTINGS_FILE=kendex.settings.toml
      printf '.env.local\n' >"$R/.gitignore"
      ;;
    # The explicit source is named so that a cache keyed by the encoded path
    # alone would materialize it ONTO the absent sentinel. The .env.local
    # lookup that follows finds no such source in HEAD and must still refuse,
    # rather than read this file's bytes off an occupied sentinel path.
    # untracked-envlocal below is the control: the same untracked .env.local
    # refusal with a settings source whose name cannot collide.
    sentinel-collision)
      SETTINGS_FILE=absent
      SETTINGS_MODE=explicit
      printf '.env.local\n' >"$R/.gitignore"
      ;;
    *) SETTINGS_FILE=kendex.settings.toml ;;
  esac
  case "$SETTINGS_FILE" in */*) mkdir -p "$R/${SETTINGS_FILE%/*}" ;; esac
  if [ "$SETTINGS_FILE" = .env.local ]; then
    printf 'SIZE_RATCHET_BASELINE=tools/active.tsv\n' >"$R/$SETTINGS_FILE"
  elif [ "$source" = flag ] || [ "$source" = envvar ]; then
    printf '[env]\nSIZE_RATCHET_BASELINE = "tools/other.tsv"\n' >"$R/$SETTINGS_FILE"
  else
    printf '[env]\nSIZE_RATCHET_BASELINE = "tools/active.tsv"\n' >"$R/$SETTINGS_FILE"
  fi
  git -C "$R" add -A
  git -C "$R" commit -q -m active
  mkfile "$path" 20
  if [ "$source" = flag ] || [ "$source" = envvar ]; then
    printf '%s\t20\n' "$path" >"$R/tools/active.tsv"
  else
    if [ "$dormant" = no ]; then printf '%s\t20\n' "$path" >"$R/tools/target.tsv"; fi
    if [ "$source" = untracked-envlocal ] || [ "$source" = sentinel-collision ]; then
      printf 'SIZE_RATCHET_BASELINE=tools/target.tsv\n' >"$R/.env.local"
    elif [ "$SETTINGS_FILE" = .env.local ]; then
      printf 'SIZE_RATCHET_BASELINE=tools/target.tsv\n' >"$R/$SETTINGS_FILE"
    else
      printf '[env]\nSIZE_RATCHET_BASELINE = "tools/target.tsv"\n' >"$R/$SETTINGS_FILE"
    fi
  fi
  git -C "$R" add -A
  run_check "$mode" "$declaration" "$frozen"
  if [ "$RC" -ne "$expect_rc" ] || { [ -n "$expect_text" ] && ! printf '%s\n' "$OUT" | grep -Fq "$expect_text"; } \
    || { [ -n "$expect_ref" ] && ! printf '%s\n' "$OUT" | grep -Fq "$expect_ref"; }; then
    printf 'FAIL: %s\nrc=%s expected=%s\n%s\n' "$label" "$RC" "$expect_rc" "$OUT" >&2
    FAIL=$((FAIL + 1))
  fi
done <<'CASES'
default-open-undeclared||0||no|root|1|baseline row raised: big.txt — row 15 -> 20 lines|reference tools/active.tsv
staged-open-undeclared|--staged|0||no|root|1|baseline row raised: big.txt — row 15 -> 20 lines|reference tools/active.tsv
default-open-declared||1||no|root|0||reference tools/active.tsv
staged-open-declared|--staged|1||no|root|0||reference tools/active.tsv
default-frozen-declared||1|*.test.*|no|root|1|frozen baseline row raised: big.test.txt — row 15 -> 20 lines|reference tools/active.tsv
staged-frozen-declared|--staged|1|*.test.*|no|root|1|frozen baseline row raised: big.test.txt — row 15 -> 20 lines|reference tools/active.tsv
default-dormant-target||0||yes|root|1|baseline row raised: big.txt — row 15 -> 20 lines|reference tools/active.tsv
staged-dormant-target|--staged|0||yes|root|1|baseline row raised: big.txt — row 15 -> 20 lines|reference tools/active.tsv
nested-default||0||no|nested|1|baseline row raised: big.txt — row 15 -> 20 lines|reference tools/active.tsv
nested-staged|--staged|0||no|nested|1|baseline row raised: big.txt — row 15 -> 20 lines|reference tools/active.tsv
envlocal-default||0||no|envlocal|1|baseline row raised: big.txt — row 15 -> 20 lines|reference tools/active.tsv
envlocal-staged|--staged|0||no|envlocal|1|baseline row raised: big.txt — row 15 -> 20 lines|reference tools/active.tsv
tracked-link-default||0||no|tracked-link|1|baseline row raised: big.txt — row 15 -> 20 lines|reference tools/active.tsv
tracked-link-staged|--staged|0||no|tracked-link|2|tracked as a symlink|
explicit-default||0||no|explicit|1|baseline row raised: big.txt — row 15 -> 20 lines|reference tools/active.tsv
explicit-staged|--staged|0||no|explicit|1|baseline row raised: big.txt — row 15 -> 20 lines|reference tools/active.tsv
candidate-explicit-default||0||no|candidate-explicit|2|policy/settings.toml: SIZE_RATCHET_BASELINE has no historical form in HEAD|
candidate-explicit-staged|--staged|0||no|candidate-explicit|2|policy/settings.toml: SIZE_RATCHET_BASELINE has no historical form in HEAD|
flag-default||0||no|flag|1|baseline row raised: big.txt — row 15 -> 20 lines|
flag-staged|--staged|0||no|flag|1|baseline row raised: big.txt — row 15 -> 20 lines|
envvar-default||0||no|envvar|1|baseline row raised: big.txt — row 15 -> 20 lines|
envvar-staged|--staged|0||no|envvar|1|baseline row raised: big.txt — row 15 -> 20 lines|
parent-link-default||0||no|parent-link|2|.kendex: HEAD carries this path component as a symlink|
parent-real-default||0||no|parent-real|1|baseline row raised: big.txt — row 15 -> 20 lines|reference tools/active.tsv
sentinel-collision-default||0||no|sentinel-collision|2|.env.local: SIZE_RATCHET_BASELINE has no historical form in HEAD|
untracked-envlocal-default||0||no|untracked-envlocal|2|no historical form|
untracked-envlocal-staged|--staged|0||no|untracked-envlocal|2|no historical form|
CASES

while IFS='|' read -r label declaration frozen expect_rc expect_text; do
  [ -n "$label" ] || continue
  new_repo "$label"
  if [ -n "$frozen" ]; then path=big.test.txt; else path=big.txt; fi
  mkfile "$path" 15
  printf '%s\t15\n' "$path" >"$R/tools/active.tsv"
  SETTINGS_FILE=kendex.settings.toml
  SETTINGS_MODE=implicit
  printf '[env]\nSIZE_RATCHET_BASELINE = "tools/active.tsv"\n' >"$R/$SETTINGS_FILE"
  git -C "$R" add -A
  git -C "$R" commit -q -m active
  mkfile "$path" 20
  : >"$R/tools/target.tsv"
  printf '[env]\nSIZE_RATCHET_BASELINE = "tools/target.tsv"\n' >"$R/$SETTINGS_FILE"
  git -C "$R" add -A
  run_check --seed "$declaration" "$frozen"
  if [ "$RC" -ne "$expect_rc" ] || { [ -n "$expect_text" ] && ! printf '%s\n' "$OUT" | grep -Fq "$expect_text"; }; then
    printf 'FAIL: %s\nrc=%s expected=%s\n%s\n' "$label" "$RC" "$expect_rc" "$OUT" >&2
    FAIL=$((FAIL + 1))
  fi
done <<'SEED_CASES'
seed-repoint-open-undeclared|0||1|baseline row raised: big.txt — row 15 -> 20 lines
seed-repoint-open-declared|1||0|
seed-repoint-frozen-declared|1|*.test.*|1|frozen baseline row raised: big.test.txt — row 15 -> 20 lines
SEED_CASES

new_repo head-count-failure
mkfile big.txt 15
printf 'big.txt\t15\n' >"$R/tools/active.tsv"
printf '[env]\nSIZE_RATCHET_BASELINE = "tools/active.tsv"\n' >"$R/kendex.settings.toml"
git -C "$R" add -A
git -C "$R" commit -q -m active
GREP_SHIM="$TMP/grep-shim"
mkdir -p "$GREP_SHIM"
REAL_GREP="$(command -v grep)"
cat >"$GREP_SHIM/grep" <<EOF
#!/usr/bin/env bash
count=0
for arg in "\$@"; do
  [ "\$arg" != -c ] || count=1
  case "\$arg" in */baseline.head) [ "\$count" -eq 0 ] || { echo "grep: simulated HEAD count failure" >&2; exit 7; } ;; esac
done
exec "$REAL_GREP" "\$@"
EOF
chmod +x "$GREP_SHIM/grep"
RC=0
OUT="$(cd "$R" && PATH="$GREP_SHIM:$PATH" "$SR" 2>&1)" || RC=$?
if [ "$RC" -ne 2 ] || ! printf '%s\n' "$OUT" | grep -Fq "could not count active HEAD baseline rows" \
  || case "$OUT" in *"size-ratchet: OK"*) true ;; *) false ;; esac; then
  printf 'FAIL: HEAD baseline count failure passed\nrc=%s\n%s\n' "$RC" "$OUT" >&2
  FAIL=$((FAIL + 1))
fi

[ "$FAIL" -eq 0 ] || exit 1
printf 'baseline-relocated.test.sh: PASS\n'
