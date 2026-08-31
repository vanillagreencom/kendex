# Drop the runtime contract from --help. Callers on macOS system Bash then get
# no statement of the requirement before their first failure.
control_expect "--help states the Bash 4+ runtime contract"
control_replace scripts/linear.sh 1 \
    "  Runtime         Bash 4.0 or newer. macOS system Bash 3.2 is unsupported." \
    "  Runtime         Any bash."
