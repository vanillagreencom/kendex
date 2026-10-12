#!/usr/bin/env bash
# Surface: the stored provider reply in lane_capabilities_read.
# Inputs: scripts/lib/lane-capabilities.sh, scripts/lib/lane-claims.sh,
# scripts/lane-host, scripts/open-terminal, scripts/lane-close,
# scripts/oversee-report, scripts/lib/*.sh, git-context,
# skills/mailbox/scripts/* and skills/github/scripts/lib/*.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$TEST_DIR/../scripts"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
mkdir -p "$TEST_DIR/../../../tmp"
TMP_ROOT="$(mktemp -d "$TEST_DIR/../../../tmp/capabilities.XXXXXX")" || { echo 'lane-capabilities: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'lane-capabilities: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'lane-capabilities: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
mkdir -p "$TMP_ROOT/repo" "$TMP_ROOT/home"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config gc.auto 0
git -C "$TMP_ROOT/repo" config maintenance.auto false
LIB="$SCRIPTS/lib/lane-capabilities.sh"
PROVIDER="$TMP_ROOT/repo/provider"
SSH=$'kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\trelaunch=resume\tpark=none\taccounts=none\tpool=plan\tland=lane'
write_provider() { # REPLY STATUS WORDS
  printf '#!%s\nset -euo pipefail\nprintf "capabilities\\n" >> "$CAPABILITY_CALLS"\nprintf "%%s\\n" %q\nprintf "%%s" %q >&2\nexit %s\n' \
    "$BASH" "$1" "$3" "$2" > "$PROVIDER"
  chmod +x "$PROVIDER"
}
read_capabilities() { # [HOST]
  RC=0
  (cd "$TMP_ROOT/repo" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$PATH" HOME="$TMP_ROOT/home" \
    CAPABILITY_CALLS="$TMP_ROOT/calls" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/state" \
    "$BASH" -c 'set -euo pipefail; source "$1"; lane_capabilities_read "$2" "$3"; printf "%s\n" "$LANE_CAPABILITIES"' \
    capabilities "$LIB" "$SCRIPTS/lane-host" "${1:-$PROVIDER}") > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" || RC=$?
  CALLS="$(wc -l < "$TMP_ROOT/calls")"; CALLS="${CALLS//[[:space:]]/}"
}
# Provider outcomes use the actual dispatcher's validation and fallback.
for row in success refused-2 refused-64 failure invalid; do
  rm -rf -- "$TMP_ROOT/state"
  : > "$TMP_ROOT/calls"
  case "$row" in
    success) write_provider "$SSH" 0 $'provider: note=value\n\nnext=value\n'; want=0 ;;
    refused-2) write_provider '' 2 ''; want=0 ;;
    refused-64) write_provider '' 64 $'provider: verb-unsupported verb=capabilities\n'; want=0 ;;
    failure) write_provider '' 65 $'provider: failed=capabilities\n'; want=65 ;;
    invalid) write_provider "${SSH/park=none/park=invalid}" 0 ''; want=1 ;;
  esac
  read_capabilities
  assert_eq "$RC" "$want" "$row: cold dispatcher status"
  cp -- "$TMP_ROOT/out" "$TMP_ROOT/cold.out"
  cp -- "$TMP_ROOT/err" "$TMP_ROOT/cold.err"
  read_capabilities
  assert_eq "$RC" "$want" "$row: warm dispatcher status"
  cmp_rc=0; cmp -s -- "$TMP_ROOT/cold.out" "$TMP_ROOT/out" || cmp_rc=$?
  assert_eq "$cmp_rc" 0 "$row: stdout bytes stay the same"
  cmp_rc=0; cmp -s -- "$TMP_ROOT/cold.err" "$TMP_ROOT/err" || cmp_rc=$?
  assert_eq "$cmp_rc" 0 "$row: stderr bytes stay the same"
  wanted_calls=1; [[ "$want" -eq 0 ]] || wanted_calls=2
  assert_eq "$CALLS" "$wanted_calls" "$row: successful replies are reused and failed reads are retried"
  [[ "$want" -ne 0 ]] || assert_eq "$(cat "$TMP_ROOT/out")" "$SSH" "$row: validated SSH reply"
done
rm -rf -- "$TMP_ROOT/state"
: > "$TMP_ROOT/calls"
write_provider "$SSH" 0 ''
read_capabilities
assert_eq "$CALLS" 1 'identity fixture starts with one cold read'
# Isolate each key change. The reply changes at fixed size for mtime; a
# comment changes size with mtime restored for size. No real clock wait.
for dimension in mtime size path; do
  case "$dimension" in
    mtime)
      write_provider "${SSH/park=none/park=verb}" 0 ''
      touch -t 202001010101.01 "$PROVIDER" ;;
    size)
      touch -r "$PROVIDER" "$TMP_ROOT/stamp"
      printf '# longer provider file\n' >> "$PROVIDER"
      touch -r "$TMP_ROOT/stamp" "$PROVIDER" ;;
    path)
      cp -p -- "$PROVIDER" "$TMP_ROOT/repo/other-provider"
      PROVIDER="$TMP_ROOT/repo/other-provider" ;;
  esac
  prior="$CALLS"
  read_capabilities
  assert_eq "$CALLS" "$((prior+1))" "$dimension: changed provider key calls the dispatcher again"
  assert_eq "$(cat "$TMP_ROOT/out")" "${SSH/park=none/park=verb}" "$dimension: next read returns the current reply"
  read_capabilities
  assert_eq "$CALLS" "$((prior+1))" "$dimension: changed reply becomes warm"
done
# A provider that loses execute permission must retain lane-host's refusal.
chmod -x "$PROVIDER"
read_capabilities
assert_eq "$RC" 1 'an unavailable provider is refused despite a stored reply'
chmod +x "$PROVIDER"
# A blocked cache directory must still return the live dispatcher result.
rm -rf -- "$TMP_ROOT/state"
printf 'file\n' > "$TMP_ROOT/state"
prior="$CALLS"
read_capabilities
assert_eq "$RC" 0 'an unwritable cache does not block a capability read'
assert_eq "$CALLS" "$((prior+1))" 'an unwritable cache asks the provider'
rm -- "$TMP_ROOT/state"
# Keep the original key match in each private mutation. The count and reply
# assertions above must reject a cache that ignores provider identity.
CONTROL_PARENT="$("$SCRIPTS/git-context" common-root "$TEST_DIR")"
mkdir -p "${CONTROL_PARENT%/*}/tmp"
CONTROL_ROOT="$(mktemp -d "${CONTROL_PARENT%/*}/tmp/capability-control.XXXXXX")" || { echo 'lane-capabilities: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $CONTROL_ROOT && ! -L $CONTROL_ROOT ]] || { echo 'lane-capabilities: scratch=not-a-directory' >&2; exit 1; }
CONTROL_ROOT="$(cd -- "$CONTROL_ROOT" && pwd -P)" || { echo 'lane-capabilities: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}" "${CONTROL_ROOT:?}"' EXIT
for dimension in mtime size; do
  CONTROL="$(TMP_ROOT="$CONTROL_ROOT" mutant_scripts "capability-$dimension" lib/lane-capabilities.sh)"
  ignored='${identity##*:}'
  [[ "$dimension" != size ]] || ignored='${identity%:*}'
  mutate_file "$CONTROL/lib/lane-capabilities.sh" \
    'cache="${cache%/claims}/usage/host-capabilities-${sum// /-}"' \
    'cache="${cache%/claims}/usage/host-capabilities-${sum// /-}"'$'\n'"    identity=\"$ignored\""
  LIB="$CONTROL/lib/lane-capabilities.sh"
  rm -rf -- "$TMP_ROOT/state"
  : > "$TMP_ROOT/calls"
  write_provider "$SSH" 0 ''
  read_capabilities
  if [[ "$dimension" == mtime ]]; then touch -t 202101010101.01 "$PROVIDER"
  else
    touch -r "$PROVIDER" "$TMP_ROOT/stamp"
    printf '# longer source\n' >> "$PROVIDER"
    touch -r "$TMP_ROOT/stamp" "$PROVIDER"
  fi
  read_capabilities
  rc=0
  ( FAIL=0; assert_eq "$CALLS" 2 'identity invalidation'; [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/control-$dimension.log" || rc=$?
  assert_eq "$rc" 1 "$dimension: the invalidation assertion rejects a cache that ignores file identity"
done

# Exercise each production caller across process boundaries. The mail and
# launch cases reach their documented channel refusals; close and report
# complete. Count the provider to prove every case reaches the shared read.
LIB="$SCRIPTS/lib/lane-capabilities.sh"
SCRIPTS="$(mutant_scripts repo/skills/orch)"
ln -s "$TEST_DIR/../../github" "$TMP_ROOT/repo/skills/github"
PROVIDER="$TMP_ROOT/repo/provider"
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/fleet"
printf 'A directive.\n' > "$TMP_ROOT/directive"
cat > "$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" != auth ]] || exit 0
printf '[]\n'
STUB
cat > "$TMP_ROOT/bin/empty" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '[]\n'
STUB
cat > "$TMP_ROOT/bin/tracker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '{"title":"Fixture","description":"## Done when\\n\\n* Ready.","state_type":"started"}\n'
STUB
cat > "$TMP_ROOT/bin/mail" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
exit 0
STUB
REAL_DATE="$(command -v date)"
printf '#!%s\nset -euo pipefail\ncase "$*" in "-u +%%s"|"+%%s") printf "1790000000\\n" ;; *) exec %q "$@" ;; esac\n' \
  "$BASH" "$REAL_DATE" > "$TMP_ROOT/bin/date"
chmod +x "$TMP_ROOT/bin/gh" "$TMP_ROOT/bin/empty" "$TMP_ROOT/bin/tracker" "$TMP_ROOT/bin/mail" "$TMP_ROOT/bin/date"
caller_run() { # CALLER
  local command=()
  case "$1" in
    watch)
      command=("$BASH" -c 'set -euo pipefail; SCRIPT_DIR="$1"; source "$SCRIPT_DIR/lib/lane-capabilities.sh"; source "$SCRIPT_DIR/lib/watch-host-kinds.sh"; HOSTED=(); ROOTS=(); host_route KEN-1 "$2" /remote; printf "%s\n" "$LANE_CAPABILITIES" "${HOSTED[@]+${HOSTED[@]}}"' watch "$SCRIPTS" "$PROVIDER") ;;
    lane-mail)
      command=("$SCRIPTS/../../mailbox/scripts/lane-mail" send --item KEN-1 --directive --file "$TMP_ROOT/directive" --state-dir "$TMP_ROOT/fleet") ;;
    lane-close)
      command=("$SCRIPTS/lane-close" --state-dir "$TMP_ROOT/fleet" --keep-sandbox KEN-1) ;;
    open-terminal)
      command=("$SCRIPTS/open-terminal" --host "$PROVIDER" --harness codex KEN-1) ;;
    oversee-report)
      command=("$SCRIPTS/oversee-report" render --state "$TMP_ROOT/fleet/workflow-state-oversee.json" --repo owner/repo) ;;
  esac
  RC=0
  (cd "$TMP_ROOT/repo" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" \
    CAPABILITY_CALLS="$TMP_ROOT/calls" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/state" ORCH_LANE_HOST="$PROVIDER" \
    WORKTREE_CLI="$TMP_ROOT/bin/mail" \
    ORCH_STATE_DIR="$TMP_ROOT/fleet" OVERSEE_REPORT_GITHUB="$TMP_ROOT/bin/empty" \
    OVERSEE_REPORT_TRACKER="$TMP_ROOT/bin/tracker" OVERSEE_REPORT_LANE_MAIL="$TMP_ROOT/bin/mail" \
    "${command[@]}") > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" || RC=$?
  CALLS="$(wc -l < "$TMP_ROOT/calls")"; CALLS="${CALLS//[[:space:]]/}"
}
for caller in watch lane-mail lane-close open-terminal oversee-report; do
  rm -rf -- "$TMP_ROOT/state"
  : > "$TMP_ROOT/calls"
  caps="$SSH"; status=running; want=0
  case "$caller" in
    lane-mail) want=2 ;;
    lane-close) status=parked ;;
    open-terminal) caps="${SSH/kind=ssh/kind=codex-cloud}"; caps="${caps/launch=ssh/launch=cloud-task}"; want=1 ;;
    oversee-report) caps="${SSH/channel=mailbox/channel=task}"; caps="${caps/files=verb/files=none}" ;;
  esac
  write_provider "$caps" 0 ''
  jq -cn --arg host "$PROVIDER" --arg root "$TMP_ROOT/repo" --arg status "$status" \
    '{issue_id:"oversee",triaged:[],lanes:[{item:"KEN-1",tracker:"linear",harness:"codex",repo:"owner/repo",status:$status,host:$host,mail_root:$root,window:null,parked:{pr:1,head:"head",at:"2026-01-01T00:00:00Z"}}]}' \
    > "$TMP_ROOT/fleet/workflow-state-oversee.json"
  caller_run "$caller"
  assert_eq "$RC" "$want" "$caller: cold caller reaches its contract" "$TMP_ROOT/err"
  assert_eq "$CALLS" 1 "$caller: cold caller asks capabilities once" "$TMP_ROOT/err"
  cp -- "$TMP_ROOT/out" "$TMP_ROOT/cold.out"
  cp -- "$TMP_ROOT/err" "$TMP_ROOT/cold.err"
  caller_run "$caller"
  assert_eq "$RC" "$want" "$caller: warm caller keeps its status" "$TMP_ROOT/err"
  assert_eq "$CALLS" 1 "$caller: warm caller starts no capabilities provider"
  for stream in out err; do
    cmp_rc=0; cmp -s -- "$TMP_ROOT/cold.$stream" "$TMP_ROOT/$stream" || cmp_rc=$?
    assert_eq "$cmp_rc" 0 "$caller: warm caller keeps $stream bytes"
  done
done
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
