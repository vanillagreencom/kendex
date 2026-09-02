# shellcheck shell=bash
# The review-gate reducer pass of oversee-watch: pr-watch over every --repo,
# each repo's rising edge against its own persisted baseline, and the context
# block every other event carries. Sourced by oversee-watch, and like the rest
# of its lib/ it reads that script's globals (REPOS, PR_WATCH, PW_STATE_DIR,
# WORK_DIR, SINCE) and calls its `die`.

# The latest pr-watch result across every --repo, appended to every event's
# output: each line carries the repo it came from, and rc is the highest
# status any repo's reducer returned.
PW_RC=0
PW_OUT=""
PW_ERR=""
PW_PASSES=0
# One entry per --repo, in REPOS order: the `<pr>\t<kind>` keys the last
# COMPLETE pass saw, and whether this run started with a baseline file for that
# repo. Indexed arrays, never associative ones: bash 3.2 has no associative
# arrays and orch's scripts run on it.
PW_SEEN=()
PW_HAD_STATE=()

# The overseer exits this watch on every event and re-runs it, so the baseline
# outlives the process: one file per repo, keyed on that repo and the --since
# value every run of that fleet passes. Loaded as pass 1's baseline, rewritten
# after every complete pass.
pw_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
pw_state_file() { printf '%s/%s__%s' "$PW_STATE_DIR" "$(pw_slug "$1")" "$(pw_slug "${SINCE:-none}")"; }

# The flush is two phases: pw_stage_state judges a repo's target and writes its
# temp file, renaming nothing, and pw_commit_state renames once every repo has
# staged. Everything that can be judged about a target is judged while staging,
# so a staging failure advances no baseline and leaves no temp. A rename that
# fails after staging is the one path that can leave the fleet split, the repos
# ahead of it advanced and the rest not; it drops the temps it can and dies,
# and nothing recovers the split.
pw_stage_state() {
  local file="$1" tmp="$1.$$.tmp"
  [[ ! -e "$file" || -f "$file" ]] \
    || { pw_discard_temps; die "could not write the pr-watch state file $file (not a regular file; set OVERSEE_WATCH_STATE_DIR)"; }
  printf '%s' "$2" > "$tmp" \
    || { pw_discard_temps; die "could not write the pr-watch state file $file (set OVERSEE_WATCH_STATE_DIR)"; }
}

pw_commit_state() {
  mv -f "$1.$$.tmp" "$1" \
    || { pw_discard_temps; die "could not replace the pr-watch state file $1 (set OVERSEE_WATCH_STATE_DIR)"; }
}

# Every temp this pass may have staged. Sweeping the whole fleet is right from
# either caller: a repo already renamed has no temp left for rm -f to remove,
# and the names carry this pid, so no later run would clean one up.
pw_discard_temps() {
  local repo
  for repo in "${REPOS[@]}"; do
    rm -f "$(pw_state_file "$repo").$$.tmp"
  done
}

# The repo a reducer line came from, ahead of the line's own tab-separated
# columns: one context block reads across the fleet, and the reader can tell
# which repo a `<pr> <kind>` belongs to.
pw_prefix() { awk -v repo="$1" '{ print repo "\t" $0 }' <<<"$2"; }

# One baseline file per repo, loaded before the first pass.
pw_init_state() {
  # Lanes count: their asking fingerprints are rows in the first repository's
  # baseline, so a lane-only run still loads and writes it.
  [[ -n "$PR_WATCH" || "${TRIAGE_ENABLED:-0}" -eq 1 || ${#LANES[@]} -gt 0 ]] || return 0
  local i state_file
  mkdir -p "$PW_STATE_DIR" \
    || die "could not create the pr-watch state directory $PW_STATE_DIR (set OVERSEE_WATCH_STATE_DIR)"
  [[ -w "$PW_STATE_DIR" ]] \
    || die "the pr-watch state directory $PW_STATE_DIR is not writable (set OVERSEE_WATCH_STATE_DIR)"
  for i in "${!REPOS[@]}"; do
    state_file="$(pw_state_file "${REPOS[$i]}")"
    PW_SEEN[$i]=""
    PW_HAD_STATE[$i]=0
    [[ -f "$state_file" ]] || continue
    PW_SEEN[$i]="$(cat "$state_file" 2>/dev/null)" \
      || die "cannot read the pr-watch state file: $state_file (set OVERSEE_WATCH_STATE_DIR)"
    PW_HAD_STATE[$i]=1
  done
}

pr_watch_context() {
  [[ "$PW_RC" -ne 0 ]] || return 0
  echo "pr-watch rc=$PW_RC"
  [[ -z "$PW_OUT" ]] || printf '%s\n' "$PW_OUT"
  [[ -z "$PW_ERR" ]] || printf '%s\n' "$PW_ERR"
}

# Every step exits on its first event; the loop body only reaches `sleep`
# when nothing needs the overseer.
check_pr_watch() {
  [[ -n "$PR_WATCH" ]] || return 0
  local errf="$WORK_DIR/pr-watch.err" i repo out err rc keys carried new_keys key
  local rc_max=0 out_all="" err_all="" event=0
  # This pass's keys per repo. The reduction touches no baseline: a die below
  # would otherwise leave a repo's rising edge recorded as seen with no event
  # printed, and that line is then never news again.
  local pass_keys=()
  PW_PASSES=$((PW_PASSES + 1))
  # Every repo is reduced on every pass, even once one of them has news: the
  # context each event carries is the whole fleet's state, and a repo skipped
  # here would carry a stale baseline into the next pass.
  for i in "${!REPOS[@]}"; do
    repo="${REPOS[$i]}"
    rc=0
    out="$(GH_REPO="$repo" "$PR_WATCH" --heal 2>"$errf")" || rc=$?
    err="$(cat "$errf")"
    [[ "$rc" -le "$rc_max" ]] || rc_max="$rc"
    [[ -z "$out" ]] || out_all+="$(pw_prefix "$repo" "$out")"$'\n'
    [[ -z "$err" ]] || err_all+="$(pw_prefix "$repo" "$err")"$'\n'
    # Rows this pass does not own: triage verdict keys and lane-asking
    # fingerprints share the file, and a rewrite that dropped them would make
    # every acknowledged item and every standing prompt news again.
    carried="$(awk -F'\t' '($1 == "triage" && NF == 2) || ($1 == "lane-asking" && NF == 3) { print }' <<<"${PW_SEEN[$i]}")"
    pass_keys[$i]="$carried"
    [[ "$rc" -ne 0 ]] || continue
    # Non-zero with no per-PR lines is pr-watch's GLOBAL failure shape
    # (pr-watch.sh --help): it reports on stderr only, and nothing here can be
    # trusted.
    [[ -n "$out" ]] || die "pr-watch failed for $repo (rc=$rc) with no per-PR lines: ${err:-<no stderr>}"
    # heal-dispatched is the reducer reporting its OWN bounded writer dispatch,
    # not attention on the PR it is attributed to. Keyed like the rest it would
    # wake the overseer for a line whose handler is "nothing to do", and its
    # attribution moves to whichever gate-stale PR comes first, so one dispatch
    # mints a new key every time the leading PR converges. It stays in $out,
    # where every event carries it as context.
    keys="$(awk -F'\t' 'NF >= 3 && $3 != "heal-dispatched" { print $1 "\t" $3 }' <<<"$out")"
    new_keys=""
    while IFS= read -r key; do
      [[ -n "$key" ]] || continue
      grep -qxF -- "$key" <<<"${PW_SEEN[$i]}" || new_keys+="$key"$'\n'
    done <<<"$keys"
    if [[ -n "$carried" && -n "$keys" ]]; then
      pass_keys[$i]="$carried"$'\n'"$keys"
    else
      pass_keys[$i]="$carried$keys"
    fi
    [[ -n "$new_keys" ]] || continue
    # Rising edge against this repo's previous pass only: a line that clears
    # and later recurs is news again. Pass 1 compares against the persisted
    # baseline; a repo this run named for the first time has none, so its
    # standing attention is that repo's baseline rather than an event.
    # An `error` key preempts even a repo's opening pass. Every other kind
    # standing at start is that repo's baseline, but an error is the reducer
    # saying it could not answer for a PR — a failed writer dispatch among
    # them — and the overseer has to act on it before another pass runs.
    # Baselined instead, it is written as seen and never news again, so the
    # first fleet run against a repo with a broken dispatch path would say
    # nothing until the heartbeat.
    if awk -F'\t' '$2 == "error" { found = 1 } END { exit !found }' <<<"$new_keys"; then
      event=1
    elif [[ "$PW_PASSES" -eq 1 && "${PW_HAD_STATE[$i]}" -eq 0 ]]; then
      echo "oversee-watch: pr-watch attention present at start for $repo (rc=$rc, $(grep -c . <<<"$new_keys") line(s)) — the fleet's baseline, reported with the next event; only NEW lines become events" >&2
    else
      event=1
    fi
  done
  PW_RC="$rc_max"
  PW_OUT="${out_all%$'\n'}"
  PW_ERR="${err_all%$'\n'}"
  # The invariant: no baseline is committed before the pass has DELIVERED the
  # event it raised. The event prints here, ahead of every write, so however
  # the flush below ends the line has already reached stdout and none is lost;
  # a baseline advanced over an undelivered event loses that line for good.
  # A staging failure then advances no baseline and the next run repeats the
  # event, which is the safe direction. A rename failure can leave the fleet
  # split, and only the repos it did advance suppress their duplicate.
  if [[ "$event" -eq 1 ]]; then
    echo "EVENT pr-watch rc=$PW_RC"
    [[ -z "$PW_OUT" ]] || printf '%s\n' "$PW_OUT"
    [[ -z "$PW_ERR" ]] || printf '%s\n' "$PW_ERR"
  fi
  for i in "${!REPOS[@]}"; do
    pw_stage_state "$(pw_state_file "${REPOS[$i]}")" "${pass_keys[$i]}"
  done
  for i in "${!REPOS[@]}"; do
    pw_commit_state "$(pw_state_file "${REPOS[$i]}")"
    PW_SEEN[$i]="${pass_keys[$i]}"
  done
  [[ "$event" -eq 1 ]] || return 0
  exit 0
}
