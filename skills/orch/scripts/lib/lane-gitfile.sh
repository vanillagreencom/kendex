#!/usr/bin/env bash
# The one reading of a linked worktree's `.git` file. Git writes
# `gitdir: <clone>/.git/worktrees/<name>` there, and a caller holding that
# file's bytes composes paths on the directory it names: `oversee-report`'s
# hosted item-state read (`lane_hosted_clone`) resolves the clone from the
# common git directory it names.

LANE_GITFILE_LIB="$(dirname -- "${BASH_SOURCE[0]}")"
source "$LANE_GITFILE_LIB/lane-host-slots.sh"
source "$LANE_GITFILE_LIB/lane-capabilities.sh"

# Print the absolute worktree git directory a worktree's `.git` file names.
# Returns 1 on any other content, including a `.git` directory's own bytes and
# a relative gitdir, neither of which names a path a remote caller can use.
LANE_GITFILE_DIR=""
lane_gitfile_git_dir() { # GITFILE_CONTENT
  LANE_GITFILE_DIR=""
  case "$1" in
    "gitdir: /"*/.git/worktrees/*) ;;
    *) return 1 ;;
  esac
  LANE_GITFILE_DIR="${1#gitdir: }"
  printf '%s\n' "$LANE_GITFILE_DIR"
}

# Print the absolute common git directory that file names, under the same rule.
LANE_GITFILE_COMMON=""
lane_gitfile_common_dir() { # GITFILE_CONTENT
  LANE_GITFILE_COMMON=""
  lane_gitfile_git_dir "$1" >/dev/null || return 1
  LANE_GITFILE_COMMON="${LANE_GITFILE_DIR%/worktrees/*}"
  printf '%s\n' "$LANE_GITFILE_COMMON"
}

# ---------------------------------------------------------------------------
# A hosted lane's files, read through lane-host: the probe oversee-report
# reads a hosted worktree's `.git` and its item's workflow state through, so
# each read answers a gone worktree the same way. Each takes the lane-host
# CLI path. ORCH_LANE_HOST is the caller's to set: oversee-report puts the
# lane record's host in front of each call.
# ---------------------------------------------------------------------------

# lane_host_fetch LANE_HOST_CLI ITEM PATH DEST ERRF: read PATH into DEST from
# the cached batch reply, or through `lane-host cat --item ITEM PATH` for a
# single read. Returns 0 read, 1 not there, 2 failed, 4 dispatcher cap refusal.
# An empty LANE_HOST_CLI reads local files with the same result statuses.
# Cached missing-file rows need no probe. A single-read exit 2 can also be a
# dispatcher refusal, so only a successful `touch` confirms absence
# (schemas/lane-host.md). A failed read leaves no DEST; ERRF holds the cause.
lane_host_fetch() {
  local rc=0
  if [[ -z "$1" ]]; then
    [[ -e "$3" || -L "$3" ]] || { rm -f -- "$4"; return 1; }
    if ! cat -- "$3" >"$4" 2>"$5"; then
      rm -f -- "$4"
      return 2
    fi
    return 0
  fi
  if [[ -n "${LANE_HOST_READ_DIR:-}" ]]; then
    source "$LANE_GITFILE_LIB/lane-host-read.sh" || return 2
    lane_host_cached_read "$LANE_HOST_READ_DIR" "$2" "$3" "$4" "$5" || rc=$?
    [[ "$rc" -ne 0 ]] || return 0
    rm -f -- "${4:?}"
    case "$rc" in
      2) return 1 ;;
      "$LANE_HOST_BUSY_EXIT") return 4 ;;
      *) return 2 ;;
    esac
  fi
  "$1" cat --item "$2" "$3" >"$4" 2>"$5" || rc=$?
  [[ "$rc" -ne 0 ]] || return 0
  rm -f -- "$4"
  [[ "$rc" -ne "$LANE_HOST_BUSY_EXIT" ]] || return 4
  [[ "$rc" -eq 2 ]] || return 2
  rc=0
  "$1" touch --item "$2" >/dev/null 2>>"$5" || rc=$?
  [[ "$rc" -ne "$LANE_HOST_BUSY_EXIT" ]] || return 4
  [[ "$rc" -eq 0 ]] || return 2
  return 1
}

# lane_hosted_clone LANE_HOST_CLI ITEM ROOT SCRATCH ERRF — the clone a hosted
# worktree at ROOT belongs to, read from its `.git` into SCRATCH, as
# LANE_HOSTED_CLONE. 0 read; 1 the worktree is gone, which
# ../../workflows/merge-pr.md § 5 leaves behind a merged lane until its close
# runs; 2 the read failed, ERRF saying why; 3 the file names no linked
# worktree, LANE_HOSTED_GITLINE holding the line it read, empty for an empty
# file; 4 lane-host refused a call at its per-home cap. A root that is itself
# a clone has a `.git` directory, which `cat` fails on and whose HEAD answers:
# the clone is the root, with no `.git` appended, and ERRF keeps the `.git`
# read's own words where HEAD does not answer either.
LANE_HOSTED_CLONE=""
LANE_HOSTED_GITLINE=""
lane_hosted_clone() {
  local rc=0 err gitfile="$4"
  LANE_HOSTED_CLONE=""
  LANE_HOSTED_GITLINE=""
  if [[ -n "${LANE_HOST_READ_DIR:-}" && -n "$1" ]]; then
    source "$LANE_GITFILE_LIB/lane-host-read.sh" || return 2
    lane_host_cached_path "$LANE_HOST_READ_DIR" "$2" "$3/.git" "$5" || rc=$?
    case "$rc" in
      0) gitfile="$LANE_HOST_READ_FILE" ;;
      2) rc=1 ;;
      "$LANE_HOST_BUSY_EXIT") rc=4 ;;
      *) rc=2 ;;
    esac
  else
    lane_host_fetch "$1" "$2" "$3/.git" "$4" "$5" || rc=$?
  fi
  if [[ "$rc" -eq 2 ]]; then
    err="$(cat "$5")"
    rc=0
    lane_host_fetch "$1" "$2" "$3/.git/HEAD" "$4.head" "$5" || rc=$?
    case "$rc" in
      0) LANE_HOSTED_CLONE="$3"; return 0 ;;
      4) return 4 ;;
    esac
    rc=2
    printf '%s\n' "$err" >"$5"
  fi
  [[ "$rc" -eq 0 ]] || return "$rc"
  IFS= read -r LANE_HOSTED_GITLINE <"$gitfile" || [[ -n "$LANE_HOSTED_GITLINE" ]] || return 3
  lane_gitfile_common_dir "$LANE_HOSTED_GITLINE" >/dev/null || return 3
  LANE_HOSTED_CLONE="${LANE_GITFILE_COMMON%/.git}"
}

# lane_hosted_state_path CLONE STATE_DIR STATE_KEY: sets LANE_HOSTED_STATE_PATH to
# the workflow-state file on its host: STATE_DIR joined to the clone
# root where it is relative, the clone being the lane's main checkout.
LANE_HOSTED_STATE_PATH=""
lane_hosted_state_path() {
  local remote="$2"
  [[ "$remote" == /* ]] || remote="$1/$remote"
  LANE_HOSTED_STATE_PATH="$remote/workflow-state-$3.json"
}

# lane_hosted_state_dir LANE_HOST_CLI ITEM ROOT SCRATCH — sets
# LANE_HOSTED_STATE_DIR to an older hosted launch's state directory at ROOT,
# where its state is absent from the worktree's tmp, where the launch puts it: ORCH_STATE_DIR
# from ROOT's kendex.settings.toml, then .kendex/settings.toml, then its
# private env file, .env.local unless those name another as KENDEX_ENV_FILE,
# the later winning, else tmp. The caller's ORCH_STATE_DIR names a directory
# on the caller's machine, never the lane's.
# Each settings file is read as data, in a subshell, as a reader of another
# checkout's settings reads them. The private env file is shell
# the lane sources and this machine never runs, so only a literal
# `ORCH_STATE_DIR=VALUE`, `export` before it allowed, is read from it; any
# other line naming the key leaves the directory unread. An empty LANE_HOST_CLI
# selects local files through lane_host_fetch. 0 read; 2 a read failed or a file
# did not parse, SCRATCH/state.err saying why; 4 lane-host refused a call at its cap.
LANE_HOSTED_STATE_DIR=""
LANE_PRIVATE_STATE_RE='^[[:space:]]*(export[[:space:]]+)?ORCH_STATE_DIR=("[^"$`\\]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]"'"'"'$`\&<>();|]*)[[:space:]]*$'
lane_hosted_state_dir() {
  local file setting line value private=.env.local rc
  LANE_HOSTED_STATE_DIR=tmp
  for file in kendex.settings.toml .kendex/settings.toml; do
    rc=0
    lane_host_fetch "$1" "$2" "$3/$file" "$4/settings.toml" "$4/state.err" || rc=$?
    case "$rc" in 0) ;; 1) continue ;; *) return "$rc" ;; esac
    if ! setting="$(
      source "$LANE_GITFILE_LIB/kendex-env.sh" || exit 1
      unset ORCH_STATE_DIR KENDEX_ENV_FILE
      kendex_load_settings_file "$4/settings.toml" -- ORCH_STATE_DIR KENDEX_ENV_FILE || exit 1
      [[ -z "${ORCH_STATE_DIR+set}" ]] || printf 's=%s\n' "$ORCH_STATE_DIR"
      [[ -z "${KENDEX_ENV_FILE+set}" ]] || printf 'e=%s\n' "$KENDEX_ENV_FILE"
    )" 2>"$4/state.err"; then
      printf 'settings-unread path=%s\n' "$3/$file" >>"$4/state.err"
      return 2
    fi
    while IFS= read -r line; do
      case "$line" in
        s=*) LANE_HOSTED_STATE_DIR="${line#s=}" ;;
        e=*) private="${line#e=}" ;;
      esac
    done <<<"$setting"
  done
  private="${private:-.env.local}"
  case "$private" in
    /* | *:* | *\\* | .. | ../* | */../* | */..)
      printf 'private-env-path path=%s\n' "$private" >"$4/state.err"; return 2 ;;
  esac
  rc=0
  lane_host_fetch "$1" "$2" "$3/$private" "$4/private.env" "$4/state.err" || rc=$?
  case "$rc" in 0) ;; 1) private="" ;; *) return "$rc" ;; esac
  if [[ -n "$private" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in *ORCH_STATE_DIR*) ;; *) continue ;; esac
      [[ ! "$line" =~ ^[[:space:]]*# ]] || continue
      if [[ ! "$line" =~ $LANE_PRIVATE_STATE_RE ]]; then
        printf 'private-env-unread path=%s key=ORCH_STATE_DIR\n' "$3/$private" >"$4/state.err"
        return 2
      fi
      value="${BASH_REMATCH[2]}"
      case "$value" in \"*\" | \'*\') value="${value:1:${#value}-2}" ;; esac
      LANE_HOSTED_STATE_DIR="$value"
    done <"$4/private.env"
  fi
  # An empty setting is tmp, as every reader of the setting reads it.
  LANE_HOSTED_STATE_DIR="${LANE_HOSTED_STATE_DIR:-tmp}"
}

# The fix writers append one patched_causes entry per finding. Distinct
# commits distinguish patch rounds; several findings in one commit do not.
# No class history can establish rounds that raised a cause but patched none.
lane_state_rounds() { # STATE_JSON [ERRF] [VALIDATION_RUNS]
  local counts
  LANE_FINDING_OCCURRENCES='{"prior":"unknown","classes":[]}'
  LANE_REVIEW_ROUNDS=unread
  LANE_FIX_RECEIPTS=unread
  LANE_VALIDATION_RUNS=unread
  LANE_RESTACKS=unread
  LANE_REPEATED_CLASS_ROUNDS=unread
  [[ -n "$1" ]] || return 0
  LANE_FINDING_OCCURRENCES="$(jq -c -L "$LANE_GITFILE_LIB" 'include "cause-keys"; finding_summary(null)' <<<"$1" 2>"${2:-/dev/stderr}")" || return 2
  if ! counts="$(jq -L "$LANE_GITFILE_LIB" --arg validations "${3:-unread}" -r '
    include "cause-keys";
    ((if .first_panel then 1 else 0 end) + (.rereview_cycles // 0) + (.pr_comment_review.iterations // 0)) as $rounds
    | (if .stages == null then "unread" else [.stages[] | select(.kind == "fix")] | length end) as $fixes
    | (.restacks // 0) as $restacks
    | (.pr_comment_review.patched_causes // []) as $patches
    | (reduce $patches[] as $patch ({seen: [], repeated: []};
        if any(.seen[]; .commit != $patch.commit and
            (.cause == $patch.cause or ([shared_cause_key(.; $patch)] | length > 0)))
          then .repeated += [$patch.commit] else . end
        | .seen += [$patch])) as $history
    | [$rounds, $fixes, ($validations | fromjson? // $validations), $restacks,
        (if ($patches | length) == 0 then "unread" else ($history.repeated | unique | length) end)] | @tsv
  ' <<<"$1" 2>"${2:-/dev/stderr}")"; then
    return 2
  fi
  IFS=$'\t' read -r LANE_REVIEW_ROUNDS LANE_FIX_RECEIPTS LANE_VALIDATION_RUNS LANE_RESTACKS LANE_REPEATED_CLASS_ROUNDS <<<"$counts"
}

# lane_item_state WORKFLOW_STATE LANE_HOST_CLI STATE_DIR ITEM HOST ROOT SCRATCH
# Sets LANE_ITEM_STATE to the item's own workflow-state JSON, empty where
# the lane has written none. A local lane's, HOST empty, is in the state
# directory of its own checkout, ROOT, where ROOT is a directory, so a lane
# of another repository reads from that repository, and of the caller's
# checkout where ROOT is gone or unrecorded (lane_local_state_path); a hosted
# lane's is in the state directory the launch uses, with
# lane_hosted_state_dir's older-launch fallback, read through the probe above
# with ORCH_LANE_HOST set to HOST. WORKFLOW_STATE and STATE_DIR are read by
# no branch. A lane whose host kind declares files=none, a Claude cloud
# session, keeps none this machine can read. 0 read, the state possibly
# empty; 2 the read failed, SCRATCH/state.err saying why; 4 lane-host refused
# the provider call at its per-home cap (lane-host-busy), SCRATCH/state.err
# carrying its line. LANE_ITEM_STATE_REASON names files=none hosts and absent
# state; absent state leaves keyed diagnostics and all paths tried in
# SCRATCH/state.err, while remaining an empty read.
LANE_ITEM_STATE=""
LANE_ITEM_VALIDATION_RUNS=unread

# The run owner publishes this inventory before reporting a start. Missing
# older inventories cannot establish zero runs. A failed index read leaves
# the other workflow-state counts available.
lane_item_validation_runs() { # LANE_HOST_CLI ITEM HOST ROOT SCRATCH
  local rc=0 count
  LANE_ITEM_VALIDATION_RUNS=unread
  [[ -n "$4" ]] || return 0
  ORCH_LANE_HOST="$3" lane_host_fetch "$1" "$2" "$4/tmp/validation-runs" \
    "$5/validation-runs" "$5/validation-runs.err" || rc=$?
  [[ "$rc" -eq 0 ]] || return 0
  count="$(jq -Rse '
    split("\n") as $rows
    | if $rows[0] == "dev-validate-runs-v1" and $rows[-1] == ""
        and all($rows[1:-1][]; test("^dev-validate-[A-Za-z0-9-]+$"))
        and ($rows[1:-1] | unique | length) == ($rows[1:-1] | length)
      then $rows[1:-1] | length else error("invalid-run-index") end
  ' "$5/validation-runs" 2>"$5/validation-runs.err")" || return 0
  LANE_ITEM_VALIDATION_RUNS="$count"
}
LANE_ITEM_STATE_TRIED=()
lane_item_state_absent() { # ITEM SCRATCH
  LANE_ITEM_STATE_REASON=state-absent
  printf 'lane-gitfile: state-unread item=%s cause=no-state\n' "$1" >"$2/state.err"
  lane_item_state_paths "$1" "$2"
}

lane_item_state_paths() { # ITEM SCRATCH
  local path
  for path in ${LANE_ITEM_STATE_TRIED[@]+"${LANE_ITEM_STATE_TRIED[@]}"}; do
    printf 'lane-gitfile: state-tried item=%s path=%s\n' "$1" "$path" >>"$2/state.err"
  done
}

# lane_local_state_path DIR ITEM SCRATCH: sets LANE_LOCAL_STATE_PATH to
# ITEM's workflow-state file for the checkout at DIR, read as data by the
# layout every reader resolves: ORCH_STATE_DIR as the caller's environment,
# then the checkout's settings and private env file, set it, else tmp, a
# relative value joined to the main checkout. The settings load in a child
# shell, which sees the caller's environment alone. 1 where they do not
# load, SCRATCH/state.err saying why.
LANE_LOCAL_STATE_PATH=""
lane_local_state_path() {
  local dir common
  LANE_LOCAL_STATE_PATH=""
  # shellcheck disable=SC2016
  dir="$("$BASH" -c 'set -euo pipefail
cd -- "$1"
. "$2"
kendex_load_project_env "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" -- ORCH_STATE_DIR
printf "%s\n" "${ORCH_STATE_DIR:-tmp}"' lane-gitfile "$1" "$LANE_GITFILE_LIB/kendex-env.sh" 2>"$3/state.err")" || return 1
  if [[ "$dir" != /* ]]; then
    common="$1"
    if git -C "$1" rev-parse --show-toplevel >/dev/null 2>&1; then
      common="$("$LANE_GITFILE_LIB/../git-context" common-root "$1" 2>"$3/state.err")" || return 1
    fi
    dir="$common/$dir"
  fi
  LANE_LOCAL_STATE_PATH="$dir/workflow-state-$2.json"
}

lane_item_state() {
  local root rc=0 files
  LANE_ITEM_STATE="" LANE_ITEM_STATE_REASON=""
  LANE_ITEM_VALIDATION_RUNS=unread
  LANE_ITEM_STATE_TRIED=()
  if [[ -z "$5" ]]; then
    lane_item_validation_runs "" "$4" "" "$6" "$7"
    root="$PWD"
    [[ -z "$6" || ! -d "$6" ]] || root="$6"
    lane_local_state_path "$root" "$4" "$7" || return 2
    LANE_ITEM_STATE_TRIED+=("$LANE_LOCAL_STATE_PATH")
    if [[ -f "$LANE_LOCAL_STATE_PATH" ]]; then
      LANE_ITEM_STATE="$(jq -c . -- "$LANE_LOCAL_STATE_PATH" 2>"$7/state.err")" || return 2
      return 0
    fi
    lane_item_state_absent "$4" "$7"
    return 0
  fi
  lane_capabilities_read "$2" "$5" 2>"$7/state.err" || return 2
  lane_capability files files
  if [[ "$files" == none ]]; then
    LANE_ITEM_STATE_REASON=files-none
    return 0
  fi
  lane_item_validation_runs "$2" "$4" "$5" "$6" "$7"
  ORCH_LANE_HOST="$5" lane_hosted_item_state "$2" "$4" "$6" "$7" || rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"
  [[ -n "$LANE_ITEM_STATE" ]] || lane_item_state_absent "$4" "$7"
}

# lane_hosted_item_state LANE_HOST_CLI ITEM ROOT SCRATCH: lane_item_state's
# live read of a hosted lane, under the caller's ORCH_LANE_HOST, with its
# statuses; LANE_HOSTED_GONE is 1 where the host answered that the worktree
# is gone.
LANE_HOSTED_GONE=0
lane_hosted_item_state() {
  local rc=0
  LANE_HOSTED_GONE=0
  LANE_ITEM_STATE_TRIED+=("$3/.git")
  lane_hosted_clone "$1" "$2" "$3" "$4/gitfile" "$4/state.err" || rc=$?
  case "$rc" in
    0) ;;
    1)
      LANE_HOSTED_GONE=1
      return 0 ;;
    3) printf '%s\n' "$3/.git: ${LANE_HOSTED_GITLINE:-<empty>}" >"$4/state.err"; return 2 ;;
    *) return "$rc" ;;
  esac
  lane_hosted_state_path "$LANE_HOSTED_CLONE" "$3/tmp" "$2"
  LANE_ITEM_STATE_TRIED+=("$LANE_HOSTED_STATE_PATH")
  rc=0
  lane_host_fetch "$1" "$2" "$LANE_HOSTED_STATE_PATH" "$4/item-state.json" "$4/state.err" || rc=$?
  case "$rc" in
    0) LANE_ITEM_STATE="$(jq -c . -- "$4/item-state.json" 2>"$4/state.err")" || return 2; return 0 ;;
    1) ;;
    *) return "$rc" ;;
  esac
  rc=0
  lane_hosted_state_dir "$1" "$2" "$3" "$4" || return $?
  lane_hosted_state_path "$LANE_HOSTED_CLONE" "$LANE_HOSTED_STATE_DIR" "$2"
  LANE_ITEM_STATE_TRIED+=("$LANE_HOSTED_STATE_PATH")
  lane_host_fetch "$1" "$2" "$LANE_HOSTED_STATE_PATH" "$4/item-state.json" "$4/state.err" || rc=$?
  case "$rc" in
    0) LANE_ITEM_STATE="$(jq -c . -- "$4/item-state.json" 2>"$4/state.err")" || return 2 ;;
    1) ;;
    *) return "$rc" ;;
  esac
}
