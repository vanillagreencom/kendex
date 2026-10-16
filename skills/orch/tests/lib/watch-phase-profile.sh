#!/usr/bin/env bash
# Temporary CI measurement for KEN-4142. The final cut removes this collector.
# Each suite owns its scratch and calls finish before that scratch is removed.

watch_phase_begin() { # SUITE
  WATCH_PHASE_ENABLED=0
  WATCH_PHASE_SUITE=$1
  [[ ${RUNNER_OS:-} == Linux ]] || return 0
  if [[ -z ${EPOCHREALTIME:-} ]]; then
    printf 'watch-phase suite=%s state=unavailable cause=clock\n' "$1"
    return 0
  fi
  WATCH_PHASE_ENABLED=1
  WATCH_PHASE_STARTED=${EPOCHREALTIME:-}
}

watch_phase_ready() { # EXISTING_SUITE_SCRATCH
  [[ $WATCH_PHASE_ENABLED == 1 ]] || return 0
  WATCH_PHASE_TRACE="$(mktemp "$1/watch-phase.XXXXXX")" || {
    printf 'watch-phase suite=%s state=unavailable cause=scratch\n' "$WATCH_PHASE_SUITE"
    WATCH_PHASE_ENABLED=0
    return 0
  }
  printf 'startup\tfixture\t%s\t%s\n' "$WATCH_PHASE_STARTED" "${EPOCHREALTIME:-}" > "$WATCH_PHASE_TRACE"
}

watch_phase_wrap() { # PHASE FUNCTION...
  [[ $WATCH_PHASE_ENABLED == 1 ]] || return 0
  local phase=$1 name definition
  shift
  for name in "$@"; do
    definition="$(declare -f "$name")" || return 1
    # Re-declaration changes these values. Keep path-sensitive helpers intact.
    if [[ $definition == *BASH_SOURCE* || $definition == *FUNCNAME* ]]; then
      printf 'watch-phase suite=%s state=partial function=%s cause=declaration-path\n' "$WATCH_PHASE_SUITE" "$name"
      continue
    fi
    eval "${definition/$name ()/_watch_phase_original_$name ()}"
    eval "$name() {
      local watch_phase_at=\${EPOCHREALTIME:-} watch_phase_status
      _watch_phase_original_$name \"\$@\"
      watch_phase_status=\$?
      printf '%s\\t%s\\t%s\\t%s\\n' '$name' '$phase' \"\$watch_phase_at\" \"\${EPOCHREALTIME:-}\" >> \"\$WATCH_PHASE_TRACE\" || return 1
      return \"\$watch_phase_status\"
    }"
  done
}

watch_phase_finish() {
  [[ $WATCH_PHASE_ENABLED == 1 ]] || return 0
  if python3 - "$WATCH_PHASE_TRACE" "$WATCH_PHASE_SUITE" "$WATCH_PHASE_STARTED" "${EPOCHREALTIME:-}" "$BASH_VERSION" <<'PY'
from collections import Counter
from pathlib import Path
import sys

path, suite, started, finished, bash = sys.argv[1:]
started, finished = float(started), float(finished)
events = [(started, None, 0), (finished, None, 0)]
counts = Counter()
priority = ('exercise', 'assertion', 'fixture')
for line in Path(path).read_text().splitlines():
    name, phase, begin, end = line.split('\t')
    begin, end = float(begin), float(end)
    if phase not in priority or not started <= begin <= end <= finished:
        raise ValueError('invalid phase interval')
    counts[name] += 1
    events.extend(((begin, phase, 1), (end, phase, -1)))
if not counts['run_watch']:
    raise ValueError('no completed watch calls')
active, seconds = Counter(), Counter()
previous = started
for at, phase, delta in sorted(events, key=lambda event: event[0]):
    owner = next((kind for kind in priority if active[kind]), 'other')
    seconds[owner] += at - previous
    if phase is not None:
        active[phase] += delta
    previous = at
print(f'watch-phase suite={suite} state=complete bash={bash} '
      f'fixture-seconds={seconds["fixture"]:.6f} '
      f'exercise-seconds={seconds["exercise"]:.6f} '
      f'assertion-seconds={seconds["assertion"]:.6f} '
      f'other-seconds={seconds["other"]:.6f} '
      f'total-seconds={finished-started:.6f} watch-calls={counts["run_watch"]}')
PY
  then
    return 0
  else
    printf 'watch-phase suite=%s state=unavailable cause=collector\n' "$WATCH_PHASE_SUITE"
    return 0
  fi
}
