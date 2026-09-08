# shellcheck shell=bash
# Diagnostic protocol: the first line carries a stable kind/code and one
# value escaped with Bash printf %q. Remaining lines explain the result.
# Callers choose stdout or stderr. The command stdout protocol stays with
# doc-limits and does not pass through this formatter.
sr_message() { # KIND CODE VALUE MESSAGE
  printf 'doc-limits-%s=%s value=%q\n%s\n' "$1" "$2" "$3" "$4"
}
