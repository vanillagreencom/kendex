# Session handoffs

| Rule | Enforced in | Status |
| --- | --- | --- |
| Handoff content stays untracked; only this README is tracked | `.gitignore` (`/docs/handoff/*` + README negation) — advisory like all gitignore rules: a forced `git add -f` bypasses it, nothing in CI blocks that | Advisory |
| Exactly ONE file (`HANDOFF.md`), pruned to clean-continuation context — no history, no prose | AGENTS.md § Session handoffs | Not enforced |
| Read only when the user asks, or when a session starts from a user-delivered handoff | AGENTS.md § Session handoffs | Not enforced |
