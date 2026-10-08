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
# other line naming the key leaves the directory unread. 0 read; 2 a read
# failed or a file did not parse, SCRATCH/state.err saying why; 4 lane-host
# refused a call at its cap.
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

# lane_archived_state ITEM ARCHIVE SCRATCH ROOT — sets LANE_ITEM_STATE to the
# item's workflow state in ARCHIVE, the `kept=` archive lane-host close wrote
# of the clone's and the worktree's tmp, empty where it holds none. Its
# `lane-host-state` member names the state file's member, the one the lane
# resolved, or is an empty line where the lane wrote none, so no other copy of
# the same name is read. An archive with no such member, written before close
# recorded it, holds the two tmp trees alone, and its copy outside the
# worktree at ROOT, the clone's, is read before the worktree's, the first in
# name order where several are. LANE_ARCHIVE_READER reads the archive as a
# stream and writes none of it to disk, since this runs on the control host,
# and reads member names raw, never from `tar -t`, which escapes a name the
# locale cannot print. 0 read; 2 the archive did not read, or names a member
# it does not hold, SCRATCH/state.err saying why.
LANE_ARCHIVE_READER='
import os, sys, tarfile
path, item, root = sys.argv[1:]
# A file tar archived twice, through a symlinked tmp or a clone path whose
# physical spelling differs, is a hard-link entry the second time, read as
# the file it names.
readable = lambda m: m.isfile() or m.islnk()
try:
    with tarfile.open(path, "r:gz") as tar:
        members = {m.name: m for m in tar.getmembers()}
        if "lane-host-state" in members:
            raw = tar.extractfile(members["lane-host-state"]).read().split(b"\n", 1)[0]
            if not raw:
                sys.exit(0)
            name = raw.decode(tar.encoding, "surrogateescape")
            found = members.get(name)
            if found is None or not readable(found):
                print(f"archive-member-missing path={path} member={name}", file=sys.stderr)
                sys.exit(2)
        else:
            files = sorted((m for m in members.values()
                            if readable(m) and os.path.basename(m.name) == f"workflow-state-{item}.json"),
                           key=lambda m: (m.name.startswith(root + "/"), m.name))
            if not files:
                sys.exit(0)
            found = files[0]
        sys.stdout.buffer.write(tar.extractfile(found).read())
except (tarfile.TarError, OSError, EOFError) as error:
    print(f"archive-unread path={path} cause={type(error).__name__}", file=sys.stderr)
    sys.exit(2)
'
lane_archived_state() {
  LANE_ITEM_STATE=""
  [[ -f "$2" ]] || { printf 'archive-missing path=%s\n' "$2" >"$3/state.err"; return 2; }
  LANE_ITEM_STATE="$(python3 -I -c "$LANE_ARCHIVE_READER" "$2" "$1" "${4#/}" 2>"$3/state.err" \
    | jq -c . 2>>"$3/state.err")" || { LANE_ITEM_STATE=""; return 2; }
}

# lane_item_state WORKFLOW_STATE LANE_HOST_CLI STATE_DIR ITEM HOST ROOT SCRATCH [ARCHIVE]
# — sets LANE_ITEM_STATE to the item's own workflow-state JSON, empty where
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
# left. A hosted worktree
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
  [[ "$rc" -eq 0 && "$LANE_HOSTED_GONE" == 1 && -n "${8:-}" ]] || return "$rc"
  lane_archived_state "$4" "$8" "$7" "$6"
}

# lane_hosted_item_state LANE_HOST_CLI ITEM ROOT SCRATCH — lane_item_state's
# live read of a hosted lane, under the caller's ORCH_LANE_HOST, with its
# statuses; LANE_HOSTED_GONE is 1 where the host answered that the worktree
# is gone.
LANE_HOSTED_GONE=0
lane_hosted_item_state() {
  local rc=0
  LANE_HOSTED_GONE=0
  lane_hosted_clone "$1" "$2" "$3" "$4/gitfile" "$4/state.err" || rc=$?
  case "$rc" in
    0) ;;
    1) LANE_HOSTED_GONE=1; return 0 ;;
    3) printf '%s\n' "$3/.git: ${LANE_HOSTED_GITLINE:-<empty>}" >"$4/state.err"; return 2 ;;
    *) return "$rc" ;;
  esac
  lane_hosted_state_path "$LANE_HOSTED_CLONE" "$3/tmp" "$2"
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
  lane_host_fetch "$1" "$2" "$LANE_HOSTED_STATE_PATH" "$4/item-state.json" "$4/state.err" || rc=$?
  case "$rc" in
    0) LANE_ITEM_STATE="$(jq -c . -- "$4/item-state.json" 2>"$4/state.err")" || return 2 ;;
    1) ;;
    *) return "$rc" ;;
  esac
}
