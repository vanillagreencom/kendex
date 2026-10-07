#!/usr/bin/env bash
# The one reading of a linked worktree's `.git` file. Git writes
# `gitdir: <clone>/.git/worktrees/<name>` there, and a caller holding that
# file's bytes composes paths on the directory it names: the hosted mail read
# resolves the clone from it, and a hosted launch writes its lane marker under
# the common git directory it names and its refresh record in the worktree git
# directory it names. Both would otherwise spell the same
# shape, and a lane whose marker lands anywhere else is handed no mail at all.

LANE_GITFILE_LIB="$(dirname -- "${BASH_SOURCE[0]}")"
source "$LANE_GITFILE_LIB/lane-host-slots.sh"
source "$LANE_GITFILE_LIB/lane-capabilities.sh"

# Print the absolute worktree git directory a worktree's `.git` file names.
# Returns 1 on any other content, including a `.git` directory's own bytes and
# a relative gitdir, neither of which names a path a remote caller can use.
lane_gitfile_git_dir() { # GITFILE_CONTENT
  case "$1" in
    "gitdir: /"*/.git/worktrees/*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "${1#gitdir: }"
}

# Print the absolute common git directory that file names, under the same rule.
lane_gitfile_common_dir() { # GITFILE_CONTENT
  local dir
  dir="$(lane_gitfile_git_dir "$1")" || return 1
  printf '%s\n' "${dir%/worktrees/*}"
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

# lane_hosted_state_dir LANE_HOST_CLI ITEM ROOT SCRATCH — sets
# LANE_HOSTED_STATE_DIR to the state directory the hosted lane at ROOT
# resolves for itself, as workflow-state resolves it there: ORCH_STATE_DIR
# from ROOT's kendex.settings.toml, then .kendex/settings.toml, the later
# winning, else tmp. A hosted launch sets no ORCH_STATE_DIR, and the caller's
# own names a directory on the caller's machine, never the lane's. Each file
# is read as data, in a subshell, as `workflow-state --no-private-env` reads
# another checkout's. 0 read; 2 a read failed or a file did not parse,
# SCRATCH/state.err saying why; 4 lane-host refused a call at its cap.
LANE_HOSTED_STATE_DIR=""
lane_hosted_state_dir() {
  local file setting rc
  LANE_HOSTED_STATE_DIR=tmp
  for file in kendex.settings.toml .kendex/settings.toml; do
    rc=0
    lane_host_fetch "$1" "$2" "$3/$file" "$4/settings.toml" "$4/state.err" || rc=$?
    case "$rc" in 0) ;; 1) continue ;; *) return "$rc" ;; esac
    if ! setting="$(
      source "$LANE_GITFILE_LIB/kendex-env.sh" || exit 1
      unset ORCH_STATE_DIR
      kendex_load_settings_file "$4/settings.toml" || exit 1
      [[ -z "${ORCH_STATE_DIR+set}" ]] || printf '=%s' "$ORCH_STATE_DIR"
    )" 2>"$4/state.err"; then
      printf 'settings-unread path=%s\n' "$3/$file" >>"$4/state.err"
      return 2
    fi
    [[ -z "$setting" ]] || LANE_HOSTED_STATE_DIR="${setting#=}"
  done
}

# lane_archived_state ITEM ARCHIVE SCRATCH — sets LANE_ITEM_STATE to the
# item's workflow state in ARCHIVE, the `kept=` archive lane-host close wrote
# of the clone's and the worktree's tmp, empty where it holds none. 0 read;
# 2 the archive did not read, SCRATCH/state.err saying why.
lane_archived_state() {
  local member
  LANE_ITEM_STATE=""
  [[ -f "$2" ]] || { printf 'archive-missing path=%s\n' "$2" >"$3/state.err"; return 2; }
  member="$(tar -tzf "$2" 2>"$3/state.err" \
    | awk -v f="workflow-state-$1.json" '{ n = split($0, p, "/") } !seen && p[n] == f { print; seen = 1 }')" || return 2
  [[ -n "$member" ]] || return 0
  LANE_ITEM_STATE="$(tar -xzOf "$2" "$member" 2>"$3/state.err" | jq -c . 2>>"$3/state.err")" \
    || { LANE_ITEM_STATE=""; return 2; }
}

# lane_item_state WORKFLOW_STATE LANE_HOST_CLI STATE_DIR ITEM HOST ROOT SCRATCH [ARCHIVE]
# — sets LANE_ITEM_STATE to the item's own workflow-state JSON, empty where
# the lane has written none. A local lane's, HOST empty, is under the project
# state directory of its own checkout, ROOT, where ROOT is a directory, so a
# lane of another repository reads from that repository, and of the caller's
# checkout where ROOT is gone or unrecorded; a hosted lane's is in the state
# directory lane_hosted_state_dir reads for ROOT, joined to its clone, read
# through the probe above with ORCH_LANE_HOST set to HOST; STATE_DIR is the
# local lane's alone. ARCHIVE, where given, is the `kept=` archive of a
# hosted lane whose sandbox is gone: a hosted read that finds no state, or
# fails, reads the state there instead. A hosted worktree
# already gone, which ../../workflows/merge-pr.md § 5 leaves behind a merged
# lane until lane-close runs, has no state either, and nor has a lane whose
# host kind declares files=none, a Claude cloud session, which keeps none this
# machine can read. 0 read, the state possibly
# empty; 2 the read failed, SCRATCH/state.err saying why; 4 lane-host refused
# the provider call at its per-home cap (lane-host-busy), SCRATCH/state.err
# carrying its line.
LANE_ITEM_STATE=""
lane_item_state() {
  local path files rc=0
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
  lane_capabilities_read "$2" "$5" 2>"$7/state.err" || return 2
  lane_capability files files
  [[ "$files" != none ]] || return 0
  ORCH_LANE_HOST="$5" lane_hosted_item_state "$2" "$4" "$6" "$7" || rc=$?
  [[ -z "$LANE_ITEM_STATE" && -n "${8:-}" ]] || return "$rc"
  lane_archived_state "$4" "$8" "$7"
}

# lane_hosted_item_state LANE_HOST_CLI ITEM ROOT SCRATCH — lane_item_state's
# live read of a hosted lane, under the caller's ORCH_LANE_HOST, with its
# statuses.
lane_hosted_item_state() {
  local rc=0
  lane_hosted_clone "$1" "$2" "$3" "$4/gitfile" "$4/state.err" || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    3) printf '%s\n' "$3/.git: ${LANE_HOSTED_GITLINE:-<empty>}" >"$4/state.err"; return 2 ;;
    *) return "$rc" ;;
  esac
  lane_hosted_state_dir "$1" "$2" "$3" "$4" || return $?
  lane_hosted_state_path "$LANE_HOSTED_CLONE" "$LANE_HOSTED_STATE_DIR" "$2"
  lane_host_fetch "$1" "$2" "$LANE_HOSTED_STATE_PATH" "$4/item-state.json" "$4/state.err" || rc=$?
  case "$rc" in
    0) LANE_ITEM_STATE="$(jq -c . -- "$4/item-state.json" 2>"$4/state.err")" || return 2 ;;
    1) ;;
    *) return "$rc" ;;
  esac
}
