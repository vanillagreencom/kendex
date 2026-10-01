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

# Run the suite's own row callback on a private mutant, not the whole suite.
# The subshell keeps the override and assertion counts out of the parent.
# Keep the matched code and remove only its effect.
skill_load_control() { # NAME SOURCE ANCHOR INSERT OVERRIDE ROWS FAILED-ROW...
  local name="$1" source="$2" anchor="$3" insert="$4" override="$5" rows="$6" text rest changed log status row matches
  shift 6
  [ ! -L "$source" ] || { echo "skill-load-control: source=symlink" >&2; exit 2; }
  text=$(cat -- "$source") || { echo "skill-load-control: source=unreadable" >&2; exit 2; }
  rest=${text#*"$anchor"}
  [ "$rest" != "$text" ] || { echo "skill-load-control: anchor=missing" >&2; exit 2; }
  case "$rest" in *"$anchor"*) echo "skill-load-control: anchor=ambiguous" >&2; exit 2 ;; esac
  changed=${text/"$anchor"/"$anchor"$'\n'"$insert"}
  [ "$changed" != "$text" ] || { echo "skill-load-control: mutation=unchanged" >&2; exit 2; }
  printf '%s\n' "$changed" >"$TMP_ROOT/$name.sh"
  # The caller can capture control results at a name-based path of its own.
  # Give the callback an exclusive log so those writes cannot overwrite rows.
  log=$(mktemp "$TMP_ROOT/$name.log.XXXXXX") || { echo "skill-load-control: log=mktemp-failed" >&2; exit 2; }
  set +e
  (
    set -e
    PASS=0
    FAIL=0
    printf -v "$override" '%s' "$TMP_ROOT/$name.sh"
    "$rows"
    [ "$FAIL" -eq 0 ]
  ) >"$log" 2>&1
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