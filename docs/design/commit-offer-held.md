# Commit offer: packages that hold the commit

The commit offer in [post-refresh-commit-flow.md](post-refresh-commit-flow.md) is never made while a package's files in this repository would go out of date in the commit. This file is that precondition: how the offer reads it, and the state each surface draws in place of the commit choices.

## The reading

A package can declare an effect on files in the checkout, the way bot-instructions renders the review-bot files. A commit carries those files, and commit-guards' pre-commit chain runs `bot-instructions check --staged` wherever that package is installed. `commit_offer::stale` asks each such package before the commit is offered, where the set touches the package's own files or a path it declares it writes. The app, whose write-opened offer starts on this action's own paths, asks once for that commit and once for every pending change, and holds only the one picked. Under the package's check, not set up or out of date, an older pending change to a package's files holds only the commit that carries it; a commit carrying some of a package's changed paths is held by the split rule below even when the older change is the part it leaves out. An effect inside `.git` is out of scope: a commit carries none of those files.

A commit never splits a package's pending paths. One that carries any of a package's changed paths while leaving another out is held, however the package stands. The paths left out can be under the package's tree or its declared writes, the manifest wherever git reports it changed or deleted, which kendex never commits, or the inventory `.kendex-generated.json` where it changed and the commit leaves it out. A package renders from the whole manifest and from the inventory: bot-instructions takes its exclusion globs from the manifest's `[install] harnesses` and from the skill trees the inventory lists. The repository's check renders from what the commit holds, so it would compare the carried files against inputs left behind. No setup clears this; the way on is Leave, and the person commits the files together. This rule is also what lets the working-tree check below stand for the staged one: with every changed input carried, the tree the check reads is the tree the commit holds. A candidate index, a temporary index built from the commit's paths and checked with `check --staged`, would judge the commit directly. It was not built: it runs a second package check per scope on every offer and needs its own index lifecycle, where this rule is one pass over paths already read.

| Standing | How kendex reads it | Why named |
| --- | --- | --- |
| Splits the package's changed paths | Its paths in the set against the commit's, the manifest's and the inventory's git status | `changed files and leave these out`, with the paths |
| Declares no installer | Its declaration; no setup could clear a hold | not named |
| Not set up here | No arming record for this checkout; no package code runs | `not set up in this checkout` |
| Set up, its check exits 1 | The declared checker, licensed by the record | `out of date`, with the check's words |
| Set up, its check could not answer | The declared checker exits above 1 or does not run | `could not say`, with its words or why |
| Set up, its check exits 0, or it declares none | The declared checker | not named |

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

After a setup that leaves the package still named, the block is printed again with the package's fresh words and ends on `it is still not ready after its setup ran; nothing was committed`, exit 1. A commit that would split a package's changed files names the paths left out and ends on `they are left as diffs; commit them together yourself`, with no setup offered and no question asked; a flag's run exits 1. With no terminal, or a flag naming a commit, the block ends on `set it up here first: at a terminal, where kendex offers it, or with Set up on its package page in the app`. A flag's run exits 1, `not committed`.

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

Where a package would have its changed files split, its line names the paths left out, with no disclosure, and the footer carries `Leave as diffs` only: no setup clears it. A setup whose installer, or the read after it, fails ends in `The setup did not finish` with the words, and `Leave as diffs` only. A setup that ran and leaves a package still named ends in `Set up, and still not ready to commit`, described `The setup ran, and kendex still does not offer the commit. Nothing was committed.`, with each package's line and fresh words, and `Leave as diffs` only.
