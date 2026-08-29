# Put the subject back in a tested position, the shape this helper replaces.
# bash suspends errexit for the whole body of a command whose status is being
# tested, so a function that relied on errexit runs past its failure and
# run_status reports the success it ends with.
control_expect "a shell function that aborts internally reports non-zero"
control_replace tests/lib/assert.sh 1 \
    '	( "$@" ) &' \
    '	"$@" || __rc=$?'
control_replace tests/lib/assert.sh 1 \
    '	wait $! || __rc=$?' \
    '	:'
