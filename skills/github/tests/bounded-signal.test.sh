#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOUNDED="$(cd "$TEST_DIR/.." && pwd)/scripts/lib/bounded.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

cat >"$TMP/worker.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$$" >"$PID_FILE"
exec >/dev/null 2>&1
sleep 30
EOF
chmod +x "$TMP/worker.sh"

cat >"$TMP/wrapper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$BOUNDED"
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
kendex_github_run_bounded 30 "$WORKER"
EOF
chmod +x "$TMP/wrapper.sh"

check_signal() {
  local signal="$1" expected="$2" rc child_pid="" tries=0
  local pid_file="$TMP/$signal.pid"
  set +e
  SIGNAL="$signal" BOUNDED="$BOUNDED" WORKER="$TMP/worker.sh" \
    WRAPPER="$TMP/wrapper.sh" PID_FILE="$pid_file" \
    bash -c '
      set -m
      "$WRAPPER" &
      wrapper=$!
      tries=0
      while [[ ! -s "$PID_FILE" && "$tries" -lt 100 ]]; do
        sleep 0.02
        tries=$((tries + 1))
      done
      kill -s "$SIGNAL" "$wrapper"
      wait "$wrapper"
      exit $?
    ' >"$TMP/$signal.out" 2>"$TMP/$signal.err"
  rc=$?
  set -e

  if [[ "$rc" -eq "$expected" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s exits %s\n' "$signal" "$expected"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s exit: expected %s, got %s\n' "$signal" "$expected" "$rc"
  fi

  if [[ -s "$pid_file" ]]; then
    child_pid="$(<"$pid_file")"
  fi
  while [[ -n "$child_pid" ]] && kill -0 -- "-$child_pid" 2>/dev/null \
    && [[ "$tries" -lt 20 ]]; do
    sleep 0.05
    tries=$((tries + 1))
  done
  if [[ -n "$child_pid" ]] && kill -0 -- "-$child_pid" 2>/dev/null; then
    FAIL=$((FAIL + 1)); printf '  FAIL  %s left process group %s alive\n' "$signal" "$child_pid"
    kill -KILL -- "-$child_pid" 2>/dev/null || true
  elif [[ -n "$child_pid" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s cleaned process group %s\n' "$signal" "$child_pid"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s worker wrote no pid\n' "$signal"
  fi
}

echo "=== bounded runner signal cleanup ==="
check_signal HUP 129
check_signal INT 130
check_signal TERM 143

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
