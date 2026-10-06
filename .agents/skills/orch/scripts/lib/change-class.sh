#!/usr/bin/env bash
# change-class.sh — dev-validate-run's and item-tier's reader of harness-ci's
# change classifier, and the version-line filter item-tier and restack-skip
# share. CI's .github/actions/change-class reads the shipped
# scripts from its own trusted checkout. Sourced; it defines the
# functions below and sets nothing until one runs.
#
# The classifier is <skills>/harness-ci/scripts/change-class beside this
# package, else change-class on PATH. harness-only is read from the directory
# the classifier resolved to, so both answers come from one install.
#
# change_class_read BASE HEAD REPO STDERR_FILE
#   Classifies the pull-request range BASE...HEAD of REPO and sets CHANGE_CLASS
#   to the class the classifier printed, a lowercase word. The classifier's
#   stdout is one change_class=<class> line and nothing else; any other shape is
#   not a class. Sets CHANGE_CLASS_MEASURED to the `measured=` value of the
#   last `class:` line in STDERR_FILE, empty where it carries none: `false` is
#   the classifier's fallback to standard, not a measured class. Returns 1 on
#   failure with CHANGE_CLASS_CAUSE set to classifier-absent,
#   classifier-exit-N or classifier-unreadable.
#
# change_class_docs BASE HEAD REPO PATHS_FILE STDERR_FILE
#   The docs verdict for the same range, from harness-only --mode docs: sets
#   CHANGE_CLASS_DOCS_ONLY to true or false and writes the changed paths the
#   verdict read to PATHS_FILE, one per line. Returns 1 on failure with
#   CHANGE_CLASS_CAUSE set to docs-reader-absent, docs-reader-exit-N or
#   docs-reader-unreadable. Call it after change_class_read, which resolves the
#   install.
#
# change_class_location_load loads harness-ci's shared path rules and the
# narrow-change list. Returns 1 with CHANGE_CLASS_CAUSE on a missing library
# or unreadable list. After loading, change_class_path PATH launch applies
# the same path rules as branch classification, without proving a render.
#
# drop_metadata_version < FILE
#   Prints a SKILL.md, source or render, less its frontmatter metadata.version
#   line: the one line a catalog package's version raise changes. item-tier and
#   restack-skip compare two sides through it.
#
# Both range readers append the called script's stderr to STDERR_FILE, and neither writes a
# workflow's GITHUB_OUTPUT. The class is never read from anything but the
# classifier: no argument here carries one.

CHANGE_CLASS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGE_CLASS=""
CHANGE_CLASS_CAUSE=""
CHANGE_CLASS_MEASURED=""
CHANGE_CLASS_DOCS_ONLY=""
CHANGE_CLASS_SCRIPTS=""

change_class_location_load() {
  local library="$CHANGE_CLASS_LIB_DIR/../../../harness-ci/scripts/lib/change-class.sh"
  CHANGE_CLASS_CAUSE=classifier-path-rules-unreadable
  [ -r "$library" ] || return 1
  # shellcheck source=../../../harness-ci/scripts/lib/change-class.sh
  . "$library" || return 1
  if ! change_class_path_load "$CHANGE_CLASS_LIB_DIR/../../references/narrow-change.conf"; then
    CHANGE_CLASS_CAUSE="$CHANGE_CLASS_PATH_CAUSE"
    return 1
  fi
  CHANGE_CLASS_CAUSE=""
}

change_class_read() { # BASE HEAD REPO STDERR_FILE
  local classifier answer status=0
  CHANGE_CLASS=""
  CHANGE_CLASS_CAUSE=""
  CHANGE_CLASS_MEASURED=""
  classifier="$CHANGE_CLASS_LIB_DIR/../../../harness-ci/scripts/change-class"
  if [[ ! -x "$classifier" ]]; then
    classifier="$(command -v change-class 2>/dev/null)" || classifier=""
  fi
  if [[ -z "$classifier" ]]; then
    CHANGE_CLASS_CAUSE=classifier-absent
    return 1
  fi
  CHANGE_CLASS_SCRIPTS="$(dirname -- "$classifier")"
  answer="$("$classifier" --event pull_request --base "$1" --head "$2" --repo "$3" \
    --output /dev/null 2>>"$4")" || status=$?
  if (( status != 0 )); then
    CHANGE_CLASS_CAUSE="classifier-exit-$status"
    return 1
  fi
  case "$answer" in
    # Letters spelled out: a range class follows the locale's collation.
    change_class=*[!abcdefghijklmnopqrstuvwxyz]* | change_class=)
      CHANGE_CLASS_CAUSE=classifier-unreadable
      return 1 ;;
    change_class=*) CHANGE_CLASS="${answer#change_class=}" ;;
    *) CHANGE_CLASS_CAUSE=classifier-unreadable; return 1 ;;
  esac
  CHANGE_CLASS_MEASURED="$(sed -n 's/^class: class=[^ ]* measured=\([^ ]*\).*/\1/p' "$4")" \
    || { CHANGE_CLASS_CAUSE=classifier-unreadable; return 1; }
  CHANGE_CLASS_MEASURED="${CHANGE_CLASS_MEASURED##*$'\n'}"
}

change_class_docs() { # BASE HEAD REPO PATHS_FILE STDERR_FILE
  local reader="$CHANGE_CLASS_SCRIPTS/harness-only" answer status=0
  CHANGE_CLASS_DOCS_ONLY=""
  CHANGE_CLASS_CAUSE=""
  if [[ -z "$CHANGE_CLASS_SCRIPTS" || ! -x "$reader" ]]; then
    CHANGE_CLASS_CAUSE=docs-reader-absent
    return 1
  fi
  answer="$("$reader" --mode docs --event pull_request --base "$1" --head "$2" --repo "$3" \
    --paths-output "$4" --output /dev/null 2>>"$5")" || status=$?
  if (( status != 0 )); then
    CHANGE_CLASS_CAUSE="docs-reader-exit-$status"
    return 1
  fi
  case "$answer" in
    docs_only=true | docs_only=false) CHANGE_CLASS_DOCS_ONLY="${answer#docs_only=}" ;;
    *) CHANGE_CLASS_CAUSE=docs-reader-unreadable; return 1 ;;
  esac
}

# The block ends where the catalog's frontmatter reader ends it, so no body
# line is read as part of the metadata map.
drop_metadata_version() {
  awk '
    NR == 1 && $0 == "---" { front = 1; print; next }
    front && /^(---|\.\.\.)[[:space:]]*$/ { front = 0 }
    front && /^[^[:space:]]/ { metadata = ($0 ~ /^metadata:[[:space:]]*$/) }
    front && metadata && /^[[:space:]]+version:/ { next }
    { print }
  '
}
