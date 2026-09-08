# shellcheck shell=bash
# Shared presentation for script messages. No exit policy in the emitter.

# Somebody's configured bytes, shown the way they have to be typed back. Not
# gg_shown: %q escapes the globs out of a value whose whole purpose is to be
# copied into a settings file or a path. Every C0 control except tab, and
# DEL, is replaced instead, and a newline becomes one of those replacements,
# so the value reaches the reader on one line and carries nothing a terminal
# would act on.
gg_scrubbed() { # VALUE — the value on one line, controls replaced
  local value="$1" code=1 octal byte
  while [ "$code" -le 31 ] || [ "$code" -eq 127 ]; do
    if [ "$code" -eq 9 ]; then code=$((code + 1)); continue; fi
    printf -v octal '%03o' "$code"
    printf -v byte '%b' "\\$octal"
    value="${value//$byte/?}"
    if [ "$code" -eq 31 ]; then code=127; else code=$((code + 1)); fi
  done
  printf '%s' "$value"
}

# A notice starts with its stable key and value. Explanation is for people;
# callers and tests select the first line and do not parse its wording.
gg_message() { # KEY VALUE EXPLANATION — message on stdout
  local value line
  value="$(gg_scrubbed "$2")" || return 2
  printf '%s: %s=%s\n' "${GG_CHECK:-commit-guards}" "$1" "$value"
  while IFS= read -r line || [ -n "$line" ]; do
    printf '  %s\n' "$line"
  done <<<"$3"
}

gg_fail() { # KEY VALUE EXPLANATION — collection/configuration refusal
  gg_message "$@" >&2
  exit 2
}

gg_fail_cause() { # KEY VALUE ERRFILE FALLBACK — stable refusal before a dependency cause
  local cause="$4"
  [ ! -s "$3" ] || cause="$(cat -- "$3" 2>/dev/null)" || cause="$4"
  gg_fail "$1" "$2" "$cause"
}
