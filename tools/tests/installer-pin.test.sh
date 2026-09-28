#!/usr/bin/env bash
# tools/installer-pin: what it writes from a tag, and what --check refuses.
# Every run is over a world built here: a repository holding the tool and
# the five pin sites, with a lightweight tag v1.0.0 on its first commit (C1)
# and an annotated tag v2.0.0 on its second (C2), and a bare clone of it on a
# local path as its `origin`, so no run reaches the network. Pins are set in
# the work tree, which is what the tool reads.
#
# A run renders as `rc=<n> keys=<k=v,...> pins=<...>`: the exit status, every
# `installer-pin: <key>=<value>` line in order, and each site's pin values
# after the run, in the tool's site order, with a commit written by its name.
# `all:X` is five sites that agree. The English under a keyed line is not
# pinned.
#
# The rows table is `label|state|tags|argv|rc|keys|pins`:
#   state   the pins before the run, set by `state` below
#   tags    where the tags are: `local` in the checkout and on origin,
#           `origin` on origin alone, the way a shallow CI checkout sees them,
#           `unreachable` nowhere the tool can list
#   argv    the arguments as written, `-` for none
#
# Each `control` call at the end is one mutant per rule: a copy of the tool
# with that rule's test cut out, run over its row's world, which must answer
# differently from the row, the answer the row would go red on.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../.." && pwd)"
TMP="$(cd "$(mktemp -d)" && pwd -P)" || { echo "installer-pin.test: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

SITES="skills/review-gate/templates/review-gate-writer.yml
skills/review-gate/templates/kendex-refresh.yml
.agents/skills/review-gate/templates/review-gate-writer.yml
.agents/skills/review-gate/templates/kendex-refresh.yml
.github/workflows/review-gate-writer.yml"
ZERO=0000000000000000000000000000000000000000
GITC=(-c user.name=world -c user.email=world@example.invalid -c tag.gpgSign=false -c commit.gpgSign=false)

site_text() { # VERSION SHA — a site's install step holding one pin of each
  printf 'jobs:\n  steps:\n    - name: Install\n      env:\n        KENDEX_VERSION: %s\n        KENDEX_INSTALLER_SHA: %s\n' "$1" "$2"
}

# world — a fresh world at $TMP/w; sets C1 and C2
world() {
  local site
  rm -rf -- "$TMP/w"
  mkdir -p "$TMP/w/tools"
  cp -- "$REPO/tools/installer-pin" "$TMP/w/tools/"
  while IFS= read -r site; do
    mkdir -p "$TMP/w/$(dirname -- "$site")"
    site_text v0.0.0 "$ZERO" >"$TMP/w/$site"
  done <<<"$SITES"
  git -C "$TMP/w" init --quiet
  git -C "$TMP/w" config gc.auto 0
  git -C "$TMP/w" config maintenance.auto false
  git -C "$TMP/w" add --all
  git -C "$TMP/w" "${GITC[@]}" commit --quiet -m one
  git -C "$TMP/w" tag v1.0.0
  git -C "$TMP/w" "${GITC[@]}" commit --quiet --allow-empty -m two
  git -C "$TMP/w" "${GITC[@]}" tag -a -m two v2.0.0
  C1="$(git -C "$TMP/w" rev-parse v1.0.0^{commit})"
  C2="$(git -C "$TMP/w" rev-parse v2.0.0^{commit})"
  [ "$C1" != "$C2" ] || { echo "installer-pin.test: the world's two tags name one commit" >&2; exit 1; }
  rm -rf -- "$TMP/origin.git"
  git clone --quiet --bare -- "$TMP/w" "$TMP/origin.git"
  git -C "$TMP/w" remote add origin "$TMP/origin.git"
}

tags() { # WHERE — see the rows table
  case "$1" in
    local) ;;
    origin) git -C "$TMP/w" tag -d v1.0.0 v2.0.0 >/dev/null ;;
    unreachable)
      git -C "$TMP/w" tag -d v1.0.0 v2.0.0 >/dev/null
      git -C "$TMP/w" remote set-url origin "$TMP/nowhere.git"
      ;;
    *) echo "installer-pin.test: unknown tags $1" >&2; exit 1 ;;
  esac
}

# state NAME — the pins before a run. `v1` is every site at v1.0.0 and C1;
# each other state is v1 with one planted defect.
state() {
  local site last
  while IFS= read -r site; do
    case "$1" in
      fresh) site_text v0.0.0 "$ZERO" >"$TMP/w/$site" ;;
      *) site_text v1.0.0 "$C1" >"$TMP/w/$site" ;;
    esac
  done <<<"$SITES"
  last=.github/workflows/review-gate-writer.yml
  case "$1" in
    fresh|v1) ;;
    sha) site_text v1.0.0 "$C2" >"$TMP/w/$last" ;;
    version) site_text v2.0.0 "$C2" >"$TMP/w/$last" ;;
    dup) printf '        KENDEX_VERSION: v1.0.0\n' >>"$TMP/w/skills/review-gate/templates/review-gate-writer.yml" ;;
    missing) printf 'jobs:\n        KENDEX_VERSION: v1.0.0\n' >"$TMP/w/.agents/skills/review-gate/templates/kendex-refresh.yml" ;;
    absent) rm -- "$TMP/w/$last" ;;
    *) echo "installer-pin.test: unknown state $1" >&2; exit 1 ;;
  esac
}

pins() { # each site's pin values, `/`-joined, commits named; all:X when they agree
  local site line values out="" first="" same=1
  while IFS= read -r site; do
    values=""
    if [ -f "$TMP/w/$site" ]; then
      while IFS= read -r line; do
        case "$line" in
          *KENDEX_VERSION:*|*KENDEX_INSTALLER_SHA:*) line="${line#*: }" ;;
          *) continue ;;
        esac
        case "$line" in "$C1") line=C1 ;; "$C2") line=C2 ;; "$ZERO") line=Z ;; esac
        values="$values/$line"
      done <"$TMP/w/$site"
      values="${values#/}"
    else
      values=absent
    fi
    [ -n "$first" ] || first="$values"
    [ "$values" = "$first" ] || same=0
    out="$out $values"
  done <<<"$SITES"
  if [ "$same" = 1 ]; then printf 'all:%s\n' "$first"; else printf '%s\n' "${out# }"; fi
}

# run TOOL ARGV... — sets RC, OUT, GOT
run() {
  local tool="$1" line keys=""
  shift
  RC=0
  OUT="$(cd "$TMP/w" && env -i PATH="$PATH" HOME="$TMP" GIT_CONFIG_NOSYSTEM=1 "$tool" "$@" 2>&1)" || RC=$?
  while IFS= read -r line; do
    case "$line" in 'installer-pin: '*) keys="$keys,${line#installer-pin: }" ;; esac
  done <<<"$OUT"
  keys="${keys#,}"
  GOT="rc=$RC keys=${keys:--} pins=$(pins)"
}

rows="
pin a lightweight tag|fresh|local|v1.0.0|0|pinned=v1.0.0|all:v1.0.0/C1
pin an annotated tag writes its commit|v1|local|v2.0.0|0|pinned=v2.0.0|all:v2.0.0/C2
pin an annotated tag on origin writes its commit|v1|origin|v2.0.0|0|pinned=v2.0.0|all:v2.0.0/C2
pin an absent tag writes nothing|v1|local|v9.9.9|1|tag=v9.9.9|all:v1.0.0/C1
pin over a bad site writes nothing|missing|local|v2.0.0|1|site=.agents/skills/review-gate/templates/kendex-refresh.yml|v1.0.0/C1 v1.0.0/C1 v1.0.0/C1 v1.0.0 v1.0.0/C1
check pinned sites|v1|local|--check|0|pinned=v1.0.0|all:v1.0.0/C1
check pinned sites against origin|v1|origin|--check|0|pinned=v1.0.0|all:v1.0.0/C1
check with origin unreachable|v1|unreachable|--check|1|remote=origin|all:v1.0.0/C1
check a version with no tag|fresh|local|--check|1|tag=v0.0.0|all:v0.0.0/Z
check a SHA that is not the tag's commit|sha|local|--check|1|mismatch=.github/workflows/review-gate-writer.yml|v1.0.0/C1 v1.0.0/C1 v1.0.0/C1 v1.0.0/C1 v1.0.0/C2
check a SHA that is not the origin tag's commit|sha|origin|--check|1|mismatch=.github/workflows/review-gate-writer.yml|v1.0.0/C1 v1.0.0/C1 v1.0.0/C1 v1.0.0/C1 v1.0.0/C2
check a site naming another version|version|local|--check|1|mismatch=.github/workflows/review-gate-writer.yml|v1.0.0/C1 v1.0.0/C1 v1.0.0/C1 v1.0.0/C1 v2.0.0/C2
check a site with two version lines|dup|local|--check|1|site=skills/review-gate/templates/review-gate-writer.yml|v1.0.0/C1/v1.0.0 v1.0.0/C1 v1.0.0/C1 v1.0.0/C1 v1.0.0/C1
check a site with no SHA line|missing|local|--check|1|site=.agents/skills/review-gate/templates/kendex-refresh.yml|v1.0.0/C1 v1.0.0/C1 v1.0.0/C1 v1.0.0 v1.0.0/C1
check an absent site|absent|local|--check|1|site=.github/workflows/review-gate-writer.yml|v1.0.0/C1 v1.0.0/C1 v1.0.0/C1 v1.0.0/C1 absent
no argument|v1|local|-|2|option=|all:v1.0.0/C1
unknown option|v1|local|--pin|2|option=--pin|all:v1.0.0/C1
check with an extra argument|v1|local|--check x|2|option=x|all:v1.0.0/C1
"
while IFS='|' read -r label st where argv rc keys want_pins; do
  [ -n "$label" ] || continue
  world
  state "$st"
  tags "$where"
  if [ "$argv" = - ]; then run tools/installer-pin; else
    # shellcheck disable=SC2086
    run tools/installer-pin $argv
  fi
  want="rc=$rc keys=$keys pins=$want_pins"
  if [ "$GOT" = "$want" ]; then ok "$label: $want"; else bad "$label: want $want" "got $GOT
$OUT"; fi
done <<<"$rows"

# control LABEL ROW RULE REPLACEMENT: the tool with RULE, which occurs
# exactly once in it, replaced, run over ROW's world.
control() {
  local label="$1" row="$2" spec st where argv rc keys want_pins want
  MUTANT_RULE="$3" MUTANT_REPLACEMENT="$4" python3 - "$REPO/tools/installer-pin" "$TMP/mutant" <<'PY_MUTANT'
import os, sys
text = open(sys.argv[1]).read()
rule, replacement = os.environ["MUTANT_RULE"], os.environ["MUTANT_REPLACEMENT"]
if text.count(rule) != 1:
    sys.exit("installer-pin.test: the rule text occurs %d times, not 1: %s" % (text.count(rule), rule))
open(sys.argv[2], "w").write(text.replace(rule, replacement))
PY_MUTANT
  spec="$(grep -F -- "$row|" <<<"$rows")" || { echo "installer-pin.test: no row $row" >&2; exit 1; }
  IFS='|' read -r _ st where argv rc keys want_pins <<<"$spec"
  world
  state "$st"
  tags "$where"
  cp -- "$TMP/mutant" "$TMP/w/tools/installer-pin"
  # shellcheck disable=SC2086
  run tools/installer-pin $argv
  want="rc=$rc keys=$keys pins=$want_pins"
  if [ "$GOT" != "$want" ]; then ok "control, $label: the mutant answers $GOT"; else bad "control, $label: the mutant still answers the row" "$GOT"; fi
}

control 'the SHA is its tag'"'"'s commit' 'check a SHA that is not the tag'"'"'s commit' '[ "$sha" = "$want" ] ||' 'true ||'
control 'every site names one version' 'check a site naming another version' '[ "$version" = "$first" ] ||' 'true ||'
control 'one line of each variable' 'check a site with two version lines' '[ "$count" = 1 ] ||' 'true ||'
control 'the tag resolves' 'pin an absent tag writes nothing' '[ -n "$sha" ] ||' 'true ||'
control 'origin could be listed' 'check with origin unreachable' '"refs/tags/$1^{}")" ||' '"refs/tags/$1^{}")" || true ||'
control 'an annotated tag on origin names its peeled commit' 'pin an annotated tag on origin writes its commit' 'print (peeled != "" ? peeled : plain)' 'print plain'
control 'every site is read before one is written' 'pin over a bad site writes nothing' 'value "$site" KENDEX_INSTALLER_SHA >/dev/null' ':'

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
