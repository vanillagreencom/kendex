---
description: Audit the Pi extension packages against npm, land their version bumps and tag them for publishing, through the npm-deploy skill
argument-hint: "[package-name]"
---
Load the `npm-deploy` skill (`.agents/skills/npm-deploy/SKILL.md`) and run its complete deployment pass. `$ARGUMENTS` is the skill's input: empty for every package, or one package name.
