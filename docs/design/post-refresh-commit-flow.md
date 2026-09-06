# Post-refresh commit flow

The design KEN-1027 builds. It fixes every state of the commit, push and pull-request offer that follows a kendex write in a git project, on both surfaces, and the exact words each state prints or draws. Nothing here is left to the implementer to word.

## What the offer is

kendex writes files into a git project's checkout, and a project commits those files so that a clone works without kendex. A write therefore leaves changes git can see. The offer is the step that asks what to do with them: commit them, commit and push them, commit them on a branch and open a pull request, or leave them as diffs.

The offer runs after the write, never before it, and never as part of it.

## Contract

- The offer is explicit. kendex commits, pushes or opens a pull request only after a person chose that in this run. There is no setting, flag or state that makes any of the three happen without a choice.
- Leaving the files as diffs is a choice of the same standing as the other three. It is the default answer on both surfaces, and taking it is a success, not a refusal.
- kendex stages only the files it owns whole. A file the person wrote is never staged and never committed.
- A file kendex owns one key in is not a file it owns whole. kendex does not commit one, because it cannot commit its own key without committing whatever else the person changed in the same file. It names those files and leaves them.
- The commit runs through `git commit`, so the repository's own hooks run on it.
- A refusal from git, from a hook, or from `gh` reaches the person in that program's own words, whole.
- kendex never undoes. It does not revert a commit, does not move a branch ref backwards, does not reset, and does not stash.
- kendex asks at most once per run per project.

## The path set

The offer covers the files kendex owns whole in this project that git reports as changed.

`crates/core/src/engine/generated_paths.rs` already collects the paths kendex generates, for the `.kendex-generated.json` inventory that CI reads. Its collection is the right one, so the offer takes it rather than building a second.

That collection is inline in `generated_paths::plan` today and returns nothing. KEN-1027 lifts it into a function of its own that returns the paths in two groups, the files kendex owns whole and the shared `edits` targets, and makes it reachable outside the `engine` module. `plan` keeps writing the union of both groups, so **`.kendex-generated.json` does not change**: CI still reads every path kendex touches, edit targets included. The offer takes the whole-file group only. Both surfaces call that one function, so neither can answer differently.

- Take the paths that collection gathers: each item's `Artifact::File` path, an `Artifact::Tree`'s files and link, an `Artifact::Registration`'s `script` path where it has one, and the instruction shims. In-place sources and items whose drift row is `Conflict` or `Unmanaged` are already out, because that collection drops them and kendex writes nothing for them.
- Exclude every `Artifact::Registration` `edits` target. Those are shared configuration files kendex writes one key in, and `crates/core/src/engine/desired.rs` states the reason it edits rather than renders them: every unrelated key in them stays intact. `.claude/settings.json`, `.codex/config.toml` and `.codex/hooks.json` are edit targets in this repository, and `.claude/settings.json` also holds the person's own `permissions.allow`. git has no way to commit one key of a file, so committing such a path would commit the person's edits with kendex's. They get the block **Shared files** below instead.
- Add the paths in `.kendex-generated.json` at `HEAD` that git reports as **deleted** and that the collection no longer gathers. Those are a sweep's removals, and the deletion is part of the same change. Only deleted ones: a path that left the inventory but still exists on disk left it for another reason, most often a person's hand edit putting the item in `Conflict`, and that file is the person's to commit.
- An unborn `HEAD`, in a repository with no commit yet, contributes nothing here.

git decides what changed, in one call over the whole checkout: `git status --porcelain=v1 -z --untracked-files=all`. `git status` takes no `--pathspec-from-file`, and a pathspec argument per path would not fit a Windows command line, so the call is unscoped and kendex matches its rows against the set itself. `-z` because a path may hold any byte but NUL. `--untracked-files=all` because a first install writes into directories git has not seen.

That one call answers three questions at once.

| Rows | Meaning |
| --- | --- |
| In the set | The offer's paths |
| An excluded `edits` target | The **Shared files** block |
| Everything else | The person's own changes, which the offer counts and never touches |

The set is re-derived immediately before the commit runs. A path that no longer differs is dropped. When none is left, the action reports that nothing was committed and the run ends without a commit.

`kendex.toml` is the person's file and `.kendex-lock.json` is this machine's install ledger. Neither is in the collection, so neither is ever in the set.

## Where the offer runs

The offer belongs to a project scope. The global scope is not a checkout and is never offered.

On the CLI it is one call in each verb that applies a plan into a project scope, made once for that scope, after the verb's blocks and before that scope's closing ledger line. It runs for every project scope the run reached, whether the run is about to succeed or about to report failures: a verb that wrote and then failed left the same diffs behind as one that wrote and succeeded. A cancel is the exception and skips it, because a cancelled scope wrote nothing.

Two verbs need naming because they sit at the edges of that rule.

- `kendex drift-hook` offers like the rest. It is a person-run installer that prints, asks two confirmations and takes `--yes`, and it applies a plan that renders hook scripts into the checkout. The thing that runs inside another tool's session is the installed script, which invokes `kendex check --quiet`; that applies no plan and so never reaches the offer.
- `kendex update-pi` writes into a project's `.pi` directory without going through `apply_report`, so the seam above does not reach it. It calls the offer itself, at the end of its run, exactly as the verbs on that seam do.

A verb that writes nothing into a project checkout never reaches the offer, and the empty path set answers for it in any case: `kendex update` replaces the app from the release feed, and `kendex init` scaffolds a catalog item in the working directory.

In the app the offer is enqueued by one exported function in `ui/src/lib/rescan.ts`, taking the project roots the write could reach. `writingRepo` calls it, and so does every write that spells `rescanEverything` out for itself rather than running inside `writingRepo`. That file's own header names those, and each is a project-scope apply that renders files into a checkout.

| Call site | Function |
| --- | --- |
| `ui/src/lib/rescan.ts` | `writingRepo` |
| `ui/src/stores/updates.ts` | `updateOne`, `updateRows` |
| `ui/src/stores/updates-edits.ts` | `run` |
| `ui/src/stores/updates-follow.ts` | `followSwitch` |
| `ui/src/components/package/package-version-actions.ts` | `afterChange` |

Those six are the whole set, and `rescan.ts`'s header is where that is established. The Updates page's Update button is the app's most common write and reaches the offer through `updateOne`.

## Preconditions

Each row removes something from the offer. Rows apply together.

| Condition | How kendex reads it | Effect |
| --- | --- | --- |
| Scope is global, or the project has no `.git` | `Scope::Project` and `root.join(".git").exists()` | No offer, no line |
| The path set is empty | The set derivation above | No offer, no line |
| `commit-offer` is `off` | `AppSettings` | No offer, no line. A flag still answers: the setting turns off the asking, not the choices |
| HEAD is detached | `git symbolic-ref --quiet HEAD` exits non-zero | No offer, one line |
| A merge, rebase, cherry-pick or bisect is in progress | `MERGE_HEAD`, `REBASE_HEAD`, `rebase-merge/`, `rebase-apply/`, `CHERRY_PICK_HEAD` or `BISECT_LOG` in the git directory | No offer, one line |
| CLI has no terminal on stdin | `std::io::stdin().is_terminal()` | No offer, one line naming the flags |
| No remote can be chosen | The rule below | Offer without push and without pull request, a reason named for each |
| The `gh` probe failed | The probe below | Offer without pull request, the reason named |

The remote is chosen by rule, never by a prompt: the current branch's upstream remote; else `origin`; else the only remote when the project has exactly one; else none, and push and pull request are unavailable.

### The `gh` probe

The pull-request choice needs three things at once: `gh` on the machine, a credential it will use, and a remote it recognises as a GitHub repository. One command answers all three, and answers a fourth question the offer asks anyway:

```
gh pr list --head <branch> --state open --json number,url
```

- It fails to spawn: `gh` is not installed.
- It exits non-zero saying it is not authenticated: `gh` is not signed in.
- It exits non-zero saying no remote points at a known GitHub host: this project is not on GitHub, which is the answer for a GitLab, a Gitea or a local-path remote.
- It exits zero: the pull-request choice stands, and the rows it returned say whether one is already open for this branch.

The reason a surface prints is `gh`'s own first line, so a case nobody anticipated still names itself rather than reading as one of the three above. The probe runs only where a remote was chosen, so a project with no remote pays no network call for it. It is bounded at 15 s, in the timeouts table.

kendex runs no separate credential check. `gh auth token` would print the token on a pipe kendex captures, and a probe that does real work answers the same question without one.

kendex does not ask GitHub whether a branch is protected. That answer needs a permission the person may not hold, and a wrong claim would take away a choice they do have. A protected branch is named by the remote's own refusal when the push runs.

## The four choices

| Id | CLI label | App segment | App button | What runs |
| --- | --- | --- | --- | --- |
| `commit` | `commit them` | `Commit` | `Commit` | the commit sequence below |
| `push` | `commit them and push to <remote>/<branch>` | `Commit and push` | `Commit and push` | the commit, then `git push <remote> <branch>`, with `--set-upstream` where the branch has none |
| `pr` | `commit them on a new branch and open a pull request` | `Pull request` | `Open pull request` | `git switch -c <branch>`, the commit, `git push --set-upstream <remote> <branch>`, `gh pr create --head <branch> --base <base> --title <message> --body <body>` |
| `leave` | `leave them as diffs` | not a segment | `Leave as diffs` | nothing |

The commit sequence is `git add` over the set's untracked members, then `git commit --only` over the whole set. Its behaviour is in **How the commit is made** below.

The `pr` choice switches the checkout to the new branch before it commits, so the branch the person was on gains no commit and needs nothing undone. The checkout is left on the new branch, and both surfaces say so before the choice is taken.

The new branch is `kendex/renders`, or the first free `kendex/renders-2`, `kendex/renders-3` and so on. Free means no local ref and no remote-tracking ref for the chosen remote already carries the name, both read from this repository with `git show-ref`. kendex runs no `git ls-remote`: it is a network call before a choice has even been made, and a name only the remote knows about surfaces as a refused push, which already has its own state. The refused-push recovery below picks its branch by the same rule.

The base of the pull request is the branch the checkout was on when the offer was made.

Where an open pull request already exists for the current branch, `push` reads `adds a commit to pull request #<n>` in place of `push to <remote>/<branch>`, and `pr` is not offered: the branch already has one. kendex reads this with `gh pr list --head <branch> --state open --json number,url`.

### When a step of the `pr` route fails

The `pr` route runs four steps and any of them can fail. Each has its own answer, because the checkout is in a different place after each.

| Step that failed | State | What kendex does |
| --- | --- | --- |
| `git switch -c` | The checkout has not moved, nothing is staged | Report it, offer `commit`, `push` and `leave` again, without `pr` |
| The commit | The checkout is on the new branch, which carries no commit of its own | Unstage what kendex staged, `git switch -` back, `git branch -d <branch>` to remove the empty branch it made, then show git's words and ask again |
| The push | The commit is on the new branch | Report it, and offer only `leave it here`: the branch and the commit are both local, and the recovery for a refused push is to make a branch, which is already done |
| `gh pr create` | The commit is on the new branch and the branch is on the remote | Report it and name the branch, so the person can open the pull request themselves |

Removing an empty branch kendex made a moment earlier is kendex clearing its own leftover, the same as unstaging its own `git add`. It is not an undo: no commit exists to undo, and no branch ref moves backwards. A `git switch -` or `git branch -d` that fails is reported and the run stops there rather than trying anything else.

## How the commit is made

`git commit --only -- <paths>` is a partial commit. Five of its behaviours decide the design, and each is what git does today.

- It refuses a path git does not track: `error: pathspec '<path>' did not match any file(s) known to git`. A first install writes paths git has never seen, so kendex stages those first with `git add`. **Untracked** here means exactly a `git status` row beginning `??`. A path the person already staged is not one, so kendex neither adds nor unstages it.
- It commits the working tree's content for the named paths, not the index's. A person who staged an older copy of a render path gets the copy kendex wrote, which is the one on disk.
- It commits a deletion of a named path that is gone from the working tree, which is how a sweep's removals land.
- It builds a temporary index and exports it to the hooks as `GIT_INDEX_FILE`. A hook running `git diff --cached` sees the named paths and nothing else, and the person's own staged changes to other paths are neither seen by the hook nor committed. A refused commit leaves those staged changes exactly as they were.
- It commits the whole of each file it names. There is no way to commit part of one, which is why the shared `edits` targets are out of the set.

### Passing the paths

The set runs to a thousand paths in a large project, about 58 KB of path text in this repository. Windows caps a command line at 32,767 characters and kendex supports Windows, so no step passes the set as arguments.

kendex writes the set to a file in the system temp directory, NUL-separated, and passes `--pathspec-from-file=<file> --pathspec-file-nul` to `git add`, `git commit` and `git reset`. All three take it. The file is removed when the step ends. It is outside the checkout, so it is never a path the offer could then find.

`git status` takes no such option, which is why the status call is unscoped and filtered in kendex instead.

### What a refusal leaves behind

The one mark the sequence leaves is the `git add` above: a path that was untracked stays staged. kendex unstages exactly the paths it staged, so the index ends as it began.

It unstages with `git reset -- <paths>`, not `git restore --staged`. `git restore --staged` resolves `HEAD` and exits 128 with `fatal: could not resolve 'HEAD'` in a repository with no commit yet, which is the state a first `kendex` write in a fresh `git init` reaches whenever a hook refuses that first commit. `git reset` works there and on a born `HEAD` alike.

## The message

The default message is `chore: kendex <command>`, where `<command>` is what the person typed, without its flags and arguments: `chore: kendex refresh`, `chore: kendex marketplace subscribe`, `chore: kendex source add`. A subcommand is named with its group, because the group alone is not a command anybody can run. A verb that delegates to another names itself, not the one it called: `kendex updates` runs `refresh`'s plan and its message says `updates`, because that is what the person ran. The message has no body.

The rule is the command, not a list, so no enumeration can fall out of date as the command surface changes.


The message is editable on both surfaces before the commit runs, because a repository's commit-msg hook decides what it will accept and kendex cannot know that rule.

The pull request's title is the message. Its body is two lines: `kendex wrote these files.` and `Files: <n>`.

## Timeouts

| Step | Bound | Reason |
| --- | --- | --- |
| Every git read: status, branch, remote, refs | 10 s | A local read that takes longer is a broken checkout |
| Every other local git command: `add`, `reset`, `switch`, `branch` | 30 s | Local writes over the set, with no hook to wait on |
| `git commit` | 300 s | A repository's own pre-commit hook can run a test suite, and a shorter bound would kill a hook that was working |
| `git push` | 120 s | `process::DEFAULT_TIMEOUT` |
| The `gh` probe | 15 s | It runs before the offer is drawn, so a person is waiting on it with nothing on screen |
| `gh pr create` | 120 s | `process::DEFAULT_TIMEOUT` |

A step that times out is reported as that step's failure, naming the step and the bound. `Hardened::scrub_git_redirects` already sets `GIT_TERMINAL_PROMPT` to `0` for every git call, so a push needing a credential fails with git's own words instead of waiting on a terminal nobody is watching.

## Surfacing a refusal

- git puts a hook's own output on git's stderr, both halves of it, and prints nothing on its stdout when a hook refuses. So stderr is what carries the words, and it is shown whole, one line at a time, in order. Where the program also wrote to stdout, as `gh` does for some diagnostics, that follows.
- Each line goes through the surface's escaping: `ui::say` on the CLI, React text on the app. A control character in a hook's output must not move a cursor or colour a line.
- Nothing is summarised, reworded, truncated to a first line, or matched against a pattern to decide what it means.
- No output cap. `Hardened::max_output` refuses the whole call when the cap is passed, and its error carries none of what the program said, which would lose exactly the words the contract promises. A hook's output is bounded by the hook, and no cap is worth a refusal that says nothing.

## CLI

The head line carries the scope label, as `print_set_changes` and the ledger do. Detail is indented two spaces. Ten paths are listed, then the overflow line the CLI already uses for a list it cut: `  … and {n} more`, from `engine_common.rs`, whose `UNMANAGED_SHOWN` is the same ten.

```
/home/method/dev/site: 12 files kendex wrote are not committed
  .claude/CLAUDE.md
  .claude/skills/dev/SKILL.md
  .claude/skills/dev/workflows/dev-fix.md
  .claude/skills/dev/workflows/dev-implement.md
  .claude/skills/reviewer/SKILL.md
  .codex/skills/dev/SKILL.md
  .codex/skills/dev/workflows/dev-fix.md
  .codex/skills/dev/workflows/dev-implement.md
  .codex/skills/reviewer/SKILL.md
  .kendex-generated.json
  … and 2 more
  kendex also changed 2 shared files; it writes one key in each, so
  committing them would commit your own changes to them too
    .claude/settings.json
    .codex/config.toml
  4 other files in this repository changed; kendex leaves those alone
  1  commit them
  2  commit them and push to origin/main
  3  commit them on a new branch and open a pull request
  4  leave them as diffs
1-4, or Enter to leave them as diffs:
```

The choices are numbered in the order above, skipping the ones the preconditions removed, and renumbered so the printed numbers are contiguous. `leave` is always last and is always the default.

The answer is read with `ui::ask`, which returns the typed line. An answer that is not one of the printed numbers is `leave` — a typo, a `9`, an `x`, a bare Enter and an end of input alike. That is how `ui::confirm` already reads its answer, where everything but a typed yes is a no, and it puts the safe outcome behind every wrong key rather than behind a retry loop nobody asked for.


A precondition that removed a choice prints its reason as a detail line under the paths, before the numbered list:

```
  no push: this repository has no remote
  no push: this branch tracks no remote and the repository has more than one
  no pull request: this repository has no remote
  no pull request: this branch tracks no remote and the repository has more than one
  no pull request: gh is not installed
  no pull request: gh said: To get started with GitHub CLI, please run:  gh auth login
  no pull request: gh said: none of the git remotes configured for this repository point to a known GitHub host
```

The reader is asked for the message next, through `ui::ask`, where an empty answer accepts what is offered:

```
  message: chore: kendex refresh
press Enter to use this message, or type a different one:
```

The `pr` choice states what it moves before it runs, as the line above the message question:

```
  this checkout will move to kendex/renders; main stays where it is
```

Results:

```
  committed 12 files as 9fbb1a2
```

```
  committed 12 files as 9fbb1a2
  pushed to origin/main
```

```
  committed 12 files as 9fbb1a2 on kendex/renders
  pushed to origin/kendex/renders
  opened https://github.com/acme/site/pull/41
  this checkout is now on kendex/renders
```

A refused commit prints git's words and asks again. The words below are one repository's hook, shown to fix the shape and the indent, not to fix what any hook says:

```
  the commit was refused
  git said:
    commit-msg: crates/ changed without a changelog entry
      write one of: changelog.d/*/*.md
      or put [no-changelog] in the header when the commit changes nothing a consumer sees
  1  commit again with the same message
  2  commit again with a different message
  3  leave them as diffs
1-3, or Enter to leave them as diffs:
```

A refused push names what landed and what did not, and offers the way on:

```
  committed 12 files as 9fbb1a2
  the push was refused
  git said:
    remote: error: GH006: Protected branch update failed for refs/heads/main.
    remote: error: Changes must be made through a pull request.
    To github.com:acme/site.git
     ! [remote rejected] main -> main (protected branch hook declined)
  the commit is on main in this checkout; kendex did not undo it
  1  push the commit to a new branch and open a pull request
  2  leave it here
1-2, or Enter to leave it here:
```

That block is the `commit` and `push` routes. On the `pr` route the commit is already on the branch kendex made, so a refused push there offers only `leave it here`: the recovery below is to put the commit on a branch, and it is there.

Choice 1 pushes the commit that already exists rather than making a branch locally: `git push <remote> HEAD:refs/heads/<branch>`, then `gh pr create --head <branch> --base <current branch> --title <message> --body <body>`. `<branch>` is picked by the first-free rule above, so the push cannot fast-forward a branch somebody else named. The title and body are the ones the `pr` route uses: `gh pr create` with no terminal to prompt at refuses without them. The local branch is left carrying the commit, and the run says how to put it back without doing it:

```
  pushed to origin/kendex/renders
  opened https://github.com/acme/site/pull/41
  main in this checkout still carries the commit
  to put main back where it was, leaving the files as diffs again:
    git reset --mixed 4c1d90e
```

Where the push is refused and no pull request is available, the block ends after `kendex did not undo it` and asks nothing further.

A refused `gh pr create` names what landed:

```
  committed 12 files as 9fbb1a2 on kendex/renders
  pushed to origin/kendex/renders
  the pull request was refused
  gh said:
    GraphQL: GitHub Actions is not permitted to create or approve pull requests (createPullRequest)
  the branch kendex/renders is on origin; open the pull request yourself
```

The `pr` route's own failures, each ending the block:

```
  the branch could not be made
  git said:
    fatal: a branch named 'kendex/renders' already exists
  1  commit them
  2  commit them and push to origin/main
  3  leave them as diffs
1-3, or Enter to leave them as diffs:
```

```
  the commit was refused
  git said:
    commit-msg: crates/ changed without a changelog entry
  this checkout is back on main and kendex/renders is gone
  1  commit again with the same message
  2  commit again with a different message
  3  leave them as diffs
1-3, or Enter to leave them as diffs:
```

```
  committed 12 files as 9fbb1a2 on kendex/renders
  the push was refused
  git said:
    remote: Permission to acme/site.git denied to nobody.
    fatal: unable to access 'https://github.com/acme/site.git/': The requested URL returned error: 403
  the commit is on kendex/renders in this checkout; kendex did not undo it
```

### Timed out

A step that ran out of time reads as that step's refusal, with the bound in place of the program's words, and offers whatever that step's refusal offers:

```
  the commit did not finish within 300 seconds
  1  commit again with the same message
  2  commit again with a different message
  3  leave them as diffs
1-3, or Enter to leave them as diffs:
```

The other three read `the push did not finish within 120 seconds`, `the pull request did not finish within 120 seconds`, and, for a step from the 30 second row, `<step> did not finish within 30 seconds`.

The single lines the preconditions print, each on its own with the scope label:

```
/home/method/dev/site: 12 files kendex wrote are not committed; this checkout is on no branch
/home/method/dev/site: 12 files kendex wrote are not committed; a rebase is in progress
/home/method/dev/site: 12 files kendex wrote are not committed; run again with --commit, --push, --pull-request or --leave
```

The in-progress line names the operation it found: `a merge`, `a rebase`, `a cherry-pick`, `a bisect`.

### The closing ledger

The ledger gains one part, after the write count and before the skipped and flagged parts.

| Outcome | Part |
| --- | --- |
| `leave`, or no offer | none |
| `commit` | `committed 12 files` |
| `push` | `committed and pushed 12 files` |
| `pr` | `committed 12 files, pull request open` |
| Commit refused | `not committed` |
| Push refused | `committed, not pushed` |
| Pull request refused | `committed and pushed, no pull request` |

No next-step line is added under any of them: the block above already carries the words and the way on, and the ledger's own rule is that a part points back at a block the run printed.

### Flags and exit codes

`--commit`, `--push`, `--pull-request` and `--leave` are one mutually exclusive group on every verb that offers, flattened from one shared clap `Args`. `--message <text>` sets the message. Two of the group together is refused before the verb writes anything, naming both.

A flag answers the offer without asking. A precondition that removed the choice a flag names refuses with that precondition's reason, and the verb's writes still stand.

| Outcome | Exit |
| --- | --- |
| `leave`, or no offer | the verb's own code |
| Commit, push or pull request went through | the verb's own code |
| A choice the person took was refused or timed out | 1 |
| Ctrl-C at the offer | 130, through `ui::cancelled` |

A cancel at the offer is not the cancel `refresh.rs` already handles. That one is a cancel at the write confirm, and it drops the scope from the reached list on the ground that the scope wrote nothing. A cancel at the offer comes after the write: the scope keeps its place on that list, so its snapshot is still recorded and its closing ledger line is still printed. Only the offer is skipped.

A refused commit, push or pull request is its own failure line and is not counted into `failed to refresh <n> item/source(s)`.

## App

One dialog, `CommitOfferDialog`, rendered once in `App.tsx` beside `RepoEffectsDialog`, driven by a store holding a queue of one entry per project. Every string lives in `ui/src/lib/copy-commit-offer.ts`, the way `copy-repo-effects.ts` holds the repository-effects wording.

Dismissing the dialog is leaving the files as diffs, the same as `RepoEffectsDialog` treats dismissal as declining.

Every value in the copy below is of the moment. `12`, `4`, `site`, `origin`, `main`, `kendex/renders`, `9fbb1a2` and `#41` stand for the count, the other count, the project's folder name, the remote, the current branch, the new branch, the commit and the pull request number. Each is an argument to the copy function that composes the string, the way `repoEffectsTitle` takes a package name. The CLI copy above uses the same values for the same reason.

### Offer state

| Element | Copy |
| --- | --- |
| Title | `kendex changed 12 files in site` |
| Description | `These are the files kendex writes in this repository. Nothing is committed yet.` |
| Section heading | `Files` |
| Section heading, only where kendex changed a shared file | `Shared files` |
| Under that heading | `kendex writes one key in each of these. Committing them would commit your own changes to them too, so kendex leaves them to you.` |
| Section heading, only where the person's files changed | `Other changes` |
| Under that heading | `4 other files in this repository changed. kendex does not commit these.` |
| Section heading | `What to do` |
| Segments | `Commit`, `Commit and push`, `Pull request` |
| Under the segments, for `Commit` | `The commit stays in this checkout.` |
| Under the segments, for `Commit and push` | `Pushes to origin/main.` |
| Under the segments, for `Commit and push`, with a pull request open | `Adds a commit to pull request #41.` |
| Under the segments, for `Pull request` | `Commits on kendex/renders and opens a pull request. This checkout moves to that branch. main stays where it is.` |
| Section heading | `Message` |
| Footer, outline | `Leave as diffs` |
| Footer, primary | `Commit`, `Commit and push`, `Open pull request` |

The `Files` list is monospace, one path per row, in a scroll area, showing every path. `Shared files` and `Other changes` are the same list at `text-muted-foreground`. Paths are printed whole: an abbreviation guesses at a directory and names a different file from the one being committed.

`Message` is a single-line input prefilled with the default message. It is never emptied by a refusal.

A segment a precondition removed is not rendered. Its reason is a labelled row under the segments, never loose text:

| Row label | Row value |
| --- | --- |
| `Push` | `This repository has no remote.` |
| `Push` | `This branch tracks no remote and the repository has more than one.` |
| `Pull request` | `This repository has no remote.` |
| `Pull request` | `This branch tracks no remote and the repository has more than one.` |
| `Pull request` | `gh is not installed.` |
| `Pull request` | `gh is not signed in. Run gh auth login.` |

Where every segment but `Commit` is gone, the segmented control is not drawn and the primary button reads `Commit`.

### Busy state

Both buttons are disabled. The primary button's label becomes `Committing…`, `Pushing…`, or `Opening the pull request…`, matching the step running. The dialog cannot be dismissed while a step runs: `git commit` is running the repository's hooks and closing the window would not stop them.

### Result states

| Outcome | Surface |
| --- | --- |
| `commit` went through | Toast `Committed 12 files`, dialog closes |
| `push` went through | Toast `Committed and pushed 12 files`, dialog closes |
| `pr` went through | The dialog's result state below |

A pull request that opened keeps the dialog, because its URL is worth a designed row rather than a toast that leaves.

| Element | Copy |
| --- | --- |
| Title | `Pull request open` |
| Row label, row value | `Commit`, `9fbb1a2 on kendex/renders` |
| Row label, row value | `Pull request`, the URL, as a link that opens in the browser |
| Line | `This checkout is now on kendex/renders.` |
| Footer, primary | `Done` |

### Refusal states

A refusal keeps the dialog open, at the point of the action.

Commit refused:

| Element | Copy |
| --- | --- |
| Title | `The commit was refused` |
| Section heading | `What git said` |
| Section body | git's words as **Surfacing a refusal** fixes them, monospace, in a scroll area |
| Section heading | `Message` |
| Footer, outline | `Leave as diffs` |
| Footer, primary | `Commit again` |

The `Files` and `Other changes` sections stay as they were, so the person can still see what the commit covers.

Branch not made, on the `pr` route:

| Element | Copy |
| --- | --- |
| Title | `The branch could not be made` |
| Section heading | `What git said` |
| Section body | git's words as **Surfacing a refusal** fixes them, monospace, in a scroll area |
| Line | `Nothing was committed and this checkout has not moved.` |
| Footer, outline | `Leave as diffs` |
| Footer, primary | `Commit` |

The `Pull request` segment is gone from that state, so the segmented control offers `Commit` and `Commit and push` only.

Commit refused on the `pr` route: the commit-refused state above, with one line added under its title, `This checkout is back on main and kendex/renders is gone.`

Push refused:

| Element | Copy |
| --- | --- |
| Title | `Committed, not pushed` |
| Row label, row value | `Commit`, `9fbb1a2 on main` |
| Section heading | `What git said` |
| Section body | git's words as **Surfacing a refusal** fixes them, monospace, in a scroll area |
| Line | `The commit is on main in this checkout. kendex did not undo it.` |
| Footer, outline | `Leave it here` |
| Footer, primary, only where a pull request is available | `Open a pull request` |

The branch in that state's rows is the branch the commit landed on. On the `pr` route that is `kendex/renders`, and `Open a pull request` is not offered there: the commit is already on a branch of its own, which is what the recovery would have made.

`Open a pull request` there runs the same recovery the CLI runs: it pushes the commit that exists to a new branch and opens the pull request, without moving the local branch. Its result state adds two rows to the pull-request result above:

| Element | Copy |
| --- | --- |
| Line | `main in this checkout still carries the commit.` |
| Row label, row value | `To put main back`, `git reset --mixed 4c1d90e`, monospace, with a copy button |

`--mixed` and not `--keep`, on both surfaces: `--keep` restores the working tree to the commit it resets to, which would take kendex's files off disk with no warning, and `--mixed` moves the branch and leaves them where they are, as the diffs the person started with. Neither surface runs the command; both print it.

Pull request refused:

| Element | Copy |
| --- | --- |
| Title | `Committed and pushed, no pull request` |
| Row label, row value | `Commit`, `9fbb1a2 on kendex/renders` |
| Row label, row value | `Branch`, `origin/kendex/renders` |
| Section heading | `What gh said` |
| Section body | gh's words as **Surfacing a refusal** fixes them, monospace, in a scroll area |
| Line | `The branch is on origin. Open the pull request yourself.` |
| Footer, primary | `Done` |

### Timed out

A step that ran out of time takes that step's refusal state, with two changes: the title's verb becomes `did not finish`, and the `What git said` or `What gh said` section is replaced by one line, because there are no words to show.

| Element | Copy |
| --- | --- |
| Title | `The commit did not finish`, `The push did not finish`, `The pull request did not finish` |
| Line, in place of the section | `kendex stopped waiting after 300 seconds. Whether it finished is not known here.` |

The bound in that line is the step's own, from the timeouts table. The footer is that state's footer unchanged: a step whose outcome is unknown is not one to report as done, and the person's ways on are the same ones the refusal offers.

### States with no offer

A dialog that offers nothing is a modal a person has to dismiss for no reason, so the app opens none. The two states where kendex owns changed files but cannot offer are flagged on that project's card in the Projects page, through `ProjectCard`'s existing `badge`, which already carries `Folder not found`.

| State | Badge | `title` |
| --- | --- | --- |
| Detached HEAD | `12 uncommitted` | `12 files kendex wrote are not committed. This checkout is on no branch.` |
| Merge, rebase, cherry-pick or bisect in progress | `12 uncommitted` | `12 files kendex wrote are not committed. A rebase is in progress.` |

`ProjectCard` renders its badge as `variant="destructive"`, which is right for its one caller today, `Folder not found`. Uncommitted files are not a fault, so the prop becomes a pair, the text and the variant, and this one passes `info`. `ProjectCard` also gains a `title` for the reason. The badge itself is short because the card's other badges are, and the reason is on hover, the way the app already hides a status word behind one.

### Settings

One `SettingRow` in a new `Section` on the Settings page, placed after `Appearance`.

| Element | Copy |
| --- | --- |
| Section title | `Git projects` |
| Label | `Offer to commit kendex's changes` |
| Description | `In a git project, ask what to do with the files kendex wrote.` |
| Control | A switch, on by default |

The switch writes `commit-offer` in `AppSettings`, which is machine-local, the same as every other field there: whether a person is asked is theirs, not their project's. The CLI reads the same field. Its two values are `ask` and `off`. There is no value that commits without asking, because the contract has none.

## State table

Every state, its detection, and where its words are.

| State | Detected by | CLI | App |
| --- | --- | --- | --- |
| Not a git project, or global scope | No `.git` under the project root | nothing | nothing |
| The verb failed after writing | The scope was reached and the set is non-empty | The offer, then the verb's own failure lines | The offer |
| Clean: nothing kendex owns changed | The path set is empty | nothing | nothing |
| Every written path ignored | Ignored paths never reach `git status` output | nothing | nothing |
| Offer turned off | `commit-offer` is `off` | nothing | nothing |
| Render-only dirty | Path set non-empty, no other path changed | The offer block, without the `4 other files` line | The offer state, without `Other changes` |
| Mixed dirty | Path set non-empty, other paths changed | The offer block with the `other files` line | The offer state with `Other changes` |
| kendex changed a shared file | A changed path is an `edits` target | The offer block with the shared-files lines | The offer state with `Shared files` |
| No remote | `git remote` empty | Offer, `no push` and `no pull request` reasons | Offer, `Push` and `Pull request` rows |
| Remote not decidable | Several remotes, no upstream, no `origin` | Offer, `no push` and `no pull request` reasons | Offer, `Push` and `Pull request` rows |
| `gh` missing | The probe fails to spawn | Offer, `no pull request: gh is not installed` | Offer, `Pull request` row |
| `gh` not signed in | The probe exits non-zero | Offer, `no pull request` with gh's first line | Offer, `Pull request` row with gh's first line |
| The remote is not on GitHub | The probe exits non-zero | Offer, `no pull request` with gh's first line | Offer, `Pull request` row with gh's first line |
| Pull request already open | The probe returns a row | `push` reworded, `pr` not offered | `Commit and push` reworded, `Pull request` segment absent |
| Detached HEAD | `git symbolic-ref --quiet HEAD` non-zero | One line | Project card badge |
| Merge, rebase, cherry-pick, bisect | The marker files in the git directory | One line | Project card badge |
| No terminal | `stdin().is_terminal()` false | One line naming the flags | not reachable |
| Commit refused | `git commit` exits non-zero | git's words, then three choices | `The commit was refused` |
| Branch not made, `pr` route | `git switch -c` exits non-zero | git's words, then the choices without `pr` | `The branch could not be made` |
| Commit refused, `pr` route | `git commit` exits non-zero after the switch | The same, plus the line naming the switch back and the removed branch | The same, plus that line |
| Push refused, `pr` route | `git push` exits non-zero after the switch | git's words, the commit named on the new branch, no further choice | `Committed, not pushed`, no `Open a pull request` |
| Push refused, protection or otherwise | `git push` exits non-zero on the `commit` or `push` route | git's words, the commit named, then two choices | `Committed, not pushed` |
| Pull request refused | `gh pr create` exits non-zero | gh's words, the commit and branch named | `Committed and pushed, no pull request` |
| A step timed out | The bound in the timeouts table | The CLI's **Timed out** block | The app's **Timed out** state |
| Nothing left to commit at commit time | The re-read path set is empty | `nothing to commit; the files changed since the offer` | Toast `Nothing to commit`, dialog closes |
| Cancelled | Ctrl-C, or the dialog dismissed | exit 130 | The dialog closes, nothing runs |
