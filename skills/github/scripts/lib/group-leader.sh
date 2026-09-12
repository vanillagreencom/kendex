# shellcheck shell=bash
#
# THE CHILD MAKES ITS OWN GROUP, BETWEEN THE FORK AND THE EXEC.
#
# A caller that has to tear down a subprocess TREE needs `$!` to be a
# process-group leader: that pid is what it probes and signals as `-$pid`, and
# probing the leader alone answers "the first process finished", never "the
# tree is gone". Bash arranges that only under job control (`set -m`), which
# also has the PARENT call setpgid on the child — a call that races the child's
# own exec and, when it loses, prints
#
#   child setpgid (N to N): Operation not permitted
#
# onto the script's stderr, where its consumers read the run's transcript. On
# the macOS CI shard that line has reddened a pin on a captured transcript and
# ejected an unrelated pull request from the merge queue. So the child does it:
# setpgid(0, 0) then exec, one pid throughout, every inherited descriptor kept,
# and no shell reporting on any of it.
#
# Job control supplied two other things, which each caller puts back by hand:
#
#   stdin    Bash points an async command's stdin at /dev/null unless the
#            command carries an explicit redirection, so a child that needs the
#            caller's stdin is written `... <&0 &`.
#   signals  Bash sets an async child's SIGINT and SIGQUIT to SIG_IGN, which
#            survives exec and no later `trap` can take back. The perl program
#            below restores both dispositions.
#
# THE FORK WINDOW. The group exists only once the child reaches its setpgid,
# microseconds after `$!` exists. A probe inside that window finds no group, and
# reading that absence as "already stopped" reports success over a running tree.
# So a caller resolves the target where the signal is sent rather than at the
# fork, and acts on the bare pid only when the group is absent and the pid is
# not: the only thing ever inside that window is the caller's own fork-to-exec
# code — bash, then perl — neither with children yet and both taking the default
# TERM. Only a caller holding its own fork may signal a bare pid; a pid read
# back off disk may by then belong to an unrelated process.
#
# The prefix EXECS its command, so that command must be an external program: a
# shell function or a builtin with no external twin stops the fork at 127.
#
# perl carries POSIX setpgid on both platforms this ships to and stock macOS has
# no setsid(1), so one mechanism covers both. Where perl is missing the fork
# stops in its caller's own voice, exiting 127 with `perl: command not found` on
# whatever stderr that caller gave the child.
#
# Source this file; do not execute it directly.
KENDEX_GROUP_LEADER=(perl -e '$SIG{INT} = $SIG{QUIT} = "DEFAULT"; setpgrp(0, 0) or die "setpgrp: $!\n"; exec { $ARGV[0] } @ARGV; die "exec $ARGV[0]: $!\n"')
