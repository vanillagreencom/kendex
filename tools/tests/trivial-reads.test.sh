#!/usr/bin/env bash
# The proof for tools/trivial-reads: a checkout holding one crate, the
# shipped harness-ci classifier and orch's measurer beside a narrow-change
# list each row writes, and one row per way a read file is judged, held or
# left unjudged; the judgements that cannot be made; and one control per
# rule, each a copy of the checker with that rule removed, turning its row
# red. What each source shape reads is tools/tests/rust-reads.test.sh's.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset HARNESS_CI_TRIVIAL_PATHS HARNESS_CI_TRIVIAL_MAX_LINES

ROOT="$(git rev-parse --show-toplevel)"
CHECK="$ROOT/tools/trivial-reads"
mkdir -p "$ROOT/tmp"
TMP="$(mktemp -d "$ROOT/tmp/trivial-reads.XXXXXX")" || exit 2
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

W="$TMP/repo"
INCLUDE_A='const A: &str = include_str!("../../../docs/a.md");'
LEGAL='let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../docs/legal").join(name);'
README='let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../README.md");'
TOOL='const T: &str = include_str!("../../../tools/x.sh");'
ROOTED='let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");'
DOCS_DIR='let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docs");'
UNTRACKED='const N: &str = include_str!("../../../docs/new.md");'

# A committed checkout whose crate source is SOURCE and whose narrow-change
# list carries the ceilings and LINES, `;`-separated `path` globs. The
# classifier and the measurer are this repository's own. docs/new.md is
# written and left untracked.
seed_world() { # SOURCE LINES
  local line
  rm -rf -- "${W:?}"
  mkdir -p "$W/crates/demo/src" "$W/docs/legal" "$W/tools" \
    "$W/skills/harness-ci" "$W/skills/orch/references" "$W/skills/orch/scripts"
  printf '[package]\nname = "demo"\n' >"$W/crates/demo/Cargo.toml"
  printf '%s\n' "$1" >"$W/crates/demo/src/lib.rs"
  printf '# a\n' >"$W/docs/a.md"
  printf '# terms\n' >"$W/docs/legal/terms.md"
  printf '# privacy\n' >"$W/docs/legal/privacy.md"
  printf '# readme\n' >"$W/README.md"
  printf '#!/usr/bin/env bash\n' >"$W/tools/x.sh"
  cp -R "$ROOT/skills/harness-ci/scripts" "$W/skills/harness-ci/scripts"
  cp -R "$ROOT/skills/orch/scripts/lib" "$W/skills/orch/scripts/lib"
  printf 'micro_max_production=20\nsmall_max_production=150\n' >"$W/skills/orch/references/narrow-change.conf"
  while IFS= read -r line; do
    [ -z "$line" ] || printf 'path %s\n' "$line" >>"$W/skills/orch/references/narrow-change.conf"
  done < <(printf '%s\n' "$2" | tr ';' '\n')
  git -C "$W" init -q
  git -C "$W" add -A
  git -C "$W" -c user.name=t -c user.email=t@invalid -c commit.gpgsign=false commit -q -m seed
  printf '# new\n' >"$W/docs/new.md"
}

run_check() { # [CHECKER] [VAR=VALUE...] — sets RAW, OUT (RAW's lines joined by ;) and RC
  local checker="$CHECK"
  case "${1:-}" in *=*) ;; */*) checker="$1"; shift ;; esac
  RAW=""
  RC=0
  RAW="$(cd "$W" && env "$@" "$checker" 2>&1 </dev/null)" || RC=$?
  OUT="$(printf '%s' "$RAW" | tr '\n' ';')"
}

# A trivial=N finding ends in its English line, which no row asserts: the
# key, the count and the paths are the contract.
keyed() { # — OUT without a finding's closing line
  case "$RAW" in
    "trivial-reads: trivial="*) printf '%s' "${RAW%$'\n'*}" | tr '\n' ';' ;;
    *) printf '%s' "$OUT" ;;
  esac
}

# LABEL|SOURCE VARIABLE|LIST LINES|ENV|RC|OUTPUT — OUTPUT's lines joined by ;
ROWS='an included doc no list line names classifies trivial|INCLUDE_A|||1|trivial-reads: trivial=1;docs/a.md
a list line naming the doc holds it|INCLUDE_A|docs/a.md||0|
a read directory is judged file by file|LEGAL|docs/legal/terms.md||1|trivial-reads: trivial=1;docs/legal/privacy.md
a glob over the read directory holds every file in it|LEGAL|docs/legal/*||0|
a root readme a test reads classifies trivial|README|||1|trivial-reads: trivial=1;README.md
a read file outside the docs set is never trivial|TOOL|||0|
a chain stopping at the checkout root names no file|ROOTED|||0|
a read untracked file is not judged|UNTRACKED|||0|
a file two reads name is reported once|INCLUDE_A DOCS_DIR|||1|trivial-reads: trivial=3;docs/a.md;docs/legal/privacy.md;docs/legal/terms.md
an allowlist in the caller environment is not the one CI reads|INCLUDE_A||HARNESS_CI_TRIVIAL_PATHS=nothing/*|1|trivial-reads: trivial=1;docs/a.md'

source_of() { # VARIABLES — the named sources, one per line
  local v text=""
  for v in $1; do text="$text${!v}"$'\n'; done
  printf '%s' "$text"
}

row() { # LABEL [CHECKER] — run the ROWS entry LABEL; sets OUT, RC, WANT_RC, WANT
  local label vars lines env_arg rc want
  IFS='|' read -r label vars lines env_arg rc want < <(printf '%s\n' "$ROWS" | grep -F -- "$1|")
  seed_world "$(source_of "$vars")" "$lines"
  if [ -n "${2:-}" ]; then
    run_check "$2" ${env_arg:+"$env_arg"}
  else
    run_check ${env_arg:+"$env_arg"}
  fi
  WANT_RC="$rc"
  WANT="$want"
}

echo "=== each read file is judged by the shipped classifier ==="
before=$((PASS + FAIL))
while IFS='|' read -r label _rest; do
  [ -n "$label" ] || continue
  row "$label"
  [ "$RC" -eq "$WANT_RC" ] && [ "$(keyed)" = "$WANT" ] && ok "$label" || bad "$label" "rc=$RC want=$WANT out=$OUT"
done <<<"$ROWS"
[ "$((PASS + FAIL))" -gt "$before" ] || { echo "no row was asserted: the judged rows" >&2; exit 2; }

echo "=== a judgement that cannot be made is never a held tree ==="
seed_world "$INCLUDE_A" ""
rm -rf -- "${W:?}/skills/harness-ci"
run_check
[ "$RC" -eq 2 ] && [ "$OUT" = "trivial-reads: unreadable=skills/harness-ci/scripts" ] && ok "a read with no classifier beside it exits 2 naming it" || bad "a read with no classifier beside it exits 2 naming it" "rc=$RC out=$OUT"
seed_world 'fn main() {}' ""
rm -rf -- "${W:?}/skills/harness-ci"
run_check
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "source reading nothing passes with no classifier beside it" || bad "source reading nothing passes with no classifier beside it" "rc=$RC out=$OUT"
seed_world "$INCLUDE_A" ""
rm -rf -- "${W:?}/skills/orch/scripts"
run_check
[ "$RC" -eq 2 ] && [[ "$OUT" == "trivial-reads: unjudged=docs/a.md;class: class=standard measured=false "* ]] && ok "an unmeasured answer exits 2 naming the file and the class line" || bad "an unmeasured answer exits 2 naming the file and the class line" "rc=$RC out=$OUT"
seed_world "$INCLUDE_A" ""
rm -rf -- "${W:?}/crates"
run_check
[ "$RC" -eq 2 ] && [ "$OUT" = "rust-reads: unreadable=crates;trivial-reads: unreadable=rust-reads" ] && ok "a read set that cannot be derived exits 2 naming the reader" || bad "a read set that cannot be derived exits 2 naming the reader" "rc=$RC out=$OUT"
OUT=""
RC=0
OUT="$("$CHECK" "$TMP/absent" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && [ "$OUT" = "trivial-reads: unreadable=$TMP/absent" ] && ok "an absent root exits 2 naming it" || bad "an absent root exits 2 naming it" "rc=$RC out=$OUT"
OUT=""
RC=0
OUT="$("$CHECK" one two 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && [[ "$OUT" == "trivial-reads: usage="* ]] && ok "a second argument is refused with the usage line" || bad "a second argument is refused with the usage line" "rc=$RC out=$OUT"

echo "=== each rule has a control ==="
# EDIT|ROW LABEL — a checker copy with EDIT applied answers that row other
# than it does. The copy runs beside the real reader. An edit carries no |.
MUTANTS="$TMP/tools"
mkdir -p "$MUTANTS"
cp "$ROOT/tools/rust-reads" "$MUTANTS/rust-reads"
before=$((PASS + FAIL))
while IFS='|' read -r edit label; do
  [ -n "$edit" ] || continue
  sed "$edit" "$CHECK" >"$MUTANTS/trivial-reads"
  chmod +x "$MUTANTS/trivial-reads"
  if cmp -s "$CHECK" "$MUTANTS/trivial-reads"; then
    bad "control: $label" "the edit changed nothing in a checker copy: $edit"
    continue
  fi
  row "$label" "$MUTANTS/trivial-reads"
  { [ "$RC" -ne "$WANT_RC" ] || [ "$(keyed)" != "$WANT" ]; } && ok "control: $label, with that rule removed" ||
    bad "control: $label, with that rule removed" "rc=$RC out=$OUT"
done <<'CONTROLS'
s/"change_class=trivial "\*)/"change_class=never "*)/|an included doc no list line names classifies trivial
s/head=$(commit_of "$file" "$base")/head=$(commit_of "$files" "$base")/|a read directory is judged file by file
/^trivial=$(printf/d|a file two reads name is reported once
s/^unset HARNESS_CI_TRIVIAL_PATHS HARNESS_CI_TRIVIAL_MAX_LINES$/:/|an allowlist in the caller environment is not the one CI reads
CONTROLS
[ "$((PASS + FAIL))" -gt "$before" ] || { echo "no row was asserted: the controls" >&2; exit 2; }
# The two refusals above, each with its rule removed.
sed 's/\*" measured=true"\*) ;;/*) ;;/' "$CHECK" >"$MUTANTS/trivial-reads"
seed_world "$INCLUDE_A" ""
rm -rf -- "${W:?}/skills/orch/scripts"
run_check "$MUTANTS/trivial-reads"
[ "$RC" -ne 2 ] && ok "control: with the measured rule removed an unmeasured answer is not refused" || bad "control: with the measured rule removed an unmeasured answer is not refused" "rc=$RC out=$OUT"
sed '/^\[ -n "\$row_files" \] || exit 0$/d' "$CHECK" >"$MUTANTS/trivial-reads"
seed_world 'fn main() {}' ""
rm -rf -- "${W:?}/skills/harness-ci"
run_check "$MUTANTS/trivial-reads"
[ "$RC" -eq 2 ] && ok "control: with the empty-set exit removed source reading nothing needs a classifier" || bad "control: with the empty-set exit removed source reading nothing needs a classifier" "rc=$RC out=$OUT"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
