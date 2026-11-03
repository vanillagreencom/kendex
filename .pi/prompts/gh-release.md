---
description: Cut a kendex release through the app-deploy skill
argument-hint: "[patch|minor|major]"
---

Load the `app-deploy` skill at `.agents/skills/app-deploy/SKILL.md` and follow its `workflows/release.md` from step 1 through publication and follow-up. `$ARGUMENTS` selects an optional version bump. When it is empty, use the bump required by the pending program entries under `changelog.d/README.md` § Release standard.
