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
# One entry per --repo, in REPOS order: the `<pr>\t<kind>` keys present on the
# previous pass (the rising-edge baseline), the file holding them, and whether
# that file already existed. Indexed arrays, never associative ones: bash 3.2
# has no associative arrays and orch's scripts run on it.
PW_SEEN=()
PW_STATE_FILE=()
PW_HAD_STATE=()

# The overseer exits this watch on every event and re-runs it, so the baseline
# outlives the process: one file per repo, keyed on that repo and the --since
# value every run of that fleet passes. Loaded as pass 1's baseline, rewritten
# after every pass.
pw_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

pw_save_state() {
  local file="$1" tmp
  [[ -n "$file" ]] || return 0
  tmp="$file.$$.tmp"
  { printf '%s' "$2" > "$tmp" && mv -f "$tmp" "$file"; } \
    || die "could not write the pr-watch state file $file (set OVERSEE_WATCH_STATE_DIR)"
}

# The repo a reducer line came from, ahead of the line's own tab-separated
# columns: one context block reads across the fleet, and the reader can tell
# which repo a `<pr> <kind>` belongs to.
pw_prefix() { awk -v repo="$1" '{ print repo "\t" $0 }' <<<"$2"; }

# One baseline file per repo, loaded before the first pass.
pw_init_state() {
  [[ -n "$PR_WATCH" ]] || return 0
  local repo state_file seen
  mkdir -p "$PW_STATE_DIR" \
    || die "could not create the pr-watch state directory $PW_STATE_DIR (set OVERSEE_WATCH_STATE_DIR)"
  [[ -w "$PW_STATE_DIR" ]] \
    || die "the pr-watch state directory $PW_STATE_DIR is not writable (set OVERSEE_WATCH_STATE_DIR)"
  for repo in "${REPOS[@]}"; do
    state_file="$PW_STATE_DIR/$(pw_slug "$repo")__$(pw_slug "${SINCE:-none}")"
    PW_STATE_FILE+=("$state_file")
    if [[ -f "$state_file" ]]; then
      seen="$(cat "$state_file" 2>/dev/null)" \
        || die "cannot read the pr-watch state file: $state_file (set OVERSEE_WATCH_STATE_DIR)"
      PW_SEEN+=("$seen")
      PW_HAD_STATE+=(1)
    else
      PW_SEEN+=("")
      PW_HAD_STATE+=(0)
    fi
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
  local errf="$WORK_DIR/pr-watch.err" repo out err rc keys new_keys key
  local i=0 event=0
  PW_RC=0
  PW_OUT=""
  PW_ERR=""
  PW_PASSES=$((PW_PASSES + 1))
  # Every repo is reduced on every pass, even once one of them has news: the
  # context each event carries is the whole fleet's state, and a repo skipped
  # here would carry a stale baseline into the next pass.
  for repo in "${REPOS[@]}"; do
    rc=0
    out="$(GH_REPO="$repo" "$PR_WATCH" 2>"$errf")" || rc=$?
    err="$(cat "$errf")"
    [[ "$rc" -le "$PW_RC" ]] || PW_RC="$rc"
    [[ -z "$out" ]] || PW_OUT+="$(pw_prefix "$repo" "$out")"$'\n'
    [[ -z "$err" ]] || PW_ERR+="$(pw_prefix "$repo" "$err")"$'\n'
    if [[ "$rc" -eq 0 ]]; then
      PW_SEEN[$i]=""
      pw_save_state "${PW_STATE_FILE[$i]}" ""
      i=$((i + 1))
      continue
    fi
    # Non-zero with no per-PR lines is pr-watch's GLOBAL failure shape
    # (pr-watch.sh --help): it reports on stderr only, and nothing here can be
    # trusted.
    [[ -n "$out" ]] || die "pr-watch failed for $repo (rc=$rc) with no per-PR lines: ${err:-<no stderr>}"
    keys="$(awk -F'\t' 'NF >= 3 { print $1 "\t" $3 }' <<<"$out")"
    new_keys=""
    while IFS= read -r key; do
      [[ -n "$key" ]] || continue
      grep -qxF -- "$key" <<<"${PW_SEEN[$i]}" || new_keys+="$key"$'\n'
    done <<<"$keys"
    # Rising edge against this repo's previous pass only: a line that clears
    # and later recurs is news again. Pass 1 compares against the persisted
    # baseline.
    PW_SEEN[$i]="$keys"
    pw_save_state "${PW_STATE_FILE[$i]}" "$keys"
    if [[ -n "$new_keys" ]]; then
      if [[ "$PW_PASSES" -eq 1 && "${PW_HAD_STATE[$i]}" -eq 0 ]]; then
        echo "oversee-watch: pr-watch attention present at start for $repo (rc=$rc, $(grep -c . <<<"$new_keys") line(s)) — the fleet's baseline, reported with the next event; only NEW lines become events" >&2
      else
        event=1
      fi
    fi
    i=$((i + 1))
  done
  PW_OUT="${PW_OUT%$'\n'}"
  PW_ERR="${PW_ERR%$'\n'}"
  [[ "$event" -eq 1 ]] || return 0
  echo "EVENT pr-watch rc=$PW_RC"
  [[ -z "$PW_OUT" ]] || printf '%s\n' "$PW_OUT"
  [[ -z "$PW_ERR" ]] || printf '%s\n' "$PW_ERR"
  exit 0
}
