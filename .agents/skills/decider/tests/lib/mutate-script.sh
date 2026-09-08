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
