# Changelog

Notable changes, per [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries are written when a change lands, not batched at release. Write each
one at 200 characters or fewer: the outcome for a consumer, a migration note
inline on a **Breaking:** change, and credit (`— thanks @name`) when the
change came from an outside contributor.

## [Unreleased]

### Added

- `preflight` fails an edit, deletion or rename of a migration the merge base
  carries, defaulting to the `V*__*.sql` shape refinery and Flyway refuse to run
  against once its checksum moves. `PREFLIGHT_MIGRATION_GLOBS` sets other paths.

- A package header may carry `summary`, the line the Packages tab shows and
  searches and `kendex index` exports beside `description`; without one the
  description stands in. Every kendex skill now has one.
- A package that changes the repository beyond kendex's own folders says so
  at install and waits for its own yes, good for that run alone. Declining
  installs it unarmed; no terminal declines unless `--allow-repo-effects`.
- The app asks the same question: installing such a package from a
  marketplace or bundle shows what it changes, writes, and how to undo it,
  with its own Apply. `kendex apply` asks too for a hand-declared package.
- `kendex remove <name> --keep-declaration` takes the files away and leaves
  kendex.toml untouched, so the next `kendex refresh` installs what it
  declares again. Fixing a broken install no longer needs the manifest restored.
- The app says when a release is out and offers the one action that fits how
  it was installed: Update now on a direct install, the package manager's own
  command on a managed one, and release notes when neither applies.
- `kendex update` brings the desktop app along on a direct install, and on a
  package-manager install prints that manager's update command instead of
  replacing files it does not own.
- Problems now lists a declared package whose place already holds files
  kendex did not write, with the ways out core reports for it: keep those
  files, or install what kendex.toml asks for and send them to the trash.
- `REVIEW_GATE_CARRY_FORWARD` gains a `vendored` class: a `kendex refresh`
  push under the render trees a repo lists in `REVIEW_GATE_VENDORED_PATHS`
  carries the prior review, whatever the files' extensions.
- The foot of the app's sidebar names the kendex.ai account you are signed
  in to, says Offline when the server could not be reached, and offers Sign
  in or Sign in again as the credential needs. Clicking opens Settings.
- Settings > Account names the kendex.ai account and offers Sign out; it reads
  Offline when the server could not be reached, and asks for a fresh sign-in
  when the credential was rejected. A failed check says why, with Try again.
- The review-gate skill ships a reviewer instruction for a repo that commits
  its `kendex refresh` output: a finding over the render goes upstream rather
  than into a thread the repo cannot act on.

### Changed

- The seeded `WORKTREE_SYMLINKS` default now lists only paths git does not
  carry. An entry does nothing when git carries every path under it, so drop
  those from your own value; one with untracked children still links them.

- **Breaking:** the worktree skill no longer installs JS dependencies. Run
  installs in the main checkout and link its `node_modules` via
  `WORKTREE_SYMLINKS`; an unlinked JS worktree warns, naming the main checkout.

- **Breaking:** skills resolve settings as env > `.env.local` >
  `.kendex/settings.toml` > `kendex.settings.toml` > default, `[env]` table
  only; a lingering `.env` is silently ignored (use `.env.local`).

- Precedence exceptions: deep-research reads env and `.env.local` only;
  `REVIEW_GATE_MODE` reads env and the committed `kendex.settings.toml` only;
  a project `LINEAR_API_KEY` beats an inherited one (`LINEAR_API_KEY_OVERRIDE` wins).

- **Breaking:** settings values are single-line double-quoted strings with no
  `"` or `\`; any other shape, a duplicate key, or an unparseable table header
  fails the load.

- **Breaking:** kendex no longer reads the pre-2.0 mutable clone in the
  source cache. Nothing has written that layout since 2.0, so a scope whose
  only copy is there reads as Pending until `kendex refresh` fetches it.

- **Breaking:** `byte-ceiling`'s staged lane now judges a file a commit
  changes, not only one it adds, and reads type changes and moved-and-grown
  files too. A repo that edits an oversized file needs a row for it.
- **Breaking:** `size-ratchet` refuses a test-class baseline row that HEAD's
  baseline does not carry or carries lower. Rows already at HEAD keep; a
  test that outgrew its class threshold is split, never frozen.

- The review gate's pending status now names the repo's own configured
  evidence sources — `no review evidence at <sha> yet; expected from <names>`
  — instead of reading as a block on someone's approval.
- **Breaking:** the pi-hooks pre-commit listener (0.7.0) defers to git hooks
  kendex armed and refuses a bypass or an unarmed repository, like the bash
  hook; it runs no fmt or clippy of its own, so arm with `kendex guard install`.

- **Breaking:** a `core.hooksPath` naming a directory answers "could not
  determine" from `kendex guard check`; the stand-down prints git's own
  report of where it is set, then says to clear it at its source and arm.
- **Breaking:** hooks read as armed only when the package's marker is in
  both hook files, both are executable, and `core.hooksPath` is unset;
  `guard install` stands down under any value. New: `kendex guard check`.
- **Breaking:** `guard uninstall` disarms the repository. Every work tree and
  nested project shares one set of commit hooks, so an uninstall from any of
  them takes the hooks; they no longer stay behind for another project.
- The worktree skill's broken-`.agents` recovery stops assuming one repo
  layout, and asks you to link to it rather than paste it into `AGENTS.md` /
  `CLAUDE.md`, where no refresh can reach a copy.

### Fixed

- `mutation-stability` no longer reads a stable test as unstable, or a killed
  mutant as a survivor, when the caller shares a build cache. Everything it
  wrote to a copy is now stamped past the build before it, so cargo rebuilds.

- A blocked declaration now names every position its take-over empties. A
  tree read through a tool's own link sits at two, and `apply --plan` named
  one while `--replace-unmanaged` moved both.
- `kendex adopt` is no longer offered for an item whose tools hold copies
  that differ. The capture refuses those, so the suggestion named a command
  that always failed; the offer now asks the same reader the verb does.
- In the app, a row you just settled no longer comes back. A machine-wide
  check that started before the change and landed after it overwrote the
  newer reading, and kept it for the freshness window.
- `kendex report --skill` files against kendex, like `--agent` and `--hook`
  already did; a skill installed from anywhere else still files against your
  own repo.
- `kendex report --upstream` takes a GitHub repo spelled any way — shorthand,
  https URL or `git@` — and files against it when your lock records the asset
  from that repo.
- `worktree cleanup` and `worktree remove` prove a merge two ways and no other:
  ancestry into the default branch, or the pull request whose head commit is
  the branch tip. Squash merges collect, and every keep now names its reason.

- `kendex remove`, and any CLI apply, refresh or unsubscribe that drops a
  package, runs its declared uninstaller before the files go, so dropping
  `growth-guards` disarms the commit hooks.

- A refresh cuts opencode.json's `kendex-hook-` `instructions` rows down to
  what it renders now, so a row kendex wrote leaves with its render. Every
  other row is untouched; rows a pre-rename tool wrote are removed by hand once.

- Removing a skill whose harness copies are only partly present now finishes.
  A copy that was already gone, or a link whose target was, failed the move to
  the trash and rolled the whole removal back, on every retry.

- harness-ci's `harness-only` reads the manifests at the selected head and answers
  `false` for a diff touching an in-place skill or an `.agents/hooks` script:
  project source under a render path no longer stands CI lanes down.

- The `task-completed-check` hook counts untracked files as changes, and blocks
  on any nonzero clippy exit or a git that cannot say what changed. It passed
  all three before: a new-file-only task, a killed clippy, an unreadable repo.

- **Breaking:** the `block-bare-cd` hook reads the command with `jq` and refuses
  every Bash call it matches on a host without it — install jq wherever the hook
  runs. Its own parser stopped at the first quote, mis-refusing `cd "$d" && ls`.

- The Library's From column says "Your own" for a skill adopted in place
  (it read as a marketplace with no repository), and the Mine import
  inventory reads such a skill's bytes from the tree it sits in.

- `kendex fork` refuses an item that is already yours — `local`, or a skill
  adopted `in-place`, whose tree of record a fork would quietly demote to a
  render of a hidden copy.

- The `block-bare-cd` hook refuses a bare `cd` with no path. It changes to
  `$HOME` for every later tool call, the move the hook exists to stop, and
  only `cd <path>` was caught before.

- `worktree`: the recovery text consumers copy into `AGENTS.md` no longer calls a
  `.agents` directory broken. A repo that commits its render has tracked files
  there, so the entry is a real directory and a child is what breaks.

- `worktree`: an untracked `.gitignore` under a tracked-content `WORKTREE_SYMLINKS`
  entry is copied, not symlinked, so the worktree ignores what the main checkout
  ignores and git stops warning `unable to access ... Too many levels of symbolic links`.
- The settings template no longer seeds `.cursor` into `WORKTREE_SYMLINKS`, so
  `worktree fix-links` passes in repos that do not use Cursor; a repo that
  does adds it back in its own `kendex.settings.toml`.

- A later `Fixed in <sha>`, `Declined:`, or `Tracked: <issue>` reply clears
  a review thread's tracking claim at the gate, and a `Fixed in <sha>` reply
  is never a claim, whatever its prose says.

- `kendex refresh` says when this clone's `info/exclude` ignores `.agents`,
  as it already did for `.gitignore`, from any linked worktree too. That
  rule hides the tree from git status on one machine, so nothing commits it.

- The lock records each skill's tree and links. **Breaking:** an install an
  older kendex made is redone by hand: refresh, then remove that scope's lock
  file and the skill trees and links kendex wrote, nothing else; then apply.

- On macOS the commit hooks were written but never made executable, so git
  ignored both and an armed repository gated nothing. `guard install` reports
  armed only when the bit is really there.

- `guard` verbs run from a linked worktree find the package under the same
  project path in the main checkout, not only at its top level.

- `kendex guard` relays the package's summary line on stdout and its warnings
  on stderr, instead of putting both on stdout.

- A `growth-guards` package inside the work tree, beside a git directory kept
  there, is no longer resolved as the main checkout's copy and run as the
  repository's commit gate.

- A `core.hooksPath` whose value ends in a newline no longer makes `--check`
  inspect a different directory and report the repository as armed.
- Under `--separate-git-dir`, the generated git-hook helper no longer runs a
  `growth-guards` package sitting beside the external git directory.

- A directory name containing a single quote can no longer inject shell into
  the generated git-hook helper, which could make every commit pass unchecked.
- Under `--separate-git-dir`, a `growth-guards` package sitting beside the
  external git directory is no longer run as the repository's commit gate.

- The commit chain finds its gates in a project whose directory name ends in
  a newline; the path was truncated, so a gate that would have failed the
  commit was reported as not installed and the commit passed.

- The commit chain finds its sibling gates in a kendex project that sits
  below the git top level; they were skipped as not installed, so a gate
  that would have failed the commit reported nothing.
- `kendex check` no longer reports commit-hook drift at a project whose only
  `growth-guards` item is an agent of that name rather than the skill.

- The guard verbs work in a checkout whose path is not valid UTF-8 or
  contains a newline; they used to report a path that does not exist.

- The `harness-ci` wiring guide covers a lane that reads a path family beside
  the render verdict; the single-gate condition it shipped skipped that lane
  whenever the classifying job died.
- A commit hook that lost its execute bit no longer reads as armed. Git
  skips such a hook silently, so the harness gate stood aside for a gate
  that ran nothing and the commit went through unchecked.

- The growth-guards `--check` reads an install whose `pre-commit` or
  `commit-msg` script is missing or not executable as not armed — that state
  blocks every commit.
- The `pre-commit-check` hook stands aside only when both git hooks are
  armed; with `commit-msg` missing it no longer waives the message gate.
- The guard verbs run the package's scripts through `sh` on Windows, where
  `#!` lines are not honoured, instead of failing to start.

- The growth-guards `--check` reads an empty `core.hooksPath` as hooks
  switched off, rather than measuring the repository root in its place.

- The `pre-commit-check` hook no longer stands aside for a repository-root
  file git never runs when `core.hooksPath` is set: any value at all reads
  as not armed.
- A hook of your own that mentions a guard marker mid-line is left alone: it
  is no longer refused, rewritten, or reported as a stale shim. A line that
  ENDS with the marker is still treated as the installer's own.
- A blocked commit is told to run `kendex guard install`, which restores the
  helper, instead of `kendex refresh`, which does not.

- The guard verbs find the package under the project's own root, so a kendex
  project below the git top level is no longer reported as having none.
- **Breaking:** the `pre-commit-check` hook refuses a commit where no git
  hook is armed, naming `kendex guard install`, instead of running the
  repository's own guard scripts — arm the hooks to keep commits gated.
- Agents no longer promise a `{{KENDEX_FAILURE_REF}}` that nothing defines:
  the failure-routing line now points at `kendex report --help`.
- OpenCode, Gemini, and Copilot agent renders list required skills at
  `.agents/skills/…` — the tree those tools read — instead of per-tool
  directories a default install no longer writes.
- Preflight no longer flags upstream `TODO` markers in vendored harness
  mirrors, and recognizes `.pi/kendex/` as a managed mirror like the other
  harness trees — repos committing their rendered harness files can pass.
- Simultaneous app and CLI account calls share one token refresh, so they no
  longer invalidate the sign-in by rotating the same refresh token twice.
- Registry refresh timeouts and rate limits no longer sign the machine out;
  the app or CLI keeps the credential and can retry.
- A package's Follow source switch moves at once, on or off, instead of
  freezing the Updates table for the seconds its write takes. Rows in other
  places stay live while it settles; the flipped package's place waits.
- `kendex adopt` and the app's keep action refuse a path-shaped name and a
  symlinked destination, so neither trashes a directory outside the tool's
  folder. A namespaced skill is kept from the one directory its tool lists.
- `kendex check` exits 1, not 2, when packages await re-evaluation, so the
  session-start report no longer opens with "kendex check could not run" after
  a completed run. The drift hook script changed; `kendex drift-hook` reinstalls it.
- A hook found in a settings file is safety-checked on its own entry, not
  the whole file: a `permissions.ask` guard naming `mkfs` no longer flags
  every hook beside it, and a hook whose own entry carries it still scores.
- A project reached through a symlinked path no longer misreports an
  editor save conflict as a plain failure or loses package update
  timelines to a "history could not be read" warning.
- The preflight skill's `unwired-suite` lane no longer flags new test files
  that a bare `vitest`/`jest` script runs through the runner's default
  include glob.
- A pi-hooks carrier registered through a scoped path such as
  `./packages/@vanillagreen/pi-hooks` no longer draws the false "nothing
  will run it" warning from `kendex apply`.
- The review-gate predicate matches `REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS`
  only in the first line of a review body, so a review quoting a pattern in
  later text (e.g. a PR editing that setting) counts as evidence again.
- Customize › Customized packages now lists every package you changed at
  that location, hand-edited and forked ones included, so it matches the
  Library's "Customized in" mark instead of only packages with settings.
- macOS builds are Developer ID signed and notarized: installing from any
  channel no longer ends in "kendex is damaged" or an `xattr -cr` workaround.
- `preflight`'s fail-open lane no longer asks a non-executable file under
  `scripts/lib/` for a `set -euo pipefail` preamble; nothing runs it, and
  sourcing it would set the caller's mode. An executable one keeps the check.

### Removed

- **Breaking:** vstack-era installs are not migrated — install fresh and
  remove the old artifacts by hand: the `vstack-hooks` directory (or
  `kendex-hooks`, from an earlier 5.x), its `core.hooksPath`, v1 settings.
- **Breaking:** the growth-guards package's scripts are the only check
  engine: `kendex guard` keeps `run`, `install` and `uninstall`, and drops
  the per-check verbs, `repair`, and `import-v1`.
- **Breaking:** `[guards]` tables in `kendex.settings.toml` are gone —
  delete them and keep the `GROWTH_GUARDS_*` / `SIZE_RATCHET_*` keys the
  package reads. Repos that never converted need no change.
- `KENDEX_DRIFT_HOOK_AVAILABLE` and the pi-hooks `sessionDriftAvailable` setting
  are gone: both passed `--no-available`, a flag `kendex check` never had, so
  turning them off broke every session start.
- **Breaking:** safety is advisory: nothing holds an install or update back.
  The app's Review & apply page, `kendex findings`/`dismiss`/`decisions` and
  `apply --allow-unsafe` are gone.
- **Breaking:** kendex.toml's `[safety-overrides]` and `[safety-reviews]`
  records decide nothing and are no longer read. The next apply removes both
  tables from the file.
- **Breaking:** the `trading-design` skill is no longer offered. Run
  `kendex remove trading-design --scope all` wherever it is installed (or
  drop its `[skills.trading-design]` entries and run `kendex apply --scope all`).
- **Breaking:** nothing reads the old vstack names any more — the files, the
  `vstack2` app directories, the repository redirect, the alias binary, and
  `kendex import`. Rename them to `kendex`, or reinstall the scope fresh.
- **Breaking:** `--scope` takes `project`, `global` or `all` only; the v1
  aliases `p`/`local`, `g`/`user` and `both`/`*` are gone. `-g` still means
  global.

### Added

- New optional `harness-ci` skill: a classifier that answers whether a CI diff
  touches nothing but the kendex render trees, so heavy lanes can stand down.
  It ships the script and its tests only — the workflow step stays yours.
- `review-gate` ships `scripts/validate.sh` — one CI step reporting whether a
  repo's own gate install is sound: engine runnable, `REVIEW_GATE_*` values
  legal, exclusions live, adopted workflow still meeting the template.
- Installing asks where it goes: the app and `kendex add` at a terminal offer
  every supported tool with the ones you have pre-checked, plus symlink or
  copy delivery. `--harness`, `--all-harnesses`, `--method` do it flag-only.
- `kendex adopt hook <event>:<matcher>:<script>` manages a hook you
  registered yourself: the script moves into `.agents/hooks` and kendex takes
  over that one registration, leaving every other entry in the file alone.
- Registering a project reports what it already holds that nothing manages,
  instead of leaving it to be found on a later visit to the Library.
- The app backend checks for new kendex releases at most once every six hours
  and stores the last result plus preferences for the upcoming notice controls.
- Moving an existing repo onto kendex works now: `kendex adopt` keeps files
  already on disk as they are, and `kendex apply --replace-unmanaged`
  installs over them (the old copies go to the trash).
- The app has its own icon — the `x` from the kendex wordmark, at every size
  the desktop, dock, and installer use.
- Releases ship for Intel Macs and arm64 Linux alongside Apple silicon,
  x86_64 Linux, and Windows; every install channel picks the right build.
- App zoom, 50%–200%: Settings buttons or `Ctrl`/`Cmd` `+` `-` `0`,
  remembered across launches. Also the fix for fractional display scales.
- Marketplaces › Community: browse a listed marketplace's packages, READMEs,
  files, and safety findings before subscribing; subscribing continues from
  the same page.
- `kendex guard install` arms the growth-guards shims in `.git/hooks` instead
  of setting `core.hooksPath`, so an armed repository gates commits with no
  kendex binary present.
- `kendex check` reports whether a project's commit hooks are armed.
- New install channels: `curl -fsSL https://kendex.ai/install.sh | sh`,
  Homebrew (`kendex`, `kendex-cli`), and the AUR (`kendex-bin`, `kendex`,
  `kendex-git`).
- The default catalog offers curated bundles and tagged packages:
  orchestration, code-review, research, and commit-guards.
- The Updates page says when it last reached your sources — "Last checked 3h
  ago" under the title, and beside "Everything is up to date" — so a standing
  the page read offline is no longer indistinguishable from a fresh check.

### Changed

- The `review-gate` writer workflow copies verbatim: no per-repo values left.
  Adopted copies drop each `default_branch || 'branch'` fallback for the bare
  expression, and a `check_run` opt-in reads `REVIEW_GATE_CHECK_RUN_NAME`.
- Consumer CI runs `review-gate`'s validate step in place of the engine
  selftest: package behaviour is proved upstream, so a repo checks only the
  configuration and wiring it owns.
- **Breaking:** carry-forward exclusions take one grammar, path characters
  plus `*`. Rewrite a `?`, `[...]` or backslash entry as a literal path or a
  `*` glob — `--check-config` names the offending value.

- A project's skills work on clone: every tool but Claude Code reads
  `.agents/skills` directly, and Claude's link into it is now relative, so
  both commit. Existing installs converge on the next `kendex refresh`.
- Committed symlinks need Developer Mode on Windows; without it, install with
  `--method copy`, which gives every tool a real tree of its own.
- kendex keeps `.kendex-lock.json` out of git — the one line it writes to a
  project's `.gitignore` — and says so when your own rules ignore `.agents`.
- Managing a project skill moves it to `.agents/skills/<name>` and leaves the
  path its tool read as a link. That tree is the content of record, so
  refresh maintains links and layout and never rewrites what you wrote.
- Every package surface in the app shows its safety score in a circle, with
  the findings behind it: the package page, the Updates table, and the page
  you install from. Nothing asks you to review, accept, or dismiss one.
- Content kendex did not install is counted on its place's card under
  Projects and taken on from there. The Library and Home no longer mention
  it — nothing is wrong with a file kendex did not write.
- `kendex update` reads schema 1 feeds (including legacy feeds with no schema). Current stays a no-op; older refuses unless `--force`.
  A newer feed, or a forced current/older feed, with no target binary exits 0 with release notes and changes nothing.
- Updates: a package you edited can't be updated over; its row offers
  **Install as new package**, which keeps your edited copy under a name you
  choose and installs the newest version beside it. Commit ids hide behind `…`.
- `add`, `apply`, `refresh` and `check --catalog` print one safety block: the
  score, then a line per finding — severity in words, what the rule matched,
  and where. Every package scores now, findings or not; no fix line under one.
- Updating one package no longer brings the scope's other following packages
  along — from the Updates page, a package page, or the new
  `kendex updates apply <kind> <name>`. `kendex refresh` still updates everything.
- A package an update could not touch — a copy you edited by hand, files in the
  way — is now named as held back instead of reported as updated, in the app and
  in `kendex updates apply`.
- Updating or holding one package no longer brings the scope's other following
  packages along — from the Updates page, a package page, `kendex pin`, or the
  new `kendex updates apply <kind> <name>`. `kendex refresh` still updates everything.
- `kendex refresh` ends on a ledger — `refreshed N changes · skipped K items on
  conflict · flagged M items on safety` — each outcome it carries naming a next
  step. A run whose installs were all blocked no longer says "nothing installed".
- One conflict prints once, naming every tool it blocks and every position it
  sits at, plus how the files in the way compare with the catalog — identical,
  or which files differ.
- A hook that skips a tool now points at the hook's own `harnesses:` line in the
  catalog, and skills that require each other read `installing dev also installs
  orch, reviewer (required)`.
- **Breaking:** in `kendex check --json`, a not-yet-evaluated line now has
  `"class": "unevaluated"` where it had `"class": "unknown"`. A parser
  matching that field exhaustively has to accept the new value.
- orch: the internal re-review loop stops at `REVIEW_MAX_CYCLES` (default 4) — `workflow-state set … rereview_panel` refuses once `cycles` is past it, so a review cannot run on for ten cycles before the PR is opened.
- **Breaking:** `check --catalog --json`, `marketplace mine --json` and `index --json`
  are schema 2: the held-back/warned counts, verdicts and per-finding dismissal tokens are
  gone, replaced by `safety_findings` (check), `safetyFindings` (mine) and `checked.findings` (index); the check never fails on them.
- **Breaking:** the install record's format moves to version 5. Older files
  upgrade in place on the first apply; if two kendex versions share a
  project, update both.
- **Breaking:** the default Homebrew formula installs the app; CLI-only
  moved to `kendex-cli`. Migrate with `brew uninstall kendex && brew
  install vanillagreencom/kendex/kendex-cli`.
- Commit checks moved into the git pre-commit hook, which also runs rust-fmt,
  rust-clippy, and biome; kendex's harness hook refuses `--no-verify` and
  hook-skipping git config.
- **Breaking:** `KENDEX_PRE_COMMIT_RUST_CLIPPY` is gone. To disable the
  lane, set `enabled = false` under `[guards.rust-clippy]` in
  `kendex.settings.toml`; a custom command moves to `KENDEX_GUARD_PRE_COMMIT_LOCAL`.
- The safety check reads every file to its last byte (it used to stop at
  512 KB or 200 files), so large packages can show findings that were
  always there; unreadable ones report "Not fully checked", not a score.
- Safety scores say what they are: automated checks, not reviews —
  beside every score, dot, and the About tab's wording.
- A safety finding's message names what it fired on, never where.
- The Updates page is one row per package, expanding to a row per place;
  "Update automatically" is renamed **Follow source** — nothing applies on
  its own — and `kendex updates` names the place on every line.
- The `second-opinion` skill waits 18 minutes for an external review, up
  from 5. A seeded `SECOND_OPINION_TIMEOUT = "300"` must be raised by hand.
- The `dangerous-commands` check no longer reads a shell `case` pattern
  list as a command, ending false flags on skills that parse command lines.
- The project-management skill's roadmap pipeline is spec-driven and asks
  once: a reviewed plan is the spec, its approval carries through to issue
  creation, and research runs inline by default.
- `kendex init --kind skill` scaffolds now say what a SKILL.md body is for:
  commands and rules, never internals.
- UI polish: project cards open that project's library, links into My
  Library land on a clean filter strip, the app uses the Geist typeface,
  and dialogs ask in the words of the button that opened them.

### Fixed
- A settings or `kendex.toml` save from a copy something else wrote since —
  another window, a resize, the CLI — no longer puts the older file back: it
  is refused and retried on a fresh copy, or offered Reload in the editor.
- A refused apply's rollback keeps the hand edit that refused it — a
  `kendex.toml` change landing mid-apply — instead of restoring the older
  copy over it.
- The Library works from the keyboard: each package name is a button, so
  Tab reaches it and Enter opens it. Dragging across text to copy it no
  longer opens anything in the Library, a marketplace list, or a Projects card.
- The worktree skill's `push` refuses a flag it does not recognize and an
  empty target, rather than pushing the current checkout with default
  behavior nobody asked for. `push --check-args` validates arguments alone.
- The worktree skill's `fix-links` no longer reports "Restored symlinks" for
  a path it did not restore: it names every configured entry left unhealthy
  — including one absent from the main checkout — and exits non-zero.
- An apply is no longer refused as "scope is busy" while nothing else
  runs: locks release explicitly when an apply finishes instead of waiting
  on a file a just-launched program still held open. Same fix for downloads.
- Home's Installed tile counts what the Library counts — packages, not
  per-harness copies — so the tile and the table it opens agree.
- A harness's name on the Harnesses page opens the Library showing
  everything that harness has, the way a project's name already does; the
  count badges still narrow to one kind each.
- Home answers a failed scan: the page says why and offers Scan again, and
  a later failure keeps the last figures, labeled as the last kendex could
  check — the status footer stops saying "Up to date" beside them.
- Updates and Marketplaces say when a check failed and offer a retry; rows
  kept from an earlier check are headed as last-checked, and acting on
  stale rows — update, follow, subscribe, unsubscribe — waits for a good check.
- Overlapping reads land in order: a slow early read cannot overwrite a
  fresher answer, changes apply in the order made, and a change that fails
  midway re-reads the standing instead of presenting old rows as current.
- `kendex apply --replace-unmanaged` no longer gives up on the whole scope
  because one item cannot be settled: everything replaceable is replaced
  and each held-back item is named with what holds it.
- Codex reads the same skill as every other tool: the invented 8 KB
  SKILL.md split is gone (Codex has no such limit), and old `details.md`
  splits are cleaned up on the next apply.
- Everywhere the app says a package is customized it now says where
  ("Customized in vg · 1 of 3 places"), and a place the app has not read
  no longer passes as untouched.
- A debug build keeps its own home and cannot touch your real setup —
  the `lock.json was written by a newer kendex` surprise. Opt out
  deliberately with `KENDEX_REAL_HOME=1`.
- Items blocked by files already on disk no longer deadlock, half-install,
  or misreport: apply names the files and both ways out, an edited skill is
  reported as edited, and `apply --plan`/`verify` count what they skipped.
- Pi no longer halts every session start in a managed project: kendex's Pi
  hooks moved out of Pi's reserved `hooks/` directory, and refresh migrates
  an existing install — moving only what kendex provably wrote.
- `kendex apply` and `kendex refresh` print what they cannot change and
  why, instead of "nothing to do".
- The Linux app draws at the right size on HiDPI Wayland (native Wayland
  client, X11 fallback; `KENDEX_GDK_BACKEND` chooses inside the AppImage),
  and the app-menu entry carries the window class and every icon size.
- On Linux, a helper command that outlived its time limit can no longer
  take unrelated processes down with it.
- Concurrent saves can no longer leave a settings, manifest, lock, or
  snapshot file half-written.
- An agent renders only the skills it actually has; a removed reviewer
  skill no longer comes back on every apply.
- A marketplace package's preview scores what installing would write.
- An unreadable catalog's own bytes are shown escaped, never written to
  the terminal.
- `kendex adopt` binds an adopted item to the tools that were actually
  reading it, not the scope's full defaults.
- Symlinked repository paths read as catalogs again.
- The review-gate package's tests run in projects that install it, and
  preflight no longer flags cross-repo citations like `kendex:docs/x.md`.
- The project-management pipeline creates Linear issues in Backlog, not
  the team's Triage default.
- "How a marketplace repo works" can be read from the keyboard.

## [5.0.1] — 2026-08-20

### Fixed

- A collection link cannot point kendex at a local directory, and a
  reused subscription installs the pinned commit, not the branch head.
- A momentary network failure no longer signs you out, and the submit
  preflight checks "everything is pushed" against the repository actually
  being submitted.

## [5.0.0] — 2026-08-20

The first kendex release — the successor to vstack v4 (vstack ended at
4.9, so nothing collides with a v1-era tag). Everything below is relative
to vstack 4.x: the product and binary are renamed, a desktop app joins the
CLI, and the kendex.ai community ships alongside. Migrate with
`kendex import` + `kendex refresh`.

### Added

- Collections: share a curated set of packages with one link —
  `kendex add https://kendex.ai/c/<id>` subscribes and installs every
  member at the exact pinned commits.
- Publish what you build: submit a package to kendex.ai from the app or
  `kendex marketplace submit`; `kendex login`/`logout` manage the terminal
  session, with credentials in the system keychain.
- Build your own marketplace: create, register, or import into a
  ready-to-publish repository from the Mine tab or
  `kendex marketplace new | use | mine | import`.
- The Community tab: browse the kendex.ai directory and search skills.sh's
  index; installs are locked, safety-checked, and updatable like any other.
- The Marketplaces page: subscribe to any repository of skills and agents,
  and read a package, with its safety verdict, before anything lands. The
  Library becomes **My Library** with a From column.
- Any repository that holds skills is a marketplace — existing ecosystem
  layouts are read with no special file, full git URLs and GitHub tree
  links work, and names can be qualified as `marketplace::name`.
- Custom hooks run wherever a harness can run them, picked from a list of
  real events and safety-checked like installed hooks; each editor card
  says where a hook is enforced versus advisory.
- Commit checks guard every commit: `kendex guard install` puts a
  kendex-owned hooks directory in front of git, each check judging exactly
  what the commit records; v1 settings convert with `kendex guard import-v1`.
- `kendex check` is the drift contract (exit 0/1/2, `--quiet`, `--json`),
  instant via a per-project snapshot, delivered into new sessions by a
  removable session-start hook (`KENDEX_DRIFT_HOOK=off` disables).
- Safety and quality are two scores, never mixed: safety can hold content
  back, quality informs. Every finding names file, line, and fix; leaked
  keys are shown only as fingerprints.
- Safety findings can be dismissed with a reason, bound to exactly that
  content and rule set; teammates inherit decisions in plain sight. CLI:
  `kendex findings`, `kendex dismiss`, `kendex decisions [--revoke]`.
- The Review page reads as two zones — needs your decision, ready to
  apply — with **Review one by one** walking findings worst-first, and
  every held-back item carrying **Accept and install**.
- `kendex check --catalog` validates a repository the way an install
  reads it, with a reusable GitHub Actions workflow; what `kendex init`
  scaffolds passes on the first run.
- Bundles: a catalog can offer named sets; installing one brings every
  member, and uninstalling explains what stays and why. Skills can require
  or suggest other skills, and removals warn what still needs them.
- GitHub Copilot and Gemini CLI are fully managed — agents, skills, hooks,
  and MCP servers land where each actually reads them, and everything the
  two tools borrow or gate is said out loud instead of left to surprise.
- Every generated file is checked against its tool's real format before
  writing; agent instructions are reworded into each tool's own
  vocabulary where the reference is unmistakable.
- A package's page carries a **Customize** tab showing what you changed,
  and the Library marks customized rows. Vendor-bundled content is
  labelled and left alone.
- Seeded settings comments stay current on refresh — only while provably
  untouched; values are never touched.
- **Breaking:** every installation records why it exists (asked for,
  required, bundled) and those reasons drive removals. Existing records
  gain "asked for directly", the only safe reading.
- **Breaking:** installing can be refused: critical findings and scores
  under 60 hold back, 60–80 warns. Override per exact content with
  `kendex apply --allow-unsafe <name>@<code>`, recorded in kendex.toml.
- **Breaking:** `kendex refresh` never changes what is installed without
  asking; scripts add `--yes`.
- **Breaking:** marketplace-style catalogs (`marketplace.json`) install
  one plugin at a time; their items are namespaced `<plugin>/<item>`.
  Plain catalogs are unaffected.
- **Breaking:** a source can pin a revision (`rev = "..."` or
  `owner/repo@rev`); a commit pins forever, a tag or branch is followed
  with changes previewed. The download cache is safe to delete.
- **Breaking:** a plugin belongs to one tool; existing declarations read
  as Claude Code's. Add `harness = "copilot"` to aim one at Copilot.
- **Breaking:** commands install on Codex as generated skills (Codex
  retired its prompt directory); collisions install as `<name>__command`.
  Existing installs: run `kendex refresh` to generate them.
- **Breaking:** installed skills follow the surface model: tools reading
  the same folder share one rendered copy, others get their own. Refresh
  regenerates; the journaled apply moves anything that needs to move.

### Changed

- **Breaking:** vstack is **kendex** — app, CLI binary, crates, and
  identifier. A `vstack` alias ships one cycle; existing libraries
  repoint in one previewed step.
- **Breaking:** rename `VSTACK_*` environment variables to `KENDEX_*` or
  they stop working (a disabled drift hook comes back); only the guard
  variables (`VSTACK_GUARDS_*`, `VSTACK_GUARD_PRE_COMMIT_LOCAL`) fall back.
- The coding tools kendex writes to are called **harnesses**.
- The app is reorganized around what you're doing: six sidebar
  destinations, Home leads with what needs attention, Sync is Review &
  apply, Library and Catalogs merge, Tools and Projects merge.
- The Library grew a real detail flyout, its own search (`/` jumps to
  it), place pills, status dots, type icons, and one rule for the line
  under a name: always the description.
- Errors got a home: failures open a dialog with the reason and fix,
  ongoing problems live on a Problems page behind a status-bar count, and
  every page shares one visual language for errors and warnings.
- Counts mean items, not rows-per-tool, computed in one shared place;
  summaries group a finding once over the items it affects instead of
  repeating it per row.
- A considered look: the app draws its own title bar, color carries
  meaning, one blue primary action per screen, and back/forward work
  like a browser.
- The safety check got about seven times faster (0.8 s → 0.11 s on a
  large project) with findings unchanged byte for byte.
- Loading states are the shape of what is coming, and the app never
  claims "Nothing installed yet" while still reading.
- **Breaking:** agent tool permissions are typed intent, never widened:
  `tools:` allowlists render or refuse per harness honestly, and a missing
  `role:` no longer renders Codex full access. Refresh regenerates.
- A role-less Codex agent that relied on implicit full access keeps it by
  declaring `role: engineer` explicitly.
- **Breaking:** model aliases resolve through one per-harness table;
  `inherit` survives every harness. Refresh regenerates.
- **Breaking:** the manifest schema and install-record version move to 2.
  v0.1 files upgrade in place on first apply; newer files refuse to load
  rather than corrupt.

### Fixed

- Migrating from v1 fails closed: a damaged record refuses with its path
  named, a stale record cannot bury live installs, and the migration runs
  as one journaled transaction.
- Installed scripts run again: any installed file that opens with `#!` is
  executable, everywhere trees are written.
- Unsubscribing with "keep the packages" moves the effective values into
  your own kendex.toml, so a kept agent keeps rendering as installed
  instead of showing out of date right after.
- The safety check stopped flagging ordinary code for reading its own
  settings (`process.env`, `os.environ`, …) — a 39-item catalog went from
  296 findings to 12.
- Commands in a SKILL.md code block count in full, single non-text bytes
  cannot hide a file, more lookalike letters are recognized, and quoted
  values are redacted.
- **Breaking:** accepting a problem now binds to every byte of what was
  installed, so nothing can change under an acceptance. Old acceptances
  cannot prove coverage and read as out of date until reviewed once more.
- Things the check could not read say so instead of scoring a silent
  hundred, and the Audit page tells the truth about accepted items.
- Removals stick while a catalog is offline, and refresh fetches only
  catalogs something is installed from — one unreachable catalog no
  longer stops the rest.
- Bundle and dependency conflicts resolve predictably: either-on wins for
  shared items, asked-for-by-name beats kept-removed, and disagreements
  are reported instead of settled by sort order.
- Gemini's machine-wide MCP switch is never rewritten by a project, hook
  matchers translate into each tool's own tool names, and `kendex verify`
  says why an installation cannot act instead of printing a clean tick.
- **Breaking:** an oversized skill splits into a head plus
  `references/details.md` instead of truncating (never cutting a code
  block); generated command names stay stable, and refresh regenerates.
- A project's identity keys off the canonical path, multiple settings
  changes to one file apply as one write, and a tool refusing a skill no
  longer wedges the project.
- One-skill repositories install the skill, not the repository; hostile
  catalog content (symlinks, lookalike names, cross-repo entries) is
  refused loudly with both sides named.
- Error notices appear where you clicked, typed paths accept `~`, and the
  promised kendex.toml format upgrade actually runs on apply.

### Security

- Catalog downloads are hardened: a source repository cannot redirect a
  refresh outside its own cache, no git call can stall on a credential
  prompt, and every external command times out instead of hanging.
- Every catalog read goes through one sealed API with depth, count, and
  byte budgets; frontmatter is parsed as real YAML with
  adversarial-input bounds.

### Removed

- **Breaking:** the v1 `project-skills-dir` setting is gone; skills live
  where they are. Importing drops the key with a note.

## [0.1.0] — 2026-08-10

First v2 release: desktop app (Tauri) + `vstack` CLI over one engine,
replacing vstack v1.

### Added

- Scan → declare → diff → apply engine over per-scope manifests:
  preview-first, journaled, transactional applies with crash recovery;
  removals go to a trash, never a hard delete.
- Five harnesses — Claude Code, Codex, OpenCode, Cursor, Pi — behind one
  adapter seam; agents and skills authored once, rendered per tool.
- Catalog sources as git repos or local paths; adopt brings hand-made
  files under management; CLI verbs mirror every core operation.
- Self-updating app and CLI via a tag-driven release feed.

### Changed

- **Breaking:** fresh manifest and lock schema; v1 files are not read.
  `vstack import` converts them, then `vstack refresh` regenerates; v1
  extras and theme packs are not carried over.

[Unreleased]: https://github.com/vanillagreencom/kendex/compare/v5.0.1...HEAD
[5.0.1]: https://github.com/vanillagreencom/kendex/compare/v5.0.0...v5.0.1
[5.0.0]: https://github.com/vanillagreencom/kendex/compare/v0.1.0...v5.0.0
[0.1.0]: https://github.com/vanillagreencom/kendex/releases/tag/v0.1.0
