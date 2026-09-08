#!/usr/bin/env bash

decider_mutate_script() {
  local source="$1" destination="$2" old="$3" new="$4" expected_count="$5"
  local content="" rest="" prefix="" mutated="" count=0 destination_dir source_dir

  if [[ -L "$source" ]]; then
    printf 'refusing to mutate symlink: %s\n' "$source" >&2
    return 1
  fi
  if ! content="$(<"$source")"; then
    printf 'could not read mutation source: %s\n' "$source" >&2
    return 1
  fi

  rest="$content"
  while [[ "$rest" == *"$old"* ]]; do
    prefix="${rest%%"$old"*}"
    mutated+="$prefix$new"
    rest="${rest#*"$old"}"
    count=$((count + 1))
  done
  mutated+="$rest"

  if [[ "$count" -ne "$expected_count" ]]; then
    printf 'mutation match count: expected %s, got %s\n' "$expected_count" "$count" >&2
    return 1
  fi

  destination_dir="${destination%/*}"
  source_dir="${source%/*}"
  if ! mkdir -p "$destination_dir"; then
    printf 'could not create mutant directory: %s\n' "$destination_dir" >&2
    return 1
  fi
  if ! cp -R "$source_dir/lib" "$destination_dir/lib"; then
    printf 'could not copy mutation support files\n' >&2
    return 1
  fi
  if ! printf '%s\n' "$mutated" >"$destination"; then
    printf 'could not write mutant: %s\n' "$destination" >&2
    return 1
  fi
  if ! chmod +x "$destination"; then
    printf 'could not mark mutant executable: %s\n' "$destination" >&2
    return 1
  fi

  if cmp -s "$source" "$destination"; then
    printf 'mutation changed no bytes: %s\n' "$destination" >&2
    return 1
  fi

  printf '%s' "$destination"
}

decider_empty_test_table() {
  local source="$1" destination="$2" delimiter="$3"
  local content="" start after_start rows old new mutant source_dir source_skill_dir
  local destination_dir destination_skill_dir

  if ! content="$(<"$source")"; then
    printf 'could not read table-control source: %s\n' "$source" >&2
    return 1
  fi
  start="  done <<'$delimiter'"
  after_start="${content#*"$start"$'\n'}"
  if [[ "$after_start" == "$content" ]]; then
    printf 'table start not found: %s\n' "$delimiter" >&2
    return 1
  fi
  rows="${after_start%%$'\n'"$delimiter"*}"
  if [[ "$rows" == "$after_start" ]]; then
    printf 'table end not found: %s\n' "$delimiter" >&2
    return 1
  fi
  old="$start"$'\n'"$rows"$'\n'"$delimiter"
  new="$start"$'\n'"$delimiter"
  if ! mutant="$(decider_mutate_script "$source" "$destination" "$old" "$new" 1)"; then
    return 1
  fi

  source_dir="${source%/*}"
  source_skill_dir="${source_dir%/*}"
  destination_dir="${destination%/*}"
  destination_skill_dir="${destination_dir%/*}"
  if ! cp -R "$source_skill_dir/scripts" "$destination_skill_dir/scripts"; then
    printf 'could not copy production scripts for table control\n' >&2
    return 1
  fi

  printf '%s' "$mutant"
}

decider_test_fails_with() {
  local test_script="$1" expected="$2" output status
  DECIDER_CONTROL_DETAIL=""
  set +e
  output=$(DECIDER_TABLE_CONTROL_RUN=1 "$test_script" 2>&1)
  status=$?
  set -e
  DECIDER_CONTROL_DETAIL="status $status; output: $output"
  [[ "$status" -ne 0 && "$output" == *"$expected"* ]]
}
