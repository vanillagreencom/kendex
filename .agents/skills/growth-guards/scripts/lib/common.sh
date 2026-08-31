# shellcheck shell=bash
# Shared plumbing for the growth-guards check family. Sourced (not executed)
# by every scripts/* check, which sets GG_CHECK to its own name first so every
# diagnostic names its producer.
#
# Family contract: exit 0 clean, 1 violations, 2 usage/config/collection
# error. A measurement that could not be taken goes through
# gg_collection_error — a loud exit 2, never a silent pass.
#
# Bash 3.2-safe throughout: no Bash 4+ builtins or array kinds, guarded
# expansion for possibly-empty arrays.

set -euo pipefail

# Sourced here rather than by each check: every one of them needs a repository
# root, and that is a path capture.
# not-a-path: this IS the bootstrap that loads the idiom, so it cannot use
# it. A library directory whose name ends in a newline fails here loudly,
# with the source unfound, rather than quietly resolving somewhere else.
# shellcheck source=paths.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/paths.sh"
# The glob-list concept, whole: the configured list, the excludes list, the
# matcher both answer through, the walk, and what a lane may measure at a
# matched path. Its helpers call back into this file, which is why it is
# sourced here rather than by each lane — resolution is at call time, so the
# order of the two is free.
# not-a-path: same bootstrap as above; the idiom it loads is not available yet.
# shellcheck source=configured-paths.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/configured-paths.sh"

GG_TAB="$(printf '\t')"
GG_VIOLATIONS=0
# Cleanup state is per-process. An INHERITED value must never decide what a
# guard deletes on exit: gg_settings_index_mode arms the same trap without
# creating a scratch directory, and the checks a hook lane runs inherit the
# exported settings cache their parent is still reading.
GG_TMP=""
GG_SETTINGS_INDEX_OWNED=0
# In-flight staging file for gg_install_file, so an interrupt between its
# creation and its rename leaves nothing beside the destination.
GG_INSTALL_TMP=""
# Extra `git grep` flags for the index lanes below, set by a check before it
# calls one and empty for every check that does not. Case sensitivity is the one
# thing it carries: a lane banning comment markers or lint pragmas matches
# their exact spelling, while a lane banning WORDS wants -i, where a
# sentence-initial capital is the same word.
GG_GREP_LANE_FLAGS=()

gg_config_error() {
  echo "::error::${GG_CHECK:-growth-guards}: $*" >&2
  exit 2
}

# Same loud exit, distinct name so call sites read as what they are: a
# measurement that failed, never a verdict.
gg_collection_error() { gg_config_error "$@"; }

# Only what THIS process created: GG_SETTINGS_INDEX_DIR is exported to the
# checks a hook lane runs, and they must not delete the directory their parent
# is still resolving settings from.
gg_cleanup() {
  [ -z "${GG_INSTALL_TMP:-}" ] || rm -f -- "$GG_INSTALL_TMP"
  [ -z "${GG_TMP:-}" ] || rm -rf -- "$GG_TMP"
  [ "${GG_SETTINGS_INDEX_OWNED:-0}" = "1" ] && rm -rf -- "$GG_SETTINGS_INDEX_DIR"
  return 0
}

gg_tmpdir() { # per-run scratch directory in GG_TMP, removed at exit
  GG_TMP="$(mktemp -d "${TMPDIR:-/tmp}/gg-${GG_CHECK:-growth-guards}.XXXXXX")" \
    || gg_config_error "could not create a temporary directory"
  trap gg_cleanup EXIT
}

gg_repo_root_cd() { # cd to the repository root; all configured paths are repo-relative
  local root
  gg_path root git rev-parse --show-toplevel || gg_config_error "not inside a git repository"
  cd -- "$root" || gg_config_error "cannot cd to repository root $(gg_shown "$root")"
}

# A hook lane judges ONE commit, configuration included: tracked settings
# sources resolve from the index while this is on, so an unstaged edit cannot
# change the policy a commit is measured against. Call it after cd-ing to the
# repository root.
gg_settings_index_mode() {
  GG_SETTINGS_INDEX_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gg-settings.XXXXXX")" \
    || gg_config_error "could not create a temporary directory"
  GG_SETTINGS_INDEX_OWNED=1
  trap gg_cleanup EXIT
  GG_SETTINGS_FROM_INDEX=1
  export GG_SETTINGS_FROM_INDEX GG_SETTINGS_INDEX_DIR
}

gg_positive_int() { # VALUE NAME — config error unless VALUE is a positive integer
  case "$1" in
    "" | *[!0-9]* | 0*[0-9] | 0) gg_config_error "$2 must be a positive integer, got '$(gg_scrubbed "$1")'" ;;
  esac
}

# Lexically normalize a configured repo-relative path (leading ./, internal
# ./ and .. segments): git records canonical relative paths, and every
# literal comparison against them must agree. Pure string surgery — no
# symlink resolution.
gg_normalize_rel_path() { # PATH -> normalized on stdout; nonzero if it escapes
  local input="$1" out="" seg rest
  rest="$input"
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    if [ "$seg" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    case "$seg" in
      "" | ".") ;;
      "..")
        case "$out" in
          "") return 1 ;;
          */*) out="${out%/*}" ;;
          *) out="" ;;
        esac
        ;;
      *) out="${out:+$out/}$seg" ;;
    esac
  done
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# Validate + normalize one configured path. Absolute paths and paths that
# escape the repository are configuration errors; a path beginning with '-'
# would read as an option to the line utilities that touch it — refuse it
# as configuration rather than trusting every call site's `--` guard.
gg_config_path() { # RAW LABEL — normalized on stdout; nonzero + ::error on stderr
  local raw="$1" label="$2" norm
  case "$raw" in
    /*)
      echo "::error::${GG_CHECK:-growth-guards}: $label path must be repo-root-relative, got absolute: $(gg_scrubbed "$raw")" >&2
      return 1
      ;;
  esac
  if ! norm="$(gg_normalize_rel_path "$raw")"; then
    echo "::error::${GG_CHECK:-growth-guards}: $label path escapes the repository or normalizes empty: $(gg_scrubbed "$raw")" >&2
    return 1
  fi
  case "$norm" in
    -*)
      echo "::error::${GG_CHECK:-growth-guards}: $label path must not begin with '-': $(gg_scrubbed "$norm")" >&2
      return 1
      ;;
  esac
  printf '%s' "$norm"
}

# The family's character count, as awk source, read under LC_ALL=C. One
# definition, because every cap in this package counts one way — bash's
# ${#var} follows the ambient locale, and a git hook inherits whatever
# environment the committer has, so the same text would be accepted in one
# shell and refused in another.
#
# Each well-formed UTF-8 sequence collapses to one character; every other byte
# counts as itself. So a stray continuation byte, an overlong form, a
# surrogate encoding and an out-of-range lead byte each cost one per byte
# rather than one per sequence: text that is not valid UTF-8 has no character
# count, and a cap must round that in the direction that cannot let an
# over-long value through. The alternatives are the byte grammar RFC 3629
# defines — the same ranges GG_ENTRY_AWK validates against — because a range
# written loosely is what makes E0 80 80 or F4 90 80 80 measure as one.
GG_CHARS_AWK_FN='
function gg_chars(s,   seq) {
  seq = "[\302-\337][\200-\277]"
  seq = seq "|\340[\240-\277][\200-\277]"
  seq = seq "|[\341-\354][\200-\277][\200-\277]"
  seq = seq "|\355[\200-\237][\200-\277]"
  seq = seq "|[\356-\357][\200-\277][\200-\277]"
  seq = seq "|\360[\220-\277][\200-\277][\200-\277]"
  seq = seq "|[\361-\363][\200-\277][\200-\277][\200-\277]"
  seq = seq "|\364[\200-\217][\200-\277][\200-\277]"
  gsub(seq, "x", s)
  return length(s)
}
'

gg_chars() { # TEXT — its character count on stdout
  printf '%s' "$1" | LC_ALL=C awk "$GG_CHARS_AWK_FN"'{ total += gg_chars($0) } END { print total + 0 }'
}

# Somebody's configured bytes, shown the way they have to be typed back. Not
# gg_shown: %q escapes the globs out of a value whose whole purpose is to be
# copied into a settings file or a path. Every C0 control except tab, and
# DEL, is replaced instead, and a newline becomes one of those replacements,
# so the value reaches the reader on one line and carries nothing a terminal
# would act on.
gg_scrubbed() { # VALUE — the value on one line, controls replaced
  printf '%s' "$1" | LC_ALL=C awk '{ gsub(/[\001-\010\013-\037\177]/, "?"); printf "%s%s", sep, $0; sep = "?" }'
}

# What a git tree mode IS, asked by what a file is rather than by a list of
# what it is not: 100644 and 100755 are a regular file, and 120000, 160000
# and 040000 are a symlink, a gitlink and a tree. A mode nobody has thought
# about yet answers no, which is the safe direction for every caller here —
# each of them is deciding whether there is a document to read at that path.
gg_mode_is_regular() { # MODE — 0 when the entry is an ordinary file
  case "$1" in
    100644 | 100755) return 0 ;;
  esac
  return 1
}

# One resolution order for every configured path: an explicit flag wins, then
# the setting, then the built-in default — validated and normalized either way.
gg_resolve_path() { # FLAG-VALUE KEY DEFAULT LABEL — normalized path on stdout
  local raw="$1"
  [ -n "$raw" ] || raw="$(gg_setting "$2" "$3")" || return 1
  gg_config_path "$raw" "$4"
}

# -L on both spellings: stat lstats by default, so a symlink destination would
# answer with the LINK's own 0777 rather than the file behind it, and the chmod
# below would publish a world-writable ratchet input any local account could
# lower. The caller tests with `[ -f ]`, which follows; both must mean one file.
gg_file_mode() { # FILE — its permission bits as octal digits; GNU stat, then BSD
  stat -L -c '%a' -- "$1" 2>/dev/null || stat -L -f '%Lp' -- "$1" 2>/dev/null
}

# What a failing install step printed, folded into the guard's own diagnostic
# rather than left to reach the terminal as a bare `mv:` line ahead of it.
# gg_scrubbed: another program's bytes on their way to a terminal.
gg_install_why() { # ERRFILE — " (TEXT)" or nothing
  local said
  said="$(head -n 1 -- "$1" 2>/dev/null || true)"
  [ -n "$said" ] || return 0
  printf ' (%s)' "$(gg_scrubbed "$said")"
}

# Replace DEST with SRC's bytes through a rename inside DEST's own directory.
# A direct redirect onto DEST, or a rename that crosses a filesystem (where mv
# degrades to copy-then-unlink), leaves DEST TRUNCATED behind an interrupt —
# and a truncated policy file is read as a complete one, which for a ratchet
# baseline loosens the gate instead of failing it.
gg_install_file() { # SRC DEST LABEL
  local src="$1" dest="$2" label="$3" mode="" err=""
  # Every caller in this family arms gg_tmpdir; one that has not is a
  # programming error, and says so rather than capturing each step's stderr to
  # whatever `$GG_TMP/install.err` means with GG_TMP empty.
  [ -n "${GG_TMP:-}" ] && [ -d "$GG_TMP" ] \
    || gg_collection_error "gg_install_file needs gg_tmpdir called first — $label was not replaced"
  err="$GG_TMP/install.err"
  # The destination's mode is READ here and applied after the write, never
  # carried onto the staging file in between: one without owner-write would
  # otherwise fail the write on a file this process just created.
  if [ -f "$dest" ]; then
    # `|| mode=""`, never a bare assignment: errexit exits the whole run on a
    # failing command substitution in one, with stat's status and no diagnostic
    # — the fail-silent the case below replaces. Nothing to relay there:
    # gg_file_mode silences both probes, the first being the one EXPECTED to
    # fail wherever the second answers. An unreadable mode is not one to guess.
    mode="$(gg_file_mode "$dest")" || mode=""
    case "$mode" in
      "" | *[!0-7]*) gg_collection_error "could not read the mode of $(gg_shown "$dest") — $label was not replaced" ;;
    esac
  fi
  # mktemp, never a name derived from the pid: the staging file lands in a
  # directory the repository controls, a predictable name can already be
  # sitting there, and `cp` writes THROUGH a symlink — so a planted
  # `.gg-install.<pid>.<name>` link would redirect the write anywhere the
  # user can reach. mktemp creates the file itself, exclusively.
  GG_INSTALL_TMP="$(mktemp "$dest.gg-install.XXXXXX" 2>"$err")" \
    || gg_collection_error "could not stage the replacement for $label beside $(gg_shown "$dest")$(gg_install_why "$err")"
  # Past mktemp the staging file has ONE owner: gg_cleanup, which the EXIT trap
  # runs and which removes GG_INSTALL_TMP first. gg_collection_error exits, so
  # every branch below reaches it and none removes the file itself. `2>` goes
  # BEFORE the output redirect in each: redirections apply left to right, so a
  # failure of the one onto the staging file would otherwise be reported on the
  # terminal rather than captured.
  if ! cat -- "$src" 2>"$err" >"$GG_INSTALL_TMP"; then
    gg_collection_error "could not stage the replacement for $label beside $(gg_shown "$dest")$(gg_install_why "$err")"
  fi
  # No `--` after the mode: chmod's mode is a non-option argument, so a BSD
  # chmod stops option parsing there and reads the `--` as a file name.
  if [ -n "$mode" ] && ! chmod "$mode" "$GG_INSTALL_TMP" 2>"$err"; then
    gg_collection_error "could not give the replacement for $label $(gg_shown "$dest")'s mode ($mode)$(gg_install_why "$err")"
  fi
  # -f, so the rename is non-interactive whatever the destination's mode: mv
  # PROMPTS before replacing one that denies write when stdin is a terminal —
  # exactly the destination this helper sets out to support, and a gate that
  # stops for an answer nobody is there to give is a gate that hangs.
  if ! mv -f -- "$GG_INSTALL_TMP" "$dest" 2>"$err"; then
    gg_collection_error "could not replace $label at $(gg_shown "$dest")$(gg_install_why "$err") — inspect the file before trusting it"
  fi
  # The one assignment that IS load-bearing: the rename consumed the staging
  # file, so the trap must not go looking for it.
  GG_INSTALL_TMP=""
}

# `git grep --cached` SKIPS an unmerged index entry entirely: it spends no
# error status and writes no `error:` line doing it, so gg_grep_guard sees a
# complete scan and the lane reports OK over a work tree whose files carry
# conflict markers. The index cannot be scanned while a merge is unresolved,
# so every --cached scan refuses first. The remedy is the only one there is:
# finish or abort the merge.
gg_require_merged_index() { # PATHSPEC... — returns only when nothing is unmerged
  local rows status=0 paths count=0 unmerged
  rows="$(git ls-files --unmerged -- "$@")" || status=$?
  [ "$status" -eq 0 ] \
    || gg_collection_error "could not read the index for unmerged paths (git ls-files exit $status)"
  [ -n "$rows" ] || return 0
  paths="$(printf '%s\n' "$rows" | cut -f2- | LC_ALL=C sort -u)"
  count="$(printf '%s\n' "$paths" | grep -c .)" || count=0
  # One rendered path per line: these are somebody's tracked names, and the
  # list is the evidence for the refusal below.
  while IFS= read -r unmerged; do
    [ -n "$unmerged" ] || continue
    printf '%s\n' "$(gg_shown "$unmerged")" >&2
  done <<<"$paths"
  gg_collection_error "the index carries $count unmerged path(s) (listed above) and a --cached scan skips them silently — finish or abort the merge, then re-run"
}

# Judge one `git grep` run from its exit status AND captured stderr. The
# status carries only the MATCH result: a staged blob git cannot read is an
# `error:` line on stderr while the status still says 1 (nothing matched) or
# 0 (something else matched), so status alone can bless a scan that skipped
# content — and a status-0 run that also errored must not fold as an
# ordinary violation verdict over a partial scan. The `error:` prefix is
# git's C-locale spelling, so every call feeding this guard runs under
# LC_ALL=C — a translated prefix would slip past the match.
gg_grep_guard() { # STATUS ERRFILE CONTEXT — returns only when the scan is complete
  local status="$1" errfile="$2" context="$3" first_err
  [ ! -s "$errfile" ] || cat -- "$errfile" >&2
  [ "$status" -le 1 ] || gg_collection_error "git grep failed $context (exit $status)"
  first_err="$(grep -E '^error:' -- "$errfile" | head -n 1 || true)"
  [ -z "$first_err" ] || gg_collection_error "git grep could not read staged content while $context ($(gg_scrubbed "$first_err"))"
}

# One banned shape, listed over INDEX content: the tracked files whose staged
# blob carries it, minus the excluded paths and the blobs whose own bytes are
# binary. Survivors land NUL-delimited in OUTFILE (-l -z, so a path containing
# ':' cannot garble parsing).
#
# CONTENT decides what is scannable here and an attribute never does. The
# listing forces text (-a): `git grep -I` asks the path's userdiff driver, so
# one committed `*.ext -diff` or `*.ext binary` row makes git call every
# matching blob binary and drop it with no status and no stderr — a whole
# extension reading as clean. What forcing text lets through is judged on
# content instead: a listed blob carrying a NUL in its leading bytes is a
# genuine asset and is NAMED as unmeasured, so it never reaches a violation
# record as raw bytes and never rides inside a clean total either. Only a path
# the listing NAMED is read, so the sniff costs one `cat-file` per matching
# file, never one per tracked file. That is the same answer todo-ban's commit
# lane gives the same question.
# Needs GG_TMP (gg_tmpdir) and the excludes already loaded.
gg_content_carriers() { # OUTFILE LABEL ERE PATHSPEC... — measurable carriers, NUL-delimited
  local out="$1" label="$2" ere="$3" status=0 f
  shift 3
  gg_require_merged_index "$@"
  LC_ALL=C git grep --cached -alzE ${GG_GREP_LANE_FLAGS[@]+"${GG_GREP_LANE_FLAGS[@]}"} "$ere" -- "$@" >"$GG_TMP/carriers.z" 2>"$GG_TMP/carriers.err" || status=$?
  gg_grep_guard "$status" "$GG_TMP/carriers.err" "scanning tracked files for $label"
  : >"$out"
  while IFS= read -r -d '' f; do
    gg_is_excluded "$f" && continue
    # The stage-0 blob at that exact path, so the sniff reads the same bytes
    # the listing matched.
    gg_read_blob ":0:$f" "$f" "$label"
    if gg_blob_is_binary "$GG_TMP/blob" "$f"; then
      gg_note_skip "$f" "binary content, not text"
      continue
    fi
    printf '%s\0' "$f" >>"$out"
  done <"$GG_TMP/carriers.z"
}

# The same shape detailed per carrier: the numbered hits in each listed file,
# where the known path prefix strips exactly. The detail pass is
# line-oriented, so a path embedding a newline yields no DETAIL lines — the
# file still fails the listing. Both scans force text and move TOGETHER; a
# text-forced listing over a binary-skipping detail scan names a file the
# detail scan then finds nothing in, which the invariant below turns into a
# spurious exit 2.
gg_grep_lane() { # LABEL ERE REMEDY PATHSPEC... — numbered violations on stdout
  local label="$1" ere="$2" remedy="$3" f hit_status hit
  shift 3
  gg_content_carriers "$GG_TMP/lane.z" "$label" "$ere" "$@"
  while IFS= read -r -d '' f; do
    hit_status=0
    LC_ALL=C git grep --cached -anE ${GG_GREP_LANE_FLAGS[@]+"${GG_GREP_LANE_FLAGS[@]}"} "$ere" -- ":(literal)$f" >"$GG_TMP/lane.hits" 2>"$GG_TMP/lane.err" || hit_status=$?
    gg_grep_guard "$hit_status" "$GG_TMP/lane.err" "detailing the $label hits in $(gg_shown "$f")"
    # This file just listed as containing hits; anything but a clean re-scan
    # (including "no matches") means the measurement is broken.
    [ "$hit_status" -eq 0 ] || gg_collection_error "git grep could not detail the $label hits in $(gg_shown "$f") (exit $hit_status)"
    while IFS= read -r hit; do
      echo "${GG_CHECK:-growth-guards} FAIL $label: $(gg_shown "$f"):$(gg_scrubbed "${hit#"$f":}")"
      echo "  remedies: $remedy"
      GG_VIOLATIONS=$((GG_VIOLATIONS + 1))
    done <"$GG_TMP/lane.hits"
  done <"$GG_TMP/lane.z"
}

gg_count_nonempty_lines() { # FILE — count on stdout; loud exit if grep cannot read it
  # grep -c exits 1 on zero matches but still prints 0 — only exit >= 2
  # (execution/read failure) means the count is unknown.
  local n status=0
  n="$(grep -c . -- "$1")" || status=$?
  [ "$status" -le 1 ] || gg_collection_error "could not count lines in $(gg_shown "$1") (grep exit $status)"
  printf '%s\n' "$n"
}
