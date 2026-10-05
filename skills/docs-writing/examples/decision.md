# Decision record

The file `docs/decisions/<ID>-one-dismiss-pattern.md`, with its INDEX row appended per the decider skill:

```markdown
# D012: One dismiss pattern for sheets, dialogs and toasts

[← Decision Index](INDEX.md)

**Date**: 2026-09-14
**Status**: Active
**Research**: LUM-233

**Decision**: Every sheet, dialog and toast closes through `dismiss()` in `ui/lib/dismiss.ts`, which owns Escape, the close control and the backdrop click.

**Why**: Three screens wired Escape by hand and two of them lost the backdrop click. One owner keeps the three ways to close in agreement, and a component that cannot call it cannot ship.

**Rejected**: Each component owning its close handling, with a lint rule for Escape. The lint cannot see a missing backdrop handler, so the two paths drift again.

**Revisit when**: A platform the shell draws on has a system dismiss gesture the shared owner cannot receive.
```

---

## Not this

```markdown
## Context

The dismiss question first came up in the 0.3 redesign (LUM-91), when the launcher's sheet closed on Escape but the notification centre's did not. In 0.4 we added `onEscape` to `Sheet` (LUM-140), then ...

## Appendix A: every component audited

| Component | Escape | Backdrop | Close control | Fixed in |
|---|---|---|---|---|
| `Sheet` | yes | no | yes | LUM-233 |
| `Dialog` | yes | yes | yes | |
```

An audit table and a history record what was done, which git history already holds; the reader came for the choice, its reason and when to reverse it.
