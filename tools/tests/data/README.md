# bash32 proof fixtures

Read by `tools/tests/bash32-pattern-parity.test.sh`, one line per case, plain
text and never sourced.

- `bash32-probes.txt` — Bash 4 constructs the shared pattern set must flag.
  Every line is a must-fail probe: dropped into a scanned `scripts/` tree it
  turns that skill's bash32-portability suite red.
- `bash32-controls.txt` — Bash 3.2-legal source the set must leave alone,
  including the real bracket expressions and separator strings in this repo
  that an unanchored operator pattern used to match.

A construct added to one belongs in the other's thinking too: a probe that
widens an anchor needs a control that keeps the widening honest.
