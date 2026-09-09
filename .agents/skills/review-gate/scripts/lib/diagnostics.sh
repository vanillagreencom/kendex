# shellcheck shell=bash
# Diagnostic protocol: the first line carries a stable kind/code and one
# value escaped with Bash printf %q. Remaining lines explain the result.
# Callers choose stdout or stderr. Predicate and watcher stdout protocols
# stay with their owning scripts and do not pass through this formatter.
rg_message() { # KIND CODE VALUE MESSAGE
  printf 'review-gate-%s=%s value=%q\n%s\n' "$1" "$2" "$3" "$4"
}

# Validator report protocol: one ok/FAIL/note line with check and value,
# then indented explanation lines. validate.sh counts only verdict lines.
rg_report() { # STATUS CHECK VALUE MESSAGE
  printf '%s check=%s value=%q\n' "$1" "$2" "$3"
  printf '%s\n' "$4" | sed 's/^/  /'
}
