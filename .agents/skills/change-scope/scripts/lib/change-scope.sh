#!/usr/bin/env bash
# The change-scope library: the path rules every classifier phase and the
# launch arm read, the base-commit settings reader the
# classifier and harness-ci's wrapper share, and the reader a consumer runs
# the classifier through. Sourced with extglob enabled. Path helpers read no
# diff or repository settings.
#
# change_class_path PATH PHASE sets CHANGE_CLASS_PATH and
# CHANGE_CLASS_PATH_CAUSE. PHASE is before-render, registry, pointer, narrow or
# launch (all phases). An unmatched path leaves both empty.
# The launch phase consumes CHANGE_CLASS_STANDARD_PATHS when the caller loads it.
# change_class_path_load CONF reads the narrow-phase lists once. Returns 1
# on a read failure, with CHANGE_CLASS_PATH_CAUSE; callers must refuse a
# narrow class. Call it before the narrow or launch phase.
# change_class_path_match PATH GLOBS sets PATH_MATCH_HIT on the first match.
# GLOBS is newline-separated, with bash patterns matching the whole path.
# change_class_list_globs CONF KEYWORD reads the narrow-change list grammar.
# change_scope_location_load REPO loads the narrow-phase lists and
# CHANGE_CLASS_STANDARD_PATHS from REPO's main checkout, returning 1 with
# CHANGE_CLASS_CAUSE on an unreadable list or settings file.
# change_scope_inventory_rendered BASE HEAD REPO STDERR_FILE returns 0 where
# harness-only proves the range's inventory change names-only under render
# roots the main checkout's settings name; it needs lib/branch-growth.sh.
#
# The helpers after the path rules are the classifier's own, shared with the
# harness-ci wrapper that judges the queue-only class on the same base commit.
# They read the sourcing script's variables rather than arguments: `repo` and
# `base` as its --repo and --base, `work` its scratch directory, `changed` the
# changed paths one per line, BASE_SETTINGS_KEYS the keys base_settings
# reads from the files BASE_SETTINGS_FILES, below, names. rev_file reads one
# file at any commit; base_file and base_settings read at the commit --base
# names and set MEASURE_CAUSE on a failed read. A script sources this file
# after it set those, and before its first call.
#
# change_scope_read BASE HEAD REPO STDERR_FILE runs the classifier beside this
# library over REPO's pull-request range BASE...HEAD, appends its stderr to
# STDERR_FILE and sets CHANGE_SCOPE_CLASS to the class it printed and
# CHANGE_SCOPE_MEASURED to the `measured=` value of the last `class:` line,
# empty where it carries none. Returns 1 with CHANGE_SCOPE_CAUSE set to
# classifier-absent, classifier-exit-N or classifier-unreadable.
# change_scope_rank CLASS sets CHANGE_SCOPE_RANK to CLASS's place in the order
# render < trivial < micro < small < standard, returning 1 for another word.
# change_scope_floor CLASS returns 0 when CLASS ranks at or above micro, the
# narrowest class a work item runs at.

CHANGE_SCOPE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The adopted caller can lack an inventory entry when adoption preserves its
# configuration. Candidacy permits proof setup; release comparison owns it.
HARNESS_CI_REFRESH_CALLER=.github/workflows/kendex-refresh.yml
# The settings files base_settings reads, in the ladder's order.
BASE_SETTINGS_FILES='kendex.settings.toml .kendex/settings.toml'

# harness-only owns the names-only verdict. Its roots must also belong to
# the caller's measurement roots before the inventory can leave the path set.
# LOAD_ROOTS sets BRANCH_GROWTH_RENDER_ROOTS from the caller's trusted settings.
names_only_roots_rendered() { # ROOTS LOAD_ROOTS [ARG...]
  local roots="$1" root listed
  shift
  [ "$roots" != - ] || return 0
  "$@" || return 1
  set -f
  for root in ${roots//,/ }; do
    for listed in $BRANCH_GROWTH_RENDER_ROOTS; do
      [ "$root" = "$listed" ] && continue 2
    done
    set +f
    echo "inventory-kept: cause=root-not-rendered root=$root" >&2
    return 1
  done
  set +f
}

change_class_path_match() { # PATH GLOBS
  local glob
  PATH_MATCH_HIT=""
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    # shellcheck disable=SC2254
    case "$1" in
      $glob) PATH_MATCH_HIT="path=$1 glob=$glob"; return 0 ;;
    esac
  done <<<"$2"
  return 1
}

change_class_list_globs() { # CONF KEYWORD
  awk -v kind="$2" '
    $1 == "superseded" { drop[$2] = 1 }
    $1 == kind { glob[++n] = $2 }
    END { for (i = 1; i <= n; i++) if (!(glob[i] in drop)) print glob[i] }
  ' "$1"
}

change_class_path_load() { # CONF
  CHANGE_CLASS_PATH_CAUSE=narrow-change-list-unreadable
  [ -r "$1" ] || return 1
  CHANGE_CLASS_EXCLUDED="$(change_class_list_globs "$1" path)" &&
    CHANGE_CLASS_INSTRUCTION="$(change_class_list_globs "$1" instruction)" || return 1
  CHANGE_CLASS_PATH_CAUSE=narrow-change-floor-missing
  [ -n "$CHANGE_CLASS_INSTRUCTION" ] || return 1
  CHANGE_CLASS_PATH_CAUSE=""
}

change_class_path() { # PATH PHASE
  local globs
  CHANGE_CLASS_PATH=""
  CHANGE_CLASS_PATH_CAUSE=""
  if [ "$2" = launch ]; then
    if change_class_path_match "$1" "${CHANGE_CLASS_STANDARD_PATHS:-}"; then
      CHANGE_CLASS_PATH=standard
      CHANGE_CLASS_PATH_CAUSE="repository-standard-path setting=HARNESS_CI_STANDARD_PATHS $PATH_MATCH_HIT"
      return 0
    fi
  fi
  if [ "$2" = before-render ] || [ "$2" = launch ]; then
    # These files decide the render and classifier inputs. Gemini's shim
    # owns one key only, not the other settings its harness executes.
    globs='kendex.toml
kendex.settings.toml
kendex-local.toml
.kendex/settings.toml
.gemini/settings.json'
    if change_class_path_match "$1" "$globs"; then
      CHANGE_CLASS_PATH=standard
      CHANGE_CLASS_PATH_CAUSE="configuration-source $PATH_MATCH_HIT"
      return 0
    fi
  fi
  if [ "$2" = registry ] || [ "$2" = launch ]; then
    # Registries execute hooks, permissions and MCP servers. A proven render
    # can own their changed keys; a Location alone proves no render.
    globs='.claude/settings.json
.claude/settings.local.json
.mcp.json
.codex/config.toml
.codex/hooks.json
.cursor/hooks.json
.cursor/mcp.json
.agents/hooks.json
.agents/mcp_config.json
.github/copilot/settings.json
.github/copilot/settings.local.json
.github/mcp.json
.github/hooks/*.json
.pi/settings.json
.pi/kendex/hooks.json
opencode.json
opencode.jsonc'
    if change_class_path_match "$1" "$globs"; then
      CHANGE_CLASS_PATH=standard
      CHANGE_CLASS_PATH_CAUSE="configuration-source $PATH_MATCH_HIT"
      return 0
    fi
  fi
  if [ "$2" = pointer ] || [ "$2" = launch ]; then
    if change_class_path_match "$1" $'CLAUDE.md\n*/CLAUDE.md'; then
      CHANGE_CLASS_PATH=standard
      CHANGE_CLASS_PATH_CAUSE="instruction-pointer $PATH_MATCH_HIT"
      return 0
    fi
  fi
  if [ "$2" = narrow ] || [ "$2" = launch ]; then
    if change_class_path_match "$1" "$CHANGE_CLASS_EXCLUDED"; then
      CHANGE_CLASS_PATH=standard
      CHANGE_CLASS_PATH_CAUSE="excluded-path $PATH_MATCH_HIT"
      return 0
    fi
    if change_class_path_match "$1" "$CHANGE_CLASS_INSTRUCTION"; then
      CHANGE_CLASS_PATH=small
      CHANGE_CLASS_PATH_CAUSE="instruction-file $PATH_MATCH_HIT"
    fi
  fi
}

# The main checkout of the checkout DIR is in, from git's common directory:
# a linked worktree reads its repository's settings, never its own.
change_scope_main_root() { # DIR
  local common
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  case "$common" in
    */.git) printf '%s\n' "${common%/.git}" ;;
    *) git -C "$1" rev-parse --show-toplevel 2>/dev/null ;;
  esac
}

change_scope_location_load() { # REPO
  local root
  if ! change_class_path_load "$CHANGE_SCOPE_LIB_DIR/../../references/narrow-change.conf"; then
    CHANGE_CLASS_CAUSE="$CHANGE_CLASS_PATH_CAUSE"
    return 1
  fi
  CHANGE_CLASS_CAUSE=base-settings-unreadable
  root="$(change_scope_main_root "$1")" || return 1
  CHANGE_CLASS_SETTINGS_ROOT="$root"
  # A lane and its inherited settings cannot choose their own standard paths.
  CHANGE_CLASS_STANDARD_PATHS="$(
    unset HARNESS_CI_STANDARD_PATHS
    # shellcheck source=kendex-env.sh
    . "$CHANGE_SCOPE_LIB_DIR/kendex-env.sh" || exit 1
    kendex_load_settings_file "$root/kendex.settings.toml" -- HARNESS_CI_STANDARD_PATHS || exit 1
    kendex_load_settings_file "$root/.kendex/settings.toml" -- HARNESS_CI_STANDARD_PATHS || exit 1
    globs=()
    read -r -a globs <<<"${HARNESS_CI_STANDARD_PATHS:-}"
    [ "${#globs[@]}" -eq 0 ] || printf '%s\n' "${globs[@]}"
  )" || return 1
  CHANGE_CLASS_CAUSE=""
}

# An unreadable or absent verdict keeps the inventory under the path rules.
change_scope_inventory_rendered() { # BASE HEAD REPO STDERR_FILE
  local reader="$CHANGE_SCOPE_LIB_DIR/../harness-only" inventory_change
  [ -x "$reader" ] || return 1
  "$reader" --mode harness --event pull_request --base "$1" --head "$2" --repo "$3" \
    --output /dev/null >/dev/null 2>"$4" || return 1
  inventory_change="$(sed -n 's/^inventory-change: //p' "$4" | tail -1)" || return 1
  case "$inventory_change" in
    names-only\ *\ roots=*)
      names_only_roots_rendered "${inventory_change##* roots=}" \
        branch_growth_render_roots "$CHANGE_CLASS_SETTINGS_ROOT" ;;
    *) return 1 ;;
  esac
}

# Splitting a blank-separated list leaves each word open to pathname
# expansion, and a glob naming a real directory would be replaced by the files
# under the caller's working directory. Expansion is off for the split alone.
GLOB_LIST=()
set_globs() { # GLOBS
  set -f
  # shellcheck disable=SC2206
  GLOB_LIST=($1)
  set +f
}

# One matcher and one glob grammar for the allowlist and the refusal lists.
PATH_MATCH_HIT=""
path_matches() { # MODE(every|any) [PATHS] — against GLOB_LIST, PATHS default $changed
  local path hit globs
  PATH_MATCH_HIT=""
  globs=""
  if [ "${#GLOB_LIST[@]}" -gt 0 ]; then
    printf -v globs '%s\n' "${GLOB_LIST[@]}"
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    hit=false
    if change_class_path_match "$path" "$globs"; then hit=true; fi
    if [ "$1" = any ]; then
      [ "$hit" = false ] || return 0
    else
      [ "$hit" = true ] || return 1
    fi
  done <<<"${2-$changed}"
  [ "$1" = every ]
}

# One tab, resolved once. The ownership pass reads it once per printed
# position per changed path, and a substitution at that read forks a
# subshell every time: minutes over a repository's own refresh.
TAB="$(printf '\t')"

# The bytes of PATH as commit REV holds it, written to OUT: status 0, 2 where
# that commit holds no PATH, 3 where it holds PATH as anything but a regular
# file, and 1 where the commit or the file could not be read. A symlink is a
# blob of its target's name, which no reader of a checkout sees: it follows
# the link.
rev_file() { # REV PATH OUT
  local listed kind blob
  listed="$(git -C "$repo" ls-tree "$1" -- "$2" 2>/dev/null)" || return 1
  [ -n "$listed" ] || return 2
  case "${listed%% *}" in
    100644 | 100755) ;;
    *) return 3 ;;
  esac
  kind="${listed#* }"
  kind="${kind%% *}"
  blob="${listed%%"$TAB"*}"
  blob="${blob##* }"
  [ "$kind" = blob ] || return 1
  git -C "$repo" cat-file blob "$blob" >"$3" 2>/dev/null || return 1
}

# rev_file at the commit --base names. BASE_REV is that commit, resolved once.
BASE_REV=""
base_file() { # PATH OUT
  if [ -z "$BASE_REV" ]; then
    BASE_REV="$(git -C "$repo" rev-parse --verify --quiet "$base^{commit}" 2>/dev/null)" ||
      BASE_REV=""
    [ -n "$BASE_REV" ] || return 1
  fi
  rev_file "$BASE_REV" "$1" "$2"
}

# The settings the base endpoint's commit holds, read from the [env] tables
# of BASE_SETTINGS_FILES, never from the judged tree: a branch cannot choose
# the ceilings or the roots its own size is scored against, nor the paths
# that keep it in the queue, and a settings file the branch changes answers
# standard as a configuration source. That commit is the one --base names,
# the pull request's base end or a merge group's base, never the merge base,
# which the author picks by choosing where to fork. The tables are parsed by
# kendex-env.sh beside this library, the shared settings reader, in its
# ladder's order, so .kendex/settings.toml outranks kendex.settings.toml;
# nothing is sourced, so the private env file its KENDEX_ENV_FILE names
# never reaches the caller. A key the process environment carries keeps that
# value, as it does on the ladder; a caller whose keys must come from the
# base alone unsets them first. The load runs in a subshell and hands back
# BASE_SETTINGS_KEYS alone.
MEASURE_CAUSE=""
base_settings() {
  local file files=() n=0 status loaded key value
  for file in $BASE_SETTINGS_FILES; do
    status=0
    base_file "$file" "$work/base-settings-$((n + 1))" || status=$?
    case "$status" in
      0) ;;
      2) continue ;;
      *)
        MEASURE_CAUSE="cause=base-settings-unreadable base=${BASE_REV:-$base}${BASE_REV:+ path=$file}"
        return 1 ;;
    esac
    n=$((n + 1))
    files=("${files[@]+"${files[@]}"}" "$work/base-settings-$n")
  done
  [ "$n" -gt 0 ] || return 0
  if ! loaded="$(
    exec 3>&1 1>&2
    # shellcheck disable=SC2086
    unset $BASE_SETTINGS_KEYS
    # shellcheck source=kendex-env.sh
    . "$CHANGE_SCOPE_LIB_DIR/kendex-env.sh" || exit 1
    for file in "${files[@]}"; do
      # shellcheck disable=SC2086
      kendex_load_settings_file "$file" -- $BASE_SETTINGS_KEYS || exit 1
    done
    for key in $BASE_SETTINGS_KEYS; do
      [ -z "${!key+x}" ] || printf '%s=%s\n' "$key" "${!key}" >&3
    done
  )"; then
    MEASURE_CAUSE="cause=base-settings-unreadable base=$BASE_REV"
    return 1
  fi
  while IFS= read -r value; do
    [ -n "$value" ] || continue
    key="${value%%=*}"
    [ -z "${!key+x}" ] || continue
    printf -v "$key" '%s' "${value#*=}"
  done <<<"$loaded"
}

# A checkout of REV at DIR, errors to ERR. It has a git directory of its own,
# which `git init` writes, and borrows the judged repository's objects
# through an alternates file. It never shares a git directory with the
# judged checkout, and that is what keeps kendex's arming records out of it.
# kendex records arming a package's repository effect under a git directory,
# the common one included, so a `git worktree add` would inherit it. With a
# record present, `kendex verify` runs the package's declared checker out of
# the tree it checks, and that checker is a file this diff can change.
#
# `git checkout` exits 0 when it cannot read a blob and leaves that file out,
# so the checkout is held to REV afterwards: a status naming anything is a
# tree that is not the commit, and is refused like a checkout that failed.
private_checkout() { # DIR REV ERR
  local private_tree="$1" objects left setting key value remote_base config_status=0
  objects="$(git -C "$repo" rev-parse --path-format=absolute --git-path objects 2>"$3")" &&
    git init -q "$private_tree" 2>>"$3" &&
    mkdir -p "$private_tree/.git/objects/info" &&
    printf '%s\n' "$objects" >"$private_tree/.git/objects/info/alternates" || return 1
  # A blob:none clone supplies missing blobs through its promisor remote.
  # Alternates alone cannot fetch them into this independent object store.
  git -C "$repo" config --null --get-regexp \
    '^remote\..*\.(url|promisor|partialclonefilter)$|^extensions\.partialclone$' \
    >"$private_tree/.git/promisor-config" 2>>"$3" || config_status=$?
  case "$config_status" in 0|1) ;; *) return 1 ;; esac
  while IFS= read -r -d '' setting; do
    key="${setting%%$'\n'*}"
    value="${setting#*$'\n'}"
    # remote set-url retains local relative paths. Their base must survive
    # the move to this checkout; a colon before a slash names a transport.
    case "$key" in
      remote.*.url)
        case "$value" in
          /*) ;;
          *)
            case "${value%%/*}" in
              *:*) ;;
              *)
                remote_base="$(cd -- "$repo" && pwd -P)" 2>>"$3" || return 1
                value="$remote_base/$value" ;;
            esac ;;
        esac ;;
    esac
    git -C "$private_tree" config "$key" "$value" 2>>"$3" || return 1
  done <"$private_tree/.git/promisor-config"
  git -C "$private_tree" checkout -q --detach "$2" 2>>"$3" &&
    left="$(git -C "$private_tree" status --porcelain 2>>"$3")" || return 1
  [ -z "$left" ] || { printf '%s\n' "$left" >>"$3"; return 1; }
}

CHANGE_SCOPE_CLASS=""
CHANGE_SCOPE_CAUSE=""
CHANGE_SCOPE_MEASURED=""
CHANGE_SCOPE_RANK=""

change_scope_rank() { # CLASS
  case "$1" in
    render) CHANGE_SCOPE_RANK=0 ;;
    trivial) CHANGE_SCOPE_RANK=1 ;;
    micro) CHANGE_SCOPE_RANK=2 ;;
    small) CHANGE_SCOPE_RANK=3 ;;
    standard) CHANGE_SCOPE_RANK=4 ;;
    *) return 1 ;;
  esac
}

change_scope_floor() { # CLASS
  local micro
  change_scope_rank micro
  micro="$CHANGE_SCOPE_RANK"
  change_scope_rank "$1" && [ "$CHANGE_SCOPE_RANK" -ge "$micro" ]
}

change_scope_read() { # BASE HEAD REPO STDERR_FILE
  local classifier="$CHANGE_SCOPE_LIB_DIR/../change-scope" answer status=0
  CHANGE_SCOPE_CLASS=""
  CHANGE_SCOPE_CAUSE=""
  CHANGE_SCOPE_MEASURED=""
  if [ ! -x "$classifier" ]; then
    CHANGE_SCOPE_CAUSE=classifier-absent
    return 1
  fi
  answer="$("$classifier" --event pull_request --base "$1" --head "$2" --repo "$3" 2>>"$4")" || status=$?
  if [ "$status" -ne 0 ]; then
    CHANGE_SCOPE_CAUSE="classifier-exit-$status"
    return 1
  fi
  case "$answer" in
    # Letters spelled out: a range class follows the locale's collation.
    change_class=*[!abcdefghijklmnopqrstuvwxyz]* | change_class=)
      CHANGE_SCOPE_CAUSE=classifier-unreadable
      return 1 ;;
    change_class=*) CHANGE_SCOPE_CLASS="${answer#change_class=}" ;;
    *) CHANGE_SCOPE_CAUSE=classifier-unreadable; return 1 ;;
  esac
  CHANGE_SCOPE_MEASURED="$(sed -n 's/^class: class=[^ ]* measured=\([^ ]*\).*/\1/p' "$4")" ||
    { CHANGE_SCOPE_CAUSE=classifier-unreadable; return 1; }
  CHANGE_SCOPE_MEASURED="${CHANGE_SCOPE_MEASURED##*$'\n'}"
}
