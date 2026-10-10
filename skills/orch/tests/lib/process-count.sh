# shellcheck shell=bash
# A shared process instrument for mailbox verbs and watch ticks. Wrappers
# count external starts. The Bash trace also sees substitutions and subshells.
# A shell that execs a wrapper has the wrapper's PID and is counted there once.
process_count_install() { # DIRECTORY
  python3 "${BASH_SOURCE[0]%/*}/process-count.py" install "$1" "$PATH" "$BASH"
}

process_count_total() { # DIRECTORY
  python3 "${BASH_SOURCE[0]%/*}/process-count.py" count "$1"
}

process_count_watch() { # DIRECTORY mail|idle
  python3 "${BASH_SOURCE[0]%/*}/process-count.py" watch "$1" "$2"
}
