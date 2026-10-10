#!/usr/bin/env bash
# Shared hook-cost instrument. PATH wrappers record every external invocation.
# DEBUG inheritance also records command substitutions and pipeline subshells.
# The caller owns COUNT_ROOT, and enables the instrument only for the hook.
process_count_supported() { [ -n "${BASHPID:-}" ]; }
process_count_setup() { # SCRATCH_ROOT [COMMAND_PATH]
  COUNT_ROOT="$1/process-count"
  COUNT_BIN="$COUNT_ROOT/bin"
  COUNT_TRACE="$COUNT_ROOT/bash-env"
  COUNT_LOG="$COUNT_ROOT/log"
  mkdir -p "$COUNT_BIN"
  local directory executable name old_ifs="$IFS" command_path="${2:-$PATH}"
  IFS=:
  for directory in $command_path; do
    [ -d "$directory" ] || continue
    for executable in "$directory"/*; do
      [ -f "$executable" ] && [ -x "$executable" ] || continue
      name=${executable##*/}
      [ ! -e "$COUNT_BIN/$name" ] || continue
      {
        printf '#!/bin/sh\n'
        printf 'printf "command %%s %%s\\n" %q "$$" >> "$PROCESS_COUNT_LOG"\n' "$name"
        printf 'exec %q "$@"\n' "$executable"
      } > "$COUNT_BIN/$name"
      chmod +x "$COUNT_BIN/$name"
    done
  done
  IFS=$old_ifs
  cat > "$COUNT_TRACE" <<'TRACE'
if [ -n "${BASHPID:-}" ]; then
  set -T
  trap 'printf "bash %s\n" "${BASHPID:-}" >> "$PROCESS_COUNT_LOG"' DEBUG
fi
TRACE
}
process_count_reset() { : > "$COUNT_LOG"; }
process_count_total() {
  process_count_supported || { echo unavailable; return 0; }
  # An exec keeps its PID, including when a PATH wrapper becomes Bash.
  awk '$1 == "bash" { ids[$2] = 1 } $1 == "command" { ids[$3] = 1 }
    END { for (id in ids) processes++; print processes + 0 }' "$COUNT_LOG"
}
process_count_command() { # COMMAND
  awk -v name="$1" '$1 == "command" && $2 == name { n++ } END { print n + 0 }' "$COUNT_LOG"
}
