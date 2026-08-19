# Changelog

## Unreleased

- CLI: a lock `source` recorded as a path inside `~/.vstack/cache/` now
  resolves as the remote that cache entry clones, instead of as an ordinary
  local checkout (#1495). vstack's cache is its own TTL-managed state, but
  the resolver could not tell one of its entries from a user's stable
  directory, so a single misclassification took the entry out of every
  freshness mechanism at once: `refresh` skipped the fetch and copied stale
  bytes, `cache-refresh` had nothing listed to fetch, and `check` and
  `verify` compared the install against those same stale bytes and printed
  `✓`. Every command reported success while propagation had stopped — one
  machine sat nine hours behind `origin/main` with sixteen globally
  installed Pi packages pinned to it and nothing reporting drift. The remote
  is read from the entry's own `origin`, never reverse-engineered from the
  directory name: a cache key is derived from the repository identity and is
  not reversible, and one machine holds `vanillagreencom_vstack` beside
  `vanillagreencom_vstack-ff0070a84862081c` for a single repository. It stays
  PINNED to the entry the lock named, so the fetch, the lease and the drift
  comparison all act on the tree the items were installed from. An entry
  whose remote cannot be established fails closed — `check` reports the
  entries as unverifiable, naming the file and the reason, and never counts
  them clean — and one that is simply not on disk is reported absent, as it
  always was. `vstack add` takes the same branch, so a cache path is fetched,
  leased and proved vstack's own there too rather than installed as whatever
  bytes were sitting in it — and an entry `check` refuses is an error in
  `add` as well, instead of `add` exiting 0 having installed from the entry
  `check` had just told the user to re-add. `vstack cache-refresh` reports a
  source it cannot map and exits nonzero, where it printed nothing and
  exited 0 on the same state.

  Membership is the whole cache SUBTREE, not its top row: a source recorded
  as `<cache>/<entry>/<subdir>` — what `vstack add` writes for a repository
  whose catalog is nested — resolves through its entry, which is fetched and
  leased before the subdirectory is read out of it.

  `refresh` migrates the recorded source onto the remote spec in the same
  pass that repairs `source_repo` — but only where the recorded path IS the
  directory that spec resolves to. Then resolution, the fetch, the hash and
  the spec all name one tree, and the lease resolution already holds covers
  the whole of it. A path naming a DIFFERENT clone of the same repository —
  every pre-`-<digest>` entry on disk is one — keeps its path, which costs it
  nothing now that it resolves through its own entry and is fetched on every
  refresh; `vstack add` is what moves it, and given that path it records the
  remote spec. Rewriting it instead would commit the lock to a clone the
  install did not come from, closable only by a second unbounded fetch run
  inside the lock-write loop, once per entry, on an answer that reports `Ok`
  for a fetch that failed and for a cache it could not write. A source naming
  a subdirectory is never migrated either: a remote spec names a repository
  and cannot carry one.

  `add` and `check` agree on every path under the cache root, and every
  command `check` prints works when pasted. A directory in the cache root
  that is not one of vstack's clones — no `.git`, from a half-deleted entry
  or a hand-made one — is refused everywhere, where `add` used to install it
  and exit 0 while every other command called the same string absent: the
  `vstack add <path>` `check` prescribed then re-ran that same no-op forever,
  and only `vstack remove` broke out. A cache entry that has VANISHED is
  answered from the identity the lock still records — `vstack add
  <owner/repo>` — because re-adding a dead cache path cannot work, and under
  the same-tree rule a wiped cache is the durable steady state for every
  legacy-key entry. When the lock records no identity, no `add` is offered
  rather than one that fails.

  The remembered-source chain records the tree it READ rather than the string
  it started from. A remembered legacy-key path resolves through the remote
  its entry clones, so recording the remembered string put one clone in the
  lock beside a `source_hash` taken against the other — `check` and `verify`
  then disagreed about one state — and announced a fetched remote as
  `local: <path>`.

- preflight: new `hardcoded-temp-path` lane — an added directory-creating
  call taking a literal `/tmp/…` or `/var/tmp/…` as (part of) its first
  argument fails. A literal absolute temp path escapes TMPDIR redirection
  by construction, so the directory outlives every run and leaks silently;
  one consumer accumulated roughly 159,000 stale directories before ENOSPC
  surfaced it, months of commits from the cause. Anchored to creation-call
  shapes — `mkdtemp`/`mkdir`(+`Sync`) (JS/TS), `mkdtemp`/`makedirs`/`mkdir`
  (Python), `create_dir_all` (Rust), shell `mkdir -p` at a command
  position — because the same repo counts literal temp-path FIXTURES by
  the hundred against a handful of real creation sites: a value in a
  config field or fixture string never fires, nor does a TMPDIR-derived
  path or a commented-out call. Complementary to `mktemp-trap`: that lane
  asks whether a correctly-created scratch dir is cleaned up, this one
  whether it was created somewhere cleanup can reach at all. Zero hits
  across the repo at HEAD (`preflight --all`), so the lane lands
  zero-pinned. (#1481)
- growth-guards + CLI: `install-git-hooks --check` answers, read-only,
  whether the git shims are armed, and `vstack check` folds the verdict in
  for projects with the skill installed (#1482). The hook file is a shared
  surface — any other writer to `.git/hooks/pre-commit` replaces it and
  silently drops the marked line — and until now no command could see that:
  `check` reported asset state only, so every commit between the disarm and
  the next `refresh` went ungated with nothing recording it. `--check` exits
  0 armed; 1 drifted, absent, or armed-but-dormant behind a `core.hooksPath`
  that redirects git away from the shims (its own wording, but the same exit:
  no commit runs a guard right now, and the safe failure direction for an
  ungated commit is a failing check); 2 could not determine — an unreadable
  hooks directory is 2, matching the family's rule that failure to measure
  is never a clean measurement, while provable drift outranks an unmeasured
  component. The CLI relays the verdict line rather than re-deriving it, so
  `check` and the installer cannot disagree about what "armed" means; a
  non-armed verdict makes `vstack check` exit 1 like any other drift.

- size-ratchet: three fail-closed fixes, each with its own regression pin.
  `--seed` stays bootstrap-only against the COMMITTED baseline too: its
  existence probe read the index alone, so staging the baseline's deletion
  (or a truncation) hid a live ratchet and the mode reseeded every row at
  today's sizes — growth laundered into a fresh freeze at exit 0. HEAD is
  probed as well, and a failing index query is a loud exit 2 rather than a
  green light to reseed.
  Staged settings resolution fails closed on a broken `git`: the
  tracked-source probe read EVERY nonzero status as "untracked", so an
  operational failure silently dropped a committed threshold back to the
  built-in default and passed staged content the commit does not authorize.
  Only `--error-unmatch`'s "no such path" now means untracked.
  `SIZE_RATCHET_SETTINGS_FILE=/dev/null` selects no settings source at all.
  It named only the settings file, so `.env.local` and `.env` kept deciding
  and a caller asking for built-in defaults got whatever the repository's
  env files said; the dotenv layers are skipped with it now, leaving
  explicit environment variables and the defaults.

- growth-guards: the same two settings fixes, which its vendored copy of the
  loader carried. A hook lane resolving tracked settings from the index no
  longer reads a broken `git` as "untracked" — a committed commit-type list
  or ceiling silently reverted to the built-in one and admitted a commit its
  own configuration rejects — and
  `GROWTH_GUARDS_SETTINGS_FILE=/dev/null` selects no settings source at all
  rather than leaving `.env.local` and `.env` deciding.

- review-gate: the `/dev/null` force-defaults handle is answered in
  `rg_setting`, ahead of every source, rather than through an exemption in
  the source-shape check. Behavior is unchanged there — the loader has no
  dotenv layers to leak — and the copies vendored from it now answer the
  sentinel through the same construct.

- size-ratchet: seven fixes absorbed from the forked copy drovr has been
  running (DRO-201), each with its own regression pin.
  `--update` converges in ONE run: the baseline's own row is reconciled
  against the file it is about to become, so a self-referential row no
  longer contradicts the rewrite that just produced it and fails the very
  next check.
  A broken gate exits 2, never 1. The repository `cd`, every scratch-file
  write, the baseline working copy, the counts sort and the `--update`
  sort pipeline route through the collection-error path instead of dying
  under `set -e` with the failing tool's own status — 1 is the code
  reserved for "a size violation was measured", so a full or read-only
  TMPDIR reached callers as a failing repository rather than a broken gate.
  A tracked exclusion list the worktree does not carry is read from the
  index, as the baseline already was: a sparse or fresh checkout ran with
  ZERO exclusions and reported violations against the vendored and
  generated files the tracked policy exempts.
  Index presence is probed with `git ls-files -s` and its status is
  checked. `git cat-file -t` exits 128 both for "not in the index" and for
  a corrupt or unavailable object, so with the status discarded a broken
  read looked exactly like an untracked file and the gate fell through to
  an empty baseline — losing every frozen row and any stale row that
  should have failed the run.
  A supplied-but-empty `--baseline` / `--excludes` is a config error;
  automation whose path came out of a bad substitution used to check the
  repository default and pass.
  `--update` stages its replacement beside the baseline instead of in
  `$TMPDIR`, so the final step is a real `rename(2)` rather than a
  cross-filesystem copy that can leave the tracked baseline truncated
  mid-write; the replaced file keeps its umask-implied mode.
  `--` moves before the pattern in the remaining greps (and before the
  mode in `chmod`) — non-permuting BSD/POSIX option scanning stops at the
  first operand, so the trailing form failed every invocation on macOS.

- pi-agents-tmux: the idle-stall watchdog skips panes with a pending
  rate-limit retry instead of condemning a merely-throttled agent as a
  post-compaction stall; its synthetic summary no longer asserts a cause it
  never verified (VST-361).
- growth-guards: the pre-commit shim runs `size-ratchet --staged` and reads
  the outcome — a first-line parser rejection of `--staged` (exit 2,
  tool-prefixed) marks a consuming repo's own replacement and skips with a
  note instead of blocking every commit repo-wide; every other failure
  blocks as before. No help-prose inference (VST-362).
- worktree: `create` installs npm dependencies only where npm is the
  package manager — a pnpm/yarn/bun lockfile or `packageManager` pin skips
  the step, so a fresh worktree in a pnpm workspace no longer starts dirty
  with a stray `package-lock.json`; a failed npm install names its log
  instead of vanishing (VST-340).
- merge-queue ejection alert: the intake issue is reason-aware — MANUAL
  (deliberate dequeue) and MERGE_CONFLICT (routine queue re-evaluation) get
  the PR comment only; failure-shaped reasons (CI_FAILURE, plus anything
  unrecognized, fail-closed) still file into triage. Cuts ~85% of the
  ejection-issue noise the GH→Linear sync was mirroring.

- cli: A shared config is read with the parser its OWN harness uses, never the
  one its file extension suggests. OpenCode hands `opencode.json`,
  `opencode.jsonc`, its global config and whatever `$OPENCODE_CONFIG` names to
  one JSONC parser, so comments and trailing commas are a working OpenCode
  config; vstack was reading all of them strictly, which reported a perfectly
  live hook install as unverifiable and made `add` and `remove` refuse to touch
  the file. Claude's `settings.json`, Codex's `hooks.json` and Pi's
  `settings.json` stay strict, because their harnesses are — a comment in one
  of those really is a file the harness drops. The relaxation is exactly what
  OpenCode's parser takes and no more: a single-quoted string, an unquoted key
  or a hex number is still a config OpenCode ignores, so vstack still refuses
  it rather than rewriting a file the harness is not loading.
  Writes preserve what they did not author. A JSONC config is edited through a
  syntax tree, the way Codex's `config.toml` is edited through `toml_edit`, so
  installing or removing a hook changes only its own entries and every comment,
  blank line, indent and key order comes back byte-for-byte. Serializing the
  parsed value back over the file would have deleted every comment in it on the
  first `vstack add`. OpenCode's GLOBAL config is now resolved by the spelling
  that is actually on disk too, so a user who keeps `opencode.jsonc` gets the
  registration written into the file they use instead of a second one beside
  it.

- cli: `vstack check` is a process contract a session can branch on — exit `0`
  clean, `1` drift, `2` the check itself failed, `--quiet` silent when clean,
  `--json` on stdout, `--offline` skipping every network call. Items a source
  ships but the scope never installed are suggestions and never drift. The
  verdict is computed from disk alone: a remote source cache older than six
  hours is refreshed by a detached `vstack cache-refresh` nobody waits on, and
  its outcome is reported at the next session, so a session start never blocks
  on the network — a cache that has been failing to refresh for more than two
  refresh windows, or that vstack cannot write to at all, is drift, and each
  report names the cause rather than a generic staleness. A source vstack
  REFUSED is reported as refused by `check`, `verify` and `refresh` alike,
  with the refusal's own remedy instead of a `vstack add` that would refuse
  again. A new `session-drift-check` hook (Claude Code and Codex) and the Pi
  `pi-hooks` `sessionDriftCheck` setting relay the quiet report at session
  start; both are thin adapters over `check --quiet`, whose output is bounded
  by construction — every section is capped, every displayed name is rendered
  through the bounded renderer, AND the quiet report as a whole has both a
  line budget and a byte budget (item name length is unrestricted, so counting
  lines alone bounded nothing), spent on drift before suggestions and closing
  with one line naming what it left out; a copy-paste command argument stays
  complete, since an elided argument is a command that cannot work. A
  config file vstack shares with a harness — a Claude `settings.json`, a Codex
  `hooks.json` or `config.toml`, an OpenCode `opencode.json`, Pi's
  `settings.json` — that EXISTS and cannot be read is reported as unverifiable
  naming the file and what was wrong with it, never as a missing hook or an
  unregistered package whose printed remedy is `vstack add`; and every writer
  refuses such a file instead of parsing it as a default and rewriting it, so
  no vstack command can discard the settings and registrations it holds.
  "Cannot be read" is now the WHOLE shape vstack depends on, declared once and
  validated at the reader: invalid JSON, but also an event value that is not
  an array, an entry, handler list, handler or command of another shape, a Pi
  `packages` that is not an array, an `opencode.json` `instructions` or
  `permission` of another type. Each of those used to read as "nothing
  registered here" while the matching writer replaced the offending value with
  an empty default, crashed on it, or refused it — leaving the user with a
  destroyed setting or a drift the printed remedy could never clear. A Codex
  agent file the prose fallback could not read is reported the same way rather
  than as a missing safety block. A command that installs from a cached source
  (`add`, `refresh`, the wizard) now waits for an in-flight refresh of that
  cache and then refuses, instead of discovering, hashing and copying out of a
  tree another process is running `reset --hard` on; only the detached
  background refresh treats a busy cache as a no-op. A READ-ONLY reader —
  `check`, `verify`, hook attribution, source-identity recovery — neither
  waits nor takes that lock: it probes it, and a source whose cache is being
  rewritten is reported as not checked this run instead of measured against a
  half-written tree. That is neither drift nor clean, it costs a session
  start nothing, and the next run reports the source normally; before it,
  `check` could call a live entry REMOVED and print `vstack remove` beside it.
  The initial clone — the one cache write no lock can cover, since the lock
  lives inside a `.git` that does not exist yet — is published into its entry
  by rename, so a clone that did not finish is never visible under the entry's
  own name. Where the platform has no `flock` to release the lock for it, a
  holder records its liveness for as long as the lock is HELD rather than only
  while its fetch runs, so a lease kept across discovery, hashing, copying or
  an interactive selection is no longer read as a crashed process's leftover
  and taken over mid-read; a holder that really is gone stops recording, and
  its lock is still taken over once it goes stale, so no cache wedges.
  Codex's safety-prose
  fallback is located by one predicate scoped to the agent's
  `developer_instructions`, so marker text in a comment or another field can
  no longer make the install skip the block and the presence read call it
  installed — and the block counts only while it still carries the hook's
  action line, so a heading whose body was deleted is reported rather than
  reported installed, and a reinstall rewrites the section instead of skipping
  it. An install that is COMPLETE and switched off is a third report with a
  third remedy: Claude's `disableAllHooks` (read through the declared schema,
  over claude's own settings precedence, and never from a
  `~/.claude/settings.local.json` claude does not load), Codex's
  `[features] hooks`, and a Cursor safety rule whose `alwaysApply` is no longer
  `true` each leave every artifact in place while the harness runs none of it —
  now named with the setting and the file holding it, instead of reported as a
  missing install whose printed remedy is a reinstall that changes nothing.
  OpenCode exposes no such switch; Pi's live in vstack's own extension-manager
  UI and stay out of the report (VST-258).
- cli: every structured file vstack reads is now read by a parser rather than
  matched as text, so the answers no longer depend on how a value was spelled.
  A Cursor rule's `alwaysApply` is a YAML boolean, so `alwaysApply: true # keep
  enabled` is the same "on" to vstack that it is to Cursor, and a rule whose
  frontmatter does not parse — or whose `alwaysApply` is a value Cursor itself
  would not honor — is unverifiable naming the file rather than silently off. A
  Codex agent's `developer_instructions` is located by parsing the TOML, so the
  assignment text quoted inside another field, or a `developer_instructions`
  belonging to a different table, is no longer spliced into or cut out of; an
  agent file that is not TOML vstack can read is refused by name and never
  rewritten, by install, removal or the presence read. A registered hook
  command is split into the words a shell would run, so a `bash '/path with
  spaces/hook.sh'` — the command vstack itself writes for any install path
  containing a space — reads back as registered instead of as permanent drift
  no reinstall could clear; a command whose words cannot be settled still reads
  as unregistered. The `session-drift-check` hook reads the session's start
  reason from the payload's top-level `source` via `jq` where it is available,
  so a nested key or a matching string elsewhere in the payload no longer
  decides whether the report is printed. Source picker rows and the scope
  summary now label a GitHub remote by the repository it names, so every
  spelling of one repository is one row. An installed agent's declared
  skills are read as parsed YAML — a block sequence and a value carrying a
  trailing comment both count, where before either read as declaring none
  and every skill the agent named went unchecked. Removing a hook from
  `opencode.json` deletes the entry that RESOLVES to vstack's own instruction
  file, through the same predicate the registration read accepts it with; it
  used to split the hook's name on `-` and drop any entry whose text held
  every fragment, so removing one hook deleted the user's own unrelated
  instructions, and a `vstack-hook-` substring anywhere in a path kept the
  bash restriction alive after the last vstack hook was gone. Whether any
  vstack hook still needs the shared bash rule is decided by that same
  predicate; a file-name glob over the entry text answered it separately, so a
  hook registered under an equivalent spelling counted as installed for
  `check` and as nothing at all for removal — removing a sibling took the rule
  out from under it and left a partial uninstall no command reported
  (VST-258).
- cli: every command vstack PRINTS for you to paste is built from one helper,
  which POSIX-quotes each argument, so a source, an item name or a package
  spelled with shell syntax is passed literally instead of executed — a
  recorded source of the shape `https://host/team/$(id).git` produced a
  restoration command that ran the substitution. The same helper owns the
  credential redaction, the terminal-escape scrub and the length bound every
  displayed string gets, and the two places that quote for EXECUTION rather
  than display — a harness's `settings.json` hook command and
  `GIT_SSH_COMMAND` — stay separate so they carry a path byte for byte.
  Diagnostics are no longer scrubbed as if each were a single source URL: a
  message's `?` is a question mark, not a query string, so a refusal is no
  longer cut off mid-sentence and given a `<redacted>` naming nothing. Neither
  is a local source path: `?` and `#` are a URL's query and fragment but
  ordinary characters in a directory name, so a local source is now shown as
  itself — still terminal-escaped and still quoted inside a command — and only
  a remote-shaped source goes through the credential and query redaction, as
  classified by the resolver itself. A local source directory spelled with
  either character used to render as `/path/source?<redacted>`, and the
  restore and add-item commands built from it named a directory that does not
  exist. A
  subprocess's output and a lock file's names are displayed text and get a
  displayed string's treatment. A hook locked for Pi is only installed when
  the `@vanillagreen/pi-hooks` carrier is deployed AND registered in a scope
  Pi loads — its absence is drift naming the carrier and the remedy, an
  unregistered copy is drift naming the registration, and an unreadable Pi
  `settings.json` is unverifiable naming the file; `check`, `verify` and the
  enforcement level `list` prints all read one probe, so they cannot disagree.
  An owning checkout's lock file that exists and cannot be parsed no longer
  reads as absent: unknown ownership is not permission to clear another
  checkout's recovery marker (VST-258).
- pi-agents-tmux: the Agents popup Transcript tab is an event timeline
  (paired tool rows, capped previews, `✖`-marked failures, line-boundary tail
  with a dropped-events note) instead of raw JSONL, and `e` opens the raw
  file in `$VISUAL`/`$EDITOR` (VST-327).

- pi-agents-tmux: Monitor tree task rows show elapsed/total run-time instead
  of a jumpy local `HH:MM` clock (`updatedAt` is no longer a time source);
  detail-pane timestamps render local human time instead of UTC ISO, and the
  Task Summary gains a Duration line once terminal; running elapsed keeps
  ticking even with spinner animation off (VST-316).

- growth-guards: the pre-commit shim chain runs `preflight --staged` when
  that skill is installed beside it — a human committing outside any harness
  gets the deterministic checks CI would report, first; a repository's first
  commit skips it with a note (VST-310).
- orch: `reconcile-work-items` reports tracker state written once and never
  re-read — parked containers, stale started items, Done items with unchecked
  acceptance boxes; oversee's close-out and audit-issues' preflight run it, so
  a skipped close step or a partial-scope `Closes` cannot stay silent (VST-318).

- settings templates: every key's comment condensed to one-line intent plus
  landmines (922 → 545 lines across the root and skill templates, zero value
  changes); refresh's seeded-comment rewrite propagates the terse form to
  consumer files whose blocks are unedited (VST-317).
- linear: a truncated `cache issues list` announces itself on stderr with
  both counts instead of returning a bare 75-row array that reads as
  complete; `--max`/`--limit` are documented in SKILL.md (VST-320).
- size-ratchet: `--seed` writes the FIRST baseline from the gate's own
  collector (exact counts, class thresholds, excludes, sorted, self-row) and
  refuses a live one — installing the skill no longer leaves a gate that can
  never be turned on; the two stale built-in-1000 test messages read 400
  (VST-328).

- preflight: the code-citation lane leaves installed-artifact subtrees alone
  (`.agents/` and the harness dirs' skills/agents/hooks/rules/instructions/
  packages trees) — a vendored skill's example path is upstream's prose, not
  the consuming repo's claim, so committing the installed copy no longer
  trips `docs-cited-paths`; authored files elsewhere under the harness dirs
  keep the lane (VST-312).

- preflight gains three added-line lanes taken from the classes review bots
  keep finding first: `unwired-suite` (a new `tests/*.test.sh`,
  `tests/test-*.sh` or `*.test.ts`/`.js`/`.mjs` that no tracked runner
  invokes — suites have shipped that CI never ran), `mktemp-trap` (a new
  shell file whose scratch directory no `trap ... EXIT` ever removes), and a
  `fail-open` extension for `grep`/`find`/`git`/`jq`/`diff`/`cmp` whose
  status a trailing `|| true` erases, which turns "could not read the input"
  into a clean empty answer. Wiring evidence for the first lane is read from
  the tracked runners themselves — the workflows, `tools/validate*`,
  `scripts/validate*`, the package/build manifests, and a `run-all.sh`
  beside the suite — through the same index-vs-worktree resolution the rest
  of the tool uses, so `--staged` judges the staged runner. Both new-file
  queries now disable rename detection like the rest of the change-set
  queries: a file that arrives by `git mv` is the new file it now is, which
  also un-blinds the existing strict-mode check.

- Reviewer agents gain five probes for the classes that were being caught
  downstream instead of in review: surface enumeration and teardown symmetry
  and staged-vs-worktree policy reads (`reviewer-correctness`), enumerations
  of named repo objects re-derived in both directions (`reviewer-doc`), the
  satisfied-but-inert control forms a text-matching guard must be shown to
  reject (`reviewer-test`), and read-then-write-back files proven regular and
  non-symlink at the point of write (`reviewer-safety`).

- The `--` rule now says which paths it governs: values sourced from
  configuration, argv, or the environment, never a path the script built
  itself. The unqualified wording drove more declined review threads than
  real fixes, so the qualifier ships in `skills/code-quality/SKILL.md` and
  `AGENTS.md`, and the same carve-out — with the test-owned `mktemp -d`
  scratch and the `${arr[@]+"${arr[@]}"}` empty-array idiom — is published
  where the review bots read it, in the new
  `.github/instructions/tests.instructions.md` and `.pr_agent.toml`.

- orch PR-comment triage batches fix rounds per fully-reviewed head: a push
  restarts every reviewer, so a round pushed into an open review pass buys
  duplicate findings and unanswered threads.
- Skill `description:` frontmatter is one or two sentences again across the
  catalog — what the skill is and when to load it, with the sub-feature
  enumerations that had grown into ten of them left to the body. The longest
  fell from 810 characters to 214, and every skill now fits in a loader's
  index without crowding out its neighbours; `vstack refresh` delivers the
  shorter text to consumers. The growth-guards skill also lost the narration
  that accumulated around its checks: duplicated scan machinery now has one
  home in `lib/common.sh`, SKILL.md carries what every load needs and README
  the adoption depth. Every verdict, remediation and exit code is unchanged;
  the only text that moves is two collection-error diagnostics, which now name
  the lane whose scan failed.
- hooks: one execution contract decides what installing a hook means. An
  event × harness matrix (`cli/src/installer/hooks/contract.rs`) names the
  mechanism, and every install path, `vstack list`/`check` label, and the
  table published in the README derive from it — a test fails when the
  published copy drifts. `list` and `check` now print `enforced` /
  `advisory` / `unsupported` per harness per installed hook, advisory
  artifacts (Cursor rules, OpenCode instructions, the Codex prose fallback)
  carry `advisory — this harness cannot execute hooks`, and Pi reports
  `unsupported` until `@vanillagreen/pi-hooks` — which carries all Pi hook
  behavior — is actually installed. Breaking: a hook whose `event:` is not a
  row of the contract is refused at install instead of registering something
  no harness runs; supported events are listed in the refusal (VST-283).
- hooks: registered commands resolve from any working directory in a project
  that is not a git repository. Project-scope Codex hooks resolved through
  `$(git rev-parse --show-toplevel)`, so in a non-git project every hook
  command expanded to `/.codex/hooks/<name>.sh` and failed silently; they now
  carry the install-time absolute path, which is the only anchor Codex can
  resolve — it sets no project-root variable and runs the command from the
  session cwd. Claude Code agent frontmatter took the project anchor even for
  global installs, pointing at a project path that does not exist; it now
  takes the same command the installer registers. A reinstall replaces a
  git-anchored registration instead of adding a second handler beside it
  (VST-283).
- hooks: `block-unsafe-rm` declares `harnesses:` without `pi`. The
  `pi-hooks` package has no port of it, and without the exclusion the
  contract would report Pi enforcement that does not exist (VST-283).
- hooks: a Codex registration is recognised by the script it runs, not by the
  literal command string, so a project that moved no longer accumulates a
  second handler pointing at a script that is gone — and removal takes the
  old one with it. Handlers naming a script outside `<root>/.codex/hooks/`
  are still left alone. A script path that is not valid UTF-8 is refused
  instead of registered lossily as a command that resolves to nothing
  (VST-283).
- hooks: `vstack add` checks every selected hook's event against the contract
  before its first write, so a refused event leaves no lock, agent, settings
  or config behind (VST-283).
- hooks: one predicate per harness decides which registered command is
  vstack's, and install, removal and every presence report ask it. A Claude
  Code or Codex command you reshaped by hand around vstack's script — an
  `env`/`timeout` prefix, extra flags, a different quoting of the same path —
  was already counted as installed, but `vstack remove` matched the literal
  string only and left it registered, so the harness kept running a hook the
  lock no longer knew about. The enforcement level `list` and `check` print
  now comes from the same reader `verify` reports the gap from, so a hook
  cannot read `enforced` on one command and drifted on another (VST-258,
  VST-283).

- growth-guards installs real git hooks: `scripts/install-git-hooks` writes
  `.git/hooks/pre-commit` and `.git/hooks/commit-msg` shims (plus the
  `vstack-guards` helper it owns) so the guard chain — `size-ratchet
  --staged`, the staged growth-guards batch, and an optional repo-local entry
  named by `GROWTH_GUARDS_PRE_COMMIT_LOCAL` — blocks a `git commit` from any
  tool, not only from the harnesses with their own hook system.
  `core.hooksPath` is never touched, an existing hook keeps its content and
  its own exit status, and the shims fail closed: a guard that cannot run
  blocks too. `vstack add` / `vstack refresh` arm and repair them, so
  consumers get them on their next refresh after adopting growth-guards, and
  `vstack remove growth-guards` disarms them again — refusing the removal if
  that cleanup fails; non-git projects are skipped with a note.
- size-ratchet grows `--staged`: it counts INDEX blobs for every tracked file
  instead of preferring the worktree copy, so growth that is staged and then
  reverted on disk cannot pass a pre-commit gate. CI, which checks out a
  clean tree, needs no flag.
- size-ratchet: thresholds are per path class. `SIZE_RATCHET_CLASSES` maps
  globs to thresholds (`"tests/*=800;*/tests/*=800"`, first match wins,
  the exclusion list's glob semantics); a path matching none takes
  `SIZE_RATCHET_THRESHOLD`, and everything else — new-offender, growth and
  stale-row detection, tighten-only `--update` — runs per file against that
  file's own number. Diagnostics now name the threshold that judged the
  path and whether it came from a class or the default. A malformed entry
  is a config error naming it; unset or empty is exact single-threshold
  behavior.
- **BREAKING** size-ratchet: the default `SIZE_RATCHET_THRESHOLD` drops
  from 1000 to 400 (the fleet's two-tier ruling: implementation 400, tests
  800). Migration for a repo on the default, in this order: declare
  `SIZE_RATCHET_CLASSES` for the repo's test layouts FIRST, then run the
  check and turn each reported `new offender` line into a `path<TAB>lines`
  baseline row — freezing before declaring would baseline 401–800-line test
  files that the test class then makes stale. `--update` never adds rows, so
  that freeze is the one hand-edit. Declaring `SIZE_RATCHET_THRESHOLD =
  "1000"` keeps the old number instead. Repos that already pin the threshold
  are unaffected.

## Earlier (condensed, through 2026-08-16)

### Still-pending consumer actions

No release boundary has passed, so these migration steps from the condensed
span stay required until taken:

- **size-ratchet default threshold drop, 1000 → 400 (breaking):** for a repo
  on the default, in this order: declare `SIZE_RATCHET_CLASSES` for the
  repo's test layouts FIRST, then run the check and turn each reported
  `new offender` line into a `path<TAB>lines` baseline row — freezing before
  declaring would baseline 401–800-line test files the test class then makes
  stale. Declaring `SIZE_RATCHET_THRESHOLD = "1000"` keeps the old number;
  repos already pinning the threshold are unaffected.
- **Retired settings and commands:** delete `REVIEW_RISK_COMMAND`,
  `PR_REVIEW_REFIX_MAX_LINES`, `ORCH_CACHE_DIR`, and
  `ORCH_LANE_CLAUDE_PERMISSION_ARG` from `vstack.settings.toml`; add
  `ORCH_LANE_ALIASES` if you alias lanes. Automation calling any removed orch
  script or passing `github.sh label-add --reason` must update. The retired
  entry points, for sweeping project-owned instructions and automation:
  orch scripts `review-init`, `review-risk`, `refix-route`,
  `local-review-budget`, `list-review-agents`, `tracker-for-issue`,
  `codex-app-agent-preflight` (no replacements); the session-kickstart layer
  `session-init`, `parallel-groups`, `workflows/initialize.md`,
  `workflows/parallel-check.md` (a session picks up the issue and goes; the
  worktree lease claim lives in `start-worktree.md` § 1); orch workflows
  `fix-reconcile.md` (→ TPM audit pipeline + `Closes` linkage),
  `agent-sequencing.md` (→ SKILL.md § Coordination), `recommendation-bias.md`
  (→ `references/finding-disposition.md`); project-management
  `workflows/tpm-audit-project-order.md` (→ a `workflows/tpm-audit.md` mode)
  and `schemas/audit-project-order-output.md` (→ `schemas/audit-output.md`);
  the legacy orch CI pair `scripts/ci/review-predicate.sh` and
  `scripts/ci/approval-refire.sh` (→ the review-gate skill's predicate +
  single writer, vendored via refresh; v1 consumers migrate per its
  `references/adoption.md`); project-management `references/issues.md`,
  `references/initiatives-projects.md`, `references/prioritization.md`
  (their few real constraints relocated into the templates and
  roadmap-create).
- **Hooks with an unsupported `event:` block refresh:** a hook whose `event:`
  is not a row of the execution contract is refused before any mutation —
  the refusal lists the supported events. Change such a hook's event to a
  supported row (or remove the hook) before refreshing.
- **Items named `all` must be renamed or removed before refresh:** `all` is
  now the shared instruction key, so an agent, skill, or hook actually named
  `all` — possible in pre-release installs, whose removal stays supported —
  is rejected by `refresh`; rename or `vstack remove` it first or the
  refresh fails without explaining itself.
- **Roadmap plans need their JSON sidecar:** roadmap-create's legacy
  markdown-parsing fallback is removed — the plan JSON is the contract, and
  `roadmap create` on a markdown-only plan now halts naming the missing
  `**Plan data**` path. Regenerate a pre-sidecar approved plan (or add the
  JSON sidecar) before running roadmap workflows against it.
- **Removed skills and pack (breaking):** before your next `vstack refresh`,
  delete any `iced-shadcn` or `html-artifact` entries from your project's
  `vstack.toml` (`[skill-instructions]`, `[agent-skills]`, `[role-skills]`).
  If you applied the `vanillagreen-themes` pack, run
  `vstack apply vanillagreen-themes --revert` **before** upgrading, while the
  pack is still resolvable; afterwards the managed blocks in Ghostty/tmux
  configs must be removed by hand and the VS Code extension uninstalled
  manually.
- **second-opinion key sweep:** drop `SECOND_OPINION_REVIEW_TARGETS` from
  every file it was seeded into (`vstack.settings.toml`, `.env.local`, and any
  `.env.local.example`/`.env.example` a new checkout copies from), and drop a
  `SECOND_OPINION_TARGET` naming the session's own model — both are now
  refused. Move `SECOND_OPINION_CURRENT_MODEL` out of every project file
  that carries it (`vstack.settings.toml`, `.env`, `.vstack/settings.toml`,
  `.env.local`, and any `.env.local.example`) — a project-file value is
  refused — and export it in the sessions that need it; Pi/OpenCode/Cursor
  and undetected sessions require it. Seeding never overwrites an existing
  `SECOND_OPINION_REVIEW_INSTRUCTIONS` key, so a settings file carrying the
  previous default keeps the old list — update the pinned value to
  `"AGENTS.md review-bots.md .github/instructions/*.instructions.md .github/copilot-instructions.md"`
  (or delete the key to track the default) to pick up AGENTS.md coverage.
- **Vendored guard scripts:** repos vendoring review-gate, size-ratchet, or
  growth-guards must re-vendor to pick up the settings-resolution and
  measurement changes.
- **review-gate v2 CI upgrade:** workflow YAML is repo-owned — `vstack
  refresh` delivers the skill but never the workflows, so refreshing alone
  does not complete the breaking CI upgrade. Replace the rerun/sweep and
  predicate-reading jobs and adopt the relay/converge writer split per
  `skills/review-gate/references/adoption.md`.
- **Remote cache re-clone:** the cache key now derives from repository
  identity, so caches created under the previous scheme are not reused. The
  first `vstack refresh` after upgrading reports each remote source as not
  present and names the `vstack add <source>` that re-clones it — run those,
  or every remote-backed install stays stale; the obsolete directory under
  `~/.vstack/cache/` can be deleted.
- **open-terminal launch flags:** the hardcoded model/effort defaults and
  `ORCH_LANE_CLAUDE_PERMISSION_ARG` are gone, and nothing in scripts,
  settings, or templates supplies a replacement — callers invoking
  `open-terminal` directly must pass model, effort, and permission flags via
  `--launch-flags`, sized to the task, or an unattended handoff launches and
  stalls at its first tool call.
- **Reviewer overhaul opt-in:** `[agent-skills]`/`[role-skills]` are
  project-owned after install, so the retirement of `reviewer-structure` and
  the new deterministic checks do not arrive by refresh alone. Remove
  `reviewer-structure` from your config, add `preflight` and `code-quality`,
  then run `vstack refresh`; CI use of preflight requires the installed
  skill committed to the repo.

### Component rollups

- cli: every git process runs through one hardened constructor — the
  environment's git-config and program-naming variables are dropped, a cache
  entry must prove it is vstack's own clone before any fetch or
  `reset --hard`, remote sources get one cache entry per repository identity,
  and credential-bearing, plaintext-HTTP or unknown-transport URLs are
  refused and never echoed (breaking: older cache entries re-clone) (VST-256).
- cli: propagation fixes — `refresh` seeds missing skill-settings keys into
  self-source repos and refreshes unedited seeded comments behind a
  provenance ledger; `vstack.toml` keeps its trailing newline; a non-TTY
  `add` without `-y` fails actionably; the TUI Updates tab refreshes each
  stale install from its own recorded source; a shared `all` instruction key
  applies to every agent or skill (breaking: `all` is reserved).
- orch: rewritten ground-up (v3) — the issue→dev→review→PR→merge cycle is
  stated once and bounded: bounded review loops, no edge-case churn, declines
  terminal, artifact-based acceptance. Breaking: the session-kickstart layer,
  seven scripts and three workflows are removed, lane launch flags arrive at
  launch time, and QA routing records signals instead of tracker labels.
- orch: a fleet layer — `oversee` runs one shepherded session per queue item,
  unattended by default; `oversee-watch` blocks until the fleet needs the
  overseer (attention, question prompts, exited or idle lanes, usage limits);
  lane launches claim worktrees and auth lanes and verify brief delivery.
- orch: merge-path guards — `queue-wait` dequeues a queued PR on late review
  findings; `PR_REVIEW_QUORUM` holds enqueue until every listed reviewer has
  a head-pinned review and zero unresolved threads; the post-merge base sync
  proves which checkout owns the base branch before advancing it; merged
  worktrees are cleaned by rule; `ORCH_MERGE_AUTONOMY=auto` merges unasked.
- orch/dev: deterministic acceptance — artifact checks print one-word
  verdicts and gained a blocking `--wait`; reviewer artifact paths are
  minted at delegation; a no-CI repo is recognized; a 67-thread triage
  sweep across nine merged PRs fixed every still-live finding.
- review-gate: v2 (breaking, consumer CI) — one default-branch writer
  workflow answering "has this exact head been reviewed?" replaces the
  four-workflow mesh; PR-attached events relay into the writer rather than
  holding its evictable group, so cancelled runs stop pinning PRs at
  `UNSTABLE`; an errored bot review is silence, not approval; settings
  resolution fails closed on unreadable sources (size-ratchet too).
- growth-guards/size-ratchet: growth-guards arrived as the shared check
  family beside size-ratchet — `todo-ban`, `byte-ceiling`, `suppression-ban`
  and a conventional `commit-msg` gate; vstack adopted its own size-ratchet
  gate in CI and at commit time; collection batches `wc` (~8x faster).
- worktree: `remove` no longer tears down a live sibling session's tree — a
  lease whose claiming process is still alive refuses removal, and release is
  bound to a per-claim generation so no race can unlock a live lease.
- hooks: two new `PreToolUse`/`Bash` guards — `block-unsafe-rm` refuses a
  recursive `rm` rooted in a possibly-empty variable, and `block-repo-copy`
  refuses recursive copies of repository or build trees into temp/scratch
  space; the latter ships for Pi as `pi-hooks` `blockRepoCopy` (0.3.0).
- pi-agents-tmux: oneshot transcript records append in event order, so the
  last assistant text a consumer extracts is the last one written (2.8.2).
- linear: fourteen defect fixes led by three that silently corrupted state (a
  failed label lookup wiping an issue's label set, a corrupt cache answering
  "no issues", unvalidated shell arithmetic); blocking relations may cross
  projects; an unknown label refuses the update, never a partial set.
- github: fail-open elimination — `git-diff-summary`, `ci-logs` and the PR
  list commands fail loud instead of fabricating clean answers; `pr-threads`
  filters honestly in every format; `pr-merge` short-circuits merged/closed
  PRs and names queued-merge volatility (breaking: the label commands drop
  `--reason`).
- reviewer/dev/preflight: the reviewer skill and agents rewritten from 24-PR
  escape mining — mined domain probes replace checklists, issue findings
  require an `impact` line, re-review scopes to the fix diff; new `preflight`
  (diff-scoped deterministic fail-only lanes, grown over the period) and
  `code-quality` (prove-your-guards, must-fail controls) skills; dev reduced
  to its contract (breaking: the `reviewer-structure` agent is retired).
- second-opinion: the cross-model guarantee holds in every mode — one roster
  walk excludes the session's own model and refuses when no eligible target
  remains; harness detection beats a contradicting declaration and a
  project-file identity value is refused; lane artifacts moved from shared
  temp into an owned owner-only home; `--output` modes clear their own
  outputs at startup; `AGENTS.md` joined the review-instruction globs.
- project-management: rewritten ground-up (v3) — the TPM files only what
  passes a creation bar and burns down more than it creates; audits headline
  `created N / closed M` and the approval gate is two questions.
- catalog: every skill and agent reduced to contracts, commands and
  non-derivable knowledge (~19,000 → ~8,900 markdown lines), with `decider`
  and `deep-research` hardened in the same waves (breaking: the `iced-shadcn`
  and `html-artifact` skills and the `vanillagreen-themes` pack are removed).
- docs/settings: cross-repo guidance cut to the contracts; the label taxonomy
  states the one-way GitHub → Linear creation sync; settings examples state
  rules, and a parity test fails the suite on skill/root template drift.
- repo/ci: `CHANGELOG.md` merges with git's union driver so concurrent
  Unreleased bullets stop conflicting; `tools/validate-changed` runs CI's
  diff-scoped lanes locally; merge-queue test flakes fixed.
