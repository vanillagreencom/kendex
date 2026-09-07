#!/usr/bin/env bash
# Pins for scripts/byte-ceiling: an addition or a change past the ceiling
# fails naming the file, its bytes and the ceiling, an existing oversized
# file may hold or shrink but not grow, a pure rename is no addition while a
# copy and a moved-and-grown file are, a symlink or gitlink is not sized
# content, --base judges the branch since its merge-base and --all sweeps
# every tracked file, lockfiles and declared asset trees are exempt, the
# ceiling resolves through the settings ladder and is validated, and a
# measurement that breaks is a collection error, never a pass. One table:
# a fixture builds the repository, the check runs with ARGS under ENVS, and
# a row pins the exit status with every line printed, so the hit, the
# remedy, the counts and the scope named are one pin; the run repeats once
# in the same repository and a second verdict that differs is shown (a
# tripwire: the check writes no state, so no row has a positive case). The
# settings ladder's own shapes are settings-precedence.test.sh's.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
BC="$SKILL_DIR/scripts/byte-ceiling"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# Hermetic: a leaked setting would move every ceiling below.
unset COMMIT_GUARDS_BYTE_CEILING_KB COMMIT_GUARDS_BYTE_EXCLUDES COMMIT_GUARDS_SETTINGS_FILE 2>/dev/null || true

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
# assignments; ARGS are passed through. The run repeats once, and a second
# verdict that differs follows after ' / again: '.
R=""
run() { # ENVS ARGS
  local envs=() rc=0 out="" rc2=0 out2="" line line2
  [ -z "$1" ] || IFS=',' read -ra envs <<<"$1"
  # shellcheck disable=SC2086
  out="$(cd "$R" && env ${envs[@]+"${envs[@]}"} "$BC" $2 2>&1)" || rc=$?
  # shellcheck disable=SC2086
  out2="$(cd "$R" && env ${envs[@]+"${envs[@]}"} "$BC" $2 2>&1)" || rc2=$?
  line="rc=$rc${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
  line2="rc=$rc2${out2:+ $(printf '%s\n' "$out2" | LC_ALL=C paste -sd ';' -)}"
  printf '%s' "$line"
  [ "$line" = "$line2" ] || printf ' / again: %s' "$line2"
}

# Fixture vocabulary. Every fixture builds its own repository; a name used
# twice is refused. `put` writes KB kibibytes of one byte (NUL unless FILL is
# given) and stages; `commit` commits what is staged.
repo() { # NAME
  R="$TMP/$1"
  [ ! -e "$R" ] || { echo "harness: fixture $1 already exists" >&2; exit 2; }
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}
put() { # PATH KB [FILL]
  mkdir -p "$R/$(dirname "$1")"
  head -c "$(($2 * 1024))" /dev/zero | tr '\0' "${3:-\0}" >"$R/$1"
  git -C "$R" add -A
}
commit() { git -C "$R" commit -qm "${1:-seed}"; }
EXCL='tools/byte-ceiling-excludes'
excludes() { mkdir -p "$R/tools"; printf '%b' "$1" >"$R/$EXCL"; git -C "$R" add -A; } # CONTENT (printf %b)

# The lines the check prints, as functions of what a row put in.
REMEDY="  remedies: keep big artifacts out of the repo (asset store, Git LFS, build-time generation); a file that genuinely belongs gets a row in $EXCL with its reason"
ERR="::error::byte-ceiling: "
over() { printf 'byte-ceiling FAIL oversized file: %s — %s bytes (~%s KB) > ceiling %s KB;%s' "$1" "$2" "$3" "$4" "$REMEDY"; } # PATH BYTES ~KB CEILING
grew() { printf 'byte-ceiling FAIL oversized file grew: %s — %s -> %s bytes (~%s KB), ceiling %s KB;%s' "$1" "$2" "$3" "$4" "$5" "$REMEDY"; } # PATH PRIOR BYTES ~KB CEILING
STAGED="staged file(s)"
SWEEP="tracked file(s) (full sweep)"
since() { printf 'file(s) added or changed since %s' "$1"; } # REF
ok() { printf 'byte-ceiling: OK — %s %s checked, ceiling %s KB' "$1" "${2:-$STAGED}" "${3:-1}"; } # CHECKED [SCOPE] [CEILING]
failed() { printf 'byte-ceiling: %s violation(s) — ceiling %s KB, %s %s checked' "$1" "${3:-1}" "$2" "${4:-$STAGED}"; } # VIOLATIONS CHECKED [CEILING] [SCOPE]
C=COMMIT_GUARDS_BYTE_CEILING_KB

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

echo "=== staged mode: an addition past the ceiling fails; at the ceiling passes ==="
staged() { repo "$1"; put small.bin 1; [ -z "${2-}" ] || put "$2" "$3"; } # NAME [PATH KB] — a 1 KB file, and one more
run_rows \
  "a 1 KB addition at ceiling 1 KB passes: at the ceiling is not over it|staged at-ceiling|$C=1||rc=0 $(ok 1)" \
  "a 2 KB addition at ceiling 1 KB fails naming file, bytes and ceiling, carrying the remedy and counting both staged files|staged over big.bin 2|$C=1||rc=1 $(over big.bin 2048 2 1);$(failed 1 2)" \
  "a 205 KB addition fails under the built-in 200 KB|staged default-over big.bin 205|||rc=1 $(over big.bin 209920 205 200);$(failed 1 2 200)" \
  "control: a 100 KB addition passes under the built-in default|staged default-under ok.bin 100|||rc=0 $(ok 2 "$STAGED" 200)"

echo "=== a change: past the ceiling fails; an oversized file may shrink or hold, not grow; a rename is no addition ==="
grown() { repo "$1"; put seed.bin "$2"; commit; } # NAME KB — one committed file of KB
fx_edit_over() { grown edit-over 1; put seed.bin 5; }
fx_edit_under() { grown edit-under 1; put seed.bin 1 x; } # the same size with other bytes
fx_untouched() { grown untouched 5; }
fx_shrink() { grown shrink 5; put seed.bin 4; }
fx_grow() { grown "${1:-grow}" 5; put seed.bin 5; printf 'x' >>"$R/seed.bin"; git -C "$R" add -A; } # [NAME]
fx_grow_prior() { fx_grow grow-prior; }
fx_hold() { grown hold 5; put seed.bin 5 y; }
fx_rename() { grown "$1" 5; git -C "$R" mv seed.bin moved.bin; } # NAME
fx_rename_beside() { fx_rename rename-beside; cp "$R/moved.bin" "$R/second-copy.bin"; printf 'x' >>"$R/second-copy.bin"; git -C "$R" add -A; }
fx_move_grow() { grown move-grow 4; git -C "$R" mv seed.bin elsewhere.bin; put elsewhere.bin 5; } # 80% similar: a rename at any lower threshold
fx_copy() { grown copy 3; cp "$R/seed.bin" "$R/twin.bin"; git -C "$R" add -A; }
fx_typechange() { repo typechange; put payload.bin 5; ln -s payload.bin "$R/thing"; git -C "$R" add -A; commit; rm "$R/thing"; put thing 5; }
fx_to_symlink() { grown to-symlink 5; rm "$R/seed.bin"; ln -s payload "$R/seed.bin"; git -C "$R" add -A; }
run_rows \
  "editing a tracked file past the ceiling fails: the staged lane reads A and M|fx_edit_over|$C=1||rc=1 $(over seed.bin 5120 5 1);$(failed 1 1)" \
  "control: the same file edited under the ceiling passes|fx_edit_under|$C=1||rc=0 $(ok 1)" \
  "a committed oversized file is not re-judged while nothing stages it|fx_untouched|$C=1||rc=0 $(ok 0)" \
  "a staged oversized file may shrink toward the ceiling, and the verdict is the same on a second run|fx_shrink|$C=1||rc=0 $(ok 1)" \
  "an existing oversized file may not grow, by one byte|fx_grow|$C=1||rc=1 $(grew seed.bin 5120 5121 6 1);$(failed 1 1)" \
  "an existing oversized file may change without growing|fx_hold|$C=1||rc=0 $(ok 1)" \
  "renaming an existing large file is not an addition: rename detection is on, and the rename is not counted|fx_rename rename|$C=1||rc=0 $(ok 0)" \
  "control: a new large file beside the rename still fails, alone|fx_rename_beside|$C=1||rc=1 $(over second-copy.bin 5121 6 1);$(failed 1 1)" \
  "a file moved AND grown is an addition at its new path: below exact similarity the growth would ride the rename unjudged|fx_move_grow|$C=1||rc=1 $(over elsewhere.bin 5120 5 1);$(failed 1 1)" \
  "an exact copy of an oversized tracked file is an addition: it duplicates the bytes, only renames are followed|fx_copy|$C=1||rc=1 $(over twin.bin 3072 3 1);$(failed 1 1)" \
  "a symlink replaced by an oversized regular file fails as an addition: the link had no prior size|fx_typechange|$C=1||rc=1 $(over thing 5120 5 1);$(failed 1 1)" \
  "control: a file replaced BY a symlink is not sized content|fx_to_symlink|$C=1||rc=0 $(ok 0)"

echo "=== --all sweeps every tracked file; --base REF judges the branch since the merge-base ==="
legacy() { repo "$1"; put old.bin 4; commit "legacy oversized file"; } # NAME
feature() { # NAME ACTION — a feature branch over the legacy file: shrink, grow, add
  legacy "$1"
  git -C "$R" checkout -qb feature
  case "$2" in
    shrink) put old.bin 3; commit "feature: shrinks the legacy file" ;;
    grow) put old.bin 5; commit "feature: grows the legacy file" ;;
    add) put feat.bin 2; commit "feature: adds an oversized file" ;;
    main-moves) put note.bin 1; commit "feature: a note"; git -C "$R" checkout -q main; put old.bin 3; commit "main shrinks the legacy file"; git -C "$R" checkout -q feature ;;
  esac
}
fx_all_symlink() { repo all-symlink; put old.bin 1; ln -s old.bin "$R/alias"; git -C "$R" add -A; commit; }
gitlink() { # NAME STAGE — a committed 1 KB file, then a gitlink at mod: staged only, or committed
  repo "$1"; put ok.bin 1; commit
  git -C "$R" update-index --add --cacheinfo "160000,$(git -C "$R" rev-parse HEAD),mod"
  [ "$2" = staged ] || commit gitlink
}
fx_unmerged() { # NAME — an add/add conflict: the index carries stages 2 and 3 for one path
  repo "$1"
  put base.bin 1; commit
  git -C "$R" checkout -qb theirs; put clash.bin 1 a; commit
  git -C "$R" checkout -q main; put clash.bin 1 b; commit
  git -C "$R" merge -q theirs >/dev/null 2>&1 || true
}
run_rows \
  "staged mode passes with nothing staged: the legacy file is untouched|legacy legacy-staged|$C=1||rc=0 $(ok 0)" \
  "--staged spelled out is the same scope, not a sweep|legacy legacy-staged-flag|$C=1|--staged|rc=0 $(ok 0)" \
  "--all fails on the legacy oversized file, naming the sweep|legacy legacy-all|$C=1|--all|rc=1 $(over old.bin 4096 4 1);$(failed 1 1 1 "$SWEEP")" \
  "--base main permits a legacy oversized file to shrink|feature base-shrink shrink|$C=1|--base main|rc=0 $(ok 1 "$(since main)")" \
  "--base main rejects growth from the merge-base size|feature base-grow grow|$C=1|--base main|rc=1 $(grew old.bin 4096 5120 5 1);$(failed 1 1 1 "$(since main)")" \
  "--base main fails on the branch's added file|feature base-add add|$C=1|--base main|rc=1 $(over feat.bin 2048 2 1);$(failed 1 1 1 "$(since main)")" \
  "--base=REF is the same mode|feature base-eq add|$C=1|--base=main|rc=1 $(over feat.bin 2048 2 1);$(failed 1 1 1 "$(since main)")" \
  "--base judges from the merge-base: a legacy file main shrank after the branch point is not the branch's growth|feature base-main-moves main-moves|$C=1|--base main|rc=0 $(ok 1 "$(since main)")" \
  "--all does not size a tracked symlink: one file checked beside it|fx_all_symlink|$C=1|--all|rc=0 $(ok 1 "$SWEEP")" \
  "--all does not size a committed gitlink either: it carries a commit id, not content|gitlink gitlink-all committed|$C=1|--all|rc=0 $(ok 1 "$SWEEP")" \
  "a staged gitlink is not sized content|gitlink gitlink-staged staged|$C=1||rc=0 $(ok 0)" \
  "control: --base main on main itself has no additions|legacy base-self|$C=1|--base main|rc=0 $(ok 0 "$(since main)")" \
  "an unknown --base ref is exit 2, naming it|legacy base-unknown|$C=1|--base no-such-ref|rc=2 ${ERR}--base ref 'no-such-ref' does not name a commit" \
  "--base without a ref is exit 2|legacy base-bare|$C=1|--base|rc=2 ${ERR}--base requires a ref" \
  "an unmerged index is refused rather than measured around: the conflict's addition would vanish from the record set|fx_unmerged unmerged-staged|$C=1||rc=2 clash.bin;${ERR}the index carries 1 unmerged path(s) (listed above) and a --cached scan skips them silently — finish or abort the merge, then re-run" \
  "--all refuses it too, where ls-files would size one blob per stage|fx_unmerged unmerged-all|$C=1|--all|rc=2 clash.bin;${ERR}the index carries 1 unmerged path(s) (listed above) and a --cached scan skips them silently — finish or abort the merge, then re-run"

echo "=== lockfiles are exempt by basename; declared asset trees by an excludes row with a reason ==="
fx_lock() { repo "$1"; put "${2:-package-lock.json}" 2; } # NAME [PATH]
fx_lock_twin() { fx_lock lock-twin; cp "$R/package-lock.json" "$R/data.json"; git -C "$R" add -A; }
fx_lock_suffix() { repo lock-suffix; put not-package-lock.json 2; }
asset() { repo "$1"; put assets/demo.gif 2; } # NAME
fx_excluded() { asset excluded; excludes 'assets/*\tdemo media\n'; }
fx_no_reason() { asset no-reason; excludes 'assets/*\n'; }
fx_excludes_flag() { asset "$1"; mkdir -p "$R/conf"; printf 'assets/*\tdemo media\n' >"$R/conf/excludes"; git -C "$R" add -A; }
run_rows \
  "an oversized package-lock.json passes and is not counted: the built-in lockfile exemption|fx_lock lock|$C=1||rc=0 $(ok 0)" \
  "a nested lockfile is exempt too: the basename is what is judged|fx_lock lock-nested ui/package-lock.json|$C=1||rc=0 $(ok 0)" \
  "control: the same bytes as data.json fail, the exemption is the basename|fx_lock_twin|$C=1||rc=1 $(over data.json 2048 2 1);$(failed 1 1)" \
  "control: a basename that only ends in a lockfile's name is not exempt|fx_lock_suffix|$C=1||rc=1 $(over not-package-lock.json 2048 2 1);$(failed 1 1)" \
  "control: an asset fails without an excludes row|asset asset-bare|$C=1||rc=1 $(over assets/demo.gif 2048 2 1);$(failed 1 1)" \
  "an excludes row exempts the declared tree; the list itself is a staged file and is counted|fx_excluded|$C=1||rc=0 $(ok 1)" \
  "a pattern without a reason is exit 2 naming the line|fx_no_reason|$C=1||rc=2 ${ERR}$EXCL:1: expected 'pattern<TAB>reason' (every exclusion carries its justification)" \
  "--excludes FILE names the list, and the remedy names it too|fx_excludes_flag excludes-flag|$C=1|--excludes conf/excludes|rc=0 $(ok 1)" \
  "the equals form of --excludes names the same list|fx_excludes_flag excludes-eq|$C=1|--excludes=conf/excludes|rc=0 $(ok 1)" \
  "control: without the flag the same repository fails on the asset, and the remedy names the default list|fx_excludes_flag excludes-default|$C=1||rc=1 $(over assets/demo.gif 2048 2 1);$(failed 1 2)"

echo "=== the ceiling resolves through the settings ladder and is validated ==="
cfg() { repo "$1"; put f.txt 1; } # NAME
fx_settings() { cfg "$1"; printf '[env]\nCOMMIT_GUARDS_BYTE_CEILING_KB = "3"\n' >"$R/kendex.settings.toml"; put big.bin 4; }
run_rows \
  "a non-numeric ceiling is exit 2, quoting it|cfg non-numeric|$C=abc||rc=2 ${ERR}COMMIT_GUARDS_BYTE_CEILING_KB must be a positive integer, got 'abc'" \
  "a zero ceiling is exit 2|cfg zero|$C=0||rc=2 ${ERR}COMMIT_GUARDS_BYTE_CEILING_KB must be a positive integer, got '0'" \
  "an unknown flag is exit 2, quoting it|cfg unknown-flag|$C=1|--no-such-flag|rc=2 ${ERR}unknown argument '--no-such-flag' (see --help)" \
  "kendex.settings.toml supplies the ceiling: 4 KB fails at 3 where the built-in 200 would pass|fx_settings settings-file|||rc=1 $(over big.bin 4096 4 3);$(failed 1 3 3)" \
  "the environment overrides the settings file: 5 passes where 3 failed|fx_settings settings-env|$C=5||rc=0 $(ok 3 "$STAGED" 5)"
assert_eq "--help prints usage at exit 0" "rc=0 usage: byte-ceiling [--staged | --base REF | --all] [--excludes FILE]" "$(run '' --help | LC_ALL=C cut -d';' -f1)"
assert_eq "-h is --help" "$(run '' --help)" "$(run '' -h)"

echo "=== fail-closed: a broken blob measurement is a collection error, never a pass ==="
# A git ahead of PATH whose `cat-file -s` fails as an object read does.
REAL_GIT="$(command -v git)"
mkdir -p "$TMP/git-shim"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = cat-file ] && [ "${2:-}" = -s ]; then echo "fatal: simulated object read failure" >&2; exit 128; fi\nexec %q "$@"\n' "$REAL_GIT" >"$TMP/git-shim/git"
chmod +x "$TMP/git-shim/git"
# Hashed outside any repository: the fixtures are sha1 by default, and a
# host checkout under another object format must not answer for them.
SHA2K="$(cd "$TMP" && head -c 2048 /dev/zero | git hash-object --stdin)"
SHA5K="$(cd "$TMP" && head -c 5120 /dev/zero | git hash-object --stdin)"
# A git whose `cat-file -s` fails for the 5 KB blob alone: the prior of a grown file.
mkdir -p "$TMP/git-shim-prior"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = cat-file ] && [ "${2:-}" = -s ] && [ "${3:-}" = %s ]; then echo "fatal: simulated object read failure" >&2; exit 128; fi\nexec %q "$@"\n' "$SHA5K" "$REAL_GIT" >"$TMP/git-shim-prior/git"
chmod +x "$TMP/git-shim-prior/git"
measure() { repo "$1"; put big.bin 2; } # NAME
run_rows \
  "control: without the shim the oversized staged file fails|measure measure-real|$C=1||rc=1 $(over big.bin 2048 2 1);$(failed 1 1)" \
  "an unmeasurable blob is exit 2 naming the blob and the file, with no verdict line, git's own words ahead of it|measure measure-shim|PATH=$TMP/git-shim:$PATH,$C=1||rc=2 fatal: simulated object read failure;${ERR}cannot read blob $SHA2K for 'big.bin' — its size is unmeasurable, refusing to skip it" \
  "an unmeasurable PRIOR blob is exit 2 too: the tighten-only baseline is not guessed|fx_grow_prior|PATH=$TMP/git-shim-prior:$PATH,$C=1||rc=2 fatal: simulated object read failure;${ERR}cannot read prior blob $SHA5K for 'seed.bin' — its size is unmeasurable, refusing to skip it"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
