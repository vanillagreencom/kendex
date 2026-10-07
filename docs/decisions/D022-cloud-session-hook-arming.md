# D022: Arm cloud git hooks through repository consent

[← Decision Index](INDEX.md)

**Date**: 2026-10-07

**Status**: Active

**Research**: [KEN-3229](https://linear.app/vanillagreen/issue/KEN-3229)

**Decision**: A repository may commit an enabled catalog SessionStart hook that runs the existing commit-guards installer only when Claude Code sets `CLAUDE_CODE_REMOTE=true`. The hook reads its project SessionStart registration from `HEAD:.claude/settings.json` as the repository's consent. A global install grants no repository consent. kendex's package runs and local clones still require their existing licence.

**Why**: Git does not clone hooks. Claude Code caches setup-script results, so setup cannot arm each fresh cloud clone. The committed project registration gives repository consent, and the harness's cloud flag limits execution to its cloud VM. Reading the native JSON avoids a second manifest parser. The hook changes no kendex arming record.

**Rejected**: Installing the session hook for every commit-guards consumer would reach repositories without committed consent. Requiring a local arming record in a fresh cloud clone would leave every commit without the git guard chain until a person or model ran setup.

**Revisit when**: Claude Code provides a per-session setup route with repository consent, changes the meaning of `CLAUDE_CODE_REMOTE`, or another harness needs this exception.
