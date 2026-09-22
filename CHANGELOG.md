# Changelog

Notable changes, per [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries are written when a change lands, not batched at release. Write each
one at 200 characters or fewer: the outcome for a consumer, a migration note
inline on a **Breaking:** change, and credit (`— thanks @name`) when the
change came from an outside contributor.

## [Unreleased]

## [1.0.0] - 2026-09-22

### Added

- `preflight` fails an edit, deletion or rename of a migration the merge base carries: refinery and Flyway refuse a `V*__*.sql` whose checksum moved. `PREFLIGHT_MIGRATION_GLOBS` sets other paths.
- A package header may carry `summary`, the line the Packages tab shows and searches and `kendex index` exports; without one the description stands in. Every kendex skill now has one.
- A package that changes the repository beyond kendex's own folders says so at install and waits for a yes, for that run alone. Declining installs it unarmed; a terminal needs `--allow-repo-effects`.
- The app asks the same: installing such a package from a marketplace or bundle shows what it changes, writes and how to undo it, with its own Apply. `kendex apply` asks for a hand-declared one too.
- `kendex remove <name> --keep-declaration` takes the files away and leaves kendex.toml untouched, so the next `kendex refresh` installs what it declares again. No manifest restore needed.
- The app says when a release is out and offers the action that fits how it was installed: Update now on a direct install, the package manager's own command on a managed one, release notes otherwise.
- `kendex update` brings the desktop app along on a direct install, and on a
  package-manager install prints that manager's update command instead of
  replacing files it does not own.
- Problems now lists a declared package whose place already holds files kendex did not write, with the ways out: keep those files, or install what kendex.toml asks for and send them to the trash.
- `REVIEW_GATE_CARRY_FORWARD` gains a `vendored` class: a `kendex refresh` push under the render trees `REVIEW_GATE_VENDORED_PATHS` lists carries the prior review, whatever the files' extensions.
- The foot of the app's sidebar names the kendex.ai account you are signed in to, says Offline when the server could not be reached, and offers Sign in or Sign in again. Clicking opens Settings.
- Settings > Account names the kendex.ai account and offers Sign out; it reads Offline when the server could not be reached, and asks for a fresh sign-in when the credential was rejected, saying why.
- The review-gate skill ships a reviewer instruction for a repo that commits
  its `kendex refresh` output: a finding over the render goes upstream rather
  than into a thread the repo cannot act on.
- New optional `harness-ci` skill: a classifier answering whether a CI diff touches only the kendex render trees, so heavy lanes stand down. It ships the script and tests; the workflow step is yours.
- `review-gate` ships `scripts/validate.sh`, a CI step reporting whether a repo's gate install is sound: engine runnable, `REVIEW_GATE_*` values legal, exclusions live, workflow meeting the template.
- Installing asks where it goes: the app and `kendex add` offer every supported tool, yours pre-checked, plus symlink or copy delivery. `--harness`, `--all-harnesses` and `--method` do it flag-only.
- `kendex adopt hook <event>:<matcher>:<script>` manages a hook you registered yourself: the script moves into `.agents/hooks` and kendex takes over that one registration, leaving other entries alone.
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
- The Updates page says when it last reached your sources — "Last checked 3h ago" under the title and beside "Everything is up to date" — so a standing read offline no longer passes for a fresh check.
- The commit offer names the declaration it cannot commit. Where an action changed your `kendex.toml`, the offer says the commit leaves that file out and asks you to commit it yourself.
- Project cards and project views carry a Review changes line when kendex has written files there that are not committed. It opens one page to read the changes, commit them, or put them back.
- Projects can configure a command-safety hook to refuse matching shell tool commands on harnesses that execute hooks. It loads policy support from its own install.
- `bot-instructions`: render, check and adopt review-bot files from shared doctrine and the manifest's `[bot-instructions]` table.
- The workflow bundle includes bot-instructions for generating GitHub review-bot files from shared rules and repository settings.
- Three waits become callable: `LINEAR_RETRY_BASE_DELAY`, `MUTATION_STABILITY_SETTLE`, and one decimal place on the `KENDEX_GITHUB_*_TIMEOUT` bounds.
- review-gate: `REVIEW_GATE_RENDER_PATHS` names the harness render trees; a PR whose whole diff sits under them is approved without review evidence, CI still deciding the merge.
- `linear.sh issues create` refuses a description with no `Reached by:` line, or a `--review-born --priority 2` body with no `Symptom:` line, where `LINEAR_REQUIRE_REACH` is set.
- New `workflow` bundle: orchestration, code-review and commit-guards plus `deep-research` in one `kendex add --bundle workflow`, 30 members that carry what each other needs.
- A catalog package's page and the install picker name what it requires and offer its optional dependencies; My Library says which package a dependency arrived with.
- orch measures a branch's added production, test and render-mirror lines before the push and refuses past the allowance the issue's Expected delta line states; with none it reports the counts.
- pr-watch's `disarmed` line carries the size recorded for the branch at submit: the production lines added and the allowance ratio, stale for another head and unavailable for none.
- `docs-writing` skill: one writing standard for every markdown file a repo owns, a directive list and a template per file type, and the blank-page rewrite workflow.
- Antigravity hooks: a hook installs into `hooks.json` under its own name at either scope, with its matcher in Antigravity's tool names, and the scan reads the registry back.
- Antigravity CLI (`agy`) is a supported harness: agents and skills install at both scopes, MCP servers and plugins are shown read-only, and hooks are not yet supported.
- MCP servers install on Antigravity in `mcp_config.json` at both scopes, a remote endpoint written as `serverUrl`, switched off on the entry's `disabled`.
- MCP servers install on Codex as `[mcp_servers.<name>]` tables in `config.toml` at both scopes through a comment-preserving edit, switched off with `enabled = false`.
- MCP servers install on Cursor in `mcp.json` at both scopes, in the shape Cursor reads, with the remove-and-restore toggle Claude Code's file has.
- Commands install on OpenCode as `commands/<name>.md` at both scopes, with the rename toggle and removal every managed kind has.
- MCP servers install on OpenCode under `mcp.<name>` in the scope's config file at both scopes, switch off on the entry's `enabled`, and an SSE declaration is refused for OpenCode with the reason.
- Commands install on Pi as prompt templates (`prompts/<name>.md`) at both scopes, with the rename toggle and removal every managed kind has.
- The desktop app registers the `kendex://` scheme on macOS, Linux and Windows, so a marketplace or package link opens in the app; a link it cannot follow shows why on the marketplace list.
- The commit-guards pre-commit chain runs `bot-instructions check --staged` itself where that package is installed, resolved like doc-limits and preflight; consumers drop their wrapper scripts.
- `tools/harness-smoke` also proves a rendered MCP server, command and Pi extension load, and asks Antigravity through its `agy` CLI instead of calling it an IDE with no CLI.
- A place card on Projects, and My Library narrowed to an empty place, offer "Add packages to <place>". Browsing from there remembers the place, so the install opens on it.
- A packages table gives each row a checkbox: tick several and one Install opens the same guided flow, with "Everything here" beside your selection on a marketplace page.
- Out-of-date packages show wherever the package or its place is: Home counts them, a place's card counts its own, and a My Library row is marked "Update available".
- The commit dialog opens each file kendex wrote, a project's skill links included, so you can read the change before deciding what to do with it.
- A diff of a file whose bytes are not all text says so, so nothing is approved that was never shown.
- A package's page reports its repository setup per project — active, not active, needs repair, could not check or unavailable — with Set up, Repair and Check again, from a check the package declares.
- Name another private env file on a package's Customize tab and saving records it as `KENDEX_ENV_FILE`, which both package loaders read. The choice saves on its own, with no key typed alongside it.
- Credentials saved in Customize go to the project's private env file — `.env.local` unless `KENDEX_ENV_FILE` names another, read from the same settings layers the packages read it from.
- A package declares the credentials it reads in a `[secrets]` table, and Customize configures them: a masked field per key, saying whether one is stored and which file it goes to.
- Change folder… is on every project's menu, and `kendex project reconnect --from <old> --to <new>` does the same from the shell.
- A project whose folder moved offers Locate folder: point it at the folder it is in now, and it keeps the packages and files already there.
- Hooks can declare a summary beside their description, the plain line a person browsing reads. Every package the kendex catalog offers now shows one.
- `skill-load-check` hook: markdown edits wait for `docs-writing`, other edits for `code-quality` and `linear.sh` calls for `linear`; `KENDEX_SKILL_LOAD_RULES` adds a repository's rules.
- commit-guards arms a third git hook, `pre-push`: a breach a rebase replayed in is refused. It runs the checks a push can scope and names the ones it skips. Re-arm each clone once.
- The pre-push hook now also runs doc-limits, md-format and md-refs over what a push carries, so a breach a rebase or cherry-pick produced is refused before it leaves the machine.
- `kendex tier-model <harness> <rank>` prints the model a tier-ladder rank names, and orch's `oversee-succeed` starts a successor overseer once a 1M-window overseer passes its context mark.
- orch: `ORCH_OVERSEER_SUCCESSION = "off"` stops the overseer from launching its own successor; it writes its handoff and asks you to start the next session.
- A `[hooks.<name>]` declaration takes an `env` table, and kendex sets each entry for that hook's script in the command it registers.
- orch: an overseer reaches another repository's overseer with `lane-mail peer ask` and `peer send`, replies thread with `--re`, and a send into a lane another repository owns is refused.
- On Claude Code, Codex and Pi, a lane-mail halt stops a working lane at its next tool call and mail arrives after each call; `open-terminal --wake` refuses a working Claude Code or live Codex lane.
- orch: `lanes pick --model <name>` chooses an account on the usage window that walls that model rather than on its binding one.
- orch: `lanes pick --lane <config-dir>` judges one named account on the fleet pick's own usage rule, measuring only that directory.
- orch: `open-terminal` refuses a `--lane` that `lanes list` inventories when its usage window for the model in `--launch-flags` is full or unmeasured, so a launch does not open on a usage banner.
- `open-terminal --state-dir` names the workflow-state directory a lane record is written to, so a launch run from another repository lands in the fleet state the watch reads.
- orch: `lanes state <item>` prints one lane's state - working, idle, asking, walled, exited or unjudged - from the same judge the watch and the wake ask.
- orch: a lane hands itself off. Its turn-end hook holds the turn at `ORCH_HANDOFF_CONTEXT_TOKENS` or `ORCH_HANDOFF_HEADROOM_PCT` until the lane writes its handoff record.
- `kendex-cli-git` on the AUR: the kendex command alone, built from the latest commit, with none of the desktop app's dependencies.
- Add one `lane-close` command that exits a finished lane, closes its hosted sandbox and tmux window, preserves whole-file render edits, and records the lane as done.
- orch: the overseer hands itself over before it runs out. Its turn-end hook refuses the turn end at its own context and account marks, and the watch reports a reached mark as `overseer-mark`.
- A tagged release candidate publishes as a pre-release, and a build that is itself a candidate takes its updates from the candidate channel in both the app and `kendex update`.
- The app asks you to accept its Terms of Service and Privacy Policy when it first opens; the command line says so on its first run. The version and date are recorded on this computer.
- `add`, `apply`, `check`, `refresh`, `remove` and `verify` frame and group their output on a terminal and close on what they did; others keep plain lines. `KENDEX_UI=plain|pretty` forces either.
- `kendex marketplace check` reads a package's `kendex.settings.toml.example` the way a consumer's shell reads it, naming each defect with its line. TOML syntax errors surface one per run.
- Plans and audits carry one note per settings key that installed packages ship with different defaults, naming every package, every default, and the one that would be seeded. Agreement stays silent.
- A skill's Customize tab lists the settings it declares, with the author's explainer and the package default, and saves them into the project's `kendex.settings.toml`.
- `audit-issues team` audits the team's Backlog, Todo, In Progress and In Review issues in one pass, including the ones sitting in no project, and recommends a project for each of those.
- A package's page has a Projects tab: a card per project it is installed in, with when it landed there, its own Update, and a Remove that leaves the other projects alone.
- growth-guards adds a `prose` lane, on by default: a date, an issue number or a past-state word fails in the markdown agents load. Scope: `GROWTH_GUARDS_PROSE_PATHS`; off: `GROWTH_GUARDS_CHECKS`.
- `lanes context` reports each live lane's context use as percent consumed, read from its pane status line; `queue-wait` gains a `conflicting` verdict when a PR's head conflicts with its base.
- `kendex version-compare <a> <b>` says where the first version stands against the second under SemVer precedence: newer, same, or older.
- `kendex bookmark` lists, shows, saves, forgets and installs saved marketplace items, over the same saved list the app reads.
- Bookmarks: save a package or curated set from a repository or folder marketplace in My Library. A saved item opens its own page and installs through the ordinary install; saving changes no project.
- Add the code-scrub command to audit merged pull requests for unused code, duplicate logic, excess scope and unmet issue requirements.
- growth-guards gains an opt-in `comments` lane: a history reference (issue id, `#NNN`, date, revision narration) in a source file's comment text fails, at commit scope and over the tree.
- After a write into a git project, kendex offers to commit the files it wrote, commit and push, or open a pull request; the CLI also takes `--commit`, `--push`, `--pull-request` and `--leave`.
- `doc-drift-check` (Claude Code Stop) blocks a stop once per set, naming unchanged docs over changed code, `Covers:` entries matching no file, and, if topics have entries, uncovered code.
- preflight fails an added line piping a shell writer into an early-closing `head` or `grep -q`/`grep -m N`, whose SIGPIPE aborts a `pipefail` script or reads as a false no-match.
- `apply`, `refresh` and `verify` manage instruction shims: a `CLAUDE.md` importing every tracked `AGENTS.md` for Claude Code, and `context.fileName` in `.gemini/settings.json` for Gemini.
- `kendex marketplace check` refuses a `# required` marker alone on a comment line, where it marks nothing, in any case and inside anything but letters and digits. It counts after a value only.
- Add `kendex update --git` and `install.sh --git` to install and follow authenticated, ordered builds from the main branch. Each install resolves one immutable set of prebuilt downloads.
- growth-guards gains `md-format` (one paragraph per line, checked at commit on the files it touches), `md-refs` (dead links, citations and decision IDs) and the `md-reflow` rewriter.
- commit-guards' `md-refs` lane fails a `<path>::<phrase>` citation in Markdown unless the path names a tracked file whose bytes hold the phrase.
- `reviewer-read-only` and `reviewer-stop-check` hooks (Claude Code): a reviewer subagent's edit, repository write, commit or push is refused; a stop leaving the reviewed worktree dirty blocks once.
- A settings template can declare the values a key takes, on one `# values: a | b | c` line. Customize offers a picker over them, and `kendex marketplace check` refuses a list nothing can pick from.
- `kendex template` lists, shows, creates, edits, installs and deletes saved package selections, and registering a project can fill it from one.
- Templates: save a group of packages in My Library and install it into any project. Create one from a marketplace selection, or from a project's own packages, leaving that project unchanged.

### Changed

- The version number restarts at 1.0.0 after the vstack 5.x line, so a 5.x install is offered no update and is reinstalled fresh from any channel.
- The seeded `WORKTREE_SYMLINKS` default lists only paths git does not carry. An entry does nothing when git carries every path under it, so drop those; one with untracked children still links them.
- **Breaking:** the worktree skill no longer installs JS dependencies. Run installs in the main checkout and link its `node_modules` via `WORKTREE_SYMLINKS`; an unlinked JS worktree warns.
- **Breaking:** skills resolve settings as env > `.env.local` > `.kendex/settings.toml` > `kendex.settings.toml` > default, `[env]` only; a lingering `.env` is ignored, so move it to `.env.local`.
- Precedence exceptions: deep-research reads env and `.env.local` only; `REVIEW_GATE_MODE` reads env and the committed `kendex.settings.toml` only; `LINEAR_API_KEY_OVERRIDE` beats a project key.
- **Breaking:** settings values are single-line double-quoted strings with no
  `"` or `\`; any other shape, a duplicate key, or an unparseable table header
  fails the load. Rewrite an offending value.
- **Breaking:** kendex no longer reads the pre-2.0 mutable clone in the source cache. Nothing has written that layout since 2.0; a scope whose only copy is there reads Pending until a refresh.
- **Breaking:** `byte-ceiling`'s staged lane judges a file a commit changes, not only one it adds, and reads type changes and moved-and-grown files. A repo editing an oversized file needs a row.
- **Breaking:** `size-ratchet` refuses a test-class baseline row HEAD's baseline does not carry or carries lower. Rows already at HEAD keep; a test that outgrew its class is split, not frozen.
- The review gate's pending status names the repo's own configured evidence sources — `no review evidence at <sha> yet; expected from <names>` — instead of reading as a block on someone's approval.
- **Breaking:** the pi-hooks pre-commit listener (0.7.0) defers to the git hooks kendex armed and refuses a bypass or an unarmed repository. It runs no fmt or clippy; arm with `kendex guard install`.
- **Breaking:** a `core.hooksPath` naming a directory answers "could not determine" from `kendex guard check`; the stand-down prints where git says it is set, then says to clear it there and arm.
- **Breaking:** hooks are armed only when the marker is in both hook files, both are executable and `core.hooksPath` is unset. `guard install` stands down under any value. New: `kendex guard check`.
- **Breaking:** `guard uninstall` disarms the repository. Every work tree and nested project shares one set of commit hooks, so an uninstall from any of them takes the hooks for all.
- The worktree skill's broken-`.agents` recovery stops assuming one repo
  layout, and asks you to link to it rather than paste it into `AGENTS.md` /
  `CLAUDE.md`, where no refresh can reach a copy.
- The `review-gate` writer workflow copies verbatim: no per-repo values left. Adopted copies drop each `default_branch || 'branch'` fallback; a `check_run` opt-in reads `REVIEW_GATE_CHECK_RUN_NAME`.
- Consumer CI runs `review-gate`'s validate step in place of the engine
  selftest: package behaviour is proved upstream, so a repo checks only the
  configuration and wiring it owns.
- **Breaking:** carry-forward exclusions take one grammar, path characters plus `*`. Rewrite a `?`, `[...]` or backslash entry as a literal path or a `*` glob; `--check-config` names the offender.
- A project's skills work on clone: every tool but Claude Code reads `.agents/skills` directly, and Claude's link is relative now, so both commit. Existing installs converge on the next refresh.
- Committed symlinks need Developer Mode on Windows; without it, install with
  `--method copy`, which gives every tool a real tree of its own.
- kendex keeps `.kendex-lock.json` out of git — the one line it writes to a
  project's `.gitignore` — and says so when your own rules ignore `.agents`.
- Managing a project skill moves it to `.agents/skills/<name>` and leaves the path its tool read as a link. That tree is the content of record, so refresh never rewrites what you wrote.
- Every package surface shows its safety score in a circle with the findings behind it: the package page, the Updates table and the page you install from. Nothing asks you to review or dismiss one.
- Content kendex did not install is counted on its place's card under
  Projects and taken on from there. The Library and Home no longer mention
  it — nothing is wrong with a file kendex did not write.
- `kendex update` reads schema 1 feeds, legacy feeds with no schema included. Current is a no-op; older refuses unless `--force`. A feed with no target binary exits 0 with release notes.
- Updates: a package you edited can't be updated over; its row offers **Install as new package**, which keeps your copy under a name you choose and installs the newest version beside it.
- `add`, `apply`, `refresh` and `check --catalog` print one safety block: the score, then a line per finding — severity in words, what the rule matched, and where. Every package scores now.
- A package an update could not touch — a copy you edited by hand, files in the
  way — is now named as held back instead of reported as updated, in the app and
  in `kendex updates apply`.
- Updating or holding one package no longer brings the scope's other following packages along: the Updates page, a package page, `kendex pin` or `kendex updates apply`. `refresh` still updates all.
- `kendex refresh` ends on a ledger — `refreshed N changes · skipped K items on conflict · flagged M items on safety` — each outcome naming a next step. A run whose installs were all blocked says so.
- One conflict prints once, naming every tool it blocks and every position it
  sits at, plus how the files in the way compare with the catalog — identical,
  or which files differ.
- A hook that skips a tool now points at the hook's own `harnesses:` line in the
  catalog, and skills that require each other read `installing dev also installs
  orch, reviewer (required)`.
- **Breaking:** in `kendex check --json` a not-yet-evaluated line has `"class": "unevaluated"` where it had `"class": "unknown"`. A parser matching that field exhaustively must accept the new value.
- orch: the internal re-review loop stops at `REVIEW_MAX_CYCLES` (default 4) — `workflow-state set … rereview_panel` refuses once `cycles` is past it, so a review cannot run on before the PR opens.
- **Breaking:** `check --catalog --json`, `marketplace mine --json` and `index --json` are schema 2: counts, verdicts and tokens give way to `safety_findings`, `safetyFindings`, `checked.findings`.
- **Breaking:** the install record's format moves to version 5. Older files
  upgrade in place on the first apply; if two kendex versions share a
  project, update both.
- **Breaking:** the default Homebrew formula installs the app; CLI-only
  moved to `kendex-cli`. Migrate with `brew uninstall kendex && brew
  install vanillagreencom/kendex/kendex-cli`.
- Commit checks moved into the git pre-commit hook, which also runs rust-fmt,
  rust-clippy, and biome; kendex's harness hook refuses `--no-verify` and
  hook-skipping git config.
- **Breaking:** `KENDEX_PRE_COMMIT_RUST_CLIPPY` is gone. Set `enabled = false` under `[guards.rust-clippy]` in `kendex.settings.toml`; a custom command moves to `KENDEX_GUARD_PRE_COMMIT_LOCAL`.
- The safety check reads every file to its last byte (it stopped at 512 KB or 200 files), so large packages can show findings that were always there; unreadable ones report "Not fully checked".
- Safety scores say what they are: automated checks, not reviews —
  beside every score, dot, and the About tab's wording.
- A safety finding's message names what it fired on, never where.
- The Updates page is one row per package, expanding to a row per place. "Update automatically" is now **Follow source**; nothing applies on its own, and `kendex updates` names the place on each line.
- The `second-opinion` skill waits 18 minutes for an external review, up
  from 5. A seeded `SECOND_OPINION_TIMEOUT = "300"` must be raised by hand.
- The `dangerous-commands` check no longer reads a shell `case` pattern
  list as a command, ending false flags on skills that parse command lines.
- The project-management skill's roadmap pipeline is spec-driven and asks
  once: a reviewed plan is the spec, its approval carries through to issue
  creation, and research runs inline by default.
- `kendex init --kind skill` scaffolds now say what a SKILL.md body is for:
  commands and rules, never internals.
- Polish: project cards open that project's library, links into My Library land on a clean filter strip, the app uses the Geist typeface, and dialogs ask in the words of the button that opened them.
- `kendex updates` lists an install edited on disk, marked `[edited on disk …]`, even with nothing newer, so it agrees with the app's Home about the same scope.
- My Library rows no longer carry a customization legend, icon colour or "Customized in" line; the package page's header is the one place that says where a package is customized.
- Installing the session-start drift hook over a declaration that was switched off switches it back on, so a yes to the note is a yes to it running.
- Adding a project says only that it was added. The start-of-session note for agents is offered on the project's card in plain words, with its state shown there.
- The offer to commit follows the action you just took: it names what that action changed, appears only where that action wrote, and can commit only that work rather than everything waiting.
- The project card's start-of-session note is now Package checks: a factual state read per coding tool, an info button explaining the check, and a confirmation listing every file the setup writes.
- Let repositories tune prose and comment history terms, or run comment reference checks without revision narration.
- Multi-paragraph review-rule additions render as nested bullets in AGENTS.md. Other bot files retain their paragraph format.
- **Breaking:** move review-bot settings to `[bot-instructions]` in the effective manifest. Prefix each child table with `bot-instructions.`. Remove the separate bot configuration file and re-render.
- A git older than 2.41 is refused with one sentence: what this host's git answered, that kendex needs git 2.41 or newer to write a checkout, and to install a newer git.
- `kendex report` stamps the source commit and rendered hash the lock recorded for the reported asset into the issue marker, so triage can date a report; an undated asset stamps `unlocked`.
- **Breaking:** the updater signing key rotated. An install of an earlier build cannot verify releases signed with the new key — reinstall once from kendex.ai.
- kendex skill scripts load project settings without forking a subshell per line: reading the 310-line `kendex.settings.toml` in this repo gets about 12x faster.
- `oversee-watch` puts a usage-limit banner's reset time on the event as `resets=`, and reports a reset that has gone by as `usage-limit-passed`, so the lane is bumped rather than left parked.
- **Breaking:** the `block-repo-copy` and `block-unsafe-rm` hooks are one regex each and need `jq` and `cat`. A copy is judged by the words it spells: a `.git` or `target` source, a temp destination.
- The `session-drift-check` hook needs `jq` too: without it, or on a payload it cannot parse, the drift report is skipped with that reason instead of being repeated on every compact.
- Detached second-opinion waits reject forged completion, preserve state on cleanup failure, and tell callers to relaunch when a worker vanishes.
- A changed entry of a `kendex.toml` list keeps any key kendex does not model only while the entries around it fix which slot was its own; two changes side by side do not, and the key goes.
- An update, a version switch and a Follow source flip each say one thing: the tool whose copy went to the trash, else the tool whose copy was left as it is, else that the action landed.
- Forking an edited rendered agent now keeps that rendering's body text instead of translating its harness vocabulary back to the catalog's wording.
- `linear.sh issues add-relation` judges the blocking-level rule from each issue's own parent in one query; a cross-bundle rejection states the rule rather than prescribing a replacement pair.
- A Customize save that refuses after a leaving package's uninstaller has already run now reports it as a failure naming what ran; the reload is offered where the refusal has nothing to report.
- Deleting a package no longer waits on the read that names where to install it again: the note appears once that read lands, and Delete is live from the start.
- Skill docs drop their `--help` and README restatements; orch's delegation, lifecycle and round-closure rules move to `references/skill-rules.md`, preflight's lane detail to `references/lanes.md`.
- Clarified where code-quality and reviewer skills require package Markdown content to live.
- The `report` command no longer appears in general help or bundled package instructions; owners can still invoke it directly.
- The marketplace About tab is a profile: author, license, homepage, when it last changed, what it holds. Repository and homepage are links; Packages dates, sorts and says where each is installed.
- A marketplace's on/off switch per project moved from its page header to that page's Projects tab, and Check for updates moved from each subscription's menu to the Marketplaces page header.
- Marketplaces: Subscribed lists one card per marketplace naming the places that hold it, Packages sorts by name, Community is a card grid, and Subscribe says what it does.
- The take-over confirmation says in one sentence that kendex moves the files and each tool goes on reading them at the same path.
- The prose lane scans `docs/architecture/*.md` by default only once a repo sets `GROWTH_GUARDS_MD_SCOPE = "all"`, so a consumer's commits are not blocked before its docs rewrite.
- Catalog agents use `high` effort and the `opus` tier, except the planner, which uses `fable`.
- On Claude Code a model tier is a pin: `opus` renders as `opus`, not `inherit`. Say `inherit` to follow the session model.
- A model of the wrong shape for a harness or an effort level it does not accept is refused at render, and an `[agent-frontmatter]` key a harness never renders is a manifest finding.
- kendex no longer lists `~/.codex/prompts`, a directory Codex stopped reading in 0.118; a Codex command is a skill.
- **Breaking:** `growth-guards` is now `commit-guards` and `size-ratchet` is now `doc-limits`; keys are `COMMIT_GUARDS_*` and `DOC_LIMITS_*`. Rename declarations and keys, then run `kendex apply`.
- `tools/harness-smoke` asks Antigravity for its rendered project hook and MCP server with the scratch project attached as a workspace, and drops the agent row kendex renders nothing for.
- A marketplace's Projects tab now lists the places that install from it and opens one. Switching a marketplace off in a place, and dropping it from a place, moved to that place's card on Projects.
- `kendex source list`, `enable` and `disable` say what they do to the packages installed from a source rather than to its declaration.
- "Scan a folder" is now "Find existing projects", and says before you choose a folder that it only searches for existing setup. Choosing a folder starts the search; a typed path has its own action.
- Installing asks what and where in one place: which packages, then which places — personally, one project, several, or all projects. One Install per surface replaces the four pickers and buttons.
- After an install, kendex names every place the packages landed in, names any that refused, and offers the way to the place that now has them.
- "Subscribe and install" on a marketplace row now subscribes you personally and then asks the same what-and-where questions every other install asks, so those packages can go into a project.
- Every Update on the Updates page shows what would change before it writes — one package, one place's worth, or everything.
- The Updates table's package name opens that package, and the place beside it opens what is installed there.
- A marketplace page has no Projects tab. Each package and each curated set names the places it is installed in and opens them; the source's location, its alias and those places are on About.
- Curated-set cards open from anywhere on the card. The name, the description and the counts read as three steps, and the Open button beside the name is gone.
- A row, card or chip that names a thing now opens it, by click or by Enter, everywhere in the app; a safety score opens the package's Safety tab. Open buttons that repeated the container are gone.
- The Shared files chip now names the files several harnesses read and what changing one costs; Forked, Bundled with, and a harness row's folder, version and count badges say what they are too.
- Comparing package versions, previewing an update and reading your own edits all open the same full-height panel over the page, and closing it leaves you where you were.
- Every screen that lists files draws one tree with folders you can open and close, and the file or its diff beside it: the package page's new Files tab, the marketplace page, and the commit dialog.
- A package's Overview reads top to bottom — where it came from, whether your harnesses load it, its version, then its README — and its files moved to a Files tab of their own.
- The update review shows what an update changes in the same file tree and diff as the rest of the app, with the two versions named above it.
- Home, Projects, Settings and Problems use plain words: a harness is never a tool, a package is removed rather than deleted, and the status bar says when kendex last scanned.
- Marketplaces and the install dialog use plain words: a harness is never a tool, a named group of packages is a bundle, and this computer is never this machine. A name clash names no origin.
- Templates and bookmarks use plain words in the app and the CLI. Creating a template says kendex copies packages it does not manage and leaves the project's files alone.
- The Library, package pages, package checks and Updates use plain words, and switching on package checks no longer promises the check runs once other waiting changes install.
- Customize, Harnesses, project changes and the commit offer use plain words: automatic agent skills name no marketplace, and a package whose files are edited on disk is no longer marked Customized.
- The terminal uses the app's words and names no marketplace where a package may be your own. It states what --clobber and a failed refresh do, and a no at a write question writes nothing.
- Save on the Customize tab now shows which files the edits on the page land in, grouped by file, before it writes one.
- Installing into a folder that is not a project yet asks first and makes it one, instead of refusing until a tool directory is created by hand. Your home directory is not one of those folders.
- A hook's command and an MCP server's endpoint moved to the package's details, under what each kind calls them.
- My Library rows and the package page show what a package's author says it does, not the command a hook or an MCP server runs.
- Hovering or focusing a package name shows its summary, with More opening the package page when the author wrote more than fits.
- Library search reads the same words the marketplace search reads, so one query finds a package in both.
- An MCP file another program left empty is no longer a problem where the scope that writes it declares and records no server. One that will not parse or read, or lacks a managed server, still is.
- The desktop app sorts what it shows into problems, decisions, notices and updates. Problems and the footer hold only what needs action; Home's notices and updates can be dismissed.
- A failed scan or update check, missing installed files and an unreadable project folder show red on every screen, and a decision waiting on you shows orange.
- `block-worktree-refresh` and `skill-load-check` read commands with the `commit-guards` skill's library, and refuse every shell call where that skill is not installed.
- **Breaking:** a lane-host provider must implement an `append` verb, and hosted `lane-mail` sends refuse until it does. Refresh a lane host made before this release; the verb runs its clone library.
- The orch overseer's fleet is one record: `open-terminal` writes each lane into the oversee workflow state, and `oversee-watch --state` reads the live fleet from it before every pass.
- orch: `oversee-watch` and `open-terminal --wake` share one judge; a wake names the state it refused on and never resumes a lane mid-turn. Without `/proc` it refuses a lane whose harness is running.
- orch: the overseer succeeds itself when its account headroom reaches `ORCH_OVERSEER_HEADROOM_PCT` too, onto an account above that trigger, so an account wall leaves no fleet unattended.
- doc-limits: the shipped byte ceiling for a root `AGENTS.md` is 8 KiB instead of 16 KiB. A repository not rendering bot-instructions keeps the old ceiling by setting `DOC_LIMITS_CLASSES`.
- bot-instructions: `[bot-instructions.repo] code_review_path` names the rendered doctrine file, which must sit directly under `.github/instructions/`.
- bot-instructions: an `AGENTS.md` § Code Review Rules region longer than its directive line is a finding — `adopt` reports it under `agents-region`, `check` under `drift`, `render` replaces it.
- bot-instructions: `.github/copilot-instructions.md` points at `.github/instructions/code-review.md` rather than restating five blocks, and CodeRabbit reads it through `code_guidelines`.
- bot-instructions: the review doctrine renders to one file per repository, `.github/instructions/code-review.md` by default, and the `AGENTS.md` § Code Review Rules region is one line pointing at it.
- **Breaking:** Commit `.kendex-lock.json`; machine fields move to `.cache/kendex/lock-local.json`. Move an old lock, then run `kendex apply --record-existing`; clones must apply before agent forks.
- `kendex check` records a matching committed render silently and reports a differing one as stale, once per state under one session-hook deadline; a copy whose file vanished is never recorded.
- On Arch, `kendex` and `kendex-git` now install the desktop app as well as the command, and update guidance names the package that owns the install instead of guessing it.
- kendex lists a loose `.mts`, `.mjs`, `.cts` or `.cjs` module under a Pi root's `extensions/` as a pi extension, beside the `.ts` and `.js` files it already showed.
- orch: `ORCH_OVERSEER_HEADROOM_PCT` defaults to 10 instead of 20, so the overseer's successor may open on an account between 10 and 20 percent headroom, which the old default refused.
- The app's **Update now** updates a `kendex` command an installer recorded, wherever it sits. Where another owns it or it needs permissions the app lacks, the card names what moves it instead.
- second-opinion now detaches foreground-capped runs, reports its artifact and deadline, and supplies one wait command.
- CLI stdout is byte-identical for all verbs. On stderr `apply` and `add` close on the outcome ledger, `remove` heads its ops `changes:`, `check` on a needs-attention line and `verify` on its verdict.
- Keeping an edited agent as your own now reads its marketplace: the copy comes from the published file, so its `description:` and `tags:` come from there too.
- Update all now brings each place current in one pass instead of one per row, so a project with several packages behind updates settles in a single apply.
- **Breaking:** the install record is version 6 and records where each bundle sits. Upgrading rewrites it on the next apply; an older kendex refuses it rather than reading it, so do not go back.
- **Breaking:** a global skill installs into `~/.agents/skills/<name>`, the tree Codex, OpenCode, Pi, Gemini and Copilot read; Claude Code and Antigravity link at it. Reinstall global skills once.
- Each skill declares the keys a consumer sets in its own `kendex.settings.toml.example`; keys only a maintainer touches stay in its docs. The repo-root example is gone; authoring: `docs/authoring`.
- **Breaking:** `check --catalog --json` and `marketplace mine --json` are schema 3: `file` is a path to open and its line is in `line`, part of a finding's identity. Read `line`, never split `file`.
- Taking over a skill kendex did not install reads as one action: "Manage these files" on the row, a confirmation naming the move and saying nothing is deleted, then Proceed, not a red "Keep them".
- A package's safety check has its own Safety score tab, with the score on the tab beside the words. Overview opens on the package itself rather than on the check's findings.
- Every issue audit recommends cancellations for work the code already satisfies or that duplicates other issues, not only the ones that also propose new issues.
- The package page's `Remove…` is now `Delete`, and its dialog names every project the package goes from and the marketplace to install it from again.
- A My Library row shows its customization mark when you hover the package name, so a package's description sits directly under the name at rest.
- **Breaking:** the `commit-msg` lane caps the header at `GROWTH_GUARDS_SUBJECT_MAX` (72) and demands an entry for `GROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS`; raise the cap for longer headers.
- Commits are judged for work markers on what they add: `todo-ban --staged` runs in the pre-commit chain, the index-wide scan is CI's, preflight's lane is gone, and a quoted marker is out of scope.
- **Breaking:** installing a package from a git repository needs git 2.41 or newer. Ubuntu 22.04, Debian 12 and the command line tools of Xcode 16 and earlier ship older ones — install a current git.
- orch: the filing bar still decides at the review cap, so a below-bar finding is declined rather than filed there, and a finding asking for an unordered product decision never files.
- **Breaking:** kendex reads only the format it writes. Move a refused lock file aside, keep it, and apply again: it is the only record naming a pi `hooks/` or `hooks.json` beside its root.
- **Breaking:** a `kendex.toml` from another version is refused and left exactly as written. Move it aside and declare again, copying from the file you moved.
- **Breaking:** a pi hook left in the older layout beside a scope root is no longer enforced: the carrier runs `kendex/hooks/<name>.sh` alone. Install the item fresh to have it guard again.
- A place the safety check could not read now says so, instead of showing the score from the last reading that worked. Scores are dated by when the check last ran, not per place.
- Marketplace switches, Unsubscribe and Turn on no longer wait on a fresh subscription read: they act, and the engine refuses anything the rows turned out to be wrong about.
- Creating a marketplace refuses when the containing folder does not exist, naming it, instead of making it. Importing refuses two selections whose copies would land on each other, naming both.
- `kendex fork` and its rename refuse any kind but a skill or an agent, naming the kind. Hooks, commands, MCP servers, plugins and Pi extensions have no fork path.
- A forked item's frontmatter `name` line is rewritten whole, so a trailing comment on that line does not survive the copy.
- A conflict listing no longer offers `kendex apply --replace-unmanaged` where the plan shows an item the sweep would refuse on. Each item's own way out is unchanged.
- `--replace-unmanaged` refuses the whole run when an item it swept up has a conflict replacing cannot settle, naming each blocked item and what blocks it. Nothing is planned or written.
- A message, heredoc or comment naming one of those words is refused too, and so is a `commit` word the split leaves beside a `git` word. Pass the message with `git commit -F <file>`.
- Pi now enforces the kendex hooks: `pi-hooks` spawns the rendered `.pi/kendex/hooks/*.sh` scripts instead of its own copies, so Claude, Codex and Pi run the same bytes.
- A bypass is seen only where a word already spells it. One the shell would join, unquote or expand into the word is not seen: a quote, a backslash, a brace, a variable, an `include.path`.
- **Breaking:** the `pre-commit-check` hook reads words, not shell, so a no-verify flag, an `-n` cluster or a `core.hooksPath` key refuses. It needs `jq`: install it wherever the hook runs.
- `kendex check` relays growth-guards' own commit-hook verdict when it has one, and only where `.git/hooks` holds an install's helper. kendex reads no hook file; the stranded-shim report is gone.
- second-opinion's detached runs no longer keep a supervisor process. The wait command owns the deadline, returns 124 there, and stops the worker when it still matches the identity recorded at launch.
- A Mine folder whose GitHub remote is spelled with `www.`, mixed case or a trailing slash now resolves as the repository it is, so it can be submitted like any other.
- **Breaking:** a hook selector spelling `planner` now gates every `role: planner` agent, and no rename rewrites it. Renaming a roleless `planner` agent drops its gate, so declare the role first.
- **Breaking:** the visible-pane default follows `role: planner`, not the name, so an agent named `planner` with no role now renders in the background. Declare the role.
- **Breaking:** Claude, Pi and OpenCode withhold the question tool by `role: planner`, not by the name `planner`, so a rename changes no tool. Declare the role on a `planner` agent that has none.
- The review gate's awaiting status is one line naming the head, with no list of eligible sources, and the harness-render review rule moves into the review-gate skill's `references/vendored-paths.md`.
- The `kendex` command an installer records is identified by its path alone, and Update now no longer refuses a command that changed under the card: it installs and says what became of it.
- harness-ci's `harness-only` reads the manifest header shape kendex writes, and carves every skill path when a manifest says `in-place` on a line it cannot tie to a name.
- Review dispositions decline an excluded class before examining the claim, and the dev rules now order a grep for a twin before new code and ban migration or compat code.
- Coding agents now test the enforcing program at the smallest failing surface, require one control per changed review instrument, and decline redundant coverage requests.
- A four-space-indented ``` at the top level no longer protects the text below it: markdown reads that indent as a code block whose one line is the backticks, not as an open fence.
- Text inside a raw HTML block is left as authored, tool references included. A blank line ends a `<div>` or `<details>`; `<pre>`, `<script>` and `<!-- -->` end at their own closing marker.
- Changelog checks accept edits to combined release notes. Fragment validation remains; collation checks its destination before writing.
- Commit guards report stable message keys and values before their English explanations.
- Hook and rendering notices start with stable reason keys, escaped values and the source of hook exclusions, followed by their English explanation.
- A restored pi-background-tasks snapshot from before the exit-notification field replays its exit wake once on upgrade, instead of being treated as already notified.
- **Breaking:** `buildWebFetchToolResult` takes an options object only. A positional `maxCharacters` argument is now ignored: pass `{ maxCharacters }` instead.
- pi-agents-tmux reads subagent cwd dirty state with `git status`, so a worker repo's own clean/process filter runs during needs_completion triage as it does for any `git status` there.
- **Breaking:** orch auto-continues post-PR work and auto-merges once gates pass. Restore prompts with `ORCH_DECISION_MODE=ask`, `ORCH_MERGE_AUTONOMY=ask`, `PR_REVIEW_ON_TIMEOUT=block`.
- **Breaking:** size-ratchet checks document byte limits only. Delete size baselines and line/frozen settings. Trim oversized documents or add reasoned exclusions; seed, update and raise are removed.
- Kendex commits compile changed Rust crates and check changed UI code. Full tests, documentation and cross-target checks run at development completion and in CI; submit reuses the same-commit result.
- Preflight names checks that cannot run because an optional tool is unavailable. Its final result lists skipped lanes while preserving the existing exit status.
- Move container closure and base synchronization from merge instructions into tested orchestration scripts.
- Orch releases a lane after arming a merge, records its exact head, and resumes recovery or post-merge work from a detached queue verdict.
- Where packages ship one key with different defaults and your `kendex.settings.toml` already sets it, the note says your line is what your scripts read, not a default none of them reads.
- **Breaking:** the lock file is version 10. An older kendex refuses a project this one wrote, rather than seeding back the `kendex.settings.toml` keys you deleted. Update every install sharing it.
- **Breaking:** a settings template may write nothing after a value but `# required`. A trailing comment now fails `kendex marketplace check` — move it into the comment block above the key.
- `kendex refresh` writes nothing into `kendex.settings.toml`. An `add` seeds the arriving skill's `# required` keys; a save from the app writes the key it names. A key you delete stays deleted.
- review-gate's `validate.sh` names a settings source it cannot read, instead of reporting on a file it never opened.
- **Breaking:** `changelog-entries --collate` folds the changelog fragments in at release, replacing the removed `changelog-collate` tool and the `--list` output it read.
- A Linear cache built before comment pagination is no longer rebuilt for you; its first-page-only threads stay until you run `linear.sh sync --full` once, or delete `.cache/linear`.
- `kendex apply` manages a marked `.gitignore` block for the `tmp/` folder, install ledger, and cache in Git projects.
- `md-refs` judges a `<path>.md § Heading` citation in a source file's comment text and in a TOML file's string literals, as it does in markdown. A decision ID with a `§` checks that heading too.
- Doc-limits and suppression-ban read the render inventory instead of hand-kept ownership rows. An absent inventory excludes nothing; a malformed one refuses.
- commit-guards `py-names` names its remedy when neither ruff nor pyflakes is installed: install one in a CI step ahead of the commit-guards step, on every run.
- Prose and comments checks accept ordinary wording. Revision-word settings are removed; date and issue-reference checks remain.
- size-ratchet ships byte classes for architecture docs (overview 12k, topics 16k), root `AGENTS.md` 16k, nested `AGENTS.md` 6k, `README.md` 16k and nested 12k.

### Removed

- **Breaking:** vstack-era installs are not migrated. Install fresh and remove by hand the `vstack-hooks` directory (or `kendex-hooks`, from an earlier 5.x), its `core.hooksPath` and the v1 settings.
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
- **Breaking:** the `trading-design` skill is no longer offered. Run `kendex remove trading-design --scope all` wherever it is installed, or drop its `[skills.trading-design]` entries and apply.
- **Breaking:** nothing reads the old vstack names: the files, the `vstack2` directories, the repository redirect, the alias binary, `kendex import`. Rename them to `kendex` or reinstall the scope.
- **Breaking:** `--scope` takes `project`, `global` or `all` only; the v1
  aliases `p`/`local`, `g`/`user` and `both`/`*` are gone. `-g` still means
  global.
- **Breaking:** the lane chooser's `--refresh` flag is removed; renewal is automatic now. Drop the flag from any command or script that passes it, which otherwise fails as an unknown option.
- Removed review-gate's `merged-sweep.sh` and its documented steps. Nothing shipped ran it; `pr-watch.sh` remains the reducer.
- **Breaking:** `dev-return-write --kind analysis` (use `fix` or `implement`), `workflow-state init --team` (drop it), and bare-numeric `workflow-state` keys (pass the `issue-N` key init got).
- **Breaking:** the orch settings `PR_REVIEW_QUORUM`, `PR_REVIEW_NUDGE`, `PR_REVIEW_NUDGE_SECS` and the `worktree-claim` script. Delete the three keys; the gate no longer nudges or awaits a quorum.
- Removed the legacy `REVIEW_GATE_OUTAGE_CONTEXT` setting from review-gate. **Breaking:** set `REVIEW_GATE_OVERRIDE_CONTEXT` instead — it takes the same value and the same default.
- **Breaking:** GitHub skill commands no longer accept deprecated `--json`; use `--format=safe`.
- **Breaking:** A skill found only at its own pinned revision, not at the one its source points at, can no longer be assigned to an agent; pin the source there too. Other pins need no change.
- The browser mock backend (`VITE_MOCK`) is gone; the app is exercised in the real window.
- **Breaking:** preflight drops the `reviewer-attribution` and `workflow-run-syntax` lanes; `PREFLIGHT_BOT_NAMES` is gone, so delete that key. PyYAML is no longer read.
- **Breaking:** the github skill's `pr-data` output drops `reactions` on the PR and its comments, along with the unused bot review-status helpers behind it. Bot reactions were never a gate.
- The refusal that blocked `issues create`/`update` when `LINEAR_API_KEY_OVERRIDE` met a real checkout's cache. `LINEAR_INLINE_KEY_CACHE_OK` is inert; a test isolates its own cache dir.
- `linear.sh cache issues validate-completion`. **Breaking:** use `linear.sh issues validate-completion`, the spelling every workflow already calls.
- `linear.sh sync` no longer sweeps legacy per-issue `comments/*.json.lock` files. Remove them once with `rm -f .cache/linear/comments/*.json.lock`.
- The Updates page's Follow source column and Held tag are gone. A package's own page holds it at a version, through its version picker.
- **Breaking:** the commit-guards hooks no longer skip a repo-local doc-limits that refuses `--staged`; it blocks the commit or push. Make that doc-limits accept `--staged`.
- **Breaking:** the `post-edit-lint` hook and Pi's `postEditLint` setting are gone, so no `.rs` write runs clippy. Run `kendex refresh`, or `kendex remove post-edit-lint` if you declared the hook.
- A pi `hooks/` or `hooks.json` beside a scope root is unmanaged: kendex reads, writes, scans, lists and removes nothing there, `kendex remove` included. Yours to look at and move aside.
- The `auto-update-check` setting. No toggle exposed it, so hand-editing it to false was the only way to set it, and that no longer stops the check; the key is ignored now rather than refused.
- **Breaking:** `kendex marketplace browse --community` is gone; it only reported that the community directory is not built yet. Browse a subscription by name instead.
- `kendex updates apply <kind> <name>`. **Breaking:** bring one package current from the app, or a whole place with `kendex refresh` or `kendex updates --apply`.
- **Breaking:** `worktree-session-guard release --expect-gen` and the `generation` field of its `status`/`list` JSON are gone; release by owner, or with `--stale`/`--force`.
- **Breaking:** `worktree restack continue|skip|abort` now requires the tool-created pending marker and state token on every paused restack; re-create a worktree whose state predates them.
- **Breaking:** The worktree skill removed `create --recover-local` and `remove --force`; bare create still refuses surviving local branches.
- **Breaking:** pi-caveman reads only the `mode` setting. `enabled` and `defaultMode` are ignored, so a config using them now resolves to `off`; set `mode` to the mode you want.
- **Breaking:** the Pi extensions drop their old-layout migrations. Reinstall on the current layout instead of upgrading in place.
- `install-git-hooks` no longer rewrites the shebang of a hook it wrote earlier: a hook under an interpreter it cannot verify is refused. **Breaking:** delete that hook and re-run the installer.

### Fixed

- `mutation-stability` no longer reads a stable test as unstable, or a killed mutant as a survivor, when the caller shares a build cache. What it writes is stamped past the build, so cargo rebuilds.
- A blocked declaration now names every position its take-over empties. A
  tree read through a tool's own link sits at two, and `apply --plan` named
  one while `--replace-unmanaged` moved both.
- `kendex adopt` is no longer offered for an item whose tools hold copies that differ. Capture refuses those, so the suggestion named a command that always failed; the offer asks what the verb asks.
- In the app, a row you just settled no longer comes back. A machine-wide
  check that started before the change and landed after it overwrote the
  newer reading, and kept it for the freshness window.
- `kendex report --skill` files against kendex, like `--agent` and `--hook`
  already did; a skill installed from anywhere else still files against your
  own repo.
- `kendex report --upstream` takes a GitHub repo spelled any way — shorthand,
  https URL or `git@` — and files against it when your lock records the asset
  from that repo.
- `worktree cleanup` and `worktree remove` prove a merge two ways and no other: ancestry into the default branch, or the pull request whose head commit is the branch tip. Every keep names its reason.
- `kendex remove`, and any CLI apply, refresh or unsubscribe that drops a
  package, runs its declared uninstaller before the files go, so dropping
  `growth-guards` disarms the commit hooks.
- A refresh cuts opencode.json's `kendex-hook-` `instructions` rows to what it renders now, so a row kendex wrote leaves with its render. Other rows are untouched; pre-rename rows go by hand once.
- Removing a skill whose harness copies are only partly present now finishes. A copy already gone, or a link whose target was, failed the move to the trash and rolled the removal back on every retry.
- harness-ci's `harness-only` reads manifests at the selected head and answers `false` for a diff touching an in-place skill or `.agents/hooks` script: project source no longer stands CI lanes down.
- The `task-completed-check` hook counts untracked files as changes, and blocks on any nonzero clippy exit or a git that cannot say what changed. A new-file task and a killed clippy passed before.
- **Breaking:** the `block-bare-cd` hook reads commands with `jq` and refuses every Bash call it matches on a host without it. Install jq wherever the hook runs. Its parser stopped at the first quote.
- The Library's From column says "Your own" for a skill adopted in place; it read as a marketplace with no repository. The Mine import inventory reads such a skill's bytes from the tree it sits in.
- `kendex fork` refuses an item that is already yours — `local`, or a skill
  adopted `in-place`, whose tree of record a fork would quietly demote to a
  render of a hidden copy.
- The `block-bare-cd` hook refuses a bare `cd` with no path. It changes to
  `$HOME` for every later tool call, the move the hook exists to stop, and
  only `cd <path>` was caught before.
- `worktree`: the recovery text consumers copy into `AGENTS.md` no longer calls a `.agents` directory broken. A repo committing its render has tracked files there, so a child is what breaks.
- `worktree`: an untracked `.gitignore` under a tracked-content `WORKTREE_SYMLINKS` entry is copied, not symlinked, so the worktree ignores what the main checkout does and git's symlink warning stops.
- The settings template no longer seeds `.cursor` into `WORKTREE_SYMLINKS`, so `worktree fix-links` passes in repos that do not use Cursor; one that does adds it back in `kendex.settings.toml`.
- A later `Fixed in <sha>`, `Declined:`, or `Tracked: <issue>` reply clears
  a review thread's tracking claim at the gate, and a `Fixed in <sha>` reply
  is never a claim, whatever its prose says.
- `kendex refresh` says when this clone's `info/exclude` ignores `.agents`, as it did for `.gitignore`, from any linked worktree too. That rule hides the tree from git status, so nothing commits it.
- The lock records each skill's tree and links. **Breaking:** redo an install an older kendex made by hand: refresh, remove that scope's lock file and the trees and links kendex wrote, then apply.
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
- The commit chain finds its gates in a project whose directory name ends in a newline. The path was truncated, so a gate that would have failed the commit was reported as not installed.
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
- A hook of your own that mentions a guard marker mid-line is left alone: no longer refused, rewritten or reported as a stale shim. A line that ENDS with the marker is still the installer's own.
- A blocked commit is told to run `kendex guard install`, which restores the
  helper, instead of `kendex refresh`, which does not.
- The guard verbs find the package under the project's own root, so a kendex
  project below the git top level is no longer reported as having none.
- **Breaking:** the `pre-commit-check` hook refuses a commit where no git hook is armed, naming `kendex guard install`, instead of running the repository's own guard scripts. Arm the hooks.
- Agents no longer promise a `{{KENDEX_FAILURE_REF}}` that nothing defines:
  the failure-routing line now points at `kendex report --help`.
- OpenCode, Gemini, and Copilot agent renders list required skills at
  `.agents/skills/…` — the tree those tools read — instead of per-tool
  directories a default install no longer writes.
- Preflight no longer flags upstream `TODO` markers in vendored harness mirrors, and reads `.pi/kendex/` as a managed mirror like the other harness trees, so repos committing their renders can pass.
- Simultaneous app and CLI account calls share one token refresh, so they no
  longer invalidate the sign-in by rotating the same refresh token twice.
- Registry refresh timeouts and rate limits no longer sign the machine out;
  the app or CLI keeps the credential and can retry.
- A package's Follow source switch moves at once, on or off, instead of freezing the Updates table for the seconds its write takes. Rows in other places stay live; the flipped package's place waits.
- `kendex adopt` and the app's keep refuse a path-shaped name and a symlinked destination, so neither trashes a directory outside the tool's folder. A namespaced skill is kept from one directory.
- `kendex check` exits 1, not 2, when packages await re-evaluation, so the session-start report no longer opens with "kendex check could not run". `kendex drift-hook` reinstalls the changed script.
- A hook found in a settings file is safety-checked on its own entry, not the whole file: a `permissions.ask` guard naming `mkfs` no longer flags every hook beside it, and one carrying it scores.
- A project reached through a symlinked path no longer misreports an
  editor save conflict as a plain failure or loses package update
  timelines to a "history could not be read" warning.
- The preflight skill's `unwired-suite` lane no longer flags new test files
  that a bare `vitest`/`jest` script runs through the runner's default
  include glob.
- A pi-hooks carrier registered through a scoped path such as
  `./packages/@vanillagreen/pi-hooks` no longer draws the false "nothing
  will run it" warning from `kendex apply`.
- The review-gate predicate matches `REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS` only in a review body's first line, so a review quoting a pattern in later text counts as evidence again.
- Customize › Customized packages lists every package you changed at that location, hand-edited and forked ones included, so it matches the Library's "Customized in" mark instead of settings alone.
- macOS builds are Developer ID signed and notarized: installing from any
  channel no longer ends in "kendex is damaged" or an `xattr -cr` workaround.
- `preflight`'s fail-open lane no longer asks a non-executable file under `scripts/lib/` for a `set -euo pipefail` preamble; nothing runs it. An executable one keeps the check.
- A settings or `kendex.toml` save from a copy something else wrote since — another window, a resize, the CLI — no longer puts the older file back: it is refused and retried, or offered Reload.
- A refused apply's rollback keeps the hand edit that refused it — a
  `kendex.toml` change landing mid-apply — instead of restoring the older
  copy over it.
- The Library works from the keyboard: each package name is a button, so Tab reaches it and Enter opens it. Dragging across text to copy it no longer opens anything, in any list or card.
- The worktree skill's `push` refuses a flag it does not recognize and an empty target, rather than pushing the current checkout by default. `push --check-args` validates alone.
- The worktree skill's `fix-links` no longer reports "Restored symlinks" for a path it did not restore: it names every configured entry left unhealthy and exits non-zero.
- An apply is no longer refused as "scope is busy" while nothing else runs: locks release when an apply finishes instead of waiting on a file a just-launched program held open. Same for downloads.
- Home's Installed tile counts what the Library counts — packages, not
  per-harness copies — so the tile and the table it opens agree.
- A harness's name on the Harnesses page opens the Library showing
  everything that harness has, the way a project's name already does; the
  count badges still narrow to one kind each.
- Home answers a failed scan: the page says why and offers Scan again, and a later failure keeps the last figures, labeled as the last kendex could check. The status footer stops saying "Up to date".
- Updates and Marketplaces say when a check failed and offer a retry; rows kept from an earlier check are headed as last-checked, and acting on stale rows waits for a good check.
- Overlapping reads land in order: a slow early read cannot overwrite a fresher answer, changes apply in the order made, and a change that fails midway re-reads instead of showing old rows as current.
- Codex reads the same skill as every other tool: the invented 8 KB
  SKILL.md split is gone (Codex has no such limit), and old `details.md`
  splits are cleaned up on the next apply.
- Everywhere the app says a package is customized it now says where
  ("Customized in vg · 1 of 3 places"), and a place the app has not read
  no longer passes as untouched.
- A debug build keeps its own home and cannot touch your real setup —
  the `lock.json was written by a newer kendex` surprise. Opt out
  deliberately with `KENDEX_REAL_HOME=1`.
- Items blocked by files already on disk no longer deadlock, half-install or misreport: apply names the files and both ways out, and `apply --plan` and `verify` count what they skipped.
- Pi no longer halts every session start in a managed project: kendex's Pi hooks moved out of Pi's reserved `hooks/` directory, and refresh migrates an existing install, moving only what kendex wrote.
- `kendex apply` and `kendex refresh` print what they cannot change and
  why, instead of "nothing to do".
- The Linux app draws at the right size on HiDPI Wayland (native client, X11 fallback; `KENDEX_GDK_BACKEND` chooses inside the AppImage), and the menu entry carries the window class and icon sizes.
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
- Match marketplace pages and the Community list against subscriptions by repository identity on any host, and keep two Windows drives declaring the same folder path as two marketplaces.
- Name the directory a linear command could not resolve a repository from, and let second-opinion run on when its install sits outside one, instead of exiting at git's bare 128 in silence.
- Say why the Settings page, the version it shows, and the marketplace authoring guide could not be read, instead of a blank page or a loading skeleton.
- Keep Pi extension records after partial updates, honor pinned revisions, and route app reports when an install record is unreadable.
- The second-opinion review reads a JSON verdict inside a code fence on macOS, where the fence extraction printed two sed errors on every run and never matched.
- Keep Name, Kind, Safety and Status on screen in the Packages table at every window width, giving up the other columns by priority as the window narrows.
- A config file several surfaces read is warned about once, so Home, Problems and the footer count one broken file as one.
- Home's Needs attention rows say what is wrong and what to do: the edited row names each package and opens the Library narrowed to them; an unreadable config file gets a row and a Problems card.
- A skill read through a tool's link to a shared tree is warned about once, and the Library's edited facet keeps the rows a failed re-check left behind instead of waiting on it.
- The package header and the Customize page read the rows a failed update re-check kept, as the Library and Home do, so a fork or edit is never shown on one page and unknown on the next.
- The Customize page's place chips keep their marks after a failed re-check that kept its rows, the same rule the Library and the package header read.
- Setting up a project's package checks refuses a registered folder that is gone, naming the path, instead of rebuilding it as a project-shaped folder. The card offers nothing until it is found.
- Tell one installed file from another by what the scan read, so a tool's two roots and an import name the same file, and a package page says what it is waiting on.
- Keep a package and a same-named file nobody installed apart: each opens its own page and carries its own origin. A copy a tool stores as another kind keeps its Remove.
- Open the row you clicked: a package and a same-named file nobody installed no longer open each other's page. Counts wait for the check behind them, and say so when it fails.
- Keep a package installed for several tools at once one package, and keep an unrecorded file's page from saving another package's settings.
- Two files nobody installed that only share a name are two Library rows, each opening its own page, while one file several tools read stays one row.
- Tell installations apart by the file each one is, so a package and a stranger sharing its name never take each other's origin, page, tabs or actions.
- Read every package's origin, places, actions and counts from the record that claimed the file and the scan on screen, so nothing shows another package's state or an older answer.
- Credit a hook registration to the package only in the file its install wrote, and keep an unrecorded row's page from reading or writing the declared package beside it.
- A page about a file nobody installed no longer reads or changes a package that shares its name, and counts wait for a check that answers about the scan on screen.
- Show one Library row per installed package, whatever each tool stores it as. A hook installed for six tools was six rows reading "Not managed"; it is one row now, under its own type.
- Give a repository's own pre-commit hooks the git a plain commit gives them when kendex commits: their glob pathspecs match their files again, and `git check-ignore` answers instead of exiting 128.
- Say that a marketplace's Packages tab is still reading while its read is out, instead of stating that the marketplace offers no packages before anything has read it.
- Say that a subscribed marketplace has not been downloaded yet on its Bundles, Packages and About tabs, naming Check for updates, instead of reporting that first state as a read failure.
- A marketplace's Packages tab counts an installed hook in the places holding it, and no longer credits a catalog name to an unrelated package whose registration happens to share it.
- The Updates page says when nothing is installed and when no check has run, instead of calling both up to date, and keeps the check wherever a scan could not read the whole machine.
- My Library's Installed table now drops its lower-value columns on a narrow window instead of running the health dot off the right edge; they come back as the window widens.
- Pressing a greyed-out button inside a row or card that opens something, such as Update while an update runs, now does nothing instead of opening the package page.
- Stop Home's edited-packages row from promising to keep or discard the edits; those choices belong to the package's own page.
- Say on a bundle page and a package page that the marketplace hasn't been downloaded yet, as a plain line rather than a read error, instead of showing the engine's refresh error for that first state.
- Say on the Library's Packages tab that a subscribed marketplace hasn't been downloaded yet, naming Check for updates, instead of counting it among the marketplaces kendex couldn't read.
- Say on an installed package's Files tab and Overview that its source hasn't been downloaded yet, in the header's words, instead of calling that first state a failed read.
- Show no installed count on Home, My Library or a project card after a failed update check, nor on a card whose place it missed; Home and My Library say why. Count packages whose files are missing.
- A narrowed My Library row takes its Where cell, its missing-files badges, its source and its click from the places that narrowing shows. Fork badges still name every place a package is forked in.
- A Library row for a package whose files were deleted shows its description and is found by a search of that text, read from the install record as an installed row's is.
- `kendex refresh` installs and records a declared Pi package with no install record, files matching its source and no `npm install`, once confirmed, asking again about anything that adds to its plan.
- Codex/OpenCode: opus → `gpt-5.6-sol`, fable → `gpt-6-astra`, sonnet → `gpt-5.6-terra`, haiku → `gpt-5.6-luna`. Pi: same sonnet/haiku ids under `openai-codex/`; opus/fable inherit.
- The commit offer after a refresh no longer reports a rebase in progress on a checkout holding only a leftover `REBASE_HEAD`, and its line names the rebase directory it found.
- A Bash call whose prose, heredoc body or comment names a kendex write verb runs from a linked worktree; a verb the shell would run, quoted or in a heredoc it reads, is still refused.
- A Claude account whose access token expired is renewed before the lane chooser measures it, so a launch gets a usable account rather than "expired"; an account that cannot be renewed is refused.
- Prevent Claude-native MCP and unqualified Pi tool calls from being dispatched more than once — thanks @Destiner
- `kendex check` no longer records a hook, MCP server or plugin whose settings entry was removed, broken or moved from under it after the deep pass proved it, so `kendex apply` does not put it back.
- Pi web tools keep `web_fetch` on installs with no Exa key: its direct HTTP, GitHub, PDF and YouTube paths never needed one. — thanks @Aelbannan
- Background task widgets disappear when their last finished task reaches its configured retention limit instead of showing zero tasks. — thanks @lhl
- Report and library ownership work without a readable lock. Verification keeps record errors visible, and record-existing recovery preserves matching renders even when CI metadata is absent.
- Let architecture topic `Covers:` entries match a directory, one file, or a shell glob.
- CI derives generated files from the kendex writer inventory, so carrier extension source and unrecorded code always run product checks.
- Pi updates preserve source ownership under the scope writer lock, and verification checks recorded package bytes for drift.
- Keep comment findings from readable files when another file cannot be scanned, then report the incomplete measurement.
- Let existing oversized files hold their size or shrink while the byte ceiling still rejects new oversized files and further growth.
- Applied migrations and other immutable first-party files can use the shared comment and prose exclusions while configured migration checks protect their bytes.
- Fixed the comments scanner for quotes and heredocs inside quoted Bash command substitutions.
- preflight accepts `.jsonc` and configured JSON-with-comments paths, including VS Code color themes, while commit checks use only staged shared settings.
- Preflight's `mktemp-trap` lane finds an `EXIT` trap in a shell file of any size, so a large new script is no longer reported as untrapped at random.
- Count packages, not installations, on the Harnesses and Projects kind badges, so a badge's number is the number of rows in the Library view its click opens.
- Cite a planned install's safety findings at the catalog file the bytes came from, not at a destination nothing has written yet; the line comes too, where the install is a verbatim copy.
- The macOS app opened from Finder runs on the login shell's `PATH`, so it finds the git a person installed to clear the 2.41 floor; a login shell that stalls no longer holds the launch.
- Bot instruction checks leave installed package files unchanged, so kendex verification does not report Python caches as local edits.
- `oversee-watch` takes a repeated `--repo` and runs the review-gate reducer over every one, so a PR needing attention in a second repository is an event instead of silence.
- Linear resolves a project name to the live project when a canceled one shares it, in `--project` writes and in `projects get` / `list-dependencies`; a name with no live match is refused.
- Library, Browse, Updates, package details, Customize, Marketplaces, Sources, the report dialog, `kendex apply`, and `kendex remove` now show malformed record errors.
- A check and the writes that change what it reports now wait for each other, and one write runs at a time, so a check answering mid-write no longer puts the old rows back.
- The review gate now refuses a decline that answers a finding with a test count and the suite it belongs to: `Declined: lifecycle 104/104 and the full tools/guard pass` turns it red.
- Pi resolves the project the way `kendex` does before rendering, so a session in a subdirectory gets the same guards. `PI_CODING_AGENT_DIR` is used only when root-anchored.
- Linear issue output now separates open blockers from completed and canceled blocking-relation history.
- second-opinion: a review CLI killed by a signal exits 6 naming the signal, distinct from a failed CLI (5); a union records a killed lane as status "killed" and exits 6 only when every lane failed.
- **Breaking:** `import --json` is schema 2. An empty `hash` is a failed read only where `problem` is null. A set `problem` names bytes a catalog cannot store. Import refuses a Codex TOML agent.
- `open-terminal` refuses a launch whose working directory is gone, and honours `$TERMINAL` then `xdg-terminal-exec` ahead of ghostty.
- The GitHub skill's diff summary now keeps Rust risk flags on large diffs instead of dropping early matches under `pipefail`.
- Refuse agent forks and hide fork actions when a harness cannot render their access settings, instead of recording a fork that may widen access.
- The catalog's bundles installed nothing, and `kendex marketplace new` scaffolded the same mistake: members belong under `agents`/`skills`/`hooks` lists, not a `members` key.
- The marketplace Bundles tab lists every curated set the catalog declares, including ones whose members it no longer offers. A pending read shows a loading line and a failed one shows its error.
- A marketplace page opened for a repository outside GitHub no longer sits on a disabled "Checking subscriptions…" forever; it offers Subscribe once the subscription list has been read.
- `ci-wait` now retries transient CI failures on large job logs, and `ci-logs` classifies and returns them instead of falling back to the job name or exiting empty.
- `kendex check --catalog` fails a `[bundles.<name>]` body with a key kendex does not read, `add --bundle` refuses a set the catalog offers no member of, and apply keeps what such a catalog installed.
- `linear.sh cache cycles list --team X` now filters the cached cycles to that team, in both the space and `--team=X` spellings; the flag was previously accepted and ignored.
- The package page names a source no fetch has downloaded yet and drops the Try again beside it, instead of reporting a failed read that re-reading cannot lift.
- The package page's file list says when its read did not land and offers it again, instead of drawing a package with no files.
- Linear `cache projects get "<name>"` returns the one live project when a canceled one shares the name, instead of printing both as concatenated JSON at exit 0.
- `linear.sh issues --milestone <name>` resolves inside its `--project`, refuses an ambiguous name naming the candidates, refuses a name with no project, and reports a lookup failure as one.
- `oversee-watch` no longer exits 2 at start on a repo with no `LINEAR_TEAM`: the team triage check is skipped with one stderr note and the watch runs its other checks.
- A read no longer fails because kendex could not write or delete its cache. A full or read-only home costs a re-fetch next time instead of an error, and an expired sign-in still says so.
- The account now says so when the failure is on your machine — a refused credential lock, a full disk, a second kendex holding it. It used to read as "Offline", blaming a directory nothing had asked.
- An update, discard, fork or install-beside whose apply fails re-reads the machine like one that landed, so Home and the audit stop counting copies its uninstallers removed.
- The Library's From column and a marketplace's Installed in column keep the newest read of where each copy came from, so an older read answering late no longer puts a pre-install answer back.
- The orch round that cuts an oversized branch can be recorded and accepted: `dev-round-write --cut` skips only the over-limit refusal, and acceptance refuses a cut that left the branch over the cap.
- `worktree` run from outside a git repository now names that directory and the checkout to run from, instead of exiting 128 with no output.
- A failed install, subscribe, repository change, source toggle, unsubscribe, editor save or audit action re-reads the machine like one that landed, so Home and the audit stop counting removed copies.
- Three sourced kendex libraries build their first line or error detail in-shell, so a value past the pipe buffer cannot abort the sourcing script.
- `gh` cross-PR verification records a build or test failure whose error output is one very long line, instead of ending the run with no result.
- `linear.sh issues add-relation` and `remove-relation` no longer strip the team from the cached issues they refresh, which dropped those rows out of a `cache issues list --team X` listing.
- `linear.sh cache` listings honor `--team` or refuse it: `issues list --team X` filters and resolves `--cycle current` inside X; a flag the cache cannot honor is refused, not ignored.
- `linear.sh` cache date filters compare in UTC, so `--cycle`, `--updated-since` and `session-status` answer off a UTC host as they do on one; with no cycle running, previous and next cut at today.
- `linear.sh cache projects list-dependencies` returns the live project for a name a canceled one shares, and refuses a reference with no live match instead of printing nothing at exit 0.
- `kendex apply` keeps what a catalog installed when nothing declares it now and the catalog will not read, is gone, or is off — one declared by name included — and the plan names that catalog.
- `kendex add --bundle` refuses a set whose members land on none of the tools the install targets, naming the set and the tools, instead of recording an install that puts nothing on disk.
- Catalog checks report set members the catalog does not offer and fail the check with the set and member names.
- A `[bundles]` table, set body, member list or description written in a shape the reader will not read is that catalog's breakage instead of sets and members that silently go missing.
- Saving in the editor, installing a package, applying a repository effect, or checking your submissions now shows why when the app cannot reach its engine, instead of quietly going idle.
- A Pi hook on `PostToolUse`, `Stop`, `TaskCompleted` or `SessionStart` runs: kendex registered it and reported it enforced while the pi-hooks carrier dispatched tool calls alone.
- A project hook for Codex, Gemini, Copilot, Pi or Antigravity finds its script when it runs, so it works in a project with no git repository or below the git top level. Pi needs pi-hooks 0.10.0.
- `worktree restack continue` names unstaged files instead of offering a `skip` that drops the resolved commit; `restack abort` exits a restack Git moved or dropped; suites drop an inherited git env.
- A curated set's tool picker opens before any member is ticked, offering every tool the set could install to, and Install all is held back when that picker is emptied by hand.
- Installing into a project from a personal marketplace whose alias the project already uses for a different repository is refused instead of silently rebinding the project's subscription.
- An agent's rendered Required Skills list is preceded by a blank line, so the render passes the markdown format lane every harness reads it under.
- `kendex add --pi-extension` names the real path (declare the package in `kendex.toml`, then `kendex update-pi`) instead of saying support is coming.
- The CLAUDE.md shim is written beside a project's own AGENTS.md files only; an AGENTS.md inside a harness render tree such as a rendered skill gets none.
- A hook's advisory instruction file (OpenCode, Cursor) renders one paragraph per line with blank lines between, so a fresh install passes the md-format lane.
- The prose lane honours `GROWTH_GUARDS_MD_EXCLUDES`, so a vendored third-party skill is carved out with a reason instead of by narrowing the scan paths.
- A person's edit to a Pi agent's `effort` key survives a fork instead of reverting to the publisher's value.
- A Pi agent whose model inherits the session now renders its effort as an `effort` key, which `pi-agents-tmux` passes to the child as `--thinking`; before, the effort was dropped with the model id.
- `open-terminal --help` states the default mode (tmux inside tmux, a GUI terminal outside), `--ghostty` inside tmux warns, and GUI terminals no longer inherit `TMUX` or `TMUX_PANE`.
- `commit-guards all` runs byte-ceiling over every tracked file, and `all --base REF` over the changes since REF, so the batch summary names a scope it read; the CI `byte-ceiling --base` step goes.
- Hold the marketplace Install buttons back when narrowing the tools on offer leaves nothing picked, rather than installing to no tool and reporting success; a hidden tool returns with its offer.
- Agents install for Antigravity at the global root alone, the one `agy` reads: a project declaration now says Antigravity cannot hold one there rather than writing a file nothing reads.
- The commit-guards installer refuses to arm from a linked work tree, where it would point every commit in the repository at scripts that vanish with that tree; run it from the main checkout.
- Adding a project says "Adding project…" while the write is out, refuses a second press, and closes as soon as the project is registered rather than waiting for the whole machine to be read.
- Going back out of a browse begun for one project no longer leaves that project selected, so the next install does not quietly target it.
- Switching tabs while browsing for a project keeps that project, so the install still opens on it.
- A new project card says "Checking installed packages…" while its contents are read, and "Project added; package check failed" with a Try again if that read fails. Zero is never shown unchecked.
- A package that changes the repository asks about it after the install has said what happened, instead of interrupting a multi-place run with a second window.
- An install whose files landed says so even when kendex cannot read the place back afterwards, and names what it could not read beside that place, instead of reporting that the install failed.
- An install into several places says which places took everything, which took only some of it, and which refused — with the reason each refusal gave, beside the place that gave it.
- The commit offer lists what a project holds now, not what an earlier write left, so a commit can no longer take files the offer never showed you.
- The questions after an install come one at a time and in order: what was installed where, then anything a package changes in the repository, then what to do with the files kendex wrote.
- A folder search always reports: what it found, what is already added, that nothing matched with an offer to add the folder itself, or why the folder could not be read with a Try again.
- Installing a package from a marketplace table offers its optional extras, the same as installing it from its own page.
- Searching a folder kendex cannot read says so, with the reason, instead of reporting that the folder holds no projects.
- An update review left open while kendex re-reads now follows what it reads, and waits for the changes to be on screen before it writes.
- A folder marketplace is titled by the name its catalogue declares, with Local folder and its path, so a checkout subscribed as `.` never reads as a marketplace called `.`, read or not yet read.
- A marketplace's card, page, curated sets, packages and the breadcrumb above them show one name: the one its catalogue declares, else what its source resolves to, read or not yet read.
- A package with no README says so on its Overview instead of showing whichever of its files came first.
- The commit dialog compares the bytes git will commit, so a checkout that converts line endings no longer shows every line of a file as changed.
- The commit dialog never reads a file through a folder replaced by a link, and it opens both halves when an update replaces a file with a folder of the same name, either way round.
- The commit dialog reads the file you opened, not another whose name its own name would match as a pattern.
- The commit dialog says when it could not read a file rather than drawing it as one the commit deletes, and it opens a file in a project with no commit yet.
- The commit dialog reads only the files kendex wrote whole, never the configuration files it edits one key in, and it names a permission change the commit carries even when the text changes too.
- Installing into a project from the command line adds that folder to your projects, so the app shows it and its packages without a second command.
- Naming a project through a link and a `..` reaches the project at that path, instead of a sibling of the link that could be another project entirely.
- A project reached through a linked folder reconnects under the name you type for it, and the line after a reconnect says a folder is clean only where a read actually covered it.
- A place's marketplaces dialog closes when its folder stops being readable, instead of leaving writes aimed at a folder kendex can no longer open.
- A project card whose folder could not be read no longer opens that place, so the Library cannot draw it as an empty project and offer to install into it.
- A project whose folder kendex cannot read says so, instead of reporting "Nothing from kendex yet" and offering to add a start-of-session note to a folder that is not there.
- Picking a folder with no kendex record in it says exactly that, rather than claiming nothing is installed there.
- A place is offered for an install only where a scan actually opened its folder, so a project added since the last scan is never treated as one kendex has read.
- Reconnecting a project leaves nothing behind pointing at the folder it came from: no page to go back to, no read still landing, no question waiting.
- A read that fails after a reconnect leaves the new folder saying it could not be checked, instead of the card reading as a project with nothing in it.
- A reconnect is kept when a settings read lands around it, instead of the card going back to the folder the project left with the new one already recorded.
- Picking the folder a project already points at says what is recorded there when something else owns it, instead of only that the project already points there.
- A project whose recorded folder now has a link standing where it was is still reconnected and still removed by naming that folder, instead of being reported as one kendex never registered.
- `kendex project reconnect` takes a relative folder name for a project whose folder has moved, the way the other project commands do.
- Removing a project from the list drops the questions kendex was still holding about files in its folder.
- Home says to restore access to a project folder it could not read, instead of sending you to point the project at a folder it never left.
- A project folder that could not be read is told apart from one that is gone, a folder kendex cannot open included, and a place it has not read takes no install.
- A template holding a bundle and a plugin under one name is refused as one contested name before anything is written, instead of installing the first and refusing the second part-way.
- `kendex verify` fails and `kendex refresh` says so when a package kendex armed here reports its effect not in force, or its check cannot be taken, naming how to arm it again where that applies.
- A template install or a collection add on a fresh machine reuses the seeded kendex subscription instead of refusing it as a duplicate.
- The app's Refresh on a fresh machine fetches the kendex marketplace the Marketplaces page already lists, so a template install no longer waits on a subscription nothing could refresh.
- A first launch lists the kendex marketplace as subscribed instead of refusing Subscribe as a duplicate, and a project's first write no longer adds a second kendex subscription.
- An install no tool it would be declared for can take is refused before the manifest gains a declaration, and the guided install's Install button stays off with no tool found on this machine.
- A hook, command or MCP server installs by name from the local source, so a template carrying one installs every member; a template install that refused names what it wrote, or that nothing went in.
- An installed package whose file was deleted outside kendex no longer reads as healthy: Home, the Library and the package page say so, and the package page offers Repair.
- Head the commit window with what is uncommitted in the project, the way the terminal does, instead of attributing every pending file to the action just run.
- Hold kendex's own committed render inventory to the set its render plan produces, so a change that lands a render without refreshing that inventory fails before it merges.
- A refused push or pull request ends on git's or gh's own refusal rather than on a hook's output, with the hook's lines kept above it.
- A package whose rendering was deleted outside kendex keeps its row in My Library, marked missing files with Repair, and a place's kind badges count it, instead of both dropping it.
- A template, collection or `project add --template` install refused before it writes leaves no subscription, local copy, declaration or projects-list entry behind.
- `.kendex-generated.json` lists one path per line, sorted, so a merge conflict between branches adding renders is bounded to the lines holding those entries, not the whole set on one line.
- Removing a harness clears stale shared skill records without false edit conflicts. Held replacement installations protect shared files, and edited files retain ownership records.
- A non-interactive refresh checks every selected scope before it writes, and reports prepared warnings and findings before it refuses missing consent.
- `kendex refresh` over a fresh clone checked out with CRLF line endings (`core.autocrlf=true`, the Git for Windows default) leaves `git status` clean instead of reporting kendex's files modified.
- Show a shortened path or name in full in a tooltip that stays open while the pointer moves over it or keyboard focus rests on it, and give screen readers the full value.
- A lane launch runs through the account's own launcher command where the machine has one (`1claude` for `~/.1claude`), and a pane observed running another account than the one picked is closed.
- `apply` and `remove` take an undeclared Pi extension whole: settings entry, append-system block, bin links, package directory and record; refresh reports the orphan instead of refusing.
- A Copilot hook with an empty matcher is registered without a `matcher` key, so it runs on every tool instead of being skipped.
- orch: a successor overseer stopped at a folder-trust dialog is reported as `successor-dialog` with the pane line, not as a deadline that names nothing.
- orch: a successor overseer launches through the account's own command where the machine has one, instead of under an environment prefix that command overwrites.
- A hosted mailbox that several overseers write keeps every line, where two writing at once used to keep only the later one with no error.
- Relaunch an overseer lane in one call: the resumed session carries its continuation line, except on a hosted Codex lane, and a merged lane keeps its worktree instead of failing on a rebase.
- The github skill's dismiss-review, and resolve-thread and unresolve-thread given several thread ids, print their summary and exit on whether the mutations landed instead of aborting.
- Overseers sharing one watch state directory no longer re-report handled mail: each keeps its own mailbox read position.
- Windows installs and later clones use one portable identity for rendered text, including first Pi package installs, removals across CRLF and LF checkouts, and a refresh over an uncommitted render.
- session-drift-check: a session with no kendex command on PATH now gets the project's package count, the install route for its platform, and the rule that rendered trees are never hand-edited.
- Armed app and CLI updates refresh bot instructions. Commit and restore preserve other AGENTS.md edits. Unarmed updates run no package code and show setup guidance. App errors show findings first.
- Restore a Pi package registration during refresh when its installed files and lock record are still current.
- Keep the drift-hook test stable on systems that install kendex in a system binary directory.
- `kendex update-pi` and the session drift check name a second copy of a managed Pi package under either `extensions/` directory Pi loads, once per run, with the paths to move.
- Cap the source cache: each marketplace keeps the snapshots its locks name plus the newest three (`KENDEX_SOURCE_CACHE_KEEP`), and a command-line refresh says how many older ones it removed.
- orch: a Codex lane or overseer successor records folder trust for the directory it opens before the harness starts, so an unattended launch no longer parks on that question.
- A dependency two items share stays on while either is on: switching one hook or skill off no longer parks a companion the other still runs.
- A hook names the hooks it cannot work without: declaring `lane-mail-check` alone installs its two wrappers, and a wrapper is left out or removed wherever its judge will not run, naming both.
- An edit to a package you forked is the fork's own content now: apply keeps the files, folds them into the fork, and stops reporting a conflict it offered no way out of.
- The plan names each item and where its write lands, following a symlinked harness directory. A write leaving the project is refused, and a rollback puts bytes back only in the file they came from.
- second-opinion now stops external model CLIs when callers terminate their process group.
- orch: the re-review cap now counts only re-review cycles, so QA and pre-PR fix rounds stop spending it, and `REVIEW_MAX_EXTERNAL_ROUNDS` (default 4) bounds external PR review rounds.
- Renaming a fork now writes the new name into the package's own file, so the renamed skill or agent installs instead of being refused at the next apply for calling itself by its old name.
- Keeping or renaming an edited agent no longer hands back denied access, drops its skills, hooks or a section, or changes what others render. It refuses a name it cannot hold or another agent uses.
- Switching a package's version, and turning Follow source back on, now say when the copy on disk was held back instead of reporting an update that never reached the files.
- Updating a package a bundle also carries now moves that package alone — the bundle and its other members stay on the version they were installed from.
- Keeping a plain-named skill no longer deletes the namespaced skills stored under that name; it is refused, naming what is stored there.
- A globally installed agent is told to read its required skills from the directory they are installed in. It named its harness's own directory, where the default delivery no longer writes them.
- The warning that a command installed as a skill is offered by other tools names every tool that reads the directory it landed in, not Pi alone.
- Forking, diffing or updating a skill installed with `method = "copy"` reads that tool's own copy. It could read a same-named skill out of the shared tree instead, or find nothing at all.
- A skill whose shared rendering is refused no longer reports that the other tools reading that directory can see it; nothing is installed there to see.
- Growth-guards and size-ratchet exclusion lists carve a tree back into the scan with a `!pattern` row. **Breaking:** an existing `!`-leading row now carves; escape it as `\!foo` to exclude.
- Mine now says when it could not check your submissions, instead of reporting every marketplace as never submitted and offering to submit work already in review.
- An expired sign-in now reads as expired everywhere instead of quietly signing you out: a submit that meets one stops offering the submit, and the submissions poll no longer hides it.
- Signing in as another account no longer shows the previous account's name, or reports its sign-in as expired. An identity read belongs to one sign-in.
- A sign-in the server rejects is removed from the credential store, so `kendex login` signs you in again instead of telling you to log out first. If the removal fails, the CLI says what to run.
- macOS: Update now works on a Homebrew cask install, and the app relaunches into the new version instead of exiting. It refused the symlinked `/Applications/kendex.app` launch path before.
- A refresh no longer deletes another project's files. **Breaking:** a record naming a path outside its project is refused; delete the lock, then apply to reinstall.
- A keychain that will not release the sign-in now says so, in the app and in `kendex login`. It used to report the community directory as unreachable, sending you to check a working network.
- Settings seeding no longer misplaces a key — inside a multiline value or array, in a second `[env]`, or beside an `[[env]]` it cannot join — and reads a quoted key as the key it is.
- Forking in place, and keeping a marketplace's packages when you unsubscribe, now refuse a symlink inside `.kendex-local` that would have put the copy outside the project rather than in it.
- Forking an agent from a rendering that says tool names in its own harness's words keeps the words the catalog published it in, wherever the capture can still tell which line is which.
- A forked or kept agent keeps the skills it was rendered with; if the scope stops offering one, kendex refuses and names it rather than dropping the agent's Required Skills section.
- Cycle planning, roadmap planning and creation, and the research workflows refresh a stale Linear cache before their first read, instead of planning against whatever the cache last held.
- A package page's mark now answers for the package everywhere, as its Library row does. The Customize tab marks which places and settings hold your changes, and names the skills an agent gets.
- Codex now loads the agents kendex renders for it. Every one carried a `tags` key Codex rejects, so it ignored all of them and warned at launch.
- Forking an agent takes off exactly what the next render writes again — nothing of the person's or the publisher's own prose, and nothing left behind to stand twice.
- Forking or renaming an agent onto a name that drops a built-in tool deny is refused, on every declared tool. Catalog settings carry; a fork needs one known revision across them, so refresh first.
- A settings-template value spanning several lines now seeds whole, instead of an unterminated line that stopped `kendex.settings.toml` parsing. A value nothing closes is named, not written.
- Syncing the Linear cache now fetches comments in their own paginated request and pages them to completion, so every thread it fetches is cached whole rather than cut off at its first page.
- An issue audit now reads every issue's comments and compares against Canceled issues, so a duplicate or cancellation call no longer rests on the description alone.
- Linear sync now warns when the page limit truncates an issue pull and reports how many issues it fetched.
- Linear cache: `LINEAR_CACHE_ROOT` points the cache at another root, and per-issue comment lock files stop accruing. A sync clears the ones already there.
- The package page follows an update started on its Projects tab, its buttons name the place they act on, a failed read says so with a retry, and a package with nothing to read stays quiet.
- On Linux, `git commit --amend` no longer demands a changelog entry the commit already carries: the commit-msg gate judges an amend against the parent it will have.
- The safety score no longer flags a dangerous switch a document writes in a code span, so a README or SKILL.md explaining one scores clean. The switch written as code still counts.
- Windows: `kendex add`, `refresh` and `apply` no longer fail with "Access is denied" before changing anything, so packages can be installed there at all.
- On Windows, hook commands and the uninstaller line a package prints are spelled with `/`, so a shell runs them; a root whose plain spelling names the same folder no longer shows as `\\?\C:\...`.
- A skill only a pinned revision carries is available again, and one two pins disagree over is not: an agent's Required Skills row, and a fork of that agent, now match what the plan installs.
- The desktop app can now update a `kendex` command installed before kendex recorded which file it had installed; running the command writes that record.
- On Windows, a package a harness installs is now one kendex verbs can find, a project skill's link reaches the tree it names, and a package's history and its origin read the same as everywhere else.
- Pi's end-of-turn clippy reaches the agent in every mode, headless included, not only the interactive screen; a run that proved nothing (no workspace, a timeout) says so instead of reading as clean.
- growth-guards and preflight judge a file by its own bytes: neither a `-diff` attributes row nor a path named `0:name` hides a marker, a suppression or an added line from a scan reporting clean.
- Adopting a plain skill no longer deletes an item a declared catalog stores deeper under that name: the adoption is refused and names what is stored.
- A catalog checks out the same bytes on every machine: its own `.gitattributes` no longer converts line endings or runs a smudge filter, and the mirror kendex clones carries no host git template.
- After an elevated `kendex update`, the next run of that command tells the app which bytes are installed, so the sidebar keeps offering to update it instead of falling silent.
- A code span's reach in the safety score is the block markdown gives it: a fence, thematic break or HTML block ends it, a lazily quoted or indented continuation does not. Cached scores refresh.
- On Windows, a refusal that names the item already stored in a name's slot spells its path with `/` instead of `\`.
- On Windows, the three adopt refusals that name where an item was expected spell that path with `/` instead of `\`.
- The commit gate no longer refuses an anchored grep over a `.git` path or behind a read-only `git log`.
- Skill audits read markdown with a full parser: a switch a table row keeps out of a code span now scores as a live use, and one behind a list indent or autolink no longer does.
- The commit gate no longer refuses `git config alias.st status`, which runs no commit, or a commit message continued across lines with a backslash, whose word it now joins as bash does.
- `kendex check` no longer reports a repository's armed git hooks as unverifiable from a linked worktree, or from a checkout whose path contains an apostrophe.
- `kendex verify` and `kendex check` now answer inside a git worktree, and `kendex refresh` there works on the worktree: a lock copied in from the main checkout reads against the tree it sits in.
- orch: a delegation states its worktree as a cwd precondition the agent proves with `pwd -P` before anything repo-relative, so a shell in another lane's worktree is caught at the first command.
- Merge-queue watch retries now consume the replacement supervisor's verdict instead of the failed supervisor's stale result.
- Merge-queue cleanup now binds to the PR branch recorded for the watch; a worktree checked out on any other branch is kept instead of removed.
- The review gate refuses a decline whose reason is empty or is nothing but a label it knows, such as `frozen` or `out of scope`. Colon or not: `Declined, out of scope` turns it red the same.
- A version switch or Follow change that fails now re-reads the package. It could leave the old version on screen as settled, over a manifest the failed attempt had already moved.
- second-opinion stops the external CLI's whole process tree when a call times out, and at a detached run's deadline when the worker still matches the identity recorded at launch.
- Names and paths off a catalog or a scanned folder reach the terminal as their own characters wherever the CLI prints them. `kendex show --file` and `--readme` still print a file as its own lines.
- On Bash 3.2, commit-guards admitted an uppercase commit type and refused its own helper on an apostrophe path; second-opinion, verification-scope and tools/guard aborted or misspelt a path.
- Every shell suite but linear's runs on macOS `/bin/bash` 3.2 in CI, where the Bash 4 constructs the text scan cannot see fail.
- `kendex.toml` is edited in place. Adding, forking, adopting and detaching change the keys they name, so the comments, blank lines and key order you wrote stay where you put them.
- The Copilot mark now takes its harness colour in the app, instead of rendering black.
- Importing a skill or agent under a new name writes that name into the copy's own declaration instead of landing a package named something else, and refuses where the file carries no frontmatter.
- Pi now runs every `PreToolUse` hook kendex installs for it, custom ones included, not three built-in guards. Needs pi-hooks 0.9.0: `pi install npm:@vanillagreen/pi-hooks`.
- **Breaking:** Mutation checks now require `--build CMD` and reject empty selections, non-compiling mutants, and timed-out runs instead of reporting misleading verdicts.
- `refresh` and `apply` write back the install record a scope declaring only Pi extensions lost. **Breaking:** `verify` exits non-zero on a scope that declares items and has no install record.
- A tool reference between backticks in two different table cells is now reworded for the reader's harness. The cells are separate blocks, so markdown never quoted it, but it used to pass through.
- A rendered agent body keeps every byte of a code sample that sits in an indented block or in a backtick span closing on a later line; the prose rewrite used to edit tool names inside both.
- `install.sh` installs the kendex command on macOS. Its elevated write passed `install -D`, a flag the mac's `install` reads as taking an operand, so the install exited instead.
- The Marketplaces page and the Customize page no longer go blank when drawn before the settings read lands: reading the project list re-rendered the window until it crashed.
- Switching Follow back on now re-reads the scan and the audit behind its own apply, so the machine inventory and the scores stop answering for the bytes the flip replaced.
- A merge-queue supervisor whose runtime directory or repository is deleted under it now stops instead of retrying, and `queue-wait` refuses with a named error and exit 4.
- An agent requiring a skill installed with `method = "copy"` is told to read it from the directory that copy wrote, not the shared tree a copy never writes.
- A hook that names no harness in its `harnesses` line no longer installs on Antigravity, whose hook payload is not the shape such a hook reads; the plan notes the skip.
- BSD sed, awk, wc, paste, touch, date, seq and mktemp differences are handled where the shipped scripts and their suites hit them; open-terminal and orch state writers need no setsid or flock.
- Shipped workflow templates and scripts pass the comment checks that consumers install.
- Count what a failed collection install already wrote: a step that subscribed or pinned before it failed now reports those changes in the closing ledger instead of none of them.
- A command installed as a skill no longer warns that another tool offers it when that tool's loader would reject the installed name.
- Comment checks use a configured tracker pattern for issue IDs, so technical names pass by default. Date and numeric issue checks remain enabled.
- The note saying which other tools already see an installed skill no longer names a tool whose loader would reject the skill's name.
- Refresh removes departed harness renders. OpenCode hook removal clears generated Bash permissions and trashes empty settings files while keeping user settings.
- A detached second-opinion run whose worker died without publishing a status now reports at once, instead of waiting out the run's whole deadline.
- Gemini commands now expand the arguments you type: a command body's `$ARGUMENTS` is written into the Gemini prompt as `{{args}}`, which Gemini reads.
- Gemini CLI is detected by its `~/.gemini/settings.json`, so a machine with only Antigravity installed no longer reads as having Gemini CLI too.
- CI stops treating a file as generated when the last rendered package becomes in-place source.
- CI runs product checks for new generated-path claims, and refused writes no longer grant generated ownership to user files.
- Refresh keeps committed inventory entries for skipped items.
- Refresh replaces stale Codex and Pi hook commands and removes duplicate handlers after a command template changes.
- Installer notices and errors start with stable keys and values. Invalid version options report option errors before a download starts.
- pi-agents-tmux schedules a rate-limit retry from a usage-endpoint window that reports only a reset time, instead of ignoring it and falling back to a later source.
- A dependency landing in a place whose lock can't be read now says its standing isn't known, instead of reading "not offered here", and the install picker won't let you ask for it.
- A place whose lock kendex can't read no longer hides packages or blanks Updates: rows read "Not known" even from cache, pages there offer no install — a redirected one isn't checked — and say so.
- A Problems card names the place and which of its files kendex couldn't read, stops calling a Personal problem a project's, and sets the error in body colour with its steps at body size.
- An install or subscription is judged against the place it lands in: its records, a name already taken there, and that place's added instructions. A problem somewhere else no longer blocks it.
- Long folder paths no longer push the Install and Create template dialogs past the window edge; the folders shorten and the buttons stay in view.
- In a narrow window, each row of a marketplace's package list still says how many places hold the package, under its name, and opens those places.
- A template's page lines its breadcrumb up with its title.
- Pressing a row's tick box in a marketplace's package list or in Bookmarks selects the row instead of opening the package, so Install selected and Add to template appear.
- The Updates page counts the places its updates are in, not its rows, and the update review says "Update 1 package?" for one package in several places.
- Skill installs and content hashes exclude tool caches at every directory depth, while nested skills can still publish authored build directories.
- Removing a package from the app now runs its declared uninstaller first, so the repository is disarmed before its scripts go, and the action says what ran.
- Group matching safety results across harnesses and avoid repeat audits of identical content during refresh.
- Your git's line-ending configuration no longer decides what a package installs; on Windows it added a carriage return to every line. Reading your own repository is unchanged.
- A catalog checked out before the line-ending fix is rebuilt after you upgrade, so the fix reaches what your cache already holds and not only what you download next.
- A `# required` key you have not set is named even where kendex cannot write `kendex.settings.toml` at all — something else in its place, or `[[env]]` in the file. It was dropped in silence there.
- `suppression-ban --update` keeps its baseline file's mode instead of rewriting it owner-only, and no longer stops for a prompt when that file is read-only.
- A lane launches under one spelling of its work item, so the mailbox it writes is the one the overseer reads; a mailbox differing only in letter case is refused, never opened beside the first.
- Markdown checks catch broken incoming references after target edits and check links followed by a section heading prefix.
- Markdown section references accept sentence punctuation and bare numbered headings, and check section suffixes after anchored links.
- Check recommends apply for missing recorded files so renamed packages do not cause a repeated refresh request.
- `open-terminal` now refuses a custom command with an unbalanced quote before it opens a window.
- Ownership routing checks every observed copy and accepts short Pi names. Pi check previews now refuse the same source conflicts as updates.
- Ownership stays within each observed harness. Record-only recovery rejects unresolved declarations and post-preview edits while accepting ordinary notices.
- Package pages keep the author's summary when a recorded copy is missing, using only that place's record.
- Installing from a personal folder marketplace into a project reads the folder the marketplace was declared as, not a folder of the same name inside the project.
- Pi compacting during a tool loop no longer leaves the Claude query on the replaced history: the bridge restarts it from the compacted context, carrying each tool result Pi recorded over once.
- Pi Claude reports stable error identifiers for tool interruptions, connector failures, and session repair, with a readable explanation below.
- Pi output-policy notices identify the affected count or error on a stable first line, with the explanation below it.
- `kendex refresh` now updates a Pi extension whose source changed while its installed copy is unedited, instead of failing until `kendex update-pi` runs.
- A Pi extension you disabled in the Pi extension manager stays disabled after `kendex update-pi` or `kendex refresh` reinstalls its package.
- Pi reports share byte and completion checks. Check directs repairs to update-pi; refresh reports packages it cannot repair. Failed dependency installs stay pending until a retry completes.
- Commands find the nearest project marked by kendex.toml even before it has a lock file or generated directories.
- Markdown reflow removes its temporary file when replacement fails and preserves the original document.
- Refresh reports final Pi safety and conflicts once, confirms its writes, and closes settled writes with commit handling, counts, and a drift snapshot on refusal or cancellation.
- Reviews require recorded starting state and an explicit repository for saved artifacts. Repeat earlier reviews; dirty starts and changed commits are refused.
- A package script kendex has just written now starts even while kendex itself still holds the file open: the start is retried within the call's time limit instead of failing with "Text file busy".
- The CLI refuses a project in a temporary folder (`/tmp`, `$TMPDIR`, `.scratch`) unless `--throwaway` is passed; Home's line for a folder not found offers pointing it elsewhere or removing it.

### Security

- kendex adds the `.gitignore` entry for a project's private env file before writing the first credential into it, rather than alongside.
- A credential typed in Customize is written to the project's private env file and nowhere else: never `kendex.settings.toml`, a plan description, a displayed diff, an error, a log or a commit offer.
- On Windows the private env file is created with an access-control list naming your account alone, never the folder's; a save whose list cannot be applied is refused, naming the failing step.
- `kendex update` verifies the desktop app download against the signature the release publishes, and refuses a mismatch rather than installing it. The installed app and CLI are left as they were.
- `kendex update` verifies the kendex command it downloads, not only the app: an altered binary is refused and the installed command left alone. `KENDEX_UPDATE_FEED` is honored in debug builds only.
- **Breaking:** A lock records which project wrote it, so a refresh no longer trashes a checkout nested inside the project. Existing locks are refused: delete `.kendex-lock.json` and apply again.
- The executables a Pi extension declares, and the system text it appends, now have to sit inside the package. A path reaching outside is refused the same way on every platform.
- `kendex update` and the app's Update button hold each download to the release's signed record of what it published for this target, so a real signature over another release's binary is refused.
- The update card no longer offers `sudo kendex update` for a `kendex` command it cannot write: the installer instead, or the download page where there is none. Neither is held to the release key.
- A run with root privilege writes no `kendex` record file, so a `sudoers` policy keeping `HOME` cannot point a root write at a path the invoking account owns. The next unprivileged run records it.
- Arming git hooks for one kendex project in a repository no longer lets a second project in that same repository run its own commit guards under that consent.
- A committed `kendex.settings.toml` could choose which library an orch command sourced, and could redirect which setting `orch-env` reported. Project configuration no longer sets either.
- Orch help answers `--help` and `help` before a checkout's `.env.local` is read, so it runs no shell that file holds. Bare `lanes` prints its command index and exits 0.
- Linear resource help no longer executes `.env.local` from the current checkout.

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

[Unreleased]: https://github.com/vanillagreencom/kendex/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/vanillagreencom/kendex/releases/tag/v1.0.0
[5.0.1]: https://github.com/vanillagreencom/kendex/compare/v5.0.0...v5.0.1
[5.0.0]: https://github.com/vanillagreencom/kendex/compare/v0.1.0...v5.0.0
[0.1.0]: https://github.com/vanillagreencom/kendex/releases/tag/v0.1.0
