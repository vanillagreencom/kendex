#!/usr/bin/env bash
# The settings loaders are vendored, not shared: each skill package installs
# standalone, so a copy that sourced another skill's path would break any
# repo that installed only that one skill. Sameness is therefore a pin, not
# a consequence — this suite is what makes an edit to one copy red.
#
# WHAT IT ENFORCES, over the source tree and its .agents render alike:
#   * kendex-env.sh — every skill carrying it carries the same bytes.
#   * lib/settings.sh — growth-guards, review-gate and size-ratchet each
#     hold their own prefixed copy of a shared helper set. Every helper is
#     compared: it must be carried by every copy and be one text once the
#     gg_/rg_/sr_ prefix is normalized away, unless a declaration below
#     names it and says why. A helper only one copy carries is a rename and
#     is never excusable. Which helpers those are is not written down here —
#     the rule is over whatever the copies declare, so a helper added
#     tomorrow is pinned without editing this file.
#   * the path shapes named below — a rostered path is a regular file or is
#     absent, no directory component below the root is a link, and a render
#     git tracks is present.
#
# WHAT IT DOES NOT ATTEMPT. It does not decide whether a tree is a readable
# catalog. SealedSource::contained answers that at read time, over every
# component of every path, and says so with SourceEscape; re-deriving it in
# bash would be a second opinion that is always the weaker one. Nor does it
# judge the index: a render deleted in the same commit as its source is a
# question for review and for the engine at use. So a green run here says
# these copies match and the shapes named above are clean. It is not a
# statement that the tree is a valid catalog or that it installs.
#
# Each check fails closed on its own terms. A roster is globbed, never
# listed, so a seventh copy is compared the day it lands; an empty glob, a
# copy whose prefix cannot be derived, and a declaration naming nothing all
# end in red rather than in a pass with nothing compared.
#
# Behavioral changes belong in skills/orch/scripts/lib/kendex-env.sh and
# skills/review-gate/scripts/lib/settings.sh, then re-vendored to the rest.
# What each loader DOES is proven elsewhere: skills/orch/tests/
# kendex-env-precedence.sh and each skill's own settings suite. Nothing here
# runs a loader.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)" || exit 2
TMP="$(mktemp -d)" || exit 2
trap 'rm -rf -- "${TMP:?}"' EXIT

NL='
'
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ $# -lt 2 ] || printf '        %s\n' "$2"; }
verdict() { printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }

# The render paths git carries. Asking the FILESYSTEM whether a skill has a
# render cannot tell one that was never rendered from one whose render was
# deleted, so a wholesale deletion read as "nothing to check" — while the
# repo rule is that a source change lands its render in the same commit.
# git knows the difference: a render it tracks is owed, whatever the working
# tree holds. One listing, status checked, because a git that could not run
# would otherwise read as a repository that renders nothing.
TRACKED_RENDERS=""
git_status=0
TRACKED_RENDERS="$(git -C "$REPO_ROOT" ls-files -- \
  '.agents/skills/*/scripts/lib/kendex-env.sh' '.agents/skills/*/scripts/lib/settings.sh')" || git_status=$?
if [ "$git_status" != 0 ] || [ -z "$TRACKED_RENDERS" ]; then
  bad "git listed no tracked render (exit $git_status), so no render below was checked"
  verdict
  exit
fi
# Membership by whole line: a path is owed a render or it is not.
render_tracked() { # RENDER_PATH
  case "$NL$TRACKED_RENDERS$NL" in *"$NL$1$NL"*) return 0 ;; esac
  return 1
}

# Helper names the three settings.sh copies deliberately spell differently,
# each with the reason it is not one text. A name here that no longer
# diverges — or that no longer exists — is a stale declaration and reds, so
# the list cannot quietly outlive what it excuses.
DIVERGENT="setting settings_source dotenv_layer"
#   setting          — the resolution ladder itself: per-key exceptions and
#                      the *_SETTINGS_FILE name differ by skill.
#   settings_source  — growth-guards shares one index dir across a hook
#                      lane's sibling checks, so its temp-and-rename keeps a
#                      killed child's partial out of a later sibling's read;
#                      size-ratchet's dies with its own single-reader run.
#   dotenv_layer     — growth-guards routes the env file through
#                      settings_source; review-gate reads the path directly.

# Helper names some copies deliberately lack, each with the reason. Every
# other name must be carried by EVERY settings.sh copy: without that, one
# copy could simply delete a shared helper and the survivors would still
# agree with each other. A name here that every copy now carries is stale
# and reds. A name only ONE copy carries is never excusable — that is a
# rename, and adding a genuinely private helper means changing this rule on
# purpose rather than declaring around it.
PARTIAL="settings_normalize_path settings_source dotenv_layer"
#   settings_normalize_path, settings_source — the staged-index read, which
#                      only the two commit-time guards perform.
#   dotenv_layer     — size-ratchet reads .env.local inline in sr_setting.

# Membership over a whitespace-separated set: the declarations above and the
# collected name list are both read this way, so one spelling serves both.
listed() { case " $2 " in *[$' \t\n']"$1"[$' \t\n']*) return 0 ;; esac; return 1; }

# How one rostered path reads. This is the classification the resolvers
# this suite pins apply to their own sources, and the one review-gate's
# scan_source applies to its TOML sources: ABSENT is an ordinary install and
# skips, a regular file is compared, and every other shape EXISTS while
# being unreadable as a vendored copy. Testing -f alone called all of them
# absent — the same "present is not absent" defect this PR is about, in the
# suite standing behind it. -L comes first because -f and -d both follow.
# The first symlinked DIRECTORY between ROOT and PATH, printed; 1 when
# there is none. classify_path answers for the leaf and `-f` follows, so a
# lib/ replaced by a link to another skill's lib/ leaves every leaf a real
# regular file and every byte equal. The engine does not read it that way:
# SealedSource::contained pushes each component in turn, takes
# symlink_metadata on it, and answers any link with SourceEscape — so the
# containing directories are as much a part of the shape as the file is.
symlinked_ancestor() { # ROOT PATH
  local probe="$1" rest="${2%/*}" component
  rest="${rest#"$1/"}"
  while [ -n "$rest" ]; do
    component="${rest%%/*}"
    probe="$probe/$component"
    [ ! -L "$probe" ] || { printf '%s' "$probe"; return 0; }
    case "$rest" in
      */*) rest="${rest#*/}" ;;
      *) rest="" ;;
    esac
  done
  return 1
}

classify_path() { # PATH — one word or phrase naming what is there
  if [ -L "$1" ]; then printf 'a symlink'
  elif [ -d "$1" ]; then printf 'a directory'
  elif [ -f "$1" ]; then printf 'file'
  elif [ -e "$1" ]; then printf 'not a regular file (a FIFO, socket or device)'
  else printf 'absent'
  fi
}

# Every skill under ROOT whose REL is a readable vendored copy, as skill
# names, one per line. Anything present but unusable is refused by the pass
# in check_tree before this roster is read, so nothing silently drops.
skills_carrying() { # ROOT PARENT REL
  local p out=""
  for p in "$1/$2"/*/scripts/lib/"$3"; do
    [ "$(classify_path "$p")" = file ] || continue
    p="${p%/scripts/lib/$3}"
    out="$out${p##*/}$NL"
  done
  printf '%s' "$out"
}

# One prefixed function, prefix normalized away. Empty when absent. It reads
# from the name's line to the first column-zero `}`, which is only the whole
# body while no body CONTAINS one — these files embed awk programs, so that
# is an assumption, and check_tree asserts it below rather than trusting it.
body_of() { # FILE PREFIX NAME
  awk -v n="$2_$3" '$0 ~ "^" n "\\(\\)" { f = 1 } f { print } f && /^}$/ { exit }' "$1" \
    | sed "s/$2_/PFX_/g"
}

# The prefix a settings.sh answers to, taken from its own *_env_table line.
prefix_of() { # FILE
  awk 'match($0, /^[a-z][a-z0-9]*_env_table\(\)/) { sub(/_env_table\(\).*/, ""); print; exit }' "$1"
}

# Both pins over an arbitrary tree root. Diagnostics on stdout, one nonzero
# exit for any divergence — the controls below run this against deliberately
# edited copies of the tree and require that exit.
check_tree() { # ROOT
  local root="$1" rc=0 rel skill first parent copies prefix names n i seen opens closes unprefixed repeated path link
  local scratch="$TMP/map.$$.$RANDOM"

  # --- 0. every rostered path is a regular file, or absent ---
  # A path that EXISTS as something else was read as absent by the -f filter
  # below, so it dropped out of the roster and the pin called the tree
  # healthy while that skill could not source its copy at all. A symlink is
  # one case of it and not a special one: source_read.rs takes
  # symlink_metadata and answers a link in a catalog with SourceEscape, so
  # the engine refuses a tree the bytes would have compared equal through.
  for parent in skills .agents/skills; do
    for rel in kendex-env.sh settings.sh; do
      for path in "$root/$parent"/*/scripts/lib/"$rel"; do
        # Ancestors first: with one symlinked directory every leaf below it
        # is a regular file, so the leaf classification has nothing to say.
        if link="$(symlinked_ancestor "$root" "$path")"; then
          echo "${link#"$root/"} is a symlinked directory on the way to ${path#"$root/"}; the engine refuses to read through it"
          rc=1
          continue
        fi
        case "$(classify_path "$path")" in
          file | absent) ;;
          *)
            echo "${path#"$root/"} is $(classify_path "$path"); a vendored copy is a regular file or is not there at all"
            rc=1
            ;;
        esac
      done
    done
  done

  # --- 1. every source has its render, byte for byte, in both families ---
  for rel in kendex-env.sh settings.sh; do
    copies="$(skills_carrying "$root" skills "$rel")"
    if [ -z "$copies" ]; then
      echo "no skills/*/scripts/lib/$rel under $root — nothing was compared"
      rc=1
      continue
    fi
    for skill in $copies; do
      # A skill this repo does not install is owed no render, and git is
      # what says which those are. One under .agents with no source is
      # caught by the reverse pass below.
      render_tracked ".agents/skills/$skill/scripts/lib/$rel" || continue
      if [ "$(classify_path "$root/.agents/skills/$skill/scripts/lib/$rel")" != file ]; then
        echo ".agents/skills/$skill/scripts/lib/$rel is tracked but not here; a source change lands its render in the same commit"
        rc=1
        continue
      fi
      if ! cmp -s "$root/skills/$skill/scripts/lib/$rel" "$root/.agents/skills/$skill/scripts/lib/$rel"; then
        echo ".agents/skills/$skill/scripts/lib/$rel is not its source, byte for byte"
        rc=1
      fi
    done
    for skill in $(skills_carrying "$root" .agents/skills "$rel"); do
      if [ ! -f "$root/skills/$skill/scripts/lib/$rel" ]; then
        echo ".agents/skills/$skill/scripts/lib/$rel is a render of no source"
        rc=1
      fi
    done
  done

  # --- 2. every kendex-env.sh copy is the same bytes ---
  first=""
  for parent in skills .agents/skills; do
    for skill in $(skills_carrying "$root" "$parent" kendex-env.sh); do
      if [ -z "$first" ]; then
        first="$root/$parent/$skill/scripts/lib/kendex-env.sh"
      elif ! cmp -s "$first" "$root/$parent/$skill/scripts/lib/kendex-env.sh"; then
        echo "$parent/$skill/scripts/lib/kendex-env.sh is not byte-identical to ${first#"$root/"}"
        rc=1
      fi
    done
  done

  # --- 3. the settings.sh helper set, keyed by name across skills ---
  # Sources only: a render was already held to its source in step 1, and
  # counting it would let a renamed helper look shared with itself.
  mkdir -p "$scratch" || return 1
  seen=""
  for skill in $(skills_carrying "$root" skills settings.sh); do
    prefix="$(prefix_of "$root/skills/$skill/scripts/lib/settings.sh")"
    if [ -z "$prefix" ]; then
      echo "skills/$skill/scripts/lib/settings.sh declares no <prefix>_env_table, so its helpers could not be named"
      rc=1
      continue
    fi
    # The comparison below collects PREFIXED definitions, so an unprefixed
    # top-level one would sit outside it while still balancing the brace
    # count — a helper that escapes the pin entirely. Requiring the prefix is
    # what keeps the two halves talking about the same set.
    unprefixed="$(grep -oE "^[A-Za-z_][A-Za-z0-9_]*\(\)" "$root/skills/$skill/scripts/lib/settings.sh" \
      | sed 's/()$//' | grep -vE "^${prefix}_" | tr '\n' ' ' || true)"
    if [ -n "$unprefixed" ]; then
      echo "skills/$skill/scripts/lib/settings.sh defines top-level helpers without the ${prefix}_ prefix, so nothing here compares them: ${unprefixed% }"
      rc=1
    fi
    # body_of cuts at the first column-zero `}`, so one inside a helper body
    # would silently shorten that helper to its head and let drift below the
    # cut pass. With every definition prefixed, the closing braces and the
    # definitions come out even exactly while no body holds one.
    opens="$(grep -cE "^[A-Za-z_][A-Za-z0-9_]*\(\)" "$root/skills/$skill/scripts/lib/settings.sh" || true)"
    closes="$(grep -cE '^\}$' "$root/skills/$skill/scripts/lib/settings.sh" || true)"
    if [ "$opens" != "$closes" ]; then
      echo "skills/$skill/scripts/lib/settings.sh has $opens top-level definitions and $closes column-zero closing braces; a brace inside a body would cut every helper comparison short"
      rc=1
    fi
    names="$(grep -oE "^${prefix}_[A-Za-z0-9_]+\(\)" "$root/skills/$skill/scripts/lib/settings.sh" | sed "s/^${prefix}_//; s/()\$//" || true)"
    # body_of reads a name's FIRST definition, while bash runs its last, so a
    # repeated one makes the copy behave differently from what is compared —
    # an ordinary copy-paste or merge accident, not a spelling.
    repeated="$(printf '%s\n' $names | sort | uniq -d | tr '\n' ' ' || true)"
    if [ -n "$repeated" ]; then
      echo "skills/$skill/scripts/lib/settings.sh defines ${prefix}_ helpers more than once, and bash runs the LAST while this compares the first: ${repeated% }"
      rc=1
    fi
    if [ -z "$names" ]; then
      echo "skills/$skill/scripts/lib/settings.sh declares no ${prefix}_ functions at all"
      rc=1
      continue
    fi
    for n in $names; do
      mkdir -p "$scratch/$n"
      body_of "$root/skills/$skill/scripts/lib/settings.sh" "$prefix" "$n" >"$scratch/$n/$skill"
      listed "$n" "$seen" || seen="$seen$n$NL"
    done
  done
  if [ -z "$seen" ]; then
    echo "no settings.sh helper was collected under $root — nothing was compared"
    rc=1
  fi

  local total drifted
  # grep -c exits 1 on a count of zero, which is a reading here, not a
  # failure — the empty case is reported by the guard above.
  total="$(skills_carrying "$root" skills settings.sh | grep -c . || true)"
  for n in $seen; do
    set -- "$scratch/$n"/*
    if [ "$#" -lt 2 ]; then
      echo "*_$n is carried by ${1##*/} alone; a lone helper is a rename that dropped its siblings out of the comparison"
      rc=1
      continue
    fi
    if [ "$#" -lt "$total" ]; then
      if ! listed "$n" "$PARTIAL"; then
        echo "*_$n is carried by $# of $total settings.sh copies; a helper missing from one copy is a deletion until PARTIAL declares it"
        rc=1
      fi
    elif listed "$n" "$PARTIAL"; then
      echo "*_$n is declared PARTIAL but every settings.sh copy carries it — drop the declaration"
      rc=1
    fi
    first="$1"
    shift
    drifted=no
    for i in "$@"; do
      if ! cmp -s "$first" "$i"; then
        drifted=yes
        listed "$n" "$DIVERGENT" && continue
        echo "*_$n differs between ${first##*/} and ${i##*/} by more than its prefix"
        rc=1
      fi
    done
    if [ "$drifted" = no ] && listed "$n" "$DIVERGENT"; then
      echo "*_$n is declared DIVERGENT but its copies are one text — drop the declaration"
      rc=1
    fi
  done

  # --- 4. no declaration outlives what it excuses ---
  for n in $DIVERGENT $PARTIAL; do
    [ -d "$scratch/$n" ] || { echo "*_$n is declared here but no settings.sh carries it"; rc=1; }
  done

  rm -rf -- "${scratch:?}"
  return "$rc"
}

echo "=== the vendored copies are one text ==="
if check_tree "$REPO_ROOT"; then
  ok "every kendex-env.sh copy, every render, and every shared settings.sh helper matches its siblings"
else
  bad "the vendored copies have diverged (see above)"
fi

# A tree holding only what check_tree reads, so a control can edit or plant a
# copy without touching the repository.
control="$TMP/control"
for parent in skills .agents/skills; do
  for rel in kendex-env.sh settings.sh; do
    for p in "$REPO_ROOT/$parent"/*/scripts/lib/"$rel"; do
      [ -f "$p" ] || continue
      skill="${p%/scripts/lib/$rel}"
      skill="${skill##*/}"
      mkdir -p "$control/$parent/$skill/scripts/lib"
      cp "$p" "$control/$parent/$skill/scripts/lib/$rel"
    done
  done
done
check_tree "$control" >/dev/null 2>&1 \
  && ok "the control tree starts clean" \
  || bad "the control tree is already divergent — every control below proves nothing"

# reds NAME EXPECT_SUBSTRING STAGE — STAGE mutates the control tree, the
# check must fail and say why, and the tree is restored afterwards.
reds() {
  local name="$1" want="$2" out status=0
  ( eval "$3" )
  # BOTH halves are required. A check that printed its diagnostic and still
  # returned 0 would leave every control here green while the pin accepted
  # the divergence, so the status is read as well as the words.
  out="$(check_tree "$control" 2>&1)" || status=$?
  if [ "$status" -eq 0 ]; then
    bad "$name — check_tree returned 0" "${out:-check_tree said nothing}"
  elif printf '%s' "$out" | grep -qF -- "$want"; then
    ok "$name"
  else
    bad "$name — no diagnostic carrying: $want" "${out:-check_tree said nothing}"
  fi
}
restore() { # PARENT SKILL REL
  # Remove first, whatever a control left there: cp onto a SYMLINK writes
  # through it into the sibling it points at, and cp onto a DIRECTORY drops
  # the file inside it, leaving the copy still missing.
  rm -rf -- "${control:?}/$1/$2/scripts/lib/$3"
  cp "$REPO_ROOT/$1/$2/scripts/lib/$3" "$control/$1/$2/scripts/lib/$3"
}

echo "=== every drift is caught (controls) ==="

reds "an edited kendex-env.sh copy fails the equality pin" \
  "is not byte-identical" \
  'printf "\n# an edit no other copy carries\n" >>"$control/skills/worktree/scripts/lib/kendex-env.sh"'
restore skills worktree kendex-env.sh

# The roster is globbed, so a copy nobody listed is compared the day it
# lands. A listed roster stayed green through exactly this.
reds "an UNLISTED seventh kendex-env.sh copy is compared, not ignored" \
  "is not byte-identical" \
  'mkdir -p "$control/skills/planted/scripts/lib" &&
   sed "s/^# Shared project/# planted/" "$REPO_ROOT/skills/orch/scripts/lib/kendex-env.sh" \
     >"$control/skills/planted/scripts/lib/kendex-env.sh"'
rm -rf -- "${control:?}/skills/planted"

# One class per control, all of them the same rule: a path that EXISTS as
# something other than a regular file is not absent. The -f filter read
# every one of these as absent, so the copy dropped off the roster and the
# pin called the tree healthy.
#
# A symlink whose bytes match is the sharp case — only the file type
# distinguishes that tree from a healthy one, and the engine still refuses
# it.
reds "a copy replaced by a SYMLINK fails, though its bytes match" \
  "is a symlink; a vendored copy is a regular file" \
  'rm -f "$control/skills/worktree/scripts/lib/kendex-env.sh" &&
   ln -s ../../../orch/scripts/lib/kendex-env.sh "$control/skills/worktree/scripts/lib/kendex-env.sh"'
restore skills worktree kendex-env.sh

# A symlinked ANCESTOR, where every leaf is a real regular file with the
# right bytes and only a containing directory is a link.
reds "a SYMLINKED ANCESTOR fails, though every leaf is a regular file" \
  "is a symlinked directory on the way to" \
  'rm -rf -- "${control:?}/skills/decider/scripts/lib" &&
   ln -s ../../orch/scripts/lib "$control/skills/decider/scripts/lib"'
rm -f -- "${control:?}/skills/decider/scripts/lib"
mkdir -p "$control/skills/decider/scripts/lib"
restore skills decider kendex-env.sh

# A DIRECTORY at one copy: the source goes, the render stays, and the pair
# is inconsistent as well as unusable.
reds "a DIRECTORY at one copy fails, never reads as absent" \
  "is a directory; a vendored copy is a regular file" \
  'rm -f "$control/skills/decider/scripts/lib/kendex-env.sh" &&
   mkdir "$control/skills/decider/scripts/lib/kendex-env.sh"'
restore skills decider kendex-env.sh

# A DIRECTORY at BOTH copies of one skill, which is the shape that passed:
# the pair stays consistent in absence, the glob is not empty, and nothing
# else in the suite has anything to say about it.
reds "a DIRECTORY at BOTH copies fails, though the pair stays consistent" \
  "is a directory; a vendored copy is a regular file" \
  'rm -f "$control/skills/decider/scripts/lib/kendex-env.sh" \
      "$control/.agents/skills/decider/scripts/lib/kendex-env.sh" &&
   mkdir "$control/skills/decider/scripts/lib/kendex-env.sh" \
      "$control/.agents/skills/decider/scripts/lib/kendex-env.sh"'
restore skills decider kendex-env.sh
restore .agents/skills decider kendex-env.sh

# The remaining class — a FIFO stands for socket and device, which read the
# same way — where the platform provides one.
if command -v mkfifo >/dev/null 2>&1; then
  reds "a FIFO at a copy fails, never reads as absent" \
    "is not a regular file (a FIFO, socket or device); a vendored copy is a regular file" \
    'rm -f "$control/skills/github/scripts/lib/kendex-env.sh" &&
     mkfifo "$control/skills/github/scripts/lib/kendex-env.sh"'
  restore skills github kendex-env.sh
else
  echo "  skip  mkfifo unavailable — the FIFO/socket/device class is not exercised"
fi

reds "a render that drifted from its source fails" \
  "is not its source, byte for byte" \
  'printf "\n# a render-only edit\n" >>"$control/.agents/skills/orch/scripts/lib/kendex-env.sh"'
restore .agents/skills orch kendex-env.sh

# A render DELETED wholesale left nothing on the filesystem to notice, so
# the skill read as one that was never rendered. git is what tells those
# apart, and the deletion is the shape the repo rule forbids.
reds "a DELETED render fails, never reads as a skill that has none" \
  "is tracked but not here" \
  'rm -f "$control/.agents/skills/worktree/scripts/lib/kendex-env.sh"'
restore .agents/skills worktree kendex-env.sh

# And the other side of that branch, which every carrier being rendered
# today would otherwise leave untaken: a source git tracks no render for is
# genuinely unrendered and must still be SKIPPED, not reported missing.
mkdir -p "$control/skills/unrendered/scripts/lib"
cp "$REPO_ROOT/skills/orch/scripts/lib/kendex-env.sh" "$control/skills/unrendered/scripts/lib/kendex-env.sh"
if check_tree "$control" >/dev/null 2>&1; then
  ok "a source with no tracked render is skipped, so the unrendered branch is reachable"
else
  bad "a source with no tracked render is skipped" "$(check_tree "$control" 2>&1 || true)"
fi
rm -rf -- "${control:?}/skills/unrendered"

reds "a render of no source fails" \
  "is a render of no source" \
  'mkdir -p "$control/.agents/skills/ghost/scripts/lib" &&
   cp "$REPO_ROOT/skills/orch/scripts/lib/kendex-env.sh" "$control/.agents/skills/ghost/scripts/lib/"'
rm -rf -- "${control:?}/.agents/skills/ghost"

# Inside the awk body, where no prefix appears: the normalization must not
# hide a real change.
reds "an edited [env] reader fails the prefix-normalized pin" \
  "*_env_table differs" \
  'sed "s/in_env = (header == \"\[env\]\")/in_env = (header == \"[ENV]\")/" \
     "$REPO_ROOT/skills/size-ratchet/scripts/lib/settings.sh" \
     >"$control/skills/size-ratchet/scripts/lib/settings.sh"'
restore skills size-ratchet settings.sh

# The hole a whitelist of function names left: renaming one copy dropped the
# helper out of the compared set instead of failing.
reds "a RENAMED shared helper fails instead of leaving the comparison" \
  "a lone helper is a rename" \
  'sed "s/^rg_dotenv_value()/rg_dotenv_val()/; s/rg_dotenv_value /rg_dotenv_val /g" \
     "$REPO_ROOT/skills/review-gate/scripts/lib/settings.sh" \
     >"$control/skills/review-gate/scripts/lib/settings.sh"'
restore skills review-gate settings.sh

# The other half of the rename hole: DELETING a shared helper from one copy
# left the survivors agreeing with each other.
reds "a DELETED shared helper fails instead of leaving the comparison" \
  "a helper missing from one copy is a deletion" \
  'awk "/^rg_settings_grep\\(\\)/ { skip = 1 } skip && /^}\$/ { skip = 0; next } !skip" \
     "$REPO_ROOT/skills/review-gate/scripts/lib/settings.sh" \
     >"$control/skills/review-gate/scripts/lib/settings.sh"'
restore skills review-gate settings.sh

# A declaration that stops excusing anything is stale, in both directions.
# These two arms are about the declarations themselves, so the control names
# a helper that does not need excusing and requires the check to say so.
declares_stale() { # NAME EXPECT_SUBSTRING VAR EXTRA
  local out status=0
  out="$(eval "$3=\"\$$3 $4\"; check_tree \"\$control\"" 2>&1)" || status=$?
  if [ "$status" -eq 0 ]; then
    bad "$1 — check_tree returned 0" "${out:-check_tree said nothing}"
  elif printf '%s' "$out" | grep -qF -- "$2"; then
    ok "$1"
  else
    bad "$1 — no diagnostic carrying: $2" "${out:-check_tree said nothing}"
  fi
}
declares_stale "a DIVERGENT name whose copies are one text is stale" \
  "declared DIVERGENT but its copies are one text" DIVERGENT bom_guard
declares_stale "a PARTIAL name every copy carries is stale" \
  "declared PARTIAL but every settings.sh copy carries it" PARTIAL bom_guard
declares_stale "a declaration naming no helper at all is stale" \
  "is declared here but no settings.sh carries it" DIVERGENT no_such_helper

reds "a settings.sh whose prefix cannot be derived fails, never passes empty" \
  "declares no <prefix>_env_table" \
  'sed "s/^sr_env_table()/sr_table()/" "$REPO_ROOT/skills/size-ratchet/scripts/lib/settings.sh" \
     >"$control/skills/size-ratchet/scripts/lib/settings.sh"'
restore skills size-ratchet settings.sh

# A fourth settings.sh vendoring the same helpers is held to them too.
# The two planted-copy mutations, as functions so the stage strings stay
# free of nested quoting. Both stay portable: `\b` and a `\n` in a sed
# REPLACEMENT are GNU extensions that BSD sed reads as something else, so a
# control written with them is inert or malformed on the mac box — the
# defect class this suite exists to remove. awk inserts the lines instead,
# matching whole lines rather than patterns so neither dialect can differ.
plant_fourth_settings() { # DEST — a fourth copy whose shared helper drifted
  sed "s/rg_/px_/g" "$REPO_ROOT/skills/review-gate/scripts/lib/settings.sh" \
    | awk -v t="px_settings_grep() {" \
        '{ print } index($0, t) == 1 { print "  : drifted" }' >"$1"
}
plant_body_brace() { # DEST — a column-zero } inside *_env_table awk program
  awk -v t='      in_env = (header == "[env]")' \
    '{ print } $0 == t { print "}" }' \
    "$REPO_ROOT/skills/size-ratchet/scripts/lib/settings.sh" >"$1"
}

reds "an UNLISTED fourth settings.sh copy is compared, not ignored" \
  "differs between" \
  'mkdir -p "$control/skills/planted/scripts/lib" &&
   plant_fourth_settings "$control/skills/planted/scripts/lib/settings.sh"'
rm -rf -- "${control:?}/skills/planted"

# The extraction assumption, planted: a column-zero `}` inside the awk
# program in *_env_table cuts every later helper comparison short.
reds "a column-zero brace inside a helper body fails, never shortens the pin" \
  "column-zero closing braces" \
  'plant_body_brace "$control/skills/size-ratchet/scripts/lib/settings.sh"'
restore skills size-ratchet settings.sh

# Its partner: an UNPREFIXED top-level helper balances the brace count while
# sitting outside the name comparison, so it escaped the pin entirely.
reds "an UNPREFIXED top-level helper fails, never escapes the comparison" \
  "without the rg_ prefix" \
  'printf "\nrogue_helper() {\n  echo unprefixed\n}\n" \
     >>"$control/skills/review-gate/scripts/lib/settings.sh"'
restore skills review-gate settings.sh

# And a REPEATED definition, which body_of reads the first of while bash runs
# the last. The duplicate is written multi-line and balanced on purpose: a
# one-liner has no column-zero `}` and would red on brace parity instead,
# leaving this arm proven by the wrong guard.
reds "a REPEATED helper definition fails, never compares only the first" \
  "bash runs the LAST while this compares the first" \
  'printf "\nrg_bom_guard() {\n  return 0\n}\n" \
     >>"$control/skills/review-gate/scripts/lib/settings.sh"'
restore skills review-gate settings.sh

# The glob itself: a root carrying no copy must red, not pass with nothing
# compared. This is the arm that keeps a moved path from reading as clean.
mkdir -p "$TMP/empty"
empty_status=0
empty_out="$(check_tree "$TMP/empty" 2>&1)" || empty_status=$?
if [ "$empty_status" -ne 0 ] && printf '%s' "$empty_out" | grep -qF -- "nothing was compared"; then
  ok "a root carrying no copy fails, never passes with nothing compared"
else
  bad "a root carrying no copy fails, never passes with nothing compared (status $empty_status)" "${empty_out:-check_tree said nothing}"
fi

# No control may leave the tree mutated: every arm above would otherwise be
# judging a tree some earlier arm broke.
check_tree "$control" >/dev/null 2>&1 \
  && ok "the control tree is clean again, so no control leaked into the next" \
  || bad "a control left the tree mutated — the arms after it proved nothing"

verdict
