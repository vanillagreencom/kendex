# bash32 proof fixtures

Read by `tools/tests/bash32-pattern-parity.test.sh`, one line per case, plain
text and never sourced.

- `bash32-probes.txt` — Bash 4 constructs the shared pattern set must flag.
  Every line is a must-fail probe: dropped into a scanned `scripts/` tree it
  turns that skill's bash32-portability suite red.

  One line per SPELLING, not one per construct. A construct absent from this
  file cannot be proven by any number of green injections, and a family
  standing behind a single listed member is how `coproc(` went uncovered
  while `coproc FOO` and `coproc {` both passed. So each alternative in the
  pattern carries its whole family here: every command word and flag cluster
  the declare rule accepts including the `+` form and a tab separator, every
  redirection shape `{fd}` takes, every parameter and operator form of case
  conversion including a pattern argument, and each name against every
  neighbour that can precede or follow it.
- `bash32-controls.txt` — Bash 3.2-legal source the set must leave alone,
  including the real bracket expressions and separator strings in this repo
  that an unanchored operator pattern used to match.
- `bash32-uncatchable.txt` — Bash 4 constructs the set does NOT flag, such as
  a builtin the shell reaches through quote removal (`'mapfile' -t v`).
- `bash32-overflagged.txt` — Bash 3.2-legal source the set DOES flag, because
  it spells a construct inside a comment, a regex literal or a string. There
  is no comment skip: a `#` line inside a multiline double-quoted word is live
  code, so skipping those let a Bash 4 expansion through in silence. The fix
  for a
  real script is to respell the line, as `skills/preflight/scripts/preflight`
  now does; these lines are kept here as the accepted cost, written down.

The last two are the block's stated limit, one file per direction. Asserting
both keeps that list from going stale: change what the set decides and the
suite reds until the limit is rewritten to match.

A construct added to one belongs in the other's thinking too: a probe that
widens an anchor needs a control that keeps the widening honest.
