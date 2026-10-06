# A package that changes a repository runs under a licence

Read before changing repository effects, the arming record, a package's declared checks, or the hold on the commit offer.

## The approach

A package may declare, in its `SKILL.md` frontmatter, an effect on files in the checkout beyond its own render: the review-bot instruction files the bot-instructions package writes, the git hooks commit-guards arms. kendex locates the package, runs its declared installer, checker and uninstaller, and surfaces their results; it judges no part of the package's grammar. Package code runs only under a licence: the arming record kendex writes in the git directory, which git clones for nobody, a person pressing the control that asks, or an invocation that asks for the one run itself and records nothing, `kendex bot-instructions-render`, which a consumer refresh run makes in the checkout it creates for that run. Commits walk through the commit-guards package's committed scripts whatever tool makes them; kendex implements no check of its own and `kendex check` relays the package's verdict.

## Why

A package is catalog content, and catalog content runs nothing until a person on this machine said so. One licence per checkout, in a place a clone does not carry, is what makes "set up here" a local decision that a pull request cannot make for the next clone. The refresh run's render needs no person because it licenses no person's machine: the runner's checkout is created and discarded per run, only the default branch reaches the kendex environment under [D003](../decisions/D003-one-merge-path.md), the run refuses a default branch that moved from the base it pinned, the package renders only where that checkout's manifest declares `[bot-instructions]`, and the render runs with no credential. Leaving the grammar to the package keeps kendex from carrying a second copy of each package's rules that drifts from the first.

## Rules

- Do run a declared installer, checker or staged checker as declared, with no argument added, and only where the arming record licenses it or the invocation asks for that run itself; an apply, refresh or check in a checkout with no record runs no package code and names the setup step.
- Do run the bot-instructions renderer after a project apply, an empty plan included, and carry the surfaces it reports into the same action's commit offer, never a later one.
- Do ask each armed package whether the commit the offer would make carries its files stale, through its staged checker over a candidate index that never touches the repository's own index; a failing answer holds the commit and offers the setup, per [commit-offer.md](commit-offer.md).
- Do splice an owned `AGENTS.md` region with the byte bounds the package's parser supplies, so every other byte of the file stays as the person left it.
- Do keep the arming record per work tree: a linked work tree whose main checkout armed the package names that checkout in its skip line and is offered the setup in one step.
- Do render bot-instructions in a consumer refresh run, `skills/review-gate/scripts/refresh-consumer.sh`, through `kendex bot-instructions-render` after staging the refresh, under `env -i` with no credential; the verb locates the installed copy wherever the install put it, writes no record, and relays the package's answer, so an unconfigured or absent package is a skip line the run prints (`skills/review-gate/tests/refresh-consumer.test.sh`, `crates/cli/tests/bot_instructions_render.rs`).
- Never run package code from a session hook or a check that could reach a repository the person has not armed, and never read the record from a clone.

## The canonical example

`crates/core/src/repo_effects/`: the declaration reader `declaration.rs` names every key a package may declare, `setup/` writes and reads the arming record, and `crates/core/tests/bot_instructions_refresh.rs` plants an unarmed doctrine change and watches the commit held. A new effect adds a key to the reader before any catalog declaration uses it.
