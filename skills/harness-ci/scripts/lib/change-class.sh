#!/usr/bin/env bash
# Shared path rules for change-class and orch's item-tier Location inputs.
# Sourced with extglob enabled. Path helpers read no diff or repository settings.
# change_class_lanes reads declarations and uses harness-only's resolved range.
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

# The adopted caller can lack an inventory entry when adoption preserves its
# configuration. Candidacy permits proof setup; release comparison owns it.
HARNESS_CI_REFRESH_CALLER=.github/workflows/kendex-refresh.yml

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

# Lane decisions shared by the installed command and the action. The caller
# supplies the class and harness-only's paths, outside list and range log in
# WORK. Results are lanes, lanes_cause and the lane_* arrays used by CI proof.
# No CI proof is read here. The action applies its proof after this decision.
change_class_lanes() { # CLASS DOCS EVENT REPO HEAD QUEUE_ONLY WORK LANES_FROM
  local class="$1" docs="$2" EVENT="$3" REPO="$4" HEAD="$5"
  local queue_only="$6" work="$7" lanes_from="$8" declaration="" lanes_root="" judged_root=""
  local base_lane_count declaration_comparison no_changed_paths unclaimed_path
  local render_base render_head has_deletions status path index delta name claimed
  local moved_paths=() added_paths=() lane_hits=() lane_changed=() render_hits=()
  local reader_missing queue_reader hit
# Every class but `standard` is reached only after the classifier read a
# changed path, so an empty list under one of them is a state neither script
# can produce. Publishing the families empty there would select the lanes a
# narrow class runs on nothing at all.
if [ ! -s "${work:?}/paths" ] && [ "$class" != standard ]; then
  die "class-without-paths class=$class" \
    "a narrow class arrived with no changed path, which no classifier emits"
fi

declaration=""
if [ -n "$lanes_from" ]; then
  lanes_root="$(cd "$lanes_from" 2>/dev/null && pwd -P)" ||
    die "lanes-from-unreadable root=$lanes_from" \
      "the lanes-from checkout is not a directory"
  judged_root="$(cd "$REPO" 2>/dev/null && pwd -P)" ||
    die "repo-unreadable repo=$REPO" "the repo checkout is not a directory"
  [ "$lanes_root" != "$judged_root" ] ||
    die "lanes-from-judged-tree root=$lanes_from" \
      "lanes-from names the tree under judgement, whose author could stand a lane down"
  declaration="$lanes_root/.github/ci-lanes.conf"
fi

if [ "$class" = render ] || [ "$class" = trivial ]; then
  lanes=false lanes_cause="$class"
elif [ "$docs" = docs_only=true ]; then
  lanes=false lanes_cause=docs-only
else
  lanes=true lanes_cause="$class"
fi

outside_docs() { # PATH — 0 outside the docs set, 1 inside it
  local status=0
  grep -qxF -- "$1" "${work:?}/outside" 2>/dev/null || status=$?
  case "$status" in
    0) return 0 ;;
    1) return 1 ;;
    *) die "outside-list-unreadable status=$status" \
      "could not read the paths harness-only placed outside the docs set" ;;
  esac
}

lane_count=0
lane_state="unset"
if [ -n "$declaration" ]; then
  if [ ! -e "$declaration" ]; then
    lane_state="absent"
  elif ci_lanes_read "$declaration"; then
    lane_state="read"
  else
    lane_state="malformed" lane_count=0
  fi
  printf 'lane-declaration: state=%s path=%s%s\n' "$lane_state" \
    "$declaration" "${declaration_note:+ $declaration_note}" >&2
fi
case "$lane_state" in
  absent | malformed)
    printf '::warning title=lane declaration %s::%s %s; no lane verdict is published\n' \
      "$lane_state" "$declaration" "${declaration_note:-}" ;;
esac

# This local comparison needs no decision record: branch claims cannot
# stand down checks for other paths, since the author controls those claims.
declaration_delta() {
  local names=("${lane_names[@]}") queues=("${lane_queue[@]}") claims=()
  local count="$lane_count" index other claim found
  index=0
  while [ "$index" -lt "$count" ]; do
    claims[$index]="$(printf '%s' "${lane_globs[$index]}" | LC_ALL=C sort -u)" || return 1
    index=$((index + 1))
  done
  git -C "$REPO" cat-file blob "$HEAD:.github/ci-lanes.conf" >"${work:?}/head-ci-lanes.conf" 2>/dev/null || return 1
  ci_lanes_read "${work:?}/head-ci-lanes.conf" || return 1
  index=0
  while [ "$index" -lt "$lane_count" ]; do
    other=0
    while [ "$other" -lt "$count" ] && [ "${names[$other]}" != "${lane_names[$index]}" ]; do
      other=$((other + 1))
    done
    claim="$(printf '%s' "${lane_globs[$index]}" | LC_ALL=C sort -u)" || return 1
    if [ "$other" -eq "$count" ] || [ "${claims[$other]}" != "$claim" ] || [ "${queues[$other]}" != "${lane_queue[$index]}" ]; then
      printf '%s\n' "${lane_names[$index]}"
    fi
    index=$((index + 1))
  done
  other=0
  while [ "$other" -lt "$count" ]; do
    found=false index=0
    while [ "$index" -lt "$lane_count" ]; do
      [ "${names[$other]}" != "${lane_names[$index]}" ] || found=true
      index=$((index + 1))
    done
    [ "$found" = true ] || printf '%s\n' "${names[$other]}"
    other=$((other + 1))
  done
}

# Each path records its own evidence. The verdict pass alone gives a failed
# comparison precedence over queue deferral, and an ordinary claim precedence
# over a valid declaration delta, without one path discarding another's fact.
base_lane_count="$lane_count"
lane_hits=()
lane_changed=()
render_hits=()
if [ "$lane_state" = read ] && [ "$class" = render ]; then
  # The classifier's reader owns the event range. Its resolved endpoints
  # keep this status read on that range, including a moving PR base.
  render_base="$(sed -n 's/^base-rev: //p' "${work:?}/class-log")" ||
    die render-range-unreadable "could not read the render base revision"
  render_head="$(sed -n 's/^head-rev: //p' "${work:?}/class-log")" ||
    die render-range-unreadable "could not read the render head revision"
  [ -n "$render_base" ] && [ -n "$render_head" ] ||
    die render-range-unreadable "the render classifier supplied no resolved range"
  git -C "$REPO" diff --no-ext-diff --no-textconv \
    --name-status -z --no-renames --diff-filter=AD "$render_base" "$render_head" -- \
    >"${work:?}/moved" || die render-moves-unreadable "could not read render additions and deletions"
  moved_paths=() added_paths=() has_deletions=false
  while IFS= read -r -d '' status <&3; do
    IFS= read -r -d '' path <&3 || die render-moves-unreadable "a moved path is absent"
    case "$status" in
      A) added_paths+=("$path") ;;
      D) has_deletions=true; moved_paths+=("$path") ;;
    esac
  done 3<"${work:?}/moved"
  # WriteTree carries paths and bytes, not move identity. Similarity can pair
  # an old file with a retained copy and hide its rewritten destination.
  # Disabling rename pairing keeps every disappeared path visible. Each
  # addition then needs its claiming lane. Additions alone grant no lane.
  if [ "$has_deletions" = true ]; then
    moved_paths=("${moved_paths[@]+"${moved_paths[@]}"}" "${added_paths[@]+"${added_paths[@]}"}")
  fi
  for path in ${moved_paths[@]+"${moved_paths[@]}"}; do
    index=0
    while [ "$index" -lt "$lane_count" ]; do
      if ci_lanes_claims "$index" "$path" && [ -z "${render_hits[$index]:-}" ]; then
        render_hits[$index]="path=$path glob=$LANE_GLOB_HIT"
        lanes=true lanes_cause=render-moved-claim
      fi
      index=$((index + 1))
    done
  done
fi
declaration_comparison=not-needed
no_changed_paths=false
unclaimed_path=""
if [ "$lane_state" = read ] && [ "$lanes" = true ] && [ "$class" != render ]; then
  index=0
  while [ "$index" -lt "$lane_count" ]; do
    lane_hits[$index]="" lane_changed[$index]=false
    index=$((index + 1))
  done
  if [ ! -s "${work:?}/paths" ]; then
    no_changed_paths=true
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ "$path" = .github/ci-lanes.conf ]; then
      if delta="$(declaration_delta)"; then
        declaration_comparison=valid
        while IFS= read -r name; do
          [ -n "$name" ] || continue
          index=0
          while [ "$index" -lt "$lane_count" ] && [ "${lane_names[$index]}" != "$name" ]; do
            index=$((index + 1))
          done
          if [ "$index" -eq "$lane_count" ]; then
            lane_names[$index]="$name" lane_globs[$index]=""
            lane_queue[$index]=false lane_uniform[$index]=false
            lane_hits[$index]="" lane_changed[$index]=false
            lane_count=$((lane_count + 1))
          fi
          lane_changed[$index]=true
        done <<<"$delta"
      else
        declaration_comparison=unreadable
      fi
      continue
    fi
    claimed=false
    index=0
    while [ "$index" -lt "$base_lane_count" ]; do
      if ci_lanes_claims "$index" "$path"; then
        claimed=true
        [ -n "${lane_hits[$index]}" ] ||
          lane_hits[$index]="path=$path glob=$LANE_GLOB_HIT"
      fi
      index=$((index + 1))
    done
    if [ "$claimed" = false ] && [ -z "$unclaimed_path" ] && outside_docs "$path"; then
      unclaimed_path="$path"
    fi
  done <"${work:?}/paths"
fi

# The trees, of the two a merge of this pull request may run pr-merge from,
# whose harness-ci render lacks the reader of the `:queue` mark: `lanes-from`,
# `judged`, both comma-joined, or empty where both carry it. The render path
# is the one the harness-ci template's render-reach step runs from. The
# judged tree is read at HEAD, not REPO's worktree, which on a pull request
# is the merge GitHub built and holds the base's render where the head has
# none; a HEAD REPO cannot read counts as absent, so the lane runs.
queue_reader=.agents/skills/harness-ci/scripts/lib/ci-lanes.sh
queue_reader_missing() {
  local missing=""
  [ -f "$lanes_root/$queue_reader" ] || missing="lanes-from"
  [ "$(git -C "$REPO" cat-file -t "$HEAD:$queue_reader" 2>/dev/null)" = blob ] ||
    missing="${missing:+$missing,}judged"
  printf '%s' "$missing"
}

# Each lane's classified verdict and cause, at its index. On a pull request
# a lane marked `:queue` that one of its own globs reached stands down only
# where this run's change-class answered queue_only=true and both renders
# read the mark, so pr-merge, asking the same question from either, keeps
# the pull request off the admin merge. Otherwise it runs, its cause naming
# what was missing. A queue lane only a fallback reached runs here, since no
# glob of its own put the diff in the queue.
# A failed declaration comparison permits no queue deferral.
lane_values=()
lane_causes=()
reader_missing=unread
index=0
while [ "$index" -lt "$lane_count" ]; do
  if [ "$lanes" = false ]; then
    lane_values[$index]=false lane_causes[$index]="cause=lanes-false lanes_cause=$lanes_cause"
  elif [ "$class" = render ]; then
    if [ -n "${render_hits[$index]:-}" ]; then
      lane_values[$index]=true lane_causes[$index]="cause=render-moved-claim ${render_hits[$index]}"
    else
      lane_values[$index]=false lane_causes[$index]="cause=render-unreached"
    fi
  elif [ "$declaration_comparison" = unreadable ]; then
    lane_values[$index]=true lane_causes[$index]="cause=lane-declaration-unreadable path=.github/ci-lanes.conf"
  elif [ "$EVENT" = pull_request ] && [ "${lane_queue[$index]}" = true ] && [ -n "${lane_hits[$index]}" ]; then
    hit="${lane_hits[$index]}"
    [ "$reader_missing" != unread ] || reader_missing="$(queue_reader_missing)"
    if [ -n "$reader_missing" ]; then
      lane_values[$index]=true lane_causes[$index]="cause=queue-reader-absent tree=$reader_missing $hit"
    elif [ "$queue_only" != true ]; then
      lane_values[$index]=true lane_causes[$index]="cause=queue-unconfirmed queue_only=${queue_only:-absent} $hit"
    else
      lane_values[$index]=false lane_causes[$index]="cause=queue-deferred $hit"
    fi
  elif [ "$no_changed_paths" = true ]; then
    lane_values[$index]=true lane_causes[$index]="cause=no-changed-paths"
  elif [ -n "$unclaimed_path" ]; then
    lane_values[$index]=true lane_causes[$index]="cause=unclaimed-path path=$unclaimed_path"
  elif [ -n "${lane_hits[$index]}" ]; then
    lane_values[$index]=true lane_causes[$index]="cause=claimed ${lane_hits[$index]}"
  elif [ "${lane_changed[$index]}" = true ]; then
    lane_values[$index]=true lane_causes[$index]="cause=declaration-changed path=.github/ci-lanes.conf"
  else
    lane_values[$index]=false lane_causes[$index]="cause=unreached"
  fi
  index=$((index + 1))
done
case "$reader_missing" in
  unread | "") ;;
  *) printf '::warning title=queue lane not deferred::tree=%s holds no %s, so github.sh pr-merge run from it would read this pull request free to take the admin merge; run kendex refresh on the default branch and rebase the pull request onto it, and until then the lane runs\n' \
    "$reader_missing" "$queue_reader" ;;
esac

}
