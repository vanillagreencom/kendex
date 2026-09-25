#!/usr/bin/env bash
# Decision IDs judged against the base branch: next-id skips a number the base
# holds, check refuses an ID two records share, and get refuses an ID on more
# than one INDEX row. Every row builds its own repositories, so a fetch one run
# makes never answers for the next.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
DECISIONS="$SKILL_DIR/scripts/decisions"
# shellcheck source=lib/mutate-script.sh
source "$TEST_DIR/lib/mutate-script.sh"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
ERR_FILE="$TMP_ROOT/stderr"

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# The developer's git configuration never reaches a fixture or a run: an
# insteadOf rewrite or a signing requirement would change what is fetched or
# committed.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# A world that is not a repository stays one wherever TMPDIR points.
export GIT_CEILING_DIRECTORIES="$TMP_ROOT"
git_q() {
  git -c user.email=test@example.com -c user.name=test -c commit.gpgsign=false "$@"
}

new_repo() { # DIR BRANCH
  git init -q "$1"
  git -C "$1" symbolic-ref HEAD "refs/heads/$2"
  git -C "$1" config gc.auto 0
  git -C "$1" config maintenance.auto false
  mkdir -p "$1/docs/decisions"
}

clone_repo() { # UPSTREAM DIR — the clone works on its own branch, lane
  git clone -q "$1" "$2"
  git -C "$2" config gc.auto 0
  git -C "$2" config maintenance.auto false
  git -C "$2" checkout -q -b lane
}

write_index() { # REPO ROW... — each ROW is ID:LINK[:STATUS]; rows start on line 3
  local repo="$1" row id link status
  shift
  {
    printf '%s\n' '| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |'
    printf '%s\n' '|------|----|----------|----------|-----------|--------------|--------|------|'
    for row in "$@"; do
      IFS=: read -r id link status <<<"$row"
      printf '| 2026-01-10 | %s | PROJ-1 | Decision %s | Reason | Never | %s | [Full](%s) |\n' \
        "$id" "$id" "${status:-Active}" "$link"
    done
  } >"$repo/docs/decisions/INDEX.md"
  for row in "$@"; do
    IFS=: read -r id link status <<<"$row"
    printf '# %s: Decision\n' "$id" >"$repo/docs/decisions/$link"
  done
}

commit_all() { # REPO MESSAGE
  git_q -C "$1" add -A
  git_q -C "$1" commit -q -m "$2"
}

# Each builder makes a fresh world under DIR and leaves the repository a row
# runs in at DIR/work.
build_ahead() { # the base gained D035 after the lane branched
  new_repo "$1/up" main
  write_index "$1/up" D034:D034-first.md
  commit_all "$1/up" base
  clone_repo "$1/up" "$1/work"
  write_index "$1/up" D034:D034-first.md D035:D035-main.md
  commit_all "$1/up" "main records D035"
}

build_behind() { # the lane added D035; the base has not moved
  new_repo "$1/up" main
  write_index "$1/up" D034:D034-first.md
  commit_all "$1/up" base
  clone_repo "$1/up" "$1/work"
  write_index "$1/work" D034:D034-first.md D035:D035-lane.md
}

build_no_remote() { # no remote and no main branch: no base resolves
  new_repo "$1/work" trunk
  write_index "$1/work" D034:D034-first.md
  commit_all "$1/work" base
}

build_unreachable() { # the lane fetched D035 once; then its remote broke
  build_ahead "$1"
  git -C "$1/work" fetch -q origin
  git -C "$1/work" remote set-url origin "$1/gone"
}

build_unreachable_collision() { # as unreachable, and the lane records its own D035
  build_unreachable "$1"
  write_index "$1/work" D034:D034-first.md D035:D035-lane.md
}

MALFORMED_ROW='| 2026-01-11 | D035 | PROJ-1 | Decision D035 | Reason | Never | Active |'

build_malformed_row() { # the lane's INDEX gains a seven-cell D035 row; local main is the base
  new_repo "$1/work" main
  write_index "$1/work" D034:D034-first.md
  commit_all "$1/work" base
  printf '%s\n' "$MALFORMED_ROW" >>"$1/work/docs/decisions/INDEX.md"
}

build_malformed_base_row() { # the base's INDEX carries a seven-cell D035 row
  new_repo "$1/up" main
  write_index "$1/up" D034:D034-first.md
  printf '%s\n' "$MALFORMED_ROW" >>"$1/up/docs/decisions/INDEX.md"
  commit_all "$1/up" base
  clone_repo "$1/up" "$1/work"
  write_index "$1/work" D034:D034-first.md
}

build_first_index_offline() { # the base gained its first INDEX.md after the lane's last fetch; the remote then broke
  git init -q "$1/up"
  git -C "$1/up" symbolic-ref HEAD refs/heads/main
  git -C "$1/up" config gc.auto 0
  git -C "$1/up" config maintenance.auto false
  printf '# fixture\n' >"$1/up/README.md"
  commit_all "$1/up" base
  clone_repo "$1/up" "$1/work"
  mkdir -p "$1/up/docs/decisions"
  write_index "$1/up" D001:D001-theirs.md
  commit_all "$1/up" "main records D001"
  mkdir -p "$1/work/docs/decisions"
  write_index "$1/work" D001:D001-mine.md
  git -C "$1/work" remote set-url origin "$1/gone"
}

build_no_repo() { # a decisions directory outside any repository
  mkdir -p "$1/work/docs/decisions"
  write_index "$1/work" D034:D034-first.md
}

build_stale_main() { # the fetch fails and only the lane's stale main resolves
  build_ahead "$1"
  git -C "$1/work" remote set-head origin -d
  git -C "$1/work" update-ref -d refs/remotes/origin/main
  git -C "$1/work" remote set-url origin "$1/gone"
}

build_collision() { # the lane and the base each record their own D035
  build_ahead "$1"
  write_index "$1/work" D034:D034-first.md D035:D035-lane.md
}

build_edited() { # the lane changes the status of the base's own D035
  build_ahead "$1"
  git -C "$1/work" pull -q --ff-only origin main
  write_index "$1/work" D034:D034-first.md "D035:D035-main.md:Superseded by D036"
}

build_origin_head() { # the upstream's default branch is master, not main
  new_repo "$1/up" master
  write_index "$1/up" D034:D034-first.md
  commit_all "$1/up" base
  clone_repo "$1/up" "$1/work"
  write_index "$1/up" D034:D034-first.md D035:D035-master.md
  commit_all "$1/up" "master records D035"
}

build_renamed_default() { # the upstream renamed master to trunk after the clone; both record a D002
  new_repo "$1/up" master
  write_index "$1/up" D001:D001-first.md
  commit_all "$1/up" base
  clone_repo "$1/up" "$1/work"
  git -C "$1/up" branch -m master trunk
  write_index "$1/up" D001:D001-first.md D002:D002-b.md
  commit_all "$1/up" "trunk records D002"
  write_index "$1/work" D001:D001-first.md D002:D002-z.md
}

build_configured_ref() { # only the upstream's release branch gains D035
  new_repo "$1/up" main
  write_index "$1/up" D034:D034-first.md
  commit_all "$1/up" base
  git -C "$1/up" branch release
  clone_repo "$1/up" "$1/work"
  git -C "$1/up" checkout -q release
  write_index "$1/up" D034:D034-first.md D035:D035-release.md
  commit_all "$1/up" "release records D035"
  git -C "$1/up" checkout -q main
}

build_local_ref() { # no remote; the local branch base holds D035
  new_repo "$1/work" trunk
  write_index "$1/work" D034:D034-first.md
  commit_all "$1/work" base
  git -C "$1/work" checkout -q -b base
  write_index "$1/work" D034:D034-first.md D035:D035-base.md
  commit_all "$1/work" "base records D035"
  git -C "$1/work" checkout -q trunk
}

build_empty_base_scheme() { # the lane's INDEX has no rows; the base gained ADR rows
  new_repo "$1/up" main
  write_index "$1/up"
  commit_all "$1/up" base
  clone_repo "$1/up" "$1/work"
  write_index "$1/up" ADR-0034:ADR-0034-first.md ADR-0035:ADR-0035-second.md
  commit_all "$1/up" "main records ADR rows"
}

build_prefix_base_width() { # the lane holds D rows only; the base gained ADR-0035
  new_repo "$1/up" main
  write_index "$1/up" D001:D001-first.md
  commit_all "$1/up" base
  clone_repo "$1/up" "$1/work"
  write_index "$1/up" D001:D001-first.md ADR-0035:ADR-0035-switch.md
  commit_all "$1/up" "main records ADR-0035"
}

build_index_absent() { # the base has no INDEX.md yet; the lane writes the first
  git init -q "$1/up"
  git -C "$1/up" symbolic-ref HEAD refs/heads/main
  git -C "$1/up" config gc.auto 0
  git -C "$1/up" config maintenance.auto false
  printf '# fixture\n' >"$1/up/README.md"
  commit_all "$1/up" base
  clone_repo "$1/up" "$1/work"
  mkdir -p "$1/work/docs/decisions"
  write_index "$1/work" D001:D001-first.md
}

build_blob_missing() { # a blob-filtered lane fetched D035's INDEX tree, not its blob
  new_repo "$1/up" main
  git -C "$1/up" config uploadpack.allowFilter true
  write_index "$1/up" D034:D034-first.md
  commit_all "$1/up" base
  git clone -q --filter=blob:none "file://$1/up" "$1/work"
  git -C "$1/work" config gc.auto 0
  git -C "$1/work" config maintenance.auto false
  git -C "$1/work" checkout -q -b lane
  write_index "$1/up" D034:D034-first.md D035:D035-main.md
  commit_all "$1/up" "main records D035"
  git -C "$1/work" fetch -q origin
  git -C "$1/work" remote set-url origin "file://$1/gone"
}

build_dup_rows() { # two INDEX rows carry D035, no remote; local main is the base
  new_repo "$1/work" main
  write_index "$1/work" D034:D034-first.md D035:D035-a.md D035:D035-b.md
  commit_all "$1/work" base
}

build_dup_files() { # one D035 row, two D035 documents, no remote; local main is the base
  new_repo "$1/work" main
  write_index "$1/work" D034:D034-first.md D035:D035-a.md
  printf '# D035: Decision\n' >"$1/work/docs/decisions/D035-b.md"
  commit_all "$1/work" base
}

run_row() { # SCRIPT FIXTURE ENV ACTION [ARG] — ENV is VAR=VALUE words or empty
  local script="$1" fixture="$2" row_env="$3" action="$4" arg="${5:-}" world build_rc
  local env_args=()
  if [[ -n "$row_env" ]]; then
    read -r -a env_args <<<"$row_env"
  fi
  # mktemp, not a counter: a control runs its row inside a command
  # substitution, where a counter's increment never reaches the next row.
  if ! world="$(mktemp -d "$TMP_ROOT/world.XXXXXX")"; then
    rc=mktemp-failed
    out=""
    err=""
    return
  fi
  # The builder runs as a plain command in a subshell that sets errexit
  # itself: behind || or if, errexit is off inside it and a failed step would
  # hand the row a half-built world.
  set +e
  ( set -e; "build_$fixture" "$world" ) >/dev/null 2>&1
  build_rc=$?
  set -e
  if [[ "$build_rc" -ne 0 ]]; then
    rc="build-failed:$build_rc"
    out=""
    err=""
    return
  fi
  set +e
  out=$( (cd "$world/work" && env -u DECISIONS_DIR -u DECISION_ID_PREFIX -u DECISION_ID_WIDTH -u DECISIONS_BASE_REF \
    DECISIONS_DIR=docs/decisions ${env_args[@]+"${env_args[@]}"} "$script" "$action" ${arg:+"$arg"}) 2>"$ERR_FILE")
  rc=$?
  set -e
  err="$(<"$ERR_FILE")"
}

record_row() {
  local mode="$1" name="$2" actual="$3" expected="$4"
  if [[ "$actual" == "$expected" ]]; then
    if [[ "$mode" == normal ]]; then
      pass "$name"
    fi
  else
    if [[ "$mode" == normal ]]; then
      fail "$name (expected: $expected; got: $actual)"
    else
      table_failures+="|$name|"
    fi
  fi
}

# Columns: name, fixture, environment, action, argument, exit status, stdout,
# and every error= and notice= record's first line on stderr, in order, joined
# by ';'. A stdout of @get-keys@ compares the key set get answers with; an
# empty records column means no record was printed.
evaluate_rows() {
  local script="$1" mode="$2" only_row="${3:-}" name fixture row_env action arg expected_rc expected_stdout expected_records
  local actual_stdout records line executed_rows=0 guard
  table_failures=""
  while IFS='~' read -r name fixture row_env action arg expected_rc expected_stdout expected_records; do
    if [[ -n "$only_row" && "$name" != "$only_row" ]]; then
      continue
    fi
    executed_rows=$((executed_rows + 1))
    run_row "$script" "$fixture" "$row_env" "$action" "$arg"
    actual_stdout="$out"
    if [[ "$expected_stdout" == @get-keys@ ]]; then
      actual_stdout="$(jq -c 'keys' <<<"$out" 2>/dev/null)" || actual_stdout="unparsed: $out"
      expected_stdout='["date","decision","id","path","rationale","research","status"]'
    fi
    records=""
    while IFS= read -r line; do
      case "$line" in
        error=* | notice=*) records="${records:+$records;}$line" ;;
      esac
    done <<<"$err"
    record_row "$mode" "$name" "$rc~$actual_stdout~$records" "$expected_rc~$expected_stdout~$expected_records"
  done <<'BASE_CASES'
next-id-base-ahead~ahead~~next-id~~0~D036~
next-id-base-behind~behind~~next-id~~0~D036~
next-id-no-remote~no_remote~~next-id~~0~D035~notice=base-unverified ref=origin/HEAD,origin/main,main reason=unresolved
next-id-fetch-failed~unreachable~~next-id~~0~D036~notice=base-unverified ref=origin/main reason=fetch-failed
next-id-fetch-failed-local-main~stale_main~~next-id~~0~D035~notice=base-unverified ref=main reason=fetch-failed
next-id-origin-head~origin_head~~next-id~~0~D036~
next-id-configured-origin-head~ahead~DECISIONS_BASE_REF=origin/HEAD~next-id~~0~D036~
check-renamed-default~renamed_default~~check~~1~~error=id-collision id=D002 path=docs/decisions/D002-z.md base=origin/trunk:docs/decisions/D002-b.md
check-stale-remote-branch~renamed_default~DECISIONS_BASE_REF=origin/master~check~~1~~error=base-unverified ref=origin/master reason=unresolved
next-id-configured-ref~configured_ref~DECISIONS_BASE_REF=origin/release~next-id~~0~D036~
next-id-local-ref~local_ref~DECISIONS_BASE_REF=base~next-id~~0~D036~
next-id-empty-index-base-scheme~empty_base_scheme~~next-id~~0~ADR-0036~
next-id-configured-prefix-base-width~prefix_base_width~DECISION_ID_PREFIX=ADR-~next-id~~0~ADR-0036~
next-id-index-absent~index_absent~~next-id~~0~D002~notice=base-unverified ref=origin/main reason=index-absent
check-collision~collision~~check~~1~~error=id-collision id=D035 path=docs/decisions/D035-lane.md base=origin/main:docs/decisions/D035-main.md
check-edited-record~edited~~check~~0~~
check-duplicate-row~dup_rows~~check~~1~~error=id-duplicate-row id=D035 rows=4,5 paths=docs/decisions/D035-a.md,docs/decisions/D035-b.md;error=id-duplicate-file id=D035 paths=docs/decisions/D035-a.md,docs/decisions/D035-b.md
check-duplicate-file~dup_files~~check~~1~~error=id-duplicate-file id=D035 paths=docs/decisions/D035-a.md,docs/decisions/D035-b.md
check-unresolved~no_remote~~check~~1~~error=base-unverified ref=origin/HEAD,origin/main,main reason=unresolved
check-configured-unresolved~collision~DECISIONS_BASE_REF=origin/mian~check~~1~~error=base-unverified ref=origin/mian reason=unresolved
check-fetch-failed~unreachable_collision~~check~~1~~error=base-unverified ref=origin/main reason=fetch-failed;error=id-collision id=D035 path=docs/decisions/D035-lane.md base=origin/main:docs/decisions/D035-main.md
check-malformed-row~malformed_row~~check~~1~~error=index-row-invalid path=docs/decisions/INDEX.md line=4 cells=7
check-malformed-base-row~malformed_base_row~~check~~1~~error=index-row-invalid path=origin/main:docs/decisions/INDEX.md line=4 cells=7
check-fetch-failed-index-absent~first_index_offline~~check~~1~~error=base-unverified ref=origin/main reason=fetch-failed
check-index-absent~index_absent~~check~~0~~notice=base-unverified ref=origin/main reason=index-absent
check-not-a-repository~no_repo~~check~~0~~notice=base-unverified ref=none reason=not-a-repository
check-blob-missing~blob_missing~~check~~1~~error=base-unverified ref=origin/main reason=unreadable
get-ambiguous~dup_rows~~get~D035~1~~error=id-ambiguous id=D035 rows=4,5 paths=docs/decisions/D035-a.md,docs/decisions/D035-b.md
get-unique~dup_rows~~get~D034~0~@get-keys@~
BASE_CASES
  if [[ "$executed_rows" -eq 0 ]]; then
    guard="base table executed no rows"
    [[ -n "$only_row" ]] && guard="base table selected no row: $only_row"
    if [[ "$mode" == normal ]]; then
      fail "$guard"
      return 1
    else
      printf 'TABLE_GUARD:%s' "$guard"
      return 1
    fi
  fi
  if [[ "$mode" == control ]]; then
    printf '%s' "$table_failures"
  fi
}

echo "=== decision IDs against the base branch ==="
evaluate_rows "$DECISIONS" normal

echo "=== must-fail controls ==="
# Each control plants one defect in a copy of the script and names the row it
# must turn red. Columns: row, text to replace, its replacement, what the
# defect removes. A \n in either text is a newline.
control_seq=0
while IFS='~' read -r row old new label; do
  control_seq=$((control_seq + 1))
  printf -v old '%b' "$old"
  printf -v new '%b' "$new"
  if ! mutant="$(decider_mutate_script "$DECISIONS" "$TMP_ROOT/control-$control_seq/decisions" "$old" "$new" 1)"; then
    fail "control $label could not be planted"
    continue
  fi
  set +e
  failures="$(evaluate_rows "$mutant" control "$row")"
  set -e
  if [[ "$failures" == *"|$row|"* ]]; then
    pass "$label fails $row"
  else
    fail "$label did not fail $row"
  fi
done <<'CONTROLS'
next-id-base-ahead~  for id in ${ids[@]+"${ids[@]}"} ${base_ids[@]+"${base_ids[@]}"}; do~  for id in ${ids[@]+"${ids[@]}"}; do~a maximum over the working tree alone
next-id-base-ahead~      if ! GIT_TERMINAL_PROMPT=0 git~      if false && ! GIT_TERMINAL_PROMPT=0 git~a base read without a fetch
next-id-no-remote~  emit_notice base-unverified "ref=~  emit_notice base-unread "ref=~a renamed base notice
next-id-fetch-failed~        fetch_failed=1\n        if [[ "$branch" == HEAD ]]; then~        fetch_failed=1; return 0\n        if [[ "$branch" == HEAD ]]; then~a failed fetch that drops the local copy
next-id-fetch-failed-local-main~    short="${cand#refs/remotes/}"~    fetch_failed=0; short="${cand#refs/remotes/}"~a fetch failure forgotten by the next candidate
next-id-origin-head~    candidates=(origin/HEAD origin/main main)~    candidates=(origin/main main)~a default ladder without origin/HEAD
next-id-configured-origin-head~|| found="${line#ref: refs/heads/}"~|| found=""~a remote HEAD that is never resolved to its branch
check-renamed-default~|| found="${line#ref: refs/heads/}"~|| found=""~a remote HEAD that is never resolved to its branch
check-stale-remote-branch~        [[ -n "$found" ]] || continue~        [[ -n "$found" ]] || found="$branch"~a branch the remote lacks read from its stale local ref
next-id-configured-ref~    candidates=("$DECISIONS_BASE_REF")~    candidates=(origin/main main)~a configured base ref that is ignored
next-id-local-ref~    candidates=("$DECISIONS_BASE_REF")~    candidates=(origin/main main)~a configured local base branch that is ignored
next-id-empty-index-base-scheme~    elif [[ "${#base_ids[@]}" -gt 0 ]]; then~    elif false; then~a scheme inferred from the working tree alone
next-id-configured-prefix-base-width~    for id in ${base_ids[@]+"${base_ids[@]}"} ${ids[@]+"${ids[@]}"}; do~    for id in ${ids[@]+"${ids[@]}"}; do~a configured prefix whose width ignores the base
next-id-index-absent~    BASE_REASON=index-absent~    BASE_REASON=""~a base without INDEX.md reported as read
check-collision~select(($held | length) > 0 and~select(($held | length) > 99 and~a collision rule that never fires
check-edited-record~($held | map(.link) | index($row.link)) == null~true~a collision rule blind to record identity
check-duplicate-row~map(select(length > 1))~map(select(length > 99))~a duplicate-row rule that never fires
check-duplicate-file~file_count=$((file_count + 1))~file_count=$((file_count + 0))~a duplicate-file rule that never counts
check-unresolved~    unresolved) refuse=1;~    unresolved) refuse=0;~an unresolved base that check passes
check-fetch-failed-index-absent~    [[ "$fetch_failed" -eq 0 ]] || BASE_REASON=fetch-failed~    :~a stale copy's missing INDEX.md taken as the base's
check-index-absent~    index-absent) text=~    index-absent) refuse=1; text=~a base without INDEX.md that check refuses
check-fetch-failed~    fetch-failed) refuse=1; text=~    fetch-failed) text=~a stale base copy that check passes
check-malformed-row~  ROW_INVALID_KIND=error~  ROW_INVALID_KIND=notice~a skipped working-tree row that check passes
check-malformed-base-row~|| BASE_ROWS_SKIPPED=1~|| BASE_ROWS_SKIPPED=0~a skipped base row that check passes
check-not-a-repository~    not-a-repository) text=~    not-a-repository) refuse=1; text=~a directory outside a repository that check refuses
check-configured-unresolved~  if [[ -n "${DECISIONS_BASE_REF:-}" ]]; then~  if false; then~a configured base ref that is ignored
check-blob-missing~rev-parse --verify --quiet "$BASE_REF:$BASE_PATH"~cat-file -e "$BASE_REF:$BASE_PATH"~a presence test that needs the blob
get-ambiguous~  if [[ "$count" -gt 1 ]]; then~  if [[ "$count" -gt 99 ]]; then~a get that answers with the first of several rows
get-unique~del(.line, .link)~del(.line)~a get that leaks the parser's link field
CONTROLS
if [[ "$control_seq" -eq 0 ]]; then
  fail "the control table planted no defect"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
