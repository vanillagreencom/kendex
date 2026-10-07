---
name: screenshots
description: "Load to capture, compare or attach app screenshots for a pull request."
summary: "Captures each screen a change touches at the fixed sizes, compares them with the base branch, and attaches the pairs to the pull request."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.0.0"
tags: [review]
---

# Screenshots

```bash
.agents/skills/screenshots/scripts/shots capture --screen <name>   # one screen at every size in sizes.conf
.agents/skills/screenshots/scripts/shots compare --against main    # pairs under tmp/shots/
.agents/skills/screenshots/scripts/shots attach <pr>               # the pairs, in one comment
```

- Capture every screen the diff touches; `shots screens --diff` lists them from the changed files.
- Compare before attaching. A pair that differs by less than `SHOTS_NOISE_PCT` is not attached.
- Never capture against a real account; `shots capture` runs against the fixture account only, and refuses any other.
- Sizes are `sizes.conf`. Add a size there, never on the command line.

## Workflows

| Workflow | Trigger |
|----------|---------|
| `workflows/review-pass.md` | A pull request changes a screen |

---

## Not this

> ## Why fixed sizes
>
> We tried letting each author pick sizes in July, and reviews disagreed about whether a layout broke. The 1.2 release fixed three sizes in `sizes.conf` (see LUM-880) and ...

Rationale and history stay in context once the skill loads; the reason goes in a decision record or a comment at `sizes.conf`, and the rule stays here.
