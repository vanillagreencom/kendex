---
applyTo: "**/tests/**,**/*.test.sh,**/*.test.ts,**/fixtures/**"
---

- A fixture path the test built itself (`mktemp -d`, its own sandbox
  directory) carries no `--`, and its absence is not a finding. The `--`
  rule covers path values arriving from configuration, argv, or the
  environment.
- A `mktemp -d` scratch directory the test removes in its own `trap ... EXIT`
  is cleaned up — do not report it as a leak or a missing-cleanup finding.
- `${arr[@]+"${arr[@]}"}` is the quoted empty-array expansion Bash 3.2
  requires under `set -u`, and is the repo-wide idiom — not an unquoted
  expansion and not a word-splitting defect.
