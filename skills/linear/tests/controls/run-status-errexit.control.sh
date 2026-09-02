# Put the subject back in a tested position, the shape this helper replaces.
# bash suspends errexit for the whole body of a command whose status is being
# tested, so a function that relied on errexit runs past its failure and
# run_status reports the success it ends with.
#
# One replacement, not two: the status the tested position produced is handed
# to a background subshell so the `wait` below still has a job to reap and
# still reports that status. Breaking the two lines separately would leave
# `wait` reaping an already-reaped pid, which reddens on the 127 that returns
# rather than on the suspension this control is about.
control_expect "a shell function that aborts internally reports non-zero"
control_replace tests/lib/assert.sh 1 \
    '	( "$@" ) &' \
    '	"$@" || __rc=$?; ( exit "$__rc" ) &'
