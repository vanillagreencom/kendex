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

# lane_hosted_state_path CLONE STATE_DIR STATE_KEY: sets LANE_HOSTED_STATE_PATH to
# the workflow-state file on its host: STATE_DIR joined to the clone
# root where it is relative, as workflow-state joins it there.
LANE_HOSTED_STATE_PATH=""
lane_hosted_state_path() {
  local remote="$2"
  [[ "$remote" == /* ]] || remote="$1/$remote"
  LANE_HOSTED_STATE_PATH="$remote/workflow-state-$3.json"
}

# lane_hosted_state_dir LANE_HOST_CLI ITEM ROOT SCRATCH — sets
# LANE_HOSTED_STATE_DIR to an older hosted launch's state directory at ROOT,
# where its state is absent at the location workflow-state --help names: ORCH_STATE_DIR
# from ROOT's kendex.settings.toml, then .kendex/settings.toml, then its
# private env file, .env.local unless those name another as KENDEX_ENV_FILE,
# the later winning, else tmp. The caller's ORCH_STATE_DIR names a directory
# on the caller's machine, never the lane's.
# Each settings file is read as data, in a subshell, as `workflow-state
# --no-private-env` reads another checkout's. The private env file is shell
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
      kendex_load_settings_file "$4/settings.toml" || exit 1
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
  # An empty setting is tmp, as workflow-state reads it.
  LANE_HOSTED_STATE_DIR="${LANE_HOSTED_STATE_DIR:-tmp}"
}

# lane_archived_state STATE_KEY ARCHIVE SCRATCH ROOT [SAVED_KEY]: sets
# LANE_ITEM_STATE to the workflow state in ARCHIVE, the `kept=` archive
# lane-host close wrote of the clone's and the worktree's tmp, empty where it
# holds none. Its `lane-host-state` member names the state file's member, the
# one the lane resolved, or is an empty line after merge-pr removed live
# state. An empty marker reads only the saved cycle copy SAVED_KEY names, the
# merge the caller records, and nothing where SAVED_KEY is empty; a copy
# another merge of the item saved never answers.
# An archive with no such member, written before close
# recorded it, holds the two tmp trees alone. Either read takes the copy
# outside the worktree at ROOT, the clone's, before the worktree's, the first
# in name order where several are. LANE_ARCHIVE_READER reads the archive as a
# stream and writes none of it to disk, since this runs on the control host,
# and reads member names raw, never from `tar -t`, which escapes a name the
# locale cannot print. 0 read; 2 the archive did not read, or names a member
# it does not hold, SCRATCH/state.err saying why.
LANE_ARCHIVE_READER='
import os, sys, tarfile
path, item, root, saved = sys.argv[1:]
# A file tar archived twice, through a symlinked tmp or a clone path whose
# physical spelling differs, is a hard-link entry the second time, read as
# the file it names.
readable = lambda m: m.isfile() or m.islnk()
try:
    with tarfile.open(path, "r:gz") as tar:
        members = {m.name: m for m in tar.getmembers()}
        # A worktree tmp linked to the clone tmp archives one saved file
        # under both paths, so several paths are not several states.
        files = sorted((m for m in members.values() if readable(m)),
                       key=lambda m: (m.name.startswith(root + "/"), m.name))
        if "lane-host-state" in members:
            raw = tar.extractfile(members["lane-host-state"]).read().split(b"\n", 1)[0]
            if not raw:
                suffix = f"/tmp/cycle-state/workflow-state-{saved}.json"
                copies = [m for m in files if saved and m.name.endswith(suffix)]
                if not copies:
                    sys.exit(0)
                found = copies[0]
            else:
                name = raw.decode(tar.encoding, "surrogateescape")
                found = members.get(name)
                if found is None or not readable(found):
                    print(f"archive-member-missing path={path} member={name}", file=sys.stderr)
                    sys.exit(2)
        else:
            states = [m for m in files if os.path.basename(m.name) == f"workflow-state-{item}.json"]
            if not states:
                sys.exit(0)
            found = states[0]
        sys.stdout.buffer.write(tar.extractfile(found).read())
except (tarfile.TarError, OSError, EOFError) as error:
    print(f"archive-unread path={path} cause={type(error).__name__}", file=sys.stderr)
    sys.exit(2)
'
lane_archived_state() {
  LANE_ITEM_STATE=""
  [[ -f "$2" ]] || { printf 'archive-missing path=%s\n' "$2" >"$3/state.err"; return 2; }
  LANE_ITEM_STATE="$(python3 -I -c "$LANE_ARCHIVE_READER" "$2" "$1" "${4#/}" "${5:-}" 2>"$3/state.err" \
    | jq -c . 2>>"$3/state.err")" || { LANE_ITEM_STATE=""; return 2; }
}

# The fix writers append one patched_causes entry per finding. Distinct
# commits distinguish patch rounds; several findings in one commit do not.
# No class history can establish rounds that raised a cause but patched none.
lane_state_rounds() { # STATE_JSON [ERRF]
  local counts
  LANE_REVIEW_ROUNDS=unread
  LANE_FIX_RECEIPTS=unread
  LANE_VALIDATION_RUNS=unread
  LANE_RESTACKS=unread
  LANE_REPEATED_CLASS_ROUNDS=unread
  [[ -n "$1" ]] || return 0
  if ! counts="$(jq -L "$LANE_GITFILE_LIB" -r '
    include "cause-keys";
    ((if .first_panel then 1 else 0 end) + (.rereview_cycles // 0) + (.pr_comment_review.iterations // 0)) as $rounds
    | (if .stages == null then "unread" else [.stages[] | select(.kind == "fix")] | length end) as $fixes
    | ([ (.validate_rounds // [])[] | select(.kind == "implement" or .kind == "fix")] | length) as $validations
    | (.restacks // 0) as $restacks
    | (.pr_comment_review.patched_causes // []) as $patches
    | (reduce $patches[] as $patch ({seen: [], repeated: []};
        if any(.seen[]; .commit != $patch.commit and
            (.cause == $patch.cause or ([shared_cause_key(.; $patch)] | length > 0)))
          then .repeated += [$patch.commit] else . end
        | .seen += [$patch])) as $history
    | [$rounds, $fixes, $validations, $restacks,
        (if ($patches | length) == 0 then "unread" else ($history.repeated | unique | length) end)] | @tsv
  ' <<<"$1" 2>"${2:-/dev/stderr}")"; then
    return 2
  fi
  IFS=$'\t' read -r LANE_REVIEW_ROUNDS LANE_FIX_RECEIPTS LANE_VALIDATION_RUNS LANE_RESTACKS LANE_REPEATED_CLASS_ROUNDS <<<"$counts"
}

# lane_item_state WORKFLOW_STATE LANE_HOST_CLI STATE_DIR ITEM HOST ROOT SCRATCH [ARCHIVE] [STATE_KEY] [STRICT] [CLONE] [SAVED_KEY]
# ITEM identifies the launched lane for every host request. STATE_KEY defaults
# to ITEM and selects only the workflow-state file, including older archives
# without a recorded member. A PR-key fallback keeps the host's item identity.
# Sets LANE_ITEM_STATE to the item's own workflow-state JSON, empty where
# the lane has written none. A local lane's, HOST empty, is under the project
# state directory of its own checkout, ROOT, where ROOT is a directory, so a
# lane of another repository reads from that repository, and of the caller's
# checkout where ROOT is gone or unrecorded; a hosted lane's is in the state
# directory the launch uses, with lane_hosted_state_dir's older-launch fallback, read
# through the probe above with ORCH_LANE_HOST set to HOST; STATE_DIR is the
# local lane's alone. ARCHIVE, where given, is the `kept=` archive of a
# hosted lane's close: where the host answers that the lane's worktree is
# gone, the state is read there instead. A read that fails keeps its
# status, never answered from an archive an earlier run of the item may have
# left. CLONE, where given, is the resolved clone address for cycle recovery.
# SAVED_KEY, pr-N for the merge a cycle caller records, also reads the copy
# merge-pr saves for that merge in CLONE/tmp/cycle-state/workflow-state-SAVED_KEY.json,
# and in an archive with an empty marker, and refuses missing state. The copy
# is named by its merge, never by STATE_KEY, so an earlier merge of the same
# item cannot answer. Advisory reads pass none and leave every saved copy
# unread. A lane whose
# host kind declares files=none, a Claude cloud session, which keeps none this
# machine can read. 0 read, the state possibly
# empty; 2 the read failed, SCRATCH/state.err saying why; 4 lane-host refused
# the provider call at its per-home cap (lane-host-busy), SCRATCH/state.err
# carrying its line. STRICT=true binds the read to ROOT, with no caller-checkout
# fallback. LANE_ITEM_STATE_REASON then identifies absent or unbound local roots
# and hosts with files=none for the public lanes facts result. Absent state
# leaves keyed diagnostics and all paths tried in SCRATCH/state.err, while
# remaining an empty read for advisory callers. Cycle callers may try their PR
# key after a state-absent refusal.
LANE_ITEM_STATE=""
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

lane_item_saved_state() { # LANE_HOST_CLI ITEM CLONE SCRATCH SAVED_KEY
  local path="$3/tmp/cycle-state/workflow-state-$5.json" rc=0
  LANE_ITEM_STATE_TRIED+=("$path")
  lane_host_fetch "$1" "$2" "$path" "$4/saved-state.json" "$4/state.err" || rc=$?
  case "$rc" in
    0)
      LANE_ITEM_STATE="$(jq -ce 'if type == "object" then . else error("state-object-required") end' -- "$4/saved-state.json" 2>"$4/state.err")" || return 2 ;;
    1) ;;
    *) return "$rc" ;;
  esac
}

lane_item_state() {
  local path files clone="${11:-}" saved_key="${12:-}" rc=0 state_key="${9:-$4}"
  LANE_ITEM_STATE="" LANE_ITEM_STATE_REASON=""
  LANE_ITEM_STATE_TRIED=()
  if [[ "${10:-false}" == true && -z "$6" ]]; then
    LANE_ITEM_STATE_REASON=root-unbound
    return 2
  fi
  if [[ -z "$5" ]]; then
    if [[ -n "$6" && -d "$6" ]]; then
      if [[ "${10:-false}" == true ]]; then
        lane_hosted_state_dir "" "$4" "$6" "$7" || return $?
        path="$(cd -- "$6" && "$1" --state-dir "$LANE_HOSTED_STATE_DIR" --no-private-env path "$state_key" 2>"$7/state.err")" || return 2
      else
        path="$(cd -- "$6" && "$1" path "$state_key" 2>"$7/state.err")" || return 2
      fi
    elif [[ "${10:-false}" == true ]]; then
      if [[ -e "$6" || -L "$6" ]]; then
        LANE_ITEM_STATE_REASON=root-unread
        return 2
      fi
      LANE_ITEM_STATE_REASON=root-gone
      return 0
    else
      if [[ -n "$clone" ]]; then
        path="$(cd -- "$clone" && "$1" path "$state_key" 2>"$7/state.err")" || return 2
      else
        path="$("$1" path "$state_key" 2>"$7/state.err")" || return 2
      fi
    fi
    LANE_ITEM_STATE_TRIED+=("$path")
    if [[ -f "$path" ]]; then
      LANE_ITEM_STATE="$(jq -c . -- "$path" 2>"$7/state.err")" || return 2
      return 0
    fi
    if [[ -n "$saved_key" && -n "$clone" ]]; then
      lane_item_saved_state "" "$4" "$clone" "$7" "$saved_key" || return $?
    fi
    [[ -n "$LANE_ITEM_STATE" ]] || lane_item_state_absent "$4" "$7"
    [[ -z "$saved_key" || -n "$LANE_ITEM_STATE" ]] || return 2
    return 0
  fi
  lane_capabilities_read "$2" "$5" 2>"$7/state.err" || return 2
  lane_capability files files
  if [[ "$files" == none ]]; then
    LANE_ITEM_STATE_REASON=files-none
    return 0
  fi
  ORCH_LANE_HOST="$5" lane_hosted_item_state "$2" "$4" "$6" "$7" "$state_key" || rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"
  if [[ -n "$saved_key" && -z "$LANE_ITEM_STATE" && -n "$clone" ]]; then
    ORCH_LANE_HOST="$5" lane_item_saved_state "$2" "$4" "$clone" "$7" "$saved_key" || return $?
  fi
  if [[ -z "$LANE_ITEM_STATE" && "$LANE_HOSTED_GONE" == 1 && -n "${8:-}" ]]; then
    LANE_ITEM_STATE_TRIED+=("$8")
    lane_archived_state "$state_key" "$8" "$7" "$6" "$saved_key" || return $?
  fi
  if [[ -z "$LANE_ITEM_STATE" ]]; then
    lane_item_state_absent "$4" "$7"
    [[ -z "$saved_key" ]] || return 2
  fi
}

# lane_hosted_item_state LANE_HOST_CLI ITEM ROOT SCRATCH [STATE_KEY]: lane_item_state's
# live read of a hosted lane, under the caller's ORCH_LANE_HOST, with its
# statuses; LANE_HOSTED_GONE is 1 where the host answered that the worktree
# is gone.
LANE_HOSTED_GONE=0
lane_hosted_item_state() {
  local rc=0 state_key="${5:-$2}"
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
  lane_hosted_state_path "$LANE_HOSTED_CLONE" "$3/tmp" "$state_key"
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
  lane_hosted_state_path "$LANE_HOSTED_CLONE" "$LANE_HOSTED_STATE_DIR" "$state_key"
  LANE_ITEM_STATE_TRIED+=("$LANE_HOSTED_STATE_PATH")
  lane_host_fetch "$1" "$2" "$LANE_HOSTED_STATE_PATH" "$4/item-state.json" "$4/state.err" || rc=$?
  case "$rc" in
    0) LANE_ITEM_STATE="$(jq -c . -- "$4/item-state.json" 2>"$4/state.err")" || return 2 ;;
    1) ;;
    *) return "$rc" ;;
  esac
}
