# shellcheck shell=bash
# Shared presentation for script messages. No exit policy in the emitter.

# Somebody's configured bytes, shown the way they have to be typed back. Not
# gg_shown: %q escapes the globs out of a value whose whole purpose is to be
# copied into a settings file or a path. Every C0 control except tab, and
# DEL, is replaced instead, and a newline becomes one of those replacements,
# so the value reaches the reader on one line and carries nothing a terminal
# would act on.
gg_scrubbed() { # VALUE — the value on one line, controls replaced
  printf '%s' "$1" | LC_ALL=C awk '{ gsub(/[\001-\010\013-\037\177]/, "?"); printf "%s%s", sep, $0; sep = "?" }'
}

# A notice starts with its stable key and value. Explanation is for people;
# callers and tests select the first line and do not parse its wording.
gg_message() { # KEY VALUE EXPLANATION — message on stdout
  local value
  value="$(gg_scrubbed "$2")" || return 2
  printf '%s: %s=%s\n' "${GG_CHECK:-commit-guards}" "$1" "$value"
  printf '  %s\n' "$3"
}

gg_fail() { # KEY VALUE EXPLANATION — collection/configuration refusal
  gg_message "$@" >&2
  exit 2
}

