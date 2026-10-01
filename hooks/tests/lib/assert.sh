#!/usr/bin/env bash
# Shared value assertion for the skill-load-check suites.
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

# Insert a defect into a private copy and require the named production row to
# turn red. The same suite reruns with controls disabled, not a second model
# of the hook. Keep the matched code and remove only its effect.
skill_load_control() { # NAME SOURCE ANCHOR INSERT OVERRIDE FAILED-ROW...
  local name="$1" source="$2" anchor="$3" insert="$4" override="$5" text rest changed log status row matches
  shift 5
  [ ! -L "$source" ] || { echo "skill-load-control: source=symlink" >&2; exit 2; }
  text=$(cat -- "$source") || { echo "skill-load-control: source=unreadable" >&2; exit 2; }
  rest=${text#*"$anchor"}
  [ "$rest" != "$text" ] || { echo "skill-load-control: anchor=missing" >&2; exit 2; }
  case "$rest" in *"$anchor"*) echo "skill-load-control: anchor=ambiguous" >&2; exit 2 ;; esac
  changed=${text/"$anchor"/"$anchor"$'\n'"$insert"}
  [ "$changed" != "$text" ] || { echo "skill-load-control: mutation=unchanged" >&2; exit 2; }
  printf '%s\n' "$changed" >"$TMP_ROOT/$name.sh"
  log="$TMP_ROOT/$name.log"
  set +e
  env -i PATH="$PATH" HOME="$TMP_ROOT" SKILL_LOAD_CONTROL_ACTIVE=1 \
    "$override=$TMP_ROOT/$name.sh" "$BASH_BIN" "$TEST_DIR/${BASH_SOURCE[1]##*/}" >"$log" 2>&1
  status=$?
  set -e
  assert_eq "$status" 1 "control $name: the mutated hook turns the suite red"
  for row in "$@"; do
    matches=$(grep -Fxc -e "  FAIL  $row" -- "$log") || {
      status=$?
      [ "$status" -eq 1 ] || { echo "skill-load-control: log=unreadable" >&2; exit 2; }
    }
    assert_eq "$matches" 1 "control $name: $row"
  done
}