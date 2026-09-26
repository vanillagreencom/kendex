#!/usr/bin/env bash
# The one reading of a linked worktree's `.git` file. Git writes
# `gitdir: <clone>/.git/worktrees/<name>` there, and a caller holding that
# file's bytes composes paths on the directory it names: the hosted mail read
# resolves the clone from it, and a hosted launch writes its lane marker under
# the common git directory it names. Both would otherwise spell the same
# shape, and a lane whose marker lands anywhere else is handed no mail at all.

source "$(dirname -- "${BASH_SOURCE[0]}")/lane-host-slots.sh"

# Print the absolute common git directory a worktree's `.git` file names.
# Returns 1 on any other content, including a `.git` directory's own bytes and
# a relative gitdir, neither of which names a path a remote caller can use.
lane_gitfile_common_dir() { # GITFILE_CONTENT
  local line="$1"
  case "$line" in
    "gitdir: /"*/.git/worktrees/*) ;;
    *) return 1 ;;
  esac
  line="${line#gitdir: }"
  printf '%s\n' "${line%/worktrees/*}"
}

# ---------------------------------------------------------------------------
# A hosted lane's files, read through lane-host: the probe oversee-watch and
# oversee-report read a hosted worktree's `.git` and its item's workflow state
# through, so both answer a gone worktree the same way. Each takes the
# lane-host CLI path. ORCH_LANE_HOST is the caller's to set: oversee-report
# puts the lane record's host in front of each call, and oversee-watch runs
# under the ambient setting.
# ---------------------------------------------------------------------------

# lane_host_fetch LANE_HOST_CLI ITEM PATH DEST ERRF — `lane-host cat --item
# ITEM PATH` into DEST: 0 read, 1 not there, 2 failed, 4 lane-host refused the
# call at its per-home cap, which says nothing about the host. Exit 2 is also
# the dispatcher's own refusal, so it reads as a missing file only once `touch`
# answers (schemas/lane-host.md). A failed read leaves no DEST; ERRF holds
# what lane-host said.
lane_host_fetch() {
  local rc=0
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
# ../../workflows/merge-pr.md § 5 leaves behind a merged lane until lane-close
# runs; 2 the read failed, ERRF saying why; 3 the file names no linked
# worktree, LANE_HOSTED_GITLINE holding the line it read, empty for an empty
# file; 4 lane-host refused a call at its per-home cap. A root that is itself
# a clone has a `.git` directory, which `cat` fails on and whose HEAD answers:
# the clone is the root, with no `.git` appended, and ERRF keeps the `.git`
# read's own words where HEAD does not answer either.
LANE_HOSTED_CLONE=""
LANE_HOSTED_GITLINE=""
lane_hosted_clone() {
  local rc=0 common err
  LANE_HOSTED_CLONE=""
  LANE_HOSTED_GITLINE=""
  lane_host_fetch "$1" "$2" "$3/.git" "$4" "$5" || rc=$?
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
  IFS= read -r LANE_HOSTED_GITLINE <"$4" || [[ -n "$LANE_HOSTED_GITLINE" ]] || return 3
  common="$(lane_gitfile_common_dir "$LANE_HOSTED_GITLINE")" || return 3
  LANE_HOSTED_CLONE="${common%/.git}"
}

# lane_hosted_state_path CLONE STATE_DIR ITEM — sets LANE_HOSTED_STATE_PATH to
# the item's workflow-state file on its host: STATE_DIR joined to the clone
# root where it is relative, as workflow-state joins it there.
LANE_HOSTED_STATE_PATH=""
lane_hosted_state_path() {
  local remote="$2"
  [[ "$remote" == /* ]] || remote="$1/$remote"
  LANE_HOSTED_STATE_PATH="$remote/workflow-state-$3.json"
}

# lane_item_state WORKFLOW_STATE LANE_HOST_CLI STATE_DIR ITEM HOST ROOT SCRATCH
# — sets LANE_ITEM_STATE to the item's own workflow-state JSON, empty where
# the lane has written none. A local lane's, HOST empty, is under the project
# state directory of its own checkout, ROOT, where ROOT is a directory, so a
# lane of another repository reads from that repository, and of the caller's
# checkout where ROOT is gone or unrecorded; a hosted lane's is in its clone
# at ROOT, read
# through the probe above with ORCH_LANE_HOST set to HOST. A hosted worktree
# already gone, which ../../workflows/merge-pr.md § 5 leaves behind a merged
# lane until lane-close runs, has no state either. 0 read, the state possibly
# empty; 2 the read failed, SCRATCH/state.err saying why; 4 lane-host refused
# the provider call at its per-home cap (lane-host-busy), SCRATCH/state.err
# carrying its line.
LANE_ITEM_STATE=""
lane_item_state() {
  local path rc=0
  LANE_ITEM_STATE=""
  if [[ -z "$5" ]]; then
    if [[ -n "$6" && -d "$6" ]]; then
      path="$(cd -- "$6" && "$1" path "$4" 2>"$7/state.err")" || return 2
    else
      path="$("$1" path "$4" 2>"$7/state.err")" || return 2
    fi
    [[ -f "$path" ]] || return 0
    LANE_ITEM_STATE="$(jq -c . -- "$path" 2>"$7/state.err")" || return 2
    return 0
  fi
  ORCH_LANE_HOST="$5" lane_hosted_clone "$2" "$4" "$6" "$7/gitfile" "$7/state.err" || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    3) printf '%s\n' "$6/.git: ${LANE_HOSTED_GITLINE:-<empty>}" >"$7/state.err"; return 2 ;;
    4) return 4 ;;
    *) return 2 ;;
  esac
  lane_hosted_state_path "$LANE_HOSTED_CLONE" "$3" "$4"
  ORCH_LANE_HOST="$5" lane_host_fetch "$2" "$4" "$LANE_HOSTED_STATE_PATH" \
    "$7/item-state.json" "$7/state.err" || rc=$?
  case "$rc" in
    0) LANE_ITEM_STATE="$(jq -c . -- "$7/item-state.json" 2>"$7/state.err")" || return 2 ;;
    1) ;;
    4) return 4 ;;
    *) return 2 ;;
  esac
}
