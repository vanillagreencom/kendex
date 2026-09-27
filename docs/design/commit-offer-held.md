# Commit offer: packages that hold the commit

The commit offer in [post-refresh-commit-flow.md](post-refresh-commit-flow.md) is never made while a package's files in this repository would go out of date in the commit. This file is that precondition: how the offer reads it, and the state each surface draws in place of the commit choices.

## The reading

A package can declare an effect on files in the checkout, the way bot-instructions renders the review-bot files. A commit carries those files, and commit-guards' pre-commit chain runs `bot-instructions check --staged` wherever that package is installed. `commit_offer::stale` asks each such package before the commit is offered, where the set touches the package's own files or a path it declares it writes. The app, whose write-opened offer starts on this action's own paths, asks once for that commit and once for every pending change, and holds only the one picked. An older pending change to a package's files holds only the commit the package's check fails over: the commit that carries it, where the package is not set up here or its files are out of date, and the commit that leaves it out, where the check over that commit fails. An effect inside `.git` is out of scope: a commit carries none of those files.

The working-tree check answers for the files on disk. The pre-commit chain's check answers for the commit, rendering from what the commit holds. So where a set-up package's check passes over the working tree, `commit_offer::stale` asks it again over the commit itself. It builds a candidate index: a temporary index file, in a directory of its own under the git directory, holding the last commit with the carried paths over it. That is the index `git commit --only` and kendex's region commit hand their hooks, written by the code the region commit writes its own with. The declared checker runs with `--staged` and `GIT_INDEX_FILE` naming that index, the way commit-guards' pre-commit lane runs `bot-instructions check --staged`. The repository's own index is never written, and the candidate is removed when the reading ends, whichever way it ends.

A check that passes over the commit leaves it on offer, whatever else changed in the manifest or the inventory. One that exits 1 there holds the commit as split: it carries the package's files without a changed input they were rendered from. The hold names the changed inputs the commit leaves out, then the check's words over it. Those inputs are the package's own paths under its tree or its declared writes, the manifest wherever git reports it changed or deleted, which kendex never commits, and the inventory `.kendex-generated.json` where it changed and is not carried. bot-instructions renders from the manifest's `[install] harnesses` and `[bot-instructions]` table and from the skill trees the inventory lists, so an edit the render does not read, such as a `[skills.*]` row's `source`, keeps the commit, and `harnesses` gaining a harness whose render root holds a tracked tree holds it. No setup clears a split; the way on is Leave, and the person commits the files together. The cost is one index build and one more package check per commit scope, only where a set-up package the commit touches passes its working-tree check: up to two for the app's write-opened offer, one for the terminal's.

| Standing | How kendex reads it | Why named |
| --- | --- | --- |
| Declares no installer | Its declaration; no setup could clear a hold | not named |
| Not set up here | No arming record for this checkout; no package code runs | `not set up in this checkout` |
| Set up, its check exits 1 | The declared checker over the working tree, licensed by the record | `out of date`, with the check's words |
| Set up, its check could not answer | The declared checker, over the working tree or over the commit, exits above 1 or does not run | `could not say`, with its words or why |
| Set up, its check exits 0 over the working tree and 1 over the commit | The declared checker with `--staged` over the candidate index | `check over the commit`, with the changed inputs left out and the check's words |
| Set up, its check exits 0 over both, or it declares none | The declared checker | not named |

Each named package comes with its disclosure from `repo_effects::offers_for`, the block every other setup's yes is given against: what it changes, what it writes, its companions, its notes, and how to undo it. The setup choice runs each named package's declared installer, the same run the package page makes, then reads the project again against the reading the offer was scoped to, and each package is asked again. Only the renders kendex reads back join the set: today bot-instructions', through `bot_instructions::add_to_generated`, its own dry run naming each file and owned region. No other package's declared writes are carried: bot-instructions declares `AGENTS.md`, where kendex owns one region, so carrying a declared write whole would commit the person's bytes. One setup per offer. A package still named after its own setup ran ends the offer with nothing committed, its fresh words shown.

A linked work tree reads its own arming record, never its main checkout's: the work tree's copy of the package is the code a record there would license. Where the main checkout set a checkout effect up, the skipped-render line names the main checkout, and the CLI prints the package's disclosure and asks at the same point whether to set the package up in this work tree too.

## CLI

The block replaces the commit choices:

```
/home/method/dev/site: 90 files kendex wrote are not committed
  bot-instructions is not set up in this checkout, so its files in this repository were not brought up to date
  committing now would carry those files out of date, so kendex does not offer the commit

bot-instructions changes how this repository works, beyond the files above:
  Renders the enabled review-bot instruction files, the pointed code-review file and the owned Code Review Rules region in this repository.
  …the rest of the disclosure, as the repository-effects block prints it…

  1  set up bot-instructions here, then offer the commit with its files
  2  leave them as diffs
1-2, or Enter to leave them as diffs:
```

After a setup that leaves the package still named, the block is printed again with the package's fresh words and ends on `it is still not ready after its setup ran; nothing was committed`, exit 1. A split prints `the commit would carry some of bot-instructions's changed files and leave these out:` over the changed inputs left out, or, with none of kendex's left out, `… and leave out a change they were rendered from`, then `bot-instructions's check over the commit says:` over its words. It ends on `they are left as diffs; commit them together yourself`, with no setup offered and no question asked; a flag's run exits 1. With no terminal, or a flag naming a commit, the block ends on `set it up here first: at a terminal, where kendex offers it, or with Set up on its package page in the app`. A flag's run exits 1, `not committed`.

## App

The held state is drawn in place of the offer state.

| Element | Copy |
| --- | --- |
| Title | `12 files kendex wrote in site are not committed` |
| Description | `Committing now would carry those files out of date, so kendex does not offer the commit.` |
| Section heading | `Not ready to commit` |
| Per package | `bot-instructions is not set up in this checkout, so its files in this repository were not brought up to date.`, `… says its files in this repository are out of date.` or `… could not say whether its files in this repository are up to date.`, the check's words under it, then the disclosure block the repository-effects dialog draws; a split package's line is below |
| Section heading | `Files` |
| Footer, outline | `Leave as diffs` |
| Footer, primary | `Set up bot-instructions here`; `Setting up…` while it runs |

A split package's line is `bot-instructions's check fails over this commit, which carries some of its changed files without a change they were rendered from. The changes it leaves out, then the check's words, are below. They belong in one commit: leave them as diffs and commit them together.`, those lines under it, with no disclosure, and the footer carries `Leave as diffs` only: no setup clears it. A setup whose installer, or the read after it, fails ends in `The setup did not finish` with the words, and `Leave as diffs` only. A setup that ran and leaves a package still named ends in `Set up, and still not ready to commit`, described `The setup ran, and kendex still does not offer the commit. Nothing was committed.`, with each package's line and fresh words, and `Leave as diffs` only.
