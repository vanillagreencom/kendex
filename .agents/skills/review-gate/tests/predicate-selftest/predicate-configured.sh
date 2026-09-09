# shellcheck shell=bash
# Sourced by review-predicate-selftest.sh with its neutral fixture world.
# ================================================================ configured ===
# The same discipline against THIS repo's resolved trust settings.
echo "--- configured layer (this repo's REVIEW_GATE_* settings)"

reset
reviews_set "$(review "$(trusted_reviewer)" APPROVED)"
run "configured: accepted non-author review object" approved

if [ -n "$ACTIVE_TRUSTED_LOGINS" ]; then
  reset
  reviews_set "$(review "not-on-the-trust-list" APPROVED)"
  run "configured: login outside the repo trust list is not evidence" awaiting
fi

while IFS= read -r ctx; do
  [ -z "$ctx" ] && continue
  context_battery "$ctx"
done <<EOF
$(list_items "$ACTIVE_CONTEXTS")
EOF

while IFS= read -r pair; do
  [ -z "$pair" ] && continue
  comment_battery "${pair%%:*}" "${pair#*:}" "$ACTIVE_FLOOR"
done <<EOF
$(list_items "$ACTIVE_REVIEWERS")
EOF

# The repo's thread-term posture: enforce keeps the fail-closed thread term;
# off must never emit threads-open (server-side ruleset is the enforcement
# point of record there).
reset
reviews_set "$(review "$(trusted_reviewer)" APPROVED)"
threads false >"$fixtures/graphql.json"
if [ "$ACTIVE_THREADS" = "off" ]; then
  run "configured: threads=off — unresolved thread does not close the gate" approved
else
  run "configured: unresolved thread fails closed (threads=enforce)" threads-open
fi

# Carry-exclude probes. Both use the predicate's matcher shape
# — an unquoted pattern in a bash `case` — so the probes pin the real glob
# semantics ('*' crosses '/', whole-path anchoring, ';' separators) against
# the repo's COMMITTED exclude list, not a hardcoded example.
carry_class_has() { # is this class among the repo's enabled carry classes?
  printf '%s' "$ACTIVE_CARRY" | tr ';|' '\n\n' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -qx "$1"
}
glob_matches() { # path, glob — the predicate's exact `case` matcher
  case "$1" in $2) return 0 ;; esac
  return 1
}
# The invoking repo's tracked tree, when this script lives inside one:
# probes derived from REAL tracked paths prove a committed glob matches the
# repository, not merely the string the probe itself manufactured from that
# same glob (a typo'd `skils/*` matches `skils/probe.md` forever). Empty in
# hermetic harnesses — the manufactured fallback keeps those deterministic.
# Resolved from the INVOKING directory's repository — the settings under
# test belong to that repo, so its tracked tree is the evidence base. Empty
# when the selftest runs outside a repository (hermetic harnesses): only
# there do manufactured probe paths apply. Loaded LAZILY at the exclude
# battery (the only consumer), not at script start, and via -z so quoted
# unusual pathnames round-trip instead of mis-probing globs.
EXCLUDE_TRACKED=""
EXCLUDE_TRACKED_ERROR=""
EXCLUDE_TRACKED_ROOT=""
EXCLUDE_TRACKED_MODE=""
exclude_tracked_loaded=""
load_exclude_tracked() {
  [ -n "$exclude_tracked_loaded" ] && return 0
  exclude_tracked_loaded=1
  # A real repository whose ls-files FAILS must not silently degrade into
  # hermetic synthetic probing — that would shrink coverage exactly when
  # git is broken. Only a genuinely-not-a-repo cwd is hermetic.
  # The evidence ANCHOR is the repository containing the RESOLVED settings
  # file: the committed exclude list under test belongs to that repo, and
  # REVIEW_GATE_SETTINGS_FILE legitimately points a run at another
  # checkout — deriving the root from the invoking cwd would judge B's
  # globs against A's tree. /dev/null (force-defaults) and the plain
  # relative default both anchor at the invoking directory.
  _elt_anchor="."
  case "${REVIEW_GATE_SETTINGS_FILE:-}" in
    '' | /dev/null) : ;;
    *)
      # Only an EXISTING override moves the anchor: when the named file is
      # absent, rg_setting falls back to built-in defaults, and anchoring
      # evidence at a nonexistent path's directory would judge defaults
      # against the wrong tree (or silently force hermetic mode). The -L
      # arm is load-bearing: -f dereferences the WHOLE chain, so a cyclic
      # or over-long symlink fails -f while very much existing — skipping
      # resolution there would silently fall back to the invoking-cwd
      # anchor, and the hop guard below could never fire.
      if [ -f "$REVIEW_GATE_SETTINGS_FILE" ] || [ -L "$REVIEW_GATE_SETTINGS_FILE" ]; then
        # Resolve a SYMLINK override to its target first: installs routinely
        # symlink settings files, and the evidence repository is the one
        # CONTAINING the real file — anchoring at the symlink's directory
        # judges the wrong tree, or (outside any repo) silently demotes a
        # tracked run to hermetic probing where a dead glob can manufacture
        # its own match. Bounded walk; a walk that CANNOT finish (readlink
        # failure, hop budget exhausted) is an unusable anchor and carries a
        # resolution error — continuing from the unresolved link's directory
        # would be exactly the silent demotion above.
        _elt_settings="$REVIEW_GATE_SETTINGS_FILE"
        _elt_hops=0
        while [ -L "$_elt_settings" ] && [ "$_elt_hops" -lt 40 ]; do
          # An option-looking path (dash-leading, no slash — a cwd-relative
          # `-settings`, or a bare dash-leading link target) would parse as
          # a readlink OPTION and fail the walk, stranding the anchor at
          # the wrong checkout: normalize with ./ first.
          case "$_elt_settings" in -*) _elt_settings="./$_elt_settings" ;; esac
          if ! _elt_link="$(readlink "$_elt_settings")"; then
            EXCLUDE_TRACKED_ERROR="could not resolve the symlinked settings override (readlink failed at '$_elt_settings') — the evidence anchor is unusable"
            break
          fi
          case "$_elt_link" in
            /*) _elt_settings="$_elt_link" ;;
            *)
              case "$_elt_settings" in
                */*) _elt_settings="${_elt_settings%/*}/$_elt_link" ;;
                *) _elt_settings="$_elt_link" ;;
              esac
              ;;
          esac
          _elt_hops=$((_elt_hops + 1))
        done
        if [ -z "$EXCLUDE_TRACKED_ERROR" ] && [ -L "$_elt_settings" ]; then
          EXCLUDE_TRACKED_ERROR="could not resolve the symlinked settings override (chain longer than 40 hops or cyclic) — the evidence anchor is unusable"
        fi
        # The walk finished but the final target must EXIST: an -L-entry
        # override (cycle survivor, dangling tail) that resolves to a
        # missing file is equally unusable — never a quiet fall-through to
        # the invoking-cwd anchor.
        if [ -z "$EXCLUDE_TRACKED_ERROR" ] && [ ! -f "$_elt_settings" ]; then
          EXCLUDE_TRACKED_ERROR="the symlinked settings override does not resolve to a regular file ('$_elt_settings') — the evidence anchor is unusable"
        fi
        [ -n "$EXCLUDE_TRACKED_ERROR" ] && return 0
        # Containing directory via parameter expansion, not dirname: BSD
        # dirname can reject `--`, and without `--` an option-looking path
        # would be misparsed — the expansion has no dialect to disagree with.
        case "$_elt_settings" in
          */*) _elt_anchor="${_elt_settings%/*}" ;;
          *) _elt_anchor="." ;;
        esac
        [ -n "$_elt_anchor" ] || _elt_anchor="/"
      fi
      ;;
  esac
  # A genuine NON-REPOSITORY is the only hermetic ticket. The probe's
  # verdict is read from its output, not its bare exit status: a broken
  # git failing this probe inside a real checkout would read as "not a
  # repository" and silently demoted the run to hermetic synthetic
  # probing — the same fail-open every other branch here refuses. LC_ALL=C
  # pins the diagnostic to git's untranslated text (a localized git would
  # otherwise fail the match and refuse legitimate hermetic runs). Only
  # git's own "not a git repository" diagnosis selects hermetic mode —
  # and only when NO .git marker sits on the anchor's ancestry: a broken
  # worktree (a .git file naming a missing gitdir) earns the same
  # standard text while repository metadata is plainly present, and that
  # is an unusable evidence base, not a non-repository. Every other
  # failure (or a "false" verdict — a git dir with no work tree) is
  # equally unusable.
  # The VERDICT is stdout-only: a healthy repo whose git also prints a
  # warning on stderr (dubious-ownership, safe.directory) must not read
  # as failed. Diagnostics are re-sampled on the failure path only.
  _elt_probe_out="$(LC_ALL=C git -C "$_elt_anchor" rev-parse --is-inside-work-tree 2>/dev/null)"
  _elt_probe_rc=$?
  if [ "$_elt_probe_rc" -ne 0 ] || [ "$_elt_probe_out" != "true" ]; then
    _elt_probe_err="$(LC_ALL=C git -C "$_elt_anchor" rev-parse --is-inside-work-tree 2>&1 >/dev/null)"
    case "$_elt_probe_err" in
      *"not a git repository"*)
        # CDPATH= and -- : a diverted or dash-leading anchor must not walk
        # somebody else's ancestry. A dangling .git SYMLINK is still a
        # marker (-e follows and misses it; -L does not). An anchor that
        # cannot even be entered is unverifiable, and unverifiable never
        # earns hermetic mode.
        # -P / pwd -P: the walk must scan the PHYSICAL ancestry git itself
        # probed — logical cd through a symlinked dir plus `..` can land
        # somewhere git never looked, granting hermetic mode off an
        # unrelated marker-free lineage.
        _elt_walk="$(CDPATH= cd -P -- "$_elt_anchor" 2>/dev/null && pwd -P)" || _elt_walk=""
        if [ -z "$_elt_walk" ]; then
          EXCLUDE_TRACKED_ERROR="repository probe says 'not a git repository' and the anchor ('$_elt_anchor') cannot be entered to verify — refusing hermetic mode on an unverifiable anchor"
        fi
        while [ -n "$_elt_walk" ]; do
          if [ -e "$_elt_walk/.git" ] || [ -L "$_elt_walk/.git" ]; then
            EXCLUDE_TRACKED_ERROR="repository probe says 'not a git repository' but a .git marker exists at '$_elt_walk' — a broken checkout is not a non-repository"
            break
          fi
          [ "$_elt_walk" = "/" ] && break
          _elt_walk="${_elt_walk%/*}"
          [ -n "$_elt_walk" ] || _elt_walk="/"
        done
        ;;
      *)
        # A clean "false" is its own condition — a git DIRECTORY with no
        # work tree (bare repo, .git itself) — and deserves its own words:
        # "exit 0: no output" sends the operator hunting a broken git.
        if [ "$_elt_probe_rc" -eq 0 ] && [ "$_elt_probe_out" = "false" ]; then
          EXCLUDE_TRACKED_ERROR="the anchor is inside a git directory but not a work tree (rev-parse said false) — no tracked evidence base here"
        else
          EXCLUDE_TRACKED_ERROR="repository probe failed (git rev-parse --is-inside-work-tree exit $_elt_probe_rc: ${_elt_probe_err:-no output}) — cannot tell a non-repository from a broken git"
        fi
        ;;
    esac
    return 0
  fi
  # Anchor verified: a real work tree. Resolve its root, read the list.
    # ROOT-relative, never cwd-relative: `git ls-files` is subtree-scoped,
    # so a run from a subdirectory compared every committed glob against a
    # partial file list — each glob quietly downgraded to its no-match
    # note while the run stayed green. The evidence base is the repository
    # root, resolved explicitly; failing to resolve it is as unusable as a
    # failed read.
    # git's OWN status must decide the error, not the pipeline tail's: a
    # `git | tr` assignment reports tr's status, so a failed ls-files with
    # a happy tr would silently degrade into hermetic synthetic probing —
    # the exact fail-open this error flag exists to prevent. Stage the -z
    # output in a file (NUL bytes cannot ride a shell variable) and check
    # the producer's exit alone.
    # mktemp checked too: with no staging file the tracked read cannot be
    # VERIFIED, and unverifiable takes the same refuse-to-degrade branch as
    # failed — never a silent slide into hermetic probing.
    # The flag carries the CAUSE: its one consumer prints it, and telling
    # an operator to fix git when mktemp failed sends them at the wrong
    # subsystem.
    # Both checks are load-bearing: the exit status is git's own verdict
    # (a failing rev-parse that still printed something must not smuggle a
    # root past the guard), and the empty-output guard catches a success
    # that produced nothing usable.
    if ! EXCLUDE_TRACKED_ROOT="$(git -C "$_elt_anchor" rev-parse --show-toplevel 2>/dev/null)" \
      || [ -z "$EXCLUDE_TRACKED_ROOT" ]; then
      EXCLUDE_TRACKED_ERROR="could not resolve the repository root (git rev-parse --show-toplevel failed inside a work tree)"
    elif _elt_tmp="$(mktemp)"; then
      if git -C "$EXCLUDE_TRACKED_ROOT" ls-files -z >"$_elt_tmp" 2>/dev/null; then
        # STATED LIMITATION: the NUL-delimited read is converted to a
        # newline-delimited list for the probe loops, so a tracked
        # filename CONTAINING a newline splits into fragments — a glob
        # matching such a file can false-FAIL as no-match. The failure
        # direction is loud (never a silent pass), and newline filenames
        # in a reviewed repository are their own defect.
        EXCLUDE_TRACKED="$(tr '\0' '\n' <"$_elt_tmp")"
        # Mode is a SEPARATE flag: a successful read in a zero-tracked-file
        # repository leaves the payload empty, and payload-emptiness must
        # not demote a tracked run to hermetic synthetic probing.
        EXCLUDE_TRACKED_MODE="tracked"
      else
        EXCLUDE_TRACKED_ERROR="'git ls-files' failed (fix git, or run the harness outside a repository)"
      fi
      rm -f "$_elt_tmp"
    else
      EXCLUDE_TRACKED_ERROR="staging file creation failed (mktemp) — the tracked read cannot be verified"
    fi
}
exclude_glob_probe() { # glob, ext... -> a carry-class path this glob matches
  # Tracked mode (a real repository): ONLY real tracked matches count — a
  # synthetic filler manufactured from the glob under test would let a
  # typo'd `skils/*` verify itself against its own fabrication. No tracked
  # match returns 2 so the caller can say so out loud. Hermetic mode (no
  # repository): the '*'-filler fallback keeps harness runs deterministic,
  # and the concrete path is still re-proven against its source glob.
  local pat="$1" ext candidate any_tracked_match=""
  shift
  if [ "$EXCLUDE_TRACKED_MODE" = "tracked" ]; then
    while IFS= read -r candidate; do
      [ -z "$candidate" ] && continue
      glob_matches "$candidate" "$pat" || continue
      any_tracked_match=1
      for ext in "$@"; do
        case "$candidate" in *"$ext")
          printf '%s\n' "$candidate"
          return 0 ;;
        esac
      done
    done <<EOF_TRACKED_PROBE
$EXCLUDE_TRACKED
EOF_TRACKED_PROBE
    # 2 and 3 are DIFFERENT verdicts: matching nothing tracked at all is
    # the typo/dead-config shape, while matching tracked paths that just
    # sit outside the enabled carry classes proves the glob names real
    # paths — inert today, not dead, and never a candidate for the
    # prophylactic declaration (whose contract is "no tracked match").
    [ -n "$any_tracked_match" ] && return 3
    return 2
  fi
  case "$pat" in *'?'*|*'['*|*'\'*) return 1 ;; esac
  for ext in "$@"; do
    case "$pat" in
      *"$ext") candidate="${pat//\*/probe}" ;;
      *'*')    candidate="${pat//\*/probe}$ext" ;;
      *)       continue ;;
    esac
    glob_matches "$candidate" "$pat" || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}
exclude_free_path() { # ext... -> a path NO committed glob matches
  # Tracked mode: a REAL tracked carry-class file outside every glob is the
  # positive proof (a committed `carry-probe*` exclusion must not read as
  # "nothing can carry" while README.md still carries). Hermetic mode:
  # synthetic candidates per extension.
  local ext candidate pat hit
  if [ "$EXCLUDE_TRACKED_MODE" = "tracked" ]; then
    while IFS= read -r candidate; do
      [ -z "$candidate" ] && continue
      hit=""
      for ext in "$@"; do
        case "$candidate" in *"$ext") hit=ext-ok ;; esac
      done
      [ "$hit" = "ext-ok" ] || continue
      hit=""
      while IFS= read -r pat; do
        [ -z "$pat" ] && continue
        if glob_matches "$candidate" "$pat"; then hit=1; break; fi
      done <<EOF_FREE_TRACKED
$(list_items "$ACTIVE_CARRY_EXCLUDE")
EOF_FREE_TRACKED
      if [ -z "$hit" ]; then printf '%s\n' "$candidate"; return 0; fi
    done <<EOF_TRACKED_FREE
$EXCLUDE_TRACKED
EOF_TRACKED_FREE
    return 1
  fi
  # The two synthetic candidates deliberately share NO filename prefix: when
  # both lived under `carry-probe*`, a committed glob matching that harness
  # namespace (non-universal in any real tree — README.md still carries)
  # matched every candidate and false-FAILed the over-broad guard. Distinct
  # shapes mean only a genuinely class-universal exclusion set can exhaust
  # them; finite probes still cannot PROVE universality — stated limitation.
  for ext in "$@"; do
    for candidate in "carry-probe/unrelated$ext" "unexcluded-sample$ext"; do
      hit=""
      while IFS= read -r pat; do
        [ -z "$pat" ] && continue
        if glob_matches "$candidate" "$pat"; then hit=1; break; fi
      done <<EOF_FREE_PROBE
$(list_items "$ACTIVE_CARRY_EXCLUDE")
EOF_FREE_PROBE
      if [ -z "$hit" ]; then printf '%s\n' "$candidate"; return 0; fi
    done
  done
  return 1
}

# The repo's carry-forward posture: with classes enabled, an identical tree
# must carry and a code delta must still refuse (the conservative floor no
# class configuration may widen).
if [ -n "$ACTIVE_CARRY" ]; then
  reset
  CFG_TRUSTED_LOGINS="$ACTIVE_TRUSTED_LOGINS"
  reviews_set "$(review "$(trusted_reviewer)" APPROVED "2026-01-01T00:00:00Z" "$OTHER")"
  compare_fix identical
  run "configured: carry-forward ($ACTIVE_CARRY) — identical tree carries" approved

  reset
  CFG_TRUSTED_LOGINS="$ACTIVE_TRUSTED_LOGINS"
  reviews_set "$(review "$(trusted_reviewer)" APPROVED "2026-01-01T00:00:00Z" "$OTHER")"
  compare_fix ahead "[$CODE_DELTA]"
  run "configured: carry-forward — a code delta still refuses" awaiting

  # The repo's exclude list must be shown to MATCH: a typo'd
  # or wrongly-anchored committed glob leaves the exclusion dead while every
  # case above stays green in both directions. So: a carry-class path a
  # committed glob matches must refuse the carry, and a sibling path outside
  # every committed glob must still carry (the exclusion neither dead nor
  # over-broad).
  # Set by the battery below; the ledger validation after it references it
  # only in tracked mode, which only the battery can establish.
  probe_exts=""
  if [ -n "$ACTIVE_CARRY_EXCLUDE" ]; then
    load_exclude_tracked
    if [ -n "$EXCLUDE_TRACKED_ERROR" ]; then
      cases=$((cases + 1))
      rg_message error selftest-tracked-base "${REVIEW_GATE_SETTINGS_FILE:-.}" "FAIL  configured: carry-exclude — the tracked-evidence base is unusable: $EXCLUDE_TRACKED_ERROR; refusing to degrade to synthetic probes" >&2
      failures=$((failures + 1))
    fi
    # The evidence MODE is printed, not inferred: a degraded run and a full
    # one would be distinguishable only by the case total, which moves on
    # every re-vendor for unrelated reasons. One line makes it readable.
    if [ "$EXCLUDE_TRACKED_MODE" = "tracked" ]; then
      rg_message notice selftest-evidence-tracked "$EXCLUDE_TRACKED_ROOT" "info  carry-exclude evidence mode: tracked (root: $EXCLUDE_TRACKED_ROOT, $(printf '%s\n' "$EXCLUDE_TRACKED" | grep -c .) tracked paths)"
    elif [ -z "$EXCLUDE_TRACKED_ERROR" ]; then
      rg_message notice selftest-evidence-hermetic "." "info  carry-exclude evidence mode: hermetic-synthetic (not inside a repository)"
    fi
    # Probe extensions span EVERY enabled class — docs alone must not leave
    # a comments-class exclusion (`src/*.sh`) untested, and an exclusion set
    # covering all Markdown is not "carry disabled" while comment-only
    # changes still carry.
    probe_exts=""
    carry_class_has docs && probe_exts=".md .markdown"
    # Every extension the predicate's comment-token table classifies —
    # both the '#' and the '//' families — so an exclusion like
    # cli/src/*.rs is exercised, not skipped as "no probe".
    carry_class_has comments && probe_exts="${probe_exts:+$probe_exts }.sh .bash .py .rb .toml .yml .yaml .js .mjs .cjs .ts .tsx .jsx .rs .go .c .h .cc .cpp .hpp .java .kt .swift"
    [ -n "$probe_exts" ] || probe_exts=".md .markdown"
    # Per-extension patches: a docs probe changes prose, a comments probe
    # changes a comment line, so the delta classifies into its class and the
    # refusal below is attributable to the exclusion alone.
    probe_patch_for() {
      case "$1" in
      *.js | *.mjs | *.cjs | *.ts | *.tsx | *.jsx | *.rs | *.go | *.c | *.h | *.cc | *.cpp | *.hpp | *.java | *.kt | *.swift)
        printf '%s' '@@ -1 +1 @@
-// old comment
+// new comment' ;;
      *.sh | *.bash | *.py | *.rb | *.toml | *.yml | *.yaml)
        printf '%s' '@@ -1 +1 @@
-# old comment
+# new comment' ;;
      *) printf '%s' '@@ -1 +1 @@
-old prose
+new prose' ;;
      esac
    }
    # shellcheck disable=SC2086 # probe_exts is a controlled word list
    probe_free="$(exclude_free_path $probe_exts)" || probe_free=""

    # NEGATIVE CONTROL (tracked mode): the no-match verdict the dead-glob
    # FAIL below rides on must be demonstrably reachable in THIS run — a
    # probe that lost the ability to say "no match" would silently green
    # every dead glob. A leading-'/' glob is impossible BY CONSTRUCTION,
    # not merely unlikely: git ls-files paths are repository-relative and
    # never start with '/', so no tracked tree anywhere can collide with
    # the control.
    if [ "$EXCLUDE_TRACKED_MODE" = "tracked" ]; then
      # shellcheck disable=SC2086 # probe_exts is a controlled word list
      negctl_out="$(exclude_glob_probe '/selftest-planted-negative-control/*' $probe_exts)"
      negctl_rc=$?
      if [ "$negctl_rc" -ne 2 ] || [ -n "$negctl_out" ]; then
        cases=$((cases + 1))
        rg_message error selftest-exclude-control "$negctl_rc" "FAIL  configured: carry-exclude — the planted no-match control probed rc=$negctl_rc ('$negctl_out'): the dead-glob verdict is unreachable and every dead glob below would silently pass" >&2
        failures=$((failures + 1))
      fi
    fi

    # EVERY committed glob is exercised, not just the first usable one: a
    # later typo'd or wrongly-anchored addition must not hide behind an
    # prior glob's green. Compare filenames are repository-relative, so a
    # leading-'/' glob can never match any real delta — structurally dead,
    # and a FAIL rather than a skip.
    while IFS= read -r probe_pat; do
      [ -z "$probe_pat" ] && continue
      case "$probe_pat" in
      /*)
        cases=$((cases + 1))
        rg_message error selftest-exclude-absolute "$probe_pat" "FAIL  configured: carry-exclude glob '$probe_pat' is anchored with a leading '/' — compare filenames are repository-relative, so this exclusion can never match and is dead" >&2
        failures=$((failures + 1))
        continue
        ;;
      esac
      # shellcheck disable=SC2086 # probe_exts is a controlled word list
      probe_match="$(exclude_glob_probe "$probe_pat" $probe_exts)"
      probe_rc=$?
      if [ "$probe_rc" -eq 0 ] && [ -n "$probe_match" ]; then
        reset
        CFG_TRUSTED_LOGINS="$ACTIVE_TRUSTED_LOGINS"
        reviews_set "$(review "$(trusted_reviewer)" APPROVED "2026-01-01T00:00:00Z" "$OTHER")"
        compare_fix ahead "[$(delta_file "$probe_match" modified "$(probe_patch_for "$probe_match")")]"
        run "configured: carry-exclude — '$probe_pat' matches '$probe_match', refusing the carry" awaiting
      elif [ "$probe_rc" -eq 2 ]; then
        # A no-match glob is dead in the same way a leading-'/' anchor is —
        # and would exit 0 with a note textually identical to a
        # deliberate prophylactic entry's, training operators to scroll
        # past real typos. Posture symmetry: an UNDECLARED no-match glob
        # FAILs; a glob listed in
        # REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC notes as declared.
        probe_declared=""
        while IFS= read -r probe_proph; do
          [ -z "$probe_proph" ] && continue
          [ "$probe_proph" = "$probe_pat" ] && probe_declared=1
        done <<EOF_PROPHYLACTIC
$(list_items "$ACTIVE_CARRY_EXCLUDE_PROPHYLACTIC")
EOF_PROPHYLACTIC
        if [ -n "$probe_declared" ]; then
          rg_message notice selftest-exclude-prophylactic "$probe_pat" "note  configured: carry-exclude — '$probe_pat' matches NO tracked carry-class ($probe_exts) path and is DECLARED prophylactic; not exercised here"
        else
          cases=$((cases + 1))
          rg_message error selftest-exclude-no-match "$probe_pat" "FAIL  configured: carry-exclude — '$probe_pat' matches NO tracked carry-class ($probe_exts) path in this repository: a typo or wrong anchor is dead config (declare it in REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC if it deliberately guards paths that do not exist yet)" >&2
          failures=$((failures + 1))
        fi
      elif [ "$probe_rc" -eq 3 ]; then
        # Matching tracked paths OUTSIDE the enabled carry classes is not
        # a typo — the glob provably names real paths — and steering it
        # into the prophylactic declaration would make that declaration
        # false (its contract: no tracked match today). Inert for today's
        # classes, legitimately kept for other or future ones: loud note.
        rg_message notice selftest-exclude-inert "$probe_pat" "note  configured: carry-exclude — '$probe_pat' matches tracked paths but none in the enabled carry classes ($probe_exts): inert for today's carry classes (kept for other or future classes); not exercised here"
      else
        rg_message notice selftest-exclude-no-probe "$probe_pat" "note  configured: carry-exclude — '$probe_pat' derives no carry-class ($probe_exts) probe: it guards paths the enabled carry class never carries, or uses ?/[/\\ metacharacters; not exercised here"
      fi
    done <<EOF_EXCLUDE_BATTERY
$(list_items "$ACTIVE_CARRY_EXCLUDE")
EOF_EXCLUDE_BATTERY

    if [ -n "$probe_free" ]; then
      reset
      CFG_TRUSTED_LOGINS="$ACTIVE_TRUSTED_LOGINS"
      reviews_set "$(review "$(trusted_reviewer)" APPROVED "2026-01-01T00:00:00Z" "$OTHER")"
      compare_fix ahead "[$(delta_file "$probe_free" modified "$(probe_patch_for "$probe_free")")]"
      run "configured: carry-exclude — '$probe_free' is outside every committed glob and still carries" approved
    else
      # No carry-free probe in EITHER mode. A STRUCTURALLY universal entry
      # is a FAIL regardless of mode — with one committed, no path today
      # or ever can carry, so "future files still carry" is false and the
      # tracked-mode note below would understate a dead config.
      # Structurally universal under the predicate's bash-case matcher: an
      # entry built ONLY of '*'/'?' wildcards, with at least one '*' and
      # AT MOST one '?' — '*', '***', '?*', '*?' match every non-empty
      # path by construction, while two or more '?'s impose a minimum
      # length that one-character paths escape, and '?'-only entries pin
      # an exact length; neither is universal.
      #
      # PER-ENTRY only, deliberately: a SET of globs can be jointly
      # universal ('?;??*' by length split, 'a*;[!a]*' by first-character
      # partition), and detecting that in general is glob-coverage
      # analysis with no bounded implementation. Such sets take the notes
      # below — loud and fail-safe, never a silent green — and tracked
      # mode judges them against real paths with no heuristic at all.
      probe_universal=""
      while IFS= read -r probe_pat_u; do
        [ -z "$probe_pat_u" ] && continue
        case "$probe_pat_u" in
          *[!*?]*) : ;;
          *'*'*)
            probe_pat_u_qs="${probe_pat_u//\*/}"
            case "$probe_pat_u_qs" in
              '' | '?') probe_universal="$probe_pat_u" ;;
            esac
            ;;
        esac
      done <<EOF_UNIVERSAL
$(list_items "$ACTIVE_CARRY_EXCLUDE")
EOF_UNIVERSAL
      if [ -n "$probe_universal" ]; then
        cases=$((cases + 1))
        rg_message error selftest-exclude-universal "$probe_universal" "FAIL  configured: carry-exclude — '$probe_universal' matches every path; the enabled carry class can never apply to any DELTA (identical-tree/rebase-residue carries alone would remain, which exclusions never touch). Overwhelmingly a misconfiguration: narrow the exclusions to the real policy surfaces, or disable REVIEW_GATE_CARRY_FORWARD instead of excluding everything" >&2
        failures=$((failures + 1))
      elif [ "$EXCLUDE_TRACKED_MODE" != "tracked" ]; then
        # Hermetic mode: finite synthetic probes cannot PROVE universality
        # — a glob set that merely spans both harness namespaces exhausts
        # the candidates while ordinary paths still carry.
        rg_message notice selftest-exclude-synthetic-covered "$ACTIVE_CARRY_EXCLUDE" "note  configured: carry-exclude — every synthetic carry-class ($probe_exts) probe is excluded but no committed glob is structurally universal: universality is UNPROVEN by synthetic probes (run inside the repository for tracked-path evidence); positive carry case not exercised here"
      else
        # Tracked mode: the CURRENT tree has no carry-free carry-class
        # file, but future files outside the globs can still carry (a repo
        # whose only Markdown is an intentionally excluded README is
        # legitimate). Loud note, not a FAIL — the current tree cannot
        # prove universality.
        rg_message notice selftest-exclude-tracked-covered "$ACTIVE_CARRY_EXCLUDE" "note  configured: carry-exclude — no TRACKED carry-class ($probe_exts) file escapes the committed exclusions today; the positive carry case is unproven against this tree (future non-excluded files still carry)"
      fi
    fi
  fi

  # The prophylactic ledger is validated in BOTH directions: each declared
  # entry must be an exact member of the active exclusion list AND (tracked
  # mode) still match nothing tracked. The battery above only consults the
  # ledger on a no-match glob, so without this pass a declaration whose glob
  # was renamed away, or whose guarded path has since been committed, would
  # sit silently false — a waiver that outlives its subject masks nothing
  # and trains operators to trust a lying ledger. Deliberately OUTSIDE the
  # exclusion-list gate: with declarations present and the exclusion list
  # EMPTY, every declaration is an orphan by definition — an all-orphan
  # ledger is stale config and must FAIL, never sit inert.
  if [ -n "$ACTIVE_CARRY_EXCLUDE_PROPHYLACTIC" ]; then
    while IFS= read -r proph_pat; do
      [ -z "$proph_pat" ] && continue
      # Membership needs no tracked evidence — an orphaned waiver is
      # stale config in hermetic runs too.
      proph_member=""
      while IFS= read -r proph_x; do
        [ "$proph_x" = "$proph_pat" ] && proph_member=1
      done <<EOF_PROPH_MEMBER
$(list_items "$ACTIVE_CARRY_EXCLUDE")
EOF_PROPH_MEMBER
      if [ -z "$proph_member" ]; then
        cases=$((cases + 1))
        rg_message error selftest-prophylactic-orphan "$proph_pat" "FAIL  configured: carry-exclude — prophylactic declaration '$proph_pat' is not an active REVIEW_GATE_CARRY_FORWARD_EXCLUDE entry: a waiver without its glob is stale config (remove the declaration, or restore the exclusion it waives)" >&2
        failures=$((failures + 1))
        continue
      fi
      # Falsification (the glob gained a tracked match) needs the
      # tracked tree; hermetic runs cannot judge it.
      [ "$EXCLUDE_TRACKED_MODE" = "tracked" ] || continue
      # shellcheck disable=SC2086 # probe_exts is a controlled word list
      proph_match="$(exclude_glob_probe "$proph_pat" $probe_exts)"
      proph_rc=$?
      if [ "$proph_rc" -ne 2 ]; then
        cases=$((cases + 1))
        rg_message error selftest-prophylactic-live "$proph_pat" "FAIL  configured: carry-exclude — prophylactic declaration '$proph_pat' no longer holds: the glob now matches ${proph_match:-tracked paths} (the declaration asserts NO tracked match today; remove it so the live exclusion is exercised)" >&2
        failures=$((failures + 1))
      fi
    done <<EOF_PROPH_VALIDATE
$(list_items "$ACTIVE_CARRY_EXCLUDE_PROPHYLACTIC")
EOF_PROPH_VALIDATE
  fi
fi

# The repo's retry budget: a read failing (attempts - 1) times must still
# reach a verdict. Delay is forced to 0 — the budget, not the pause, is the
# behavior under test.
if [ "$ACTIVE_API_ATTEMPTS" -gt 1 ] 2>/dev/null; then
  reset
  CFG_API_DELAY=0
  reviews_set "$(review "$(trusted_reviewer)" APPROVED)"
  export GH_SHIM_FAIL=reviews GH_SHIM_FAIL_TIMES=$((ACTIVE_API_ATTEMPTS - 1))
  run "configured: a transient read failure survives the repo's retry budget ($ACTIVE_API_ATTEMPTS attempts)" approved
  unset GH_SHIM_FAIL GH_SHIM_FAIL_TIMES
fi

if [ -n "$ACTIVE_OUTAGE" ]; then
  reset
  status_ctx "$ACTIVE_OUTAGE" success "reviewer outage attested"
  run "configured: outage attestation ($ACTIVE_OUTAGE)" approved

  # The REASON is enforced, not merely documented: an override with an empty
  # (or whitespace-only) description is an unexplained relaxation of the one
  # manual escape hatch the engine keeps.
  reset
  status_ctx "$ACTIVE_OUTAGE" success ""
  run "configured: override with an EMPTY reason is not evidence" awaiting

  reset
  status_ctx "$ACTIVE_OUTAGE" success "   "
  run "configured: override with a whitespace-only reason is not evidence" awaiting

  # And the attested reason rides out in the verdict detail, so the gate
  # status says why this PR merged without a review.
  reset
  status_ctx "$ACTIVE_OUTAGE" success "internal review loop clean (attested by the operator)"
  cases=$((cases + 1))
  detail_rc=0
  detail_line="$(PATH="$shim:$PATH" GH_SHIM_FIXTURES="$fixtures" \
    REVIEW_GATE_SETTINGS_FILE=/dev/null \
    REVIEW_GATE_TRUSTED_STATUS_CONTEXTS="$CFG_CONTEXTS" \
    REVIEW_GATE_COMMENT_REVIEWERS="$CFG_REVIEWERS" \
    REVIEW_GATE_OVERRIDE_CONTEXT="$CFG_OUTAGE" \
    REVIEW_GATE_STATUS_PUBLISHER_REJECT="$CFG_PUBLISHER_REJECT" \
    REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS="$CFG_TRUSTED_LOGINS" \
    REVIEW_GATE_CONTEXT="$CFG_GATE_CONTEXT" REVIEW_GATE_THREADS="$CFG_THREADS" \
    REVIEW_GATE_CARRY_FORWARD="$CFG_CARRY" \
    REVIEW_GATE_CARRY_FORWARD_EXCLUDE="$CFG_CARRY_EXCLUDE" \
    REVIEW_GATE_VENDORED_PATHS="$CFG_VENDORED_PATHS" \
    REVIEW_GATE_MODE="$CFG_GATE_MODE" \
    GH_REPO="owner/repo" PR_NUMBER=1 HEAD_SHA="$HEAD" PR_AUTHOR="$CFG_PR_AUTHOR" \
    "$predicate" 2>/dev/null)" || detail_rc=$?
  case "$detail_line" in
    "verdict=approved detail=operator override ($ACTIVE_OUTAGE): internal review loop clean (attested by the operator)")
      if [ "${detail_rc:-0}" -ne 0 ]; then
        rg_message error selftest-override-exit "$detail_rc" "FAIL  configured: the override-detail case exited ${detail_rc} despite the expected line" >&2
        failures=$((failures + 1))
      else
        echo "ok    configured: the override reason rides out in the verdict detail (approved)"
      fi ;;
    *)
      rg_message error selftest-override-detail "$detail_line" "FAIL  configured: override reason missing from the detail: $detail_line" >&2
      failures=$((failures + 1)) ;;
  esac
  detail_rc=0

  if [ -n "$ACTIVE_PUBLISHER_REJECT" ]; then
    reset
    status_ctx "$ACTIVE_OUTAGE" success "reviewer outage attested" "$(first_item "$ACTIVE_PUBLISHER_REJECT")"
    run "configured: outage attestation from a rejected publisher is not evidence" awaiting
  fi
fi

if [ -n "$ACTIVE_RENDER_PATHS" ]; then
  # A file the repo's own first entry covers: every '*' of the glob replaced
  # by a name character is a path that glob matches, under the closed
  # grammar (path characters plus '*') the engine enforces.
  reset
  CFG_RENDER_PATHS="$ACTIVE_RENDER_PATHS"
  compare_fix ahead "[$(delta_file "$(first_item "$ACTIVE_RENDER_PATHS" | tr '*' 'x')" modified "")]"
  run "configured: a diff under this repo's render set approves with no evidence" approved

  reset
  CFG_RENDER_PATHS="$ACTIVE_RENDER_PATHS"
  compare_fix ahead "[$(delta_file "$(first_item "$ACTIVE_RENDER_PATHS" | tr '*' 'x')" modified "")]"
  GH_SHIM_FAIL=compare
  export GH_SHIM_FAIL
  run "configured: the same diff, unenumerable — the normal path, awaiting" awaiting
fi
