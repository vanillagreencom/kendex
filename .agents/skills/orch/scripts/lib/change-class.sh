#!/usr/bin/env bash
# change-class.sh — dev-validate-run's and item-tier's reader of the change
# classifier, and the owner of the class order item-tier ranks
# by. CI's .github/actions/change-class reads the shipped scripts from its own
# trusted checkout. Sourced; it defines the functions below and sets nothing
# until one runs.
#
# The classifier, its reader harness-only and the path rules are change-scope's,
# the required sibling beside this package (<skills>/change-scope). Where
# harness-ci, an optional sibling, is installed beside it too, its
# scripts/change-class wrapper runs in the classifier's place: its log is the
# classifier's lines plus the queue-only record dev-validate-run's PR coverage
# reads, so one run answers both. Nothing is read from PATH, and a layout
# holding neither answers classifier-absent.
#
# change_class_read BASE HEAD REPO STDERR_FILE
#   Classifies the pull-request range BASE...HEAD of REPO and sets CHANGE_CLASS
#   to the class the classifier printed, a lowercase word. The classifier's
#   stdout is one change_class=<class> line and nothing else; any other shape is
#   not a class. Sets CHANGE_CLASS_MEASURED to the `measured=` value of the
#   last `class:` line in STDERR_FILE, empty where it carries none: `false` is
#   the classifier's fallback to standard, not a measured class. Also sets
#   CHANGE_CLASS_QUEUE_ONLY from the last queue-only line, empty when absent.
#   Only false proves pull-request CI covers the queue's work. Returns 1 on
#   failure with CHANGE_CLASS_CAUSE set to classifier-absent,
#   classifier-exit-N or classifier-unreadable.
#
# change_class_docs BASE HEAD REPO PATHS_FILE STDERR_FILE
#   The docs verdict for the same range, from harness-only --mode docs: sets
#   CHANGE_CLASS_DOCS_ONLY to true or false and writes the changed paths the
#   verdict read to PATHS_FILE, one per line. Returns 1 on failure with
#   CHANGE_CLASS_CAUSE set to docs-reader-absent, docs-reader-exit-N or
#   docs-reader-unreadable.
#
# change_class_rank CLASS
#   Sets CHANGE_CLASS_RANK to CLASS's place in the order
#   render < trivial < micro < small < standard. Returns 1 for any other word.
#
# change_class_floor CLASS
#   Returns 0 when CLASS is a floor item-tier and review-depth take: a class
#   at or above micro, the narrowest class a work item runs at.
#
# change_class_location_load REPO loads change-scope's shared path rules, its
# narrow-change list and CHANGE_CLASS_STANDARD_PATHS from the main checkout.
# Returns 1 with CHANGE_CLASS_CAUSE on unreadable rules or settings.
# After loading, change_class_path PATH launch applies
# the same path rules as branch classification, without proving a render.
#
# The readers append stderr to STDERR_FILE and write no workflow outputs.
# Executable readers use the classifier. No argument here carries a class.

CHANGE_CLASS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGE_SCOPE_SCRIPTS="$CHANGE_CLASS_LIB_DIR/../../../change-scope/scripts"
HARNESS_CI_SCRIPTS="$CHANGE_CLASS_LIB_DIR/../../../harness-ci/scripts"
CHANGE_CLASS=""
CHANGE_CLASS_CAUSE=""
CHANGE_CLASS_MEASURED=""
CHANGE_CLASS_QUEUE_ONLY=""
CHANGE_CLASS_DOCS_ONLY=""
CHANGE_CLASS_RANK=""

change_class_rank() { # CLASS
  case "$1" in
    render) CHANGE_CLASS_RANK=0 ;;
    trivial) CHANGE_CLASS_RANK=1 ;;
    micro) CHANGE_CLASS_RANK=2 ;;
    small) CHANGE_CLASS_RANK=3 ;;
    standard) CHANGE_CLASS_RANK=4 ;;
    *) return 1 ;;
  esac
}

change_class_floor() { # CLASS
  local micro
  change_class_rank micro
  micro="$CHANGE_CLASS_RANK"
  change_class_rank "$1" && [ "$CHANGE_CLASS_RANK" -ge "$micro" ]
}

change_class_location_load() { # REPO
  local library="$CHANGE_SCOPE_SCRIPTS/lib/change-scope.sh" root
  CHANGE_CLASS_CAUSE=classifier-path-rules-unreadable
  [ -r "$library" ] || return 1
  # shellcheck source=../../../change-scope/scripts/lib/change-scope.sh
  . "$library" || return 1
  if ! change_class_path_load "$CHANGE_SCOPE_SCRIPTS/../references/narrow-change.conf"; then
    CHANGE_CLASS_CAUSE="$CHANGE_CLASS_PATH_CAUSE"
    return 1
  fi
  CHANGE_CLASS_CAUSE=base-settings-unreadable
  root="$("$CHANGE_CLASS_LIB_DIR/../git-context" common-root "$1")" || return 1
  CHANGE_CLASS_SETTINGS_ROOT="$root"
  # The lane and its inherited settings cannot choose their own review depth.
  CHANGE_CLASS_STANDARD_PATHS="$(
    unset HARNESS_CI_STANDARD_PATHS
    # shellcheck source=kendex-env.sh
    . "$CHANGE_CLASS_LIB_DIR/kendex-env.sh" || exit 1
    kendex_load_settings_file "$root/kendex.settings.toml" || exit 1
    kendex_load_settings_file "$root/.kendex/settings.toml" || exit 1
    globs=()
    read -r -a globs <<<"${HARNESS_CI_STANDARD_PATHS:-}"
    [ "${#globs[@]}" -eq 0 ] || printf '%s\n' "${globs[@]}"
  )" || return 1
  CHANGE_CLASS_CAUSE=""
}

# An unreadable or absent verdict keeps the inventory under the path rules.
change_class_inventory_rendered() { # BASE HEAD REPO STDERR_FILE
  local reader="$CHANGE_SCOPE_SCRIPTS/harness-only" inventory_change
  [ -x "$reader" ] || return 1
  "$reader" --mode harness --event pull_request --base "$1" --head "$2" --repo "$3" \
    --output /dev/null > /dev/null 2>"$4" || return 1
  inventory_change="$(sed -n 's/^inventory-change: //p' "$4" | tail -1)" || return 1
  case "$inventory_change" in
    names-only\ *\ roots=*)
      names_only_roots_rendered "${inventory_change##* roots=}" \
        branch_growth_render_roots "$CHANGE_CLASS_SETTINGS_ROOT" ;;
    *) return 1 ;;
  esac
}

change_class_read() { # BASE HEAD REPO STDERR_FILE
  local classifier answer status=0
  CHANGE_CLASS=""
  CHANGE_CLASS_CAUSE=""
  CHANGE_CLASS_MEASURED=""
  CHANGE_CLASS_QUEUE_ONLY=""
  # The wrapper takes --output, which /dev/null keeps off a caller's
  # GITHUB_OUTPUT; the classifier takes no such flag.
  if [[ -x "$HARNESS_CI_SCRIPTS/change-class" ]]; then
    classifier=("$HARNESS_CI_SCRIPTS/change-class" --output /dev/null)
  elif [[ -x "$CHANGE_SCOPE_SCRIPTS/change-scope" ]]; then
    classifier=("$CHANGE_SCOPE_SCRIPTS/change-scope")
  else
    CHANGE_CLASS_CAUSE=classifier-absent
    return 1
  fi
  answer="$("${classifier[@]}" --event pull_request --base "$1" --head "$2" --repo "$3" 2>>"$4")" || status=$?
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
  CHANGE_CLASS_QUEUE_ONLY="$(sed -n '/^queue-only:/p' "$4")" \
    || { CHANGE_CLASS_CAUSE=classifier-unreadable; return 1; }
  CHANGE_CLASS_QUEUE_ONLY="${CHANGE_CLASS_QUEUE_ONLY##*$'\n'}"
  case "$CHANGE_CLASS_QUEUE_ONLY" in
    'queue-only: queue_only='*)
      CHANGE_CLASS_QUEUE_ONLY="${CHANGE_CLASS_QUEUE_ONLY#queue-only: queue_only=}"
      CHANGE_CLASS_QUEUE_ONLY="${CHANGE_CLASS_QUEUE_ONLY%% *}" ;;
    *) CHANGE_CLASS_QUEUE_ONLY="" ;;
  esac
}

change_class_docs() { # BASE HEAD REPO PATHS_FILE STDERR_FILE
  local reader="$CHANGE_SCOPE_SCRIPTS/harness-only" answer status=0
  CHANGE_CLASS_DOCS_ONLY=""
  CHANGE_CLASS_CAUSE=""
  if [[ ! -x "$reader" ]]; then
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
