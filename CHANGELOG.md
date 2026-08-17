# Changelog

## Unreleased

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
  own name. Codex's safety-prose
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
  bash restriction alive after the last vstack hook was gone (VST-258).
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
  longer cut off mid-sentence and given a `<redacted>` naming nothing. A
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
- settings templates: every key's comment condensed to one-line intent plus
  landmines (922 → 545 lines across the root and skill templates, zero value
  changes); refresh's seeded-comment rewrite propagates the terse form to
  consumer files whose blocks are unedited (VST-317).

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

- second-opinion settings example: the `SECOND_OPINION_CURRENT_MODEL` block
  announced "three cases, and only the third makes a project file usable at
  all" over a list of two, neither of which does — and no case does, since a
  project-file value is refused wherever it would matter. `vstack refresh`
  copies the file verbatim, so every consuming repo carried the contradiction
  and flagged it as drift. Both copies (the skill's template and the root
  `vstack.settings.toml.example` the README points at) now state the rule
  itself — a project file is read by every session in the repo, so a value in
  one describes no single session — with no count and no positional reference
  to maintain.

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
- orch: `oversee-watch` gains `usage-limit` (the harness is still running but
  its account's limit banner is up — one pass, ahead of `question`, naming the
  config dir when a live lane claim covers the pane it read) and
  `idle-after-return` (the lane sits at its input prompt with nothing in
  flight on two consecutive passes). Both kinds were previously invisible: a
  spent account read as a working lane, and a finished lane held its slot
  until a heartbeat. `open-terminal` now records a claim per tmux lane it
  launches under a resolved lane, and `lanes pick` takes the lane with the
  fewest live claims before the one with the most headroom — usage numbers lag
  a launch by minutes, so back-to-back picks were handing one account the
  whole fleet. `lanes list`/`--json` report the count, `null` when the store
  could not be read. `pick` refuses (exit 1) rather than deciding on a claim
  store that exists but cannot be read — consumers delegating lane selection
  see a misconfigured `OVERSEE_WATCH_STATE_DIR` as a launch failure instead
  of a fleet stacked on one account (VST-296).
- repo: the root `CHANGELOG.md` merges with git's `union` driver
  (`.gitattributes`) — two branches each adding a bullet under Unreleased no
  longer conflict on rebase; both bullets are kept. The driver also keeps both
  sides of an in-place rewrite of one line and, across a release rotation,
  lands a rebased bullet under the new heading: read the Unreleased list after
  a rebase, and rotate a release only with no PR open.
- orch: pruning a lane claim re-enumerates the tmux server once per pass
  before deleting a same-server miss, and keeps the snapshot it already had
  when that re-enumeration fails — a claim another launcher wrote after the
  first `list-panes` looked dead on this server and was deleted, handing a
  running account straight back out (VST-296).
- review-gate/size-ratchet: settings resolution fails closed on a source it
  cannot read. `-f` and `-e` both pass on an existing mode-000 file, so only
  the read itself sees it: `grep` failed, the resolver read that as "no
  match", and resolution fell through to a lower-precedence source or to the
  built-in default — a configured value silently replaced by another one, on
  the gate a permissive default nobody set. Every settings probe now treats
  grep exit >= 2 as an unreadable source and refuses by name (the discipline
  growth-guards already carried). This retires review-predicate-selftest's
  own unreadable-settings guard: the resolver refuses first, for the live
  predicate and writer as much as for the selftest. The same "only an
  ABSENT source is skipped" rule now covers the `.env.local` and `.env`
  lanes, which still fell through on a directory, FIFO, socket, device or
  unresolvable symlink. Repos vendoring review-gate, size-ratchet or
  growth-guards must re-vendor.
- size-ratchet: the collection loop measures worktree files in batched `wc`
  invocations instead of one process per file — 6.3s -> 0.8s on a tree
  measuring 9,325 files, 0.86s -> 0.09s on one measuring 1,454, with the
  verdict byte-identical on both. Counts are matched to inputs by position
  and the summary row a multi-file `wc` appends is counted rather than
  parsed, so a batch that comes back short, out of order or non-numeric is
  discarded and re-measured one file at a time: an unreadable or vanished
  file still fails loud naming that file, and a count row is required for
  every file selected.
- second-opinion: a multi-lane review run without `--output` no longer keeps
  its lane reviews in shared system temp (VST-241), and the lane umask no
  longer governs the external model CLI's own files (VST-243). Each lane's
  review is now a per-run file in `SECOND_OPINION_ARTIFACT_DIR` (default
  `tmp/second-opinion` under `--cwd`), created there exclusively and removed at
  exit — a home that cannot be created, vetted or written sends that lane back
  to a temp file with the reason on stderr — so an actor clearing temp *files*
  — not only the one
  directory the run creates there — can no longer cost a blocker-carrying lane
  its findings, and the durability guarantee now holds in both modes. Owner-
  only is applied by whoever writes the file instead of by a umask wrapped
  around the lane process: lane artifacts and their sidecars are still
  owner-only whatever the caller's umask, while the session and cache state the
  external CLI keeps for itself comes out exactly as it does on a single-lane
  run, rather than being fixed at `0600`/`0700` by whichever lane mode happened
  to create it first.
- review-gate/size-ratchet/growth-guards: settings resolution fails closed
  on an unusable settings path. A directory, FIFO, socket or device at
  `*_SETTINGS_FILE` (or at the default `vstack.settings.toml`) failed `-f`
  exactly like an absent file, and a symlink that does not resolve failed
  `-e` as well, so every key resolved to its built-in default with nothing
  said — on the gate that meant an empty trusted-logins list (any
  non-author counts) on a run nobody could tell apart from a configured
  one. The refusal sits in the resolver, so the live predicate and writer
  get it too. `/dev/null` stays the documented force-defaults handle; an
  absent plain file, and a symlink that resolves, are unchanged.
- review-gate: a prophylactic carry-exclude declaration is validated
  whenever declarations exist, not only when the exclusion list is
  non-empty — an EMPTY `REVIEW_GATE_CARRY_FORWARD_EXCLUDE` makes every
  declaration an orphan, and the selftest now FAILs it with the existing
  stale-waiver remediation instead of sitting inert. Repos vendoring
  review-gate must re-vendor to pick both changes up.
- orch: every dev delegation now takes possession of its worktree first. New
  `skills/orch/scripts/worktree-claim` binds a session to the session-guard lease
  generation it claimed under (recorded at `worktree_gen` in workflow state),
  re-verifies it at every round stamp, and passes it to the agent as the
  delegation's `Worktree Lease:` line — so a second session claiming the same
  tree makes both the next stamp and the delegated agent's first step exit 75
  instead of silently sharing the worktree. Previously the lease was claimed
  once at `start-worktree` and never checked again, and a concurrent writer
  could reset the tree, rewrite round artifacts, and move the PR head
  underneath a live round with nothing failing.
- github: `pr-merge` exit 75 (queued / auto-merge armed) now states on stderr
  that the state is volatile — a merge-group ejection disarms it silently —
  and names the watcher (`queue-wait`, `pr-watch.sh`) and the re-arm; the
  SKILL.md outcomes table says the same, and that `await-mergeable` is not
  that watcher (VST-295).
- ci: `CHANGELOG.md` joins the size-ratchet excludes — an append-only log
  grows every PR by design and its seam is release rotation, not a code
  split; the gate was about to block every open PR at 1000 lines.
- hooks: `block-unsafe-rm` scans harder shapes — backslash-escaped flags
  (`rm -\rf`), case-arm bodies (`x) rm -rf …;;`), and here-string targets
  classify correctly, and a PATH missing the text tools refuses up front on
  both decode paths instead of dying mid-scan.
- New `block-unsafe-rm` hook (`PreToolUse`/`Bash`): a recursive `rm` whose
  path starts with a variable that may expand empty is refused with the
  accepted rewrite (`rm -rf -- "${NAME:?}/sub"` or a literal absolute path)
  — that shape halts the whole session on the harness's "Dangerous rm
  operation on possibly-empty variable path" prompt even with permissions
  bypassed, and lanes stalled on it. Consumers pick it up with
  `vstack add --hook block-unsafe-rm -y`.
- ci: the merge-queue ejection alert's comment/intake step never ran — an
  apostrophe in a comment inside its single-quoted jq program ended the
  quote and the step died on a bash syntax error. Fixed, and preflight
  gains a `workflow-run-syntax` lane: `bash -n` over every `run:` block of
  a changed workflow file (expressions placeholdered, non-shell steps
  skipped), reported at the file line.
- worktree tests: `worktree_remove_live_lease.sh` failed most merge-queue
  runs and stalled the surviving ones five minutes. Signalling a
  just-forked `sleep 300 &` raced its exec: the pre-exec child ran the
  test's EXIT trap and deleted the fixture, or the signal was lost and the
  sleeper lived out its timer. The dead pid now comes from a job that
  exits on its own and the cleanup trap runs only in the test process.
- project-management tests: `tracker-routing-contract` failed open on the
  GitHub-route Linear-free check — its sed pattern was BRE (parens grouped,
  never matched) and the extraction failure inside `$(...)` could not stop
  the run. ERE now, and an empty region fails the assertion.
- cli: `vstack refresh` now seeds missing skill-settings keys into a repo
  that is its own package source (previously such repos silently received
  none and drifted on every settings addition), and refreshes a seeded
  key's comment block when the skill template revises it — gated by a new
  `settings_seeds` provenance ledger in `.vstack-lock.json`, so a comment
  the user edited is never rewritten. Installs predating the ledger pick up
  provenance on their first refresh where the comment still matches the
  template; a pre-ledger comment that already drifted from the incoming
  template stays untouched (indistinguishable from a hand edit) (VST-260).
- growth-guards: new skill — the shared check family beside size-ratchet
  (VST-214): `todo-ban` (flat work-marker ban, marker-shape scoped so prose
  naming a marker never fires), `byte-ceiling` (newly added tracked files
  over N KB fail, default 200; staged/base/full-sweep modes, lockfiles
  exempt), `suppression-ban` (blanket lint suppressions fail flat; bare
  rust dead_code/unused allows ratchet against a tighten-only baseline),
  and `commit-msg` (conventional gate; uppercase issue keys and
  git-generated messages pass). Dispatcher `growth-guards [all|CHECK]`,
  each check independently invocable; exit 2 on anything unmeasurable. The
  vstack repo seeds its own excludes lists, and the `vstack init` hook
  scaffold no longer plants a work marker in generated hooks.
- orch: `queue-wait` default budget is 2400s, sized to the merge-group suite
  (VST-249); the budget-exhausted `queued` verdict now carries `progressing`
  and a `cause` of `still_progressing` vs `stalled` from merge-queue-entry
  movement or a still-running check-run on the merge-group head, so a caller
  never re-arms a merge that is about to land.

- github: every `git diff` scan in `git-diff-summary` — stats, `*.rs` risk
  flags, and both panic-path scans — fails closed and loud when git fails
  (unreadable tracked file, exit 128): a diagnostic naming the scan, the
  arguments, and git's stderr, exit 1, no summary. Previously the panic scan
  died bare, the test-path scan degraded to "no test panics", the risk-flag
  scan to no unsafe/repr(C)/extern/atomics flags, and stats to a fabricated
  "0 files changed" (VST-233); nested `{ }` inside `( )`/`[ ]` groups no
  longer end an item early (VST-254).
- pi-agents-tmux 2.8.2: oneshot transcript records are appended in event
  order (one ordered write chain instead of concurrent `appendFile` calls),
  so the last assistant text a consumer extracts is the last one written —
  the out-of-order case surfaced as a merge-queue flake in
  `session-lanes.test.ts`.
- preflight: the `docs-cited-paths` lane covers the reverse direction too —
  an added source line citing a `.md` path (the "read this doc first"
  pointer a doc reorganization leaves dangling) fails when the path names
  nothing tracked or on disk. Same shared existence and directory guards as
  the markdown side; URL spans and double-quoted strings are stripped
  before matching, and data files (JSON/TOML/YAML/lock) and test-named
  files are out of scope.
- preflight: new `reviewer-attribution` lane — an added line crediting a
  transient reviewer-bot pass (a fleet bot name coupled to a PR/review
  reference: a parenthetical credit, a per-bot review credit, or a bot
  review-of-#N form) fails with "state the rationale, drop the reviewer
  credit". Naming a bot without the credit shape stays clean,
  `CHANGELOG.md` is exempt (rationale lives there), and
  `PREFLIGHT_BOT_NAMES` replaces the built-in fleet set (VST-284).
- agents: the seven engineer/analyst agents (generalist, iced, planner,
  researcher, rust, scout, tpm) drop the house "never trust a green check"
  blockquote — the rule's canonical homes are `code-quality` § Prove Your
  Guards (engineers) and the reviewer skill (reviewers); rust drops
  project-owned Build/Portability opinions; planner's discipline is cut to
  what its output format does not already require.
- preflight: the default and `--base` scopes include every non-ignored
  untracked file as a new file — the dev validate step and
  `tools/validate-changed` run before the commit, so a brand-new file was
  invisible to every lane until staged; `--staged` still sees only the
  index. The workflow lane's expression placeholder is expression-aware
  (a `}}` inside a single-quoted literal no longer ends it).
- tools: `validate-changed` — diff-scoped local validation that mirrors CI's
  lanes (skill/hook/cli/pi-extension suites plus the always-on cheap checks),
  printing its derived lane list first; suites whose tests read another
  area's files (orch's repo-wide doc lints, github/reviewer reading orch,
  project-management reading linear, pi-agents-tmux importing
  pi-session-bridge) run for changes there too; the shell lints cover
  untracked files and the working-tree executable bit; `--all` for the full sweep;
  dev-implement reads the project validation command from settings
  (`DEV_VALIDATE_CMD`; VST-237).

- code-quality/dev: must-fail controls are required where code is written,
  not only where it is reviewed (VST-266) — dev-implement § Validate requires
  a red-once control for every added or modified check, and Prove Your Guards
  names the source-text shapes a pattern-matching guard must be proven
  against.
- docs: issue-label-taxonomy states the one-way GitHub → Linear creation
  sync; cross-repo.md is cut to the cross-repo contracts (generic epistemics
  removed, the vendored-tree section is a pointer to
  `skills/review-gate/references/vendored-paths.md`, the bundle-import note moved to
  the pi-claude-bridge DEVELOPMENT.md); the retired in-repo mailbox path leaves
  .gitignore.

- cli: `vstack add`/`refresh` no longer strip the trailing newline from
  `vstack.toml` (the `[skill-instructions]`/`[agent-skills]` insert paths
  did), and every `vstack.toml` writer now repairs a file that already lost
  it on the first pass that reads it — one write, then stable — instead of
  pinning the malformed file forever (VST-252).
- orch oversee: `oversee-watch` — one command that blocks until the fleet
  needs the overseer (a new pr-watch attention line, a live `--item`'s PR
  merged at or after a fixed `--since`, a lane window gone, a lane pane
  showing a question prompt, or a heartbeat), replacing per-session
  hand-rolled watch loops and the Codex-rejected export+reducer shape;
  pr-watch attention standing at run start is a baseline carried on every
  event rather than a preempting event, so it cannot starve the lane checks —
  and that baseline persists per fleet (repo + `--since`, under
  `OVERSEE_WATCH_STATE_DIR`), so attention that arrives between two runs is
  the next run's first-pass event, not a fresh baseline; oversee's tmux claim is open-terminal's own worktree
  create (an owned item is skipped, siblings launch) instead of a pre-claim it
  then refused; GitHub items labeled `blocked` are not fleet candidates; lanes stopped by a harness session limit are resumed under another auth lane or nudged after the reset; a lane whose window is alive but whose pane has fallen back to a bare shell — harness exited on a session limit, crash, or quit — is its own `lane-exited` event with the pane tail, instead of holding a slot until the next heartbeat; the merged check is one `--head` query per live item, so a busy repo's listing window cannot miss an item's merge.
- orch submit-pr: GitHub items get a real `Closes #N` line in the PR body (the
  template rendered `Closes issue-N`, which GitHub ignores; three drill PRs
  merged without closing their issue).
- orch: `open-terminal` skips an item whose worktree is owned by another
  session (create exit 75) and launches the rest, instead of aborting the
  batch; the summary line reports launched/skipped/failed, exit 75 when every
  item was owned.
- tools/ci: vstack adopts its own size-ratchet — tracked baseline + excludes
  under `tools/`, enforced PR-time in the preflight job, queue-time in the
  merge group's shell shard, and locally by the pre-commit lane; the
  1000-line bar has a machine enforcer again (VST-248).
- second-opinion: the cross-model guarantee holds in every mode. Target
  selection is one roster walk — `SECOND_OPINION_MODELS`, priority-ordered
  (default `claude codex`) — that skips any target whose declared model
  identity equals the session's (the detected harness's model where there is
  one, else `SECOND_OPINION_CURRENT_MODEL`; per-target `SECOND_OPINION_<NAME>_MODEL`,
  default the name), forced `--target`/`SECOND_OPINION_TARGET` included, and
  refuses (exit 1, every candidate and its reason on stderr, nothing written
  or invoked) when no eligible model remains. `review` collects
  `SECOND_OPINION_COUNT` opinions (default 1); 2+ is the former multi-lane
  union, now opt-in breadth. `SECOND_OPINION_REVIEW_TARGETS` is no longer
  read (a set value is named on stderr). **Migration, consumer repos:** sweep
  every file these keys are seeded into — `vstack.settings.toml`, `.env.local`
  AND any `.env.local.example` or `.env.example`, which carry their own copies
  and are what a new checkout copies from. Drop `SECOND_OPINION_REVIEW_TARGETS`
  wherever it appears, and drop a `SECOND_OPINION_TARGET` that names the
  session's own model: it is now refused rather than honoured (the refusal names
  what the roster would pick). Pi/OpenCode/Cursor and undetected
  sessions must set `SECOND_OPINION_CURRENT_MODEL` (model ids normalize;
  `none` = no session model) or are refused; a declared identity the roster
  does not spell is refused too. A shortfall against
  `SECOND_OPINION_COUNT` is stamped as `qa_metadata.requested_count` /
  `selected_count` with `coverage: "degraded"`. `SECOND_OPINION_ARTIFACT_DIR`
  (default `tmp/second-opinion` under `--cwd`, owner-only) is the home for
  review/audit records written without `--output`. `detect` prints the
  target(s) a review would run.
- second-opinion: a split-form option refuses a flag-shaped value —
  `review --timeout --output report.json` is now a named parse error instead of
  taking `--output` as the timeout and silently dropping the designated output.
  Pass a value that legitimately begins with `-` as `--output=-report.json`.
- second-opinion: no run can hand a caller a stale result. Every mode that
  writes `--output` — `review`, `audit`, `challenge`, `quick` — DELETES that
  path at startup, plus exactly the sidecar records that mode can produce
  (`.raw.txt`, `.retry.txt`, `.failed.json`, `.noreview.json`,
  `.incomplete.json` for `review`/`audit`; `challenge` and `quick` write no such
  record, so beside their `--output` those names are yours and are left alone), before target selection and
  before any CLI runs, so no exit past the argument loop leaves a previous run's
  output standing — external review is advisory, and callers are told to
  continue past its non-zero exits. `--help` and `detect` never reach the write
  and clear nothing. One rule governs every deletion: a path is removed
  unconditionally only when THIS run will write it — `--output` itself, and the
  `<output>.<lane>.json` files a multi-lane run is about to write. Every other
  sibling must first prove the skill wrote it (the review schema AND an
  `external-…` agent marker, which only this skill's pipeline produces),
  ROSTER-NAMED ONES INCLUDED: at the default `SECOND_OPINION_COUNT=1` a run
  writes no lane file, so `<output>.codex.json` holding your own data survives
  while the same name carrying the marker is reclaimed. A sibling sharing the name shape
  (`<output>.notes.json`), or sharing the review schema under another agent (an
  internal `reviewer-*` artifact — that schema is a shared contract, not a
  signature), is never removed, and nothing outside `--output`'s own name space
  is ever touched. The `agent` field is wrapper-stamped like `timestamp`
  (`external-<target>` for a lane, `external-union(...)` for a union),
  overwriting whatever the provider returned, so the marker is this skill's own
  assertion of authorship rather than something a provider may omit. Reusing one
  `--output` path across runs is now safe, and pointing `--output` at a file you
  want to keep is not.
- second-opinion: a positively detected single-model harness (`claude`,
  `codex`) beats any CONTRADICTING `SECOND_OPINION_CURRENT_MODEL`, whatever its
  source — the run refuses naming both values rather than picking one. A
  declaration is a variable and variables are inherited, so an exported identity
  reaches every nested session (a Claude session starting a Codex one), where
  trusting it would dispatch to that session's own model; the harness is
  evidence about this process, the variable is not. An agreeing declaration
  changes nothing. Where detection CANNOT arbitrate (Pi, OpenCode, Cursor,
  undetected) the declaration is the only identity available and is still
  required — exported in that session's environment. **A value reaching
  such a run from any project file — `.env`, `vstack.settings.toml`,
  `.vstack/settings.toml`, `.env.local` — is refused, naming the file**: those
  are read by every session in the repo, so a value in one is not a declaration
  about any single session. A declaration set to make Pi or OpenCode work
  otherwise arrives in Claude Code and Codex sessions too (where it outranks
  detection that was already correct) and in other Pi sessions running a
  different model (where nothing can catch it) — either way a silent same-model
  review. The one exemption is a project value that agrees with a positively
  detected `claude`/`codex` harness: it changes nothing and is simply not used.
  Migration: move the key out of every project file that carries it —
  `vstack.settings.toml`, `.env`, `.vstack/settings.toml`, `.env.local` and any
  `.env.local.example` — and export it in the sessions that need it.
  Model ids also canonicalize with their provider prefix
  (`openai-codex/gpt-5.6-sol` → codex, `anthropic/claude-opus-4` → claude), and
  surrounding whitespace is ignored — a stray space in a settings file no longer
  makes an identity compare unequal and leave the session's own model eligible. The
  roster-spelling refusal applies only to DECLARED identities: a detected
  identity the roster does not name excludes nothing, so `SECOND_OPINION_MODELS`
  may name only the cross-model target. Set that roster to the empty string and
  the run refuses instead of falling back to the default targets.
  `SECOND_OPINION_COUNT` is validated only in the modes that read it
  (`review`, `detect`).
- second-opinion: `SECOND_OPINION_ARTIFACT_DIR` accepts `~/…` (expanded via
  `$HOME`, like `WORKTREE_BASE_DIR`) alongside relative and absolute paths, and
  a relative home the run CREATES is seeded with a `*` `.gitignore` so records
  never dirty the reviewed working tree. A directory that already existed is
  left as the operator arranged it: no `.gitignore` is seeded into it, so
  records written there are visible to git — point the setting at a directory
  you already ignore, or let the run create its own.
- orch: `PR_REVIEW_QUORUM` — approval-wait's multi-bot enqueue gate. When a
  repo lists its reviewer logins, no success emits (either mode) until every
  listed login has a non-dismissed review pinned to the current head AND
  zero threads are unresolved; JSON gains `quorum_missing`. Deterministic on
  review objects and thread state — a bot's findings hold the gate as
  threads; its prose is never parsed (the retired bot-review-wait pattern
  stays retired). Deadline and `PR_REVIEW_ON_TIMEOUT` still bound a dead
  reviewer. Empty setting = existing behavior.

- orch: `dev-artifact-check` and `review-artifact-check` gain a blocking
  `--wait SECS [--interval N]` mode; the armed watchdog now returns the moment
  a completion artifact lands (or at the deadline), so round closure never
  depends on a sub-agent's return message being delivered.
- orch: `queue-wait` guards queued PRs against late review findings (#1289,
  five near-misses in one night): a new unresolved thread while queued or
  armed triggers a dequeue — verdict `dequeued`, cause `late_findings` —
  and merge-pr routes it to comment triage and re-enqueue. Default on;
  `--no-guard` opts out. Failed reads are never quiet; failed dequeues are
  loud and distinct.
- cli: the TUI's Updates tab lists every stale install in either scope —
  the same set `vstack check` reports — whatever source is selected, and
  updating from it refreshes each item from its own recorded source (per
  scope, as `vstack refresh` does), recording that source's identity; an
  item whose source is gone is reported instead of silently skipped, and a
  recorded source that vanished is reported missing rather than silently
  rebound to the only other source (in `vstack refresh` too, whose lock
  repair now applies only to entries that never recorded a usable source);
  a stale extra picked there is reported as re-applied via `vstack apply`,
  not silently skipped. The source registry also drops per-project choices
  whose project root no longer exists, including Windows drive-letter and
  UNC roots (#1310).
- orch oversee: unattended by default (#1290). Minted briefs route blocking
  questions to the overseer via harness session-messaging where available
  (local question tool still used); the watch checks tmux lanes for pending
  question prompts and answers what available evidence decides, relaying
  only product-changing or owner-standing calls to the user.
- reviewer: six gap-closing scope lines from the vgs #133-135 analysis (87
  real bot findings, 91% precision): decoy-mutation must-fail controls,
  unconfirmed-start and dead-branch-success fail-open shapes, full
  field×malformation enumeration for new declarative formats,
  pre-steady-state probes, and mutation kills under every selection mode.
  review-pr's cycle cap now bounds new cycles, never verification — an
  unreviewed fix diff always gets its focused pass; submit-pr proves the
  HEAD it pushes (preflight + the session's validation command).
- review-gate: an errored bot review object is treated as silence, not
  approval evidence — the gate stays awaiting (VST-253; fail-open observed
  live). New selftest cases with pre-fix controls.
- github: thread and merge state are reported honestly (VST-269, VST-271) —
  `pr-threads --unresolved`/`--resolved` filter `--format=raw` as well as
  `safe`, and `pr-merge` short-circuits a PR that has left OPEN: an
  already-merged PR exits 0 with `ALREADY MERGED PR #N <mergedAt>`, a closed
  unmerged PR exits 1 with `CLOSED (not merged) PR #N`, and `--check` carries
  the lifecycle state in a new `state` field instead of reporting the
  permanently-UNKNOWN mergeable value, post-merge CI, and post-merge comment
  threads as blockers.
- cli: `vstack add` without `-y` in a non-TTY session fails with an
  actionable message instead of `os error 6`, and no longer repoints the
  global source registry on that failure (VST-255).
- **Review-thread triage sweep across the last nine merged PRs (#1298).** 67
  unresolved threads re-derived against `main`; the ones still live:
  - orch `approval-wait`: the quorum gate no longer reports a verdict it never
    emitted. Keep-polling is now a reserved return value (`QUORUM_KEEP_POLLING`)
    the call site matches on explicitly, replacing the blanket `|| true` that
    swallowed genuine failures alongside it; every emit inside the helper is
    propagated by hand, because reading the helper's status disables errexit
    through its body exactly as `|| true` did; and `emit_result` returns jq's
    status instead of an unconditional `return 0`. A failed emission can no
    longer reach `exit 0` — proven by a test that fails only the emission call.
    `PR_REVIEW_QUORUM` accepts any whitespace
    as a separator (carriage returns included — a CRLF-sourced value no longer
    holds the gate open forever on a login nothing can match). A PARTIAL
    quorum now counts as reviewer engagement, so `PR_REVIEW_ON_TIMEOUT=proceed`
    can no longer report a met gate while a listed sibling stayed silent. The
    paginated reviews read is captured in two steps with a zero-byte guard, a
    jq failure in the quorum parse is a loud failed read rather than an empty
    reviewer set, and the text (non-`--json`) timeout/proceeded lines name the
    missing logins. `PR_REVIEW_QUORUM` joins the orch README's setting table.
  - worktree: `remove <ID>` closes the last two holes in the live-lease guard.
    A session whose `VSTACK_SESSION_OWNER`/`HT_SESSION_OWNER` happens to equal
    the issue ID no longer skips the liveness gate — two sessions on one issue
    export the same string, so it proves nothing the argument did not. And the
    liveness verdict is now bound to the lease it was made on:
    `worktree-session-guard release --expect-gen` re-reads the lease
    generation under the same lock that serializes claim/refresh/release, so a
    sibling that claimed between the check and the release is refused instead
    of unlocked. The compare token is a per-claim GENERATION (`gen=` in the
    lease, `generation` in `status` JSON): every claim mints one — including a
    same-owner claim landing on a live lease, which is a replacement session —
    while a refresh continues the same claim and carries it across, so a slow
    decision still releases. A pid is reused by the OS, so a replacement claim
    landing on the recorded pid would have passed a pid compare and unlocked a
    live lease.
  - orch `queue-wait`: an `errors` field that is present but not an array is a
    malformed body, not an empty error set — `{}` and `""` both measure zero
    length and would have been counted as a clean page.
  - orch `queue-wait`: a GraphQL response carrying both data and a top-level
    `errors` array is a failed read, not a thread count — partial data can no
    longer undercount the blockers the late-findings guard exists to see. A
    blind guard keeps warning every three consecutive failed probes instead of
    once, and `merge-pr`'s `queued` row now says to re-enter the wait, since
    the guard only watches while a wait is running.
  - orch `ci-wait`: a no-CI probe skipped because the PR's base-branch or
    head-sha lookup failed is reported as unattempted, not as its own failed
    lookup.
  - orch `review-pr`: the QA safety-signal scan is a single
    `git diff --quiet -G…` predicate instead of a `git diff | grep -c`
    pipeline, which Codex `approval=never` classifies as approval-required.
  - linear `issues update`: `--labels` with `--clear-labels` is refused before
    `--attach` uploads, so the deterministic refusal no longer strands the
    uploaded asset in Linear storage.
  - cli `vstack add`: an unreadable `sources.json` fails the confirmed-source
    persist instead of defaulting to an empty registry and saving it back over
    the remembered sources and `forget_source` tombstones.
  - docs: gates.md distinguishes the two gate modes on the zero-thread
    requirement and states the concrete reason the triage-then-re-enqueue
    route cannot churn-loop; the worktree live-lease suite's check count is
    corrected (35, not 20).
- cli: every git process vstack runs — cache clone/fetch/reset, the cache's
  work-tree, origin and ssh-config reads, the repository-identity reads the
  `.agents/skills` ownership boundary is judged against, a Pi package's HEAD
  read, and the source-repository reads behind `vstack report` — is built by one
  hardened constructor: the `GIT_DIR`/`GIT_WORK_TREE` family dropped, and with
  it every way an environment hands git configuration to the process it starts
  (`GIT_CONFIG_PARAMETERS` — which git sets ITSELF for every subprocess of a
  `git -c key=value` invocation — `GIT_CONFIG`, `GIT_CONFIG_GLOBAL`/`_SYSTEM`/
  `_NOSYSTEM` and the indexed `GIT_CONFIG_COUNT`/`KEY_n`/`VALUE_n` pairs), since
  an injected `core.fsmonitor`, `core.hooksPath` or `core.sshCommand` names a
  program git RUNS — the last of those was read back and re-exported to the
  fetch. The programs an environment can name directly go with them:
  `GIT_EXEC_PATH`, whose directory supplies the `git-remote-<transport>` helper
  a fetch executes; `GIT_TEMPLATE_DIR`, whose `hooks/` a clone copies into the
  new repository and whose `post-checkout` the clone then runs; and
  `GIT_ASKPASS`/`SSH_ASKPASS`, which are used INSTEAD of
  the terminal and so are not covered by `GIT_TERMINAL_PROMPT=0` — which is set
  too.
  Cache commands additionally drop `GIT_CEILING_DIRECTORIES` and
  `GIT_DISCOVERY_ACROSS_FILESYSTEM`, which are hostile only where vstack owns
  the repository — for the user's own project they are configuration, and
  clearing them changed the answer the anchoring callers fail closed on.
  Network commands take the ssh program the USER named (`GIT_SSH_COMMAND`,
  `GIT_SSH`, then `core.sshCommand` in their global or system config) with its
  own variant's noninteractive flag APPENDED — `-o BatchMode=yes` for OpenSSH,
  `-batch` for plink/putty/tortoiseplink, nothing for `simple`, honouring
  `GIT_SSH_VARIANT` then `ssh.variant`. Git puts
  the host and upload-pack arguments after the whole string, so a trailing
  option still applies and a command carrying arguments of its own
  (`ssh -i key`, `env FOO=bar ssh`) keeps working AND stops prompting — the one
  prompt `GIT_TERMINAL_PROMPT=0` cannot suppress is ssh's own. An explicit
  `-o BatchMode=no` the user wrote earlier in their command still wins. A
  `GIT_SSH` program, and a plink-family command with arguments, keep the
  argument list they expect — but `GIT_SSH_COMMAND` is always SET, never left
  for git to resolve, and the cache entry's own `.git/config` is never read for
  either key: `core.sshCommand` there names a program git RUNS, so a cache that
  passed every ownership check could still execute one.
  `reset --hard` runs only after the cache entry
  proves to be vstack's own clone: not a symlink, not a redirected `.git`,
  `rev-parse --show-toplevel` is the entry itself, `rev-parse
  --git-common-dir` resolves inside it — a `commondir` file redirects refs and
  objects at another repository while the work tree still answers as the cache,
  so a fetch advanced the victim's remote-tracking refs — and `origin` is this
  source with no credential in it. Its own `.git/config` must also hold nothing
  but the settings `git clone` writes — checked as an allowlist, because the
  keys naming a program git runs on a repository's behalf (`core.fsmonitor`,
  `core.hooksPath`, a `filter.<driver>.smudge`) grow with git while the set a
  clone writes does not, and `fetch`/`reset --hard` run them. Nothing anywhere
  under its `.git` may be a symlink, nor (on Unix, where a link count is
  readable) a hard link to another file, and its `.git/config` must be a plain
  file that is present: git follows a link at any depth, so a redirected
  `config` answered every check for another repository and then had its
  `origin` rewritten, a redirected `refs` or `objects` took what the fetch
  wrote, and a hard-linked `config` or reflog is the same file under two names,
  with no link to follow. `--git-common-dir` answers for the `.git` root alone,
  which is why the check is a walk. Every cache
  command runs with `core.hooksPath` pinned at a regular file vstack maintains
  under the cache root, so no `<hooksPath>/<name>` resolves on any platform:
  an entry's own `.git/hooks/` is a directory of programs — git runs
  `reference-transaction` for every ref a fetch writes — that no check on its
  config or its location can see. That sentinel is fail-closed: if it cannot be
  created, or something other than a plain file is at its path, no cache
  command runs at all. A cache whose
  `core.worktree` pointed at a user checkout used to have that checkout's
  tracked files overwritten (VST-256). A
  Reading an entry asks every one of those questions too, not just the
  filesystem ones: reading is how a cache entry's content becomes the installed
  asset, so an entry that is a real clone of a different repository is refused
  on the read-only path as well as the updating one. A
  remote source is a source whether or not its clone is present or usable:
  `add` fails, `refresh` reports the entry as not refreshed naming the real
  cause — the refusal, or a cache that is not on this machine — and exits
  non-zero, never rebinding the entry to another source (hooks included) or
  repairing its lock record; the TUI's startup cache refresh skips it, and a
  hook removal that cannot regenerate the affected agents fails instead of
  leaving them carrying the removed hook. Neither `refresh` nor `add` rewrites
  an agent with a hook set the run could not determine — whether the hook's
  source did not resolve, was refused, or no longer carries it, the agent file
  is left exactly as installed and named in the report, rather than silently
  losing that hook's frontmatter while its script and its settings.json
  registration stay; `add`'s end-of-install reconciliation now reads hooks from
  every recorded source rather than only the one being installed from. `check` and
  `verify` name the same cause and the same command as `refresh` for a source
  that did not resolve, instead of calling it outdated or reporting a bare
  `src:!`. `add` no longer walks past a refused source to a different one: a
  credential, transport, ownership or clone failure on the source a project
  selected is an error naming it, not a silent fall-back that installs from
  somewhere else — and a remembered source spelled with a transport's scheme is
  refused rather than walked past when it is too malformed to parse as a URL —
  and a lock entry recording one is owned by it, so no same-named asset from
  another loaded source stands in for it either —
  while a missing local path stays a candidate the chain may walk past, `:`
  being an ordinary character in one. A remembered source that is remote-shaped
  is read as the remote even when a directory of that name exists under the
  current working directory, matching how `refresh` reads the same string.
  `Source not found` goes through the redacting display like every other source
  diagnostic. A failed fetch keeps the stale clone
  (warned once per source and message, not once per resolve); a failed reset is
  an error. Remote
  sources resolve to one cache entry per repository identity — every spelling
  of a GitHub repo shares one, two repositories never do — so URL-added sources
  refresh from the clone `add` made. On a non-GitHub host the ssh account and
  the transport are both part of that identity — an scp-like path resolves
  relative to the account's home, and nothing says an arbitrary host serves the
  same tree at one path over https and over ssh — so `alice@host:repo` and
  `bob@host:repo`, and the https and ssh spellings of one path, no longer share
  a cache entry and pass each other's origin check. The three spellings of one
  ssh transport (`git@host:repo`, `ssh://`, `git+ssh://`) still do, and GitHub
  remains the documented exception. The readable half of a cache key is bounded
  so a deeply nested `file://` or self-hosted path cannot push the directory
  name past a filesystem's 255-byte limit; the digest that separates two
  repositories is never truncated. An update points the entry's `origin` at the
  URL the invocation selected before fetching, so switching transport because
  the first one stopped authenticating actually takes effect instead of failing
  over the old URL into a tolerated stale cache. The revision it moves to comes
  from the REMOTE's own `HEAD` on every fetch, into a ref only vstack writes:
  an entry's stored refspec and its `origin/HEAD` are values inside the entry,
  and an altered refspec mapped another branch onto `origin/main` and had that
  branch's content installed. An accepted URL reaches git in git's own
  lowercase spelling, since `SSH://` is a request for a `git-remote-SSH`
  helper.
  **Breaking:** cache entries written by earlier vstack versions are not
  reused, because the cache key now derives from the repository identity. The
  first `vstack refresh` after upgrading reports each remote source as not
  present and names the `vstack add <source>` that re-clones it; the stale
  directory under `~/.vstack/cache/` can be deleted.
  Only https, ssh, git+ssh and file transports are handed to git: `git://` is
  unauthenticated and unencrypted and an unknown scheme makes git run a
  `git-remote-<scheme>` helper, so both are refused — as is a cached entry
  whose own `origin` uses one. Credential-bearing
  or plaintext-HTTP source URLs (userinfo token, `user:pass@` in any spelling
  including `user:pass@host:path`, query or fragment, `http://`), URLs whose
  authority carries whitespace or control characters, URLs naming no host
  (`https:///user:token@host/repo` put its credential in the path, where the
  authority checks could not see it), and sources starting with `-` are rejected
  before any git runs and never echoed — including in the
  source picker, which used to print a legacy registry entry's token verbatim,
  and in the sanitized git-output summary, which redacted only tokens carrying
  `://` and so let an scp-like `user:secret@host:path` through,
  and in the "source not found" line, which reached a credential URL malformed
  enough to be classified as a local path (`https:/user:token@host/repo`);
  an ssh remote's username is kept — but only where the spelling names ssh, so
  a token-only `https:///TOKEN@host/repo` is redacted rather than read as an
  account name — and any control or direction-changing character in a
  source string is escaped before it reaches a terminal. The bare `owner/repo`
  shorthand is not URL-shaped and so never reached those refusals: an owner or
  repository segment now accepts only characters GitHub allows, so
  `owner/repo?access_token=…` is no longer expanded into an HTTPS URL carrying
  the token.
- decider: index rows are append-only, never re-sorted — the template's
  "date order" clause contradicted its own example and the CLI reads rows
  positionally (VST-263); the schema carries the placement rule.
- AGENTS.md: the "Engineer over patch" rule now states determinism/tooling
  first, prose last; skills are instructions, not explanations.

- Post-merge bot triage of #1284: `open-terminal` now renders the
  merged-and-cleaned terminal condition into every launched brief — including
  the tmux delivery/re-send copy, which first shipped without it (caught by
  three bots on the triage PR itself); the README pattern row keeps the
  GFM table-escaped pipe (`\|` renders as `|` inside table code spans, the
  form this README already uses) so the copyable value is a working regex;
  README's `GH_ISSUE_PATTERN` row documents the real built-in default
  (`([A-Z]+-[0-9]+|issue-[0-9]+)` — the transcribed value would have
  rejected `issue-N` branches if copied into settings); post-summary's
  downstream-handoff trigger regains `interface` alongside `API`.

- **orch/fleet simplification v2 — ablation-tested condensation.** Every
  contested SKILL.md section got an A/B answer from live drills on the private
  rig (claude arm: full cycle 13 min vs the 14 min CI+perf baseline, zero
  questions, section removed; codex one-shot arm: full unattended cycle to
  merged-and-cleaned in 26.5 min — better than the stops-at-asks baseline —
  zero shape rejections, four transient runtime errors all self-recovered),
  and a section survived only where its removal measurably hurt an arm or a
  contract test pins it:
  - **Bootstrap Message deleted.** It shipped with every agent spawn; the
    claude arm ran a full cycle without it. Sub-agent spawning is already
    blocked deterministically (generated agents deny the spawn/question
    tools in frontmatter), the artifact contracts live in the dev/reviewer
    skills, and the drill held single-return and idle discipline with no
    bootstrap prose. Spawns go straight to the delegation message.
  - **Claude Code runtime block deleted** (team-creation/task-ordering
    guidance): the ablated arm created teams, re-delegated, and read idle
    wakes correctly without it.
  - **Codex runtime block and Harness-Safe Shell reduced to the rejection
    rule plus pointers**; the full shape catalogue, env-prefix normalization,
    spawn contract (`fork_context: false`, `spawn-adapter`, thread cap), and
    the no-`git rebase` rule are canonical in `references/codex-runtime.md` —
    which also carries the corrected conflict-recovery flag form
    (`--restack --replay` pauses; `--reuse --replay` aborts), fixing a
    bot-flagged wrong-flag recovery path that survived two review rounds.
  - **Codex dual-channel completion note kept**: not exercised by the arm,
    pinned by its regression test, four lines.
  - **Configuration table moved to README.md** (repo-owner material; no
    executing workflow reads it — they call `orch-env` inline), and the
    workflow-state/review-gate-modes/multi-PR-watching paragraphs collapsed
    to their non-derivable rules plus pointers to the CLI reference and
    `references/gates.md`.
  - Coordination, Round Closure, reviewer-persistence, Tracker Resolution,
    and Review Pipeline compressed to their contracts; `dev-artifact-check`'s
    one-word verdict made the acceptance re-explanations redundant.
- **Untriaged bot findings from #1272-#1277 markdown fixed** (the md-prose
  comments deliberately deferred to this pass): review-pr's diff scan used a
  broken `grep -clE` count and an unbound `[BASE]` placeholder; its DECLINED
  derivation never loaded `fixed_items`, so already-fixed blockers could be
  reported as outstanding; both settings templates still claimed
  `ORCH_DECISION_MODE=ask` restores the retired findings menus; submit-pr
  ignored `ORCH_MERGE_AUTONOMY` on the standalone path and misread non-CI
  merge-blockers (conflicts, unresolved threads) as stale CI state;
  start-worktree parsed the dev return's retired `QA Labels` field name;
  oversee shipped with five launch-surface defects (no `workflow-state init`,
  unresolved `GH_REPO` for pr-watch, `/orch` slash syntax on Codex lanes, an
  unread `ORCH_OVERSEER_LANES`, and no atomic per-item claim on
  thread/session surfaces); the workflow-state schema and help text still
  showed the number-shaped `last_threads` example that recreates the
  comment-triage loop.
- **merge-pr: post-merge worktree cleanup is by rule, not a question.** A
  merged PR's worktree with a clean tree and the merged branch checked out is
  removed and its branch deleted; a dirty tree or foreign lease keeps it,
  reported in the outcome table. submit-pr's merge offer now honors
  `ORCH_MERGE_AUTONOMY=auto` the same way the managed path does. handoff and
  oversee briefs state the terminal condition — complete means PR merged and
  worktree cleaned, not opened (codex one-shot sessions self-judged "done" at
  PR-open).
- **worktree: `remove` no longer tears down a live sibling session's tree.**
  An issue-addressed `remove` derives lease ownership from the issue ID, so
  any session naming the issue passed the probe; now a lease whose recorded
  claiming process is still alive on this host (and is not this session or an
  ancestor) refuses the removal, naming the owner and pid. `remove --force`
  skips exactly that refusal; dead or ancestor pids, env-ladder identities,
  and every other safeguard behave as before. New 35-check suite with
  mutation-proven controls.
- project-management, dev, preflight, worktree, review-gate markdown:
  verified tight (three prior passes + this one); zero-cut apart from a
  second-opinion harness-table dedupe and the fixes above. linear/github
  markdown untouched.

- review-gate: the writer template header now counts the retry path's second
  content-creating request, matching the #1280 adoption.md correction (the
  two had diverged); adopted consumer copies inherit it at their next writer
  migration.

- **review-gate docs: a compression in #1277 INVERTED the gate's central
  safety caveat** — README claimed "Two greens prove no review" where the
  contract is "two greens do NOT prove a review happened" (they attest only
  that the gate is off). Caught by both bot reviewers on all five consumer
  vendor PRs, held unmerged by the propagation agent, fixed upstream here and
  re-vendored. Also: the relay cost line now counts the retry path's second
  content-creating request, and the rate-limit table row states the real
  beyond-cap behavior (skip, not clamp).

- **Bot-review triage across #1272-#1277 scripts** (admin merges skip bot
  rounds; this closes the loop): linear `issues update --labels` now refuses
  an unknown label instead of silently shipping a partial set (new
  refusal test asserts no mutation is sent); open-terminal guards every
  valued flag against a missing value under nounset and single-quotes the
  lane env value in rendered launch commands; ci-wait's no-CI shortcut
  waits for a second empty poll and probes external commit statuses, so
  late-registering or non-Actions CI cannot be misread as absent; a blank
  `impact` is rejected like a missing one; the dev acceptance tables in
  dev-start/dev-fix/review-pr-comments now branch on the one-word `verdict`
  (closing the gap where a failing-validation artifact could route to
  Accept) with an explicit never-accept `retry` row; the external-review
  prompt schema teaches `impact` for issue candidates; a test's `mapfile`
  replaced for Bash 3.2 portability.

- **Issue candidates must argue reality: `category: issue` findings require an
  `impact` line.** One sentence naming who hits the problem, on what real path
  — enforced by `review-artifact-check` (a candidate without it is rejected
  with the field named), stated in the finding schema, and adjudicated by the
  filing bar: an impact that needs "could", "might", or "in theory" is a
  decline, not an issue. Hypothetical edge-case candidates now die at the
  artifact gate instead of becoming suggestion pressure and backlog residue.
- **Review fix-selection is disposition-by-rule everywhere — the menus are
  gone.** `review.md` § 4 and `review-pr.md` §§ 4/7 no longer ask which
  findings to fix or whether to file: blockers and fix-category suggestions
  delegate to the fix round in every decision mode, issue candidates flow to
  the audit input (audit-issues' own approval gate remains the user's say on
  creation), and declined items surface in a required DECLINED report section
  — re-derived from on-disk artifacts, so compaction cannot silently drop
  one. review-pr's `ORCH_DECISION_MODE` resolution step is deleted with the
  menus. A 213-line lint pins both workflows' menu-free sections, the
  every-mode binding, and the declined reporting (10 planted controls).
- **Fresh-eyes sweep across all skill and agent markdown.** The verdict of
  three independent passes: the corpus is tight — most surviving repetition
  is deliberate, test-enforced redundancy. What the sweep did find: four
  silent defects in orch/dev (a workflow-state schema example documenting the
  wrong type for `pr_review_baseline.last_threads`, which would have looped
  comment triage to its cap; `QA_PERF_PATHS` read by review-pr but documented
  nowhere a repo owner could find it — now in § Configuration and both
  settings templates, enrolled in the parity guard; a broken code fence in
  the reviewer Output Contract swallowing the self-validation instruction; a
  wrong section cross-reference in dev-implement § 8), two defects in
  project-management (research issues created with a duplicated section and
  placeholders used before definition; `audit-issues-input` omitting the
  `research_issue` field two workflows exchange), and consolidation in
  review-gate/second-opinion (triplicated adoption preconditions, a six-copy
  mode caveat, a five-copy artifact-integrity contract — one canonical home
  each) that surfaced a silently diverged Pi `deny-tools` example, corrected
  against the CLI source. Bootstrap message trimmed (ships with every agent
  spawn); stale model-version tables replaced with `--help` pointers; two
  tracker-citation violations of the house rule removed from shipped md.

- **orch: `oversee` fleet mode.** A standing session that burns down the
  unblocked queue: one orch session per item, shepherded to merge. The launch
  surface resolves once — tmux lanes via `open-terminal`; otherwise the
  harness's own session/thread launching (Codex threads, agent teams, app
  session tools) carrying the same brief; with neither, the queue runs
  sequentially in-session. `ORCH_OVERSEER_LANES` caps concurrent lanes
  (default 3). pr-watch is the fleet's single PR reducer where installed.
  The settings-parity test now enrolls new orch keys, so template drift
  between the skill and root examples fails the suite.

- finding-disposition: a decline is terminal — it appears as its one-line
  summary entry and is never re-presented as a "file it anyway?" question
  (drill 3: an orchestrator improvised exactly that ask after a correct
  decline).

- orch review-pr mints each reviewer's artifact path at delegation time
  (`review-artifact-check --path`) and passes it as the delegation's
  `Artifact:` line; reviewers write to that exact path instead of
  hand-formatting filename timestamps (two of four drill-2 reviewers still
  wrote placeholder clocks under the mint-it-yourself contract).

- **orch + dev: six determinism/efficiency fixes from a live end-to-end drill**
  (a fake issue run through the full stack on a low-effort lane, watched phase
  by phase; every fix is a deletion, a short-circuit, or a tool — no added
  instruction prose).
  - `start` no longer asks where the work should run — the invocation already
    answers it (`start` runs in-session, `handoff` launches a separate one).
    The routing question stalled launch-only sessions forever.
  - **New `ORCH_MERGE_AUTONOMY` setting** (`ask` default | `auto`): `auto`
    merges without asking once every merge gate is green; `MERGE_READY = false`
    never auto-merges. Merge leaves the unconditional always-ask set.
  - `dev-artifact-check` prints a one-word `verdict` — `accept`/`wait`/`retry`
    — folding artifact validity, validation state, and commit resolution into
    a single answer. Round closure's on-wake check is now run-one-command,
    read-one-word; in the drill a low-effort orchestrator narrated the wake
    instead of combining two checks and a table, and misread a completed round.
  - `ci-wait` recognizes a repo with no CI at all (zero active workflows, no
    branch protection, no required-check rules — every probe affirmative,
    probe failures fall through to the normal grace) and reports
    `verdict=none` immediately; submit-pr routes it as a documented no-CI
    path. Previously a CI-less repo burned the dispatch grace repeatedly and
    ended in an override-framed merge.
  - `review-artifact-check --path` prints the canonical timestamped artifact
    path; reviewers stop hand-formatting filename clocks (three of four
    drill reviewers wrote placeholder times).
  - **Breaking — QA routing no longer touches tracker labels.** dev § 8
    becomes Record QA Signals: the same trigger table (unsafe/atomics →
    `needs-safety-audit`, hot path → `needs-perf-test`, new public API →
    `needs-review`) now records signals in the completion artifact
    (`--qa-label`, artifact field `qa_labels` unchanged) instead of applying
    repository labels — a fresh repo can no longer fail QA with
    `configuration_error`, and no label inventory is required. review-pr § 5
    derives the QA panel from dev signals ∪ a deterministic diff scan
    (unsafe/atomics grep; `QA_PERF_PATHS` glob matching for perf) ∪ recorded
    one-line judgment, and § 6 maps signals to agents directly. QA passes are
    costly, so judgment may drop a trivial-trigger signal — with the rationale
    recorded, never silently. The bundled parent label aggregation is gone
    with the rest of the label mechanics.
  - New `acceptance-verdicts` test covers all three script changes, including
    an active-workflows control proving the no-CI shortcut cannot fire when
    workflows exist.

- **Catalog-wide cleanup: every skill and agent reduced to contracts, commands,
  and non-derivable domain knowledge; orch and project-management rewritten
  from scratch.** Markdown across the touched assets drops from ~19,000 to
  ~8,900 lines, with scripts preserved and their test coverage strengthened.
  The principle throughout: frontier agents need contracts and deterministic
  tooling, not technique tutorials; ordered workflow steps stay (the sequence
  is the contract) while the padding inside them goes; a rule lives in exactly
  one file and everything else points at it. The branch closed with a
  five-lens review fleet (correctness, error-handling, docs, architecture,
  tests) plus one bounded fix round; every finding below marked "found in
  review" comes from that pass.

- **orch: ground-up rewrite (v3).** The cycle — get issue → dev implements →
  review → fix blockers → re-review → PR → review gate → merge — is stated
  once at the top of SKILL.md and bounded by four rules: bounded review loops
  (minor suggestions never trigger another cycle; re-review narrows to the fix
  diff and its domains; two consecutive clean rounds end review), no edge-case
  churn (a finding that cannot affect real usage is declined with one line —
  neither fixed in-PR nor filed), user questions only for product or
  experience decisions, and artifact-based acceptance. Finding disposition
  (fix vs issue vs decline, with the filing bar) lives in
  `references/finding-disposition.md`; project-management's creation bar is
  the final authority for anything the audit pipeline files, and the two bars
  were reconciled in review (a reproducible anomaly with evidence files as an
  investigation issue whose deliverable is the diagnosis). Trivial diffs
  (docs-only or under ten lines with no logic change) skip review by rule
  instead of asking. md 6320 → 3589 lines.
  - **Breaking — session-kickstart layer removed:** `session-init`,
    `parallel-groups`, `workflows/initialize.md`, `workflows/parallel-check.md`.
    A session picks up the issue and goes. The worktree session-guard lease
    claim moved intact into `start-worktree.md` § 1. Consumers lose
    session-init's Linear writes preflight and its Codex-worktree branch
    normalization step (normalization still runs inside the orch flow).
  - **Breaking — scripts removed:** `review-init`, `review-risk`,
    `refix-route`, `local-review-budget`, `list-review-agents`,
    `tracker-for-issue`, `codex-app-agent-preflight`. Settings
    `REVIEW_RISK_COMMAND`, `PR_REVIEW_REFIX_MAX_LINES`, `ORCH_CACHE_DIR`, and
    `ORCH_LANE_CLAUDE_PERMISSION_ARG` are retired with them.
  - **Breaking — workflows removed:** `fix-reconcile.md` (tracker
    reconciliation belongs to the TPM audit pipeline and `Closes` linkage),
    `agent-sequencing.md` (→ SKILL.md § Coordination), `recommendation-bias.md`
    (→ `references/finding-disposition.md`).
  - **Breaking — `open-terminal` launch flags are chosen at launch time.** The
    hardcoded `--model 'opus[1m]' --effort max` and the
    `ORCH_LANE_CLAUDE_PERMISSION_ARG` default are gone; model, effort, and
    permission flags arrive via `--launch-flags`, sized to the task by the
    launching workflow, and nothing in scripts, settings, or templates
    supplies a default. Lanes auto-populate from discovery; `ORCH_LANE_ALIASES`
    names them and `--lane <alias>` resolves against the discovered inventory
    (found in review: a cwd directory sharing an alias's name no longer
    shadows it, and rendered launch tokens are quoted so a bracketed model id
    survives the launch shell).
  - The orch test suite is reshaped from prose pinning to contract testing:
    a 55-assertion helper contract, a reference-integrity scan (every cited
    orch asset must exist — its own control now runs through the real
    extraction pipeline), a retired-asset scan (no deleted script or workflow
    has a surviving caller), and re-pinned structural assertions for the
    post-merge base-sync ownership contract. The lanes suite now stubs tmux
    and proves hermeticity — a test run can no longer create real terminal
    windows or sessions (found in review after test runs inside a live tmux
    session launched real `CC-1` windows).

- **project-management: ground-up rewrite (v3); the TPM files less and closes
  more.** The job description changes from "decompose and file" to "file only
  what is critical and actionable, and burn down more than you create." A
  creation bar gates every issue: it must change what a user or operator
  experiences (or block work that does), not already be covered, and be
  finishable without a new investigation — a reproducible anomaly with
  evidence in hand passes as an investigation issue whose deliverable is the
  diagnosis. Anything else is declined with one line instead of becoming a
  tracked placeholder. Every audit proposing creations completes its
  cancellation sweep and reports `created N / closed M` as its headline. The
  approval gate went from eleven multi-selects to two questions (what to
  create, what to cancel); labels, priorities, relations, hierarchy, sort
  order, and project moves are applied on the workflow's own authority and
  reported. The velocity-adjustment, domain-confirmation, manual
  project-placement, and commit-the-findings prompts are gone. md 6452 → 2700
  lines.
  - **Breaking:** `workflows/tpm-audit-project-order.md` merged into
    `workflows/tpm-audit.md` as a mode; `schemas/audit-project-order-output.md`
    merged into `schemas/audit-output.md`; `references/issues.md`,
    `references/initiatives-projects.md`, and `references/prioritization.md`
    removed (their few real constraints relocated to the templates and
    roadmap-create); roadmap-create's legacy markdown-parsing fallback removed
    — the plan JSON is the contract. A new `disposition-contract` test fails
    if any parallelism-ceremony reference returns.

- **dev: reduced to the implementer's contract (v2).** The skill carried four
  copies of orch's harness-shell rules and two copies each of the
  completion-artifact semantics, validation-failure ladder, and reflect rule;
  each now has one home (harness rules point at orch; the artifact,
  validation, and reflect contracts live in dev SKILL.md, each workflow
  keeping only its kind-specific commands). The container-classification
  essay collapsed to the three single-PR opt-in markers and the
  stop-and-report rule. 825 → 500 lines; all four dev contract tests pass
  byte-identical to the previous revision.

- **linear: fourteen defect fixes, no functional loss (v1.1).** Led by three
  that silently corrupted state: a transient label-lookup failure no longer
  wipes an issue's entire label set; a corrupt cache file now fails loudly
  naming the file instead of answering "no issues" to every query; and
  `projects list --limit` no longer feeds unvalidated input to shell
  arithmetic (a command-execution vector). Also fixed: `--with-relations`
  eating the next flag, multi `--label` filters matching nothing,
  `--cycle current` returning empty on resolver failure, empty titles from
  `echo -n` values, unknown `--assignee` silently dropped, write actions with
  an empty identifier exiting 0, `add-relation` rejections exiting 0,
  block/unblock label-set logic, and `create --labels` dropping labels on
  lookup failure. GraphQL payloads are jq-bound throughout; the undeclared
  `bc` dependency is gone. Found in review and fixed in the same pass: an
  `echo -n`→`printf` conversion slip that would have wrapped every
  label/milestone/project-label name in literal quotes (13 sites, caught
  before merge), `cache issues relations` reading stdin instead of the cache
  file, `bulk-update` folding warnings into the JSON it parses (a committed
  update reported as failed), unknown `--format` values silently served as
  safe output, and fractional `--estimate` values refused on create. Parity:
  zero subcommand diffs against the previous revision; 42 test files.

- **github: fail-open elimination and hardening (v2).** `git-diff-summary` on
  a bad base ref no longer reports a trivial no-risk change with exit 0;
  `ci-logs` no longer returns a fetch failure as the log text; the PR list
  commands no longer widen to every open PR when the GitHub login cannot be
  resolved, and now see failing classic commit statuses; `sticky-comment` and
  the thread/dismiss commands distinguish API failure from genuine absence.
  `find-comment` and the batch thread mutations bind values as variables
  instead of splicing them into jq/GraphQL programs; all JSON is emitted via
  jq so API error text containing quotes cannot produce malformed output.
  - **Breaking:** `label-add`/`label-remove` drop the `--reason` flag — its
    only sink was a committed no-op. `_activity-emit.sh`,
    `lib/label-activity.sh`, and `lib/pr-branch.sh` (no-op compatibility
    stubs) are removed.

- **decider: `decisions` CLI hardened (v1.1).** The GNU-grep/PCRE dependency
  is gone (works on stock macOS); index parsing is a single jq pass (~30x
  faster on a 200-row index); INDEX link cells written as backticked or bare
  filenames now resolve instead of silently hiding the decision from `get`
  and body search; malformed index rows are named on stderr instead of
  vanishing. The `search-decisions` workflow file is removed — SKILL.md's
  command table is the single home.

- **deep-research (v1.1):** `--timeout` rejects non-positive and non-integer
  values with a message naming the flag, instead of aborting the request and
  blaming the network. Duplicate and orphan templates removed; a new test
  locks the findings template to the validator so they cannot drift.

- **Agents: the seven non-reviewer agents (`rust`, `scout`, `tpm`, `planner`,
  `researcher`, `iced`, `generalist`) reduced to the reviewer shape** —
  identity, house blockquotes, domain scope, specialist probes, output
  expectations. Capability lists restating frontmatter, process narration,
  output-format templates, and rust's curated ctx7 table are gone. 455 → 237
  lines; no frontmatter, name, or contract changes.

- **Skills reduced:** worktree (README rewritten for humans; CLI contracts
  frozen and proven diff-identical), iced-rs (SKILL.md prose only —
  `examples/`, `references/`, and `iced_wgpu/` untouched), price-handling,
  trading-design, dep-radar.

- **Breaking — removed: the `iced-shadcn` and `html-artifact` skills, and the
  shipped `vanillagreen-themes` extras pack.** Before your next
  `vstack refresh`, delete any `iced-shadcn` or `html-artifact` entries from
  your project's `vstack.toml` (`[skill-instructions]`, `[agent-skills]`,
  `[role-skills]`). If you applied the theme pack, run
  `vstack apply vanillagreen-themes --revert` **before** upgrading, while the
  pack is still resolvable; afterwards the managed blocks in Ghostty/tmux
  configs must be removed by hand and the VS Code extension uninstalled
  manually. The `extras` catalog kind and `vstack apply` are unaffected —
  vstack simply no longer ships a pack of its own.

- Consumer adoption notes: `vstack refresh` picks everything up after the
  config edits above. Delete retired settings keys (`REVIEW_RISK_COMMAND`,
  `PR_REVIEW_REFIX_MAX_LINES`, `ORCH_CACHE_DIR`,
  `ORCH_LANE_CLAUDE_PERMISSION_ARG`) from `vstack.settings.toml`; add
  `ORCH_LANE_ALIASES` if you alias lanes. Automation calling any removed orch
  script or passing `github.sh label-add --reason` must update.

- **linear: blocking relations no longer require both issues to sit in the
  same project.** `issues add-relation --blocks`/`--blocked-by` rejected any
  pair whose projects differed — including a pair where one issue had a
  project and the other had none — forcing real dependencies to be downgraded
  to `--related` or the issues relocated. A dependency between two issues is a
  property of the work, not of how the work is filed, and cross-project
  sequencing is ordinary in roadmaps that span projects. The project-equality
  check is gone, along with the `project { id name }` selection in the
  `ValidateBlocking` query and `issue-validation.sh`'s
  `validate_issue_project_shape` helper, which existed only to prove the shape
  that check consumed. The other blocking guards are
  untouched: a relation still must connect peers of one bundle (same direct
  parent, or both top-level), an issue still cannot block its own ancestor or
  descendant, and each parent chain is still proved to reach an explicit null
  root through well-formed unique-ID edges before any mutation, with
  incomplete, cyclic, or malformed hierarchy responses rejected. The
  project-management, orch, and linear guidance that told agents to relocate
  issues or fall back to `related` for cross-project dependencies now says to
  record the dependency directly; the same-project rule for parent/child
  hierarchy placement is a separate constraint and is unchanged.

- **New `block-repo-copy` hook: a recursive copy of a repository or build tree
  into a temp/scratch destination is refused before the command runs.** An agent
  told to sanity-check behavior against a real consumer repo "read-only, under
  `~/dev`" reasoned that copying it somewhere safe first was how to make it
  read-only, and ran a recursive copy of that repo — a ~29GB `target/` build
  tree plus a large `.git` — into its scratchpad, twice. `/tmp` on that machine
  is a tmpfs at the kernel default of half of RAM (63GB), so the copy consumed
  roughly half of system memory, filled the filesystem to 100%, and every
  process writing there began failing with ENOSPC, which broke tool output
  across the whole session until it was cleaned up by hand. Prose instructions
  did not prevent it and cannot be relied on to: the reasoning that produced it
  was locally sensible, so the rule has to be enforced by the harness before the
  command runs. `hooks/block-repo-copy.sh` is a `PreToolUse`/`Bash` hook that
  refuses `cp -r`/`-R`/`-a`, recursive or archive `rsync`, `git clone` of a
  local path, and `tar` create-to-extract pipes when BOTH halves hold: the
  source is itself named `.git`/`target`/`node_modules` or carries one of
  `.git`, `target`, `node_modules`, `vendor`, `.venv`, `venv`, `.next`,
  `.cache`, `.gradle`, `Pods` one level down, AND the destination resolves under
  `/tmp`, `/var/tmp`, `$TMPDIR`, `$CLAUDE_CODE_TMPDIR`, a `mktemp -d`, or any
  path containing `scratchpad`. Requiring both halves is what keeps false
  positives near zero — an expensive tree copied to an ordinary destination and
  an ordinary directory copied into scratch both pass, as does a
  non-recursive copy, `rsync -R` (which is `--relative`, not recursion), and a
  repository subdirectory that carries no marker of its own (the source check
  never walks upward). The refusal names the source, the marker that made it
  expensive, the destination, and the two alternatives: read the source in
  place, since reading does not mutate it, or build a minimal synthetic fixture
  in `mktemp -d`. The hook fires on every Bash call, so a non-copy command
  exits through a bash-builtin regex before any subprocess or filesystem work
  and the source check uses `-e` existence tests only — never `du` or a
  traversal; the suite pins the fast exit with a PATH shim log that must stay
  empty for a non-copy command and must record tool use when a copy is actually
  evaluated. Registration needed no config change: `[hook-events]`'s existing
  `"PreToolUse:Bash" = "all"` is matched by the hook's frontmatter, so consuming
  repos pick it up on the next `vstack refresh`. Operand parsing decides the
  destination the shell would actually write to rather than assuming the last
  word: an earlier `cd` sets the base a relative destination resolves against,
  `cp -t DIR`/`--target-directory=DIR` inverts source and destination, options
  that consume an argument (`--depth 1`, `--exclude PAT`) no longer shift the
  operand count, quoted paths containing spaces stay one operand, and a
  destination variable assigned `$(mktemp -d)` earlier in the same command is
  resolved. The JSON decode is escape-aware, so an embedded `\"` no longer
  truncates the command on a host without `jq`, and a payload that names a
  command the decoder cannot recover is refused rather than allowed — a guard
  that cannot read its input must not wave the call through, while a
  well-formed payload carrying no command still passes. Per the Pi hook parity
  rule (AGENTS.md § Repository conventions), the same predicate ships for Pi in
  `pi-extensions/pi-hooks` as the `blockRepoCopy` setting (default on), with
  its own 30-case suite; the package goes to 0.3.0.


- **orch: the post-merge main sync proves which checkout owns the base branch
  before advancing it, and reports a stale base as a warning.** `merge-pr.md`
  § 5 step 4 ran `git -C [MAIN_REPO_ROOT] merge --ff-only origin/[BASE_BRANCH]`
  unconditionally. `merge --ff-only` advances whatever branch the target
  checkout has on `HEAD`, so a main checkout parked on a foreign branch got
  THAT branch fast-forwarded, exited 0, and left local `[BASE_BRANCH]`
  untouched with nothing reported — in one observed session the main checkout drifted 30
  commits behind `origin/main` across four merges, a branch cut from it needed
  a mid-flight rebase and full revalidation, two review agents produced false
  findings from the stale tree (one filed issue needed a correction pass), and
  a ten-reviewer fleet ran retired agent definitions including one `main` had
  deleted. The step now reads `rev-parse --abbrev-ref HEAD` first and routes:
  on the base branch it ff-merges in place; on any other branch (or detached
  `HEAD`) it advances the local ref by name with
  `git -C [MAIN_REPO_ROOT] fetch .
  "refs/remotes/origin/[BASE_BRANCH]:refs/heads/[BASE_BRANCH]"`, which re-uses
  the tracking ref the origin fetch already updated — no second network round
  trip and no credential helper — while updating a non-checked-out branch and
  refusing a non-fast-forward; when that refspec is refused because another
  worktree holds the branch, it locates that worktree via `worktree list` and
  ff-merges there. Three named blocking outcomes replace the old
  "surface the divergence" note — a merge-blocking dirty tree (naming every
  file git listed and its checkout), a non-fast-forward rejection (naming both
  shas), and an unreachable base — and § 7 now always carries a `Base sync`
  row, a WARNING with the stale local sha, the origin sha, and the cause
  whenever local `[BASE_BRANCH]` could not be advanced. `start-worktree.md`'s
  existing `base-freshness` gate needed no new machinery — it is reached by every
  `start.md` § 5 route, and bare `worktree create` already cuts new branches
  from a freshly fetched `origin/<default>` — so its wording was corrected to
  stop reading as reuse-only. `workflow_helpers.sh` pins the precondition, both
  non-ff-merge routes, the blocking dirty report, and the § 7 warning; the
  retired sentence is pinned absent.

- **reviewer: ground-up rewrite driven by 24-PR escape mining; new
  `preflight` skill; `reviewer-structure` retired.** A survey of the last 6
  PRs in each of four consuming repos classified every bug that escaped
  internal review; the reviewer skill and all reviewer agents were rewritten
  from scratch around those classes, on the principle that frontier reviewers
  need domain probes and contracts, not technique tutorials. Cut outright:
  the duplicated field tables, repeated artifact-naming warnings, the inlined
  Harness-Safe Shell essay (orch is the canonical home; the worked backtick
  example moved to `references/codex-runtime.md`), the central scope-boundary
  table (each agent file owns its scope and its leave-to-peers line),
  reviewer-side decider recovery (a broken decision path is noted and
  reviewed without — decision context is the orchestrator's to provide; the
  `decider` and `github` skill dependencies drop with it), the perf agent's
  33-row resource library, and every generic read-the-architecture-docs
  boilerplate section. In their place: every review workflow mandates a
  pre-return self-check with orch's `review-artifact-check`, the ethos adds
  "report the class, not the instance", and re-review rounds scope to the
  fix diff plus blast radius while sweeping each fixed defect's class.
  Agents carry mined high-yield probes instead of generic checklists:
  fail-open catalogue (`reviewer-error`), must-fail controls and assertion
  tightness (`reviewer-test`), claim/derivation/citation verification
  (`reviewer-doc`, now xhigh effort — doc drift is the largest escape class),
  boundary probes (`reviewer-correctness`), ownership-gating class
  enforcement (`reviewer-security`), file/process races (`reviewer-safety`),
  mechanism-over-shapes (`reviewer-quality`), spec review (`reviewer-arch`).
  Perf benchmark recording contracts live in
  `skills/reviewer/references/perf-qa.md`, loaded only by the perf agent.
  A new `code-quality` skill (VST-212, modeled on Turso's) gives dev agents
  the authoring mirror of the reviewer probes — no fail-open branches,
  prove-your-guards, comment do's/don'ts (why-not-what, no temporal markers
  or review archaeology), over-engineering and cleanup rules — one generic
  copy upstream, repo specifics via the `[skill-instructions]` seam; wired
  into `[role-skills] engineer`.
  Size-ratchet enforcement moves earlier without changing semantics: the
  pre-commit hook now runs the repo's own ratchet script — adoption-gated on
  a baseline existing, so installing the skill alone never starts enforcing
  — and dev-implement § 5 runs it pre-PR, replacing the CI-round-trip
  discovery path; the reviewer-side duplicate of the size rule is gone with
  `reviewer-structure`, leaving the script as the single source of truth.
  **Breaking**: the `reviewer-structure` agent is retired — its file-size job
  is size-ratchet's, TODO hygiene is preflight's, god objects and test
  placement fold into `reviewer-quality`; remove it from consuming-repo
  configs on next refresh. The new `preflight` skill is a diff-scoped,
  fail-only deterministic checker (shell syntax + shellcheck error lanes,
  masked-return/unchecked-`mktemp` fail-open lint, dead doc citations,
  unlinked TODO markers, JSON/TOML syntax) wired into dev-implement § 5, the
  pre-commit hook, `[role-skills] engineer`, and a PR-time CI dogfood job.
  Consumer adoption: `[agent-skills]`/`[role-skills]` are project-owned
  after install, so existing consumers opt in by adding `preflight` and
  `code-quality` to their own config and running `vstack refresh`; the
  updated pre-commit hook arrives with refresh and its preflight lane
  self-gates on the skill being installed. CI use of preflight, like
  review-gate, requires the installed skill committed to the repo.
- **review-gate: the writer relays PR-attached legs instead of running the
  evictable job in a PR's check rollup** (VST-210 / #1210). The single-writer
  concurrency group is global, so a burst evicts pending runs — harmless to
  convergence (every run converges every open PR), but an evicted run is
  still a *check run*, and one attached to a PR head left a `CANCELLED` entry
  that pinned the PR at `mergeStateStatus UNSTABLE` until someone reran it by
  hand. `templates/review-gate-writer.yml` now splits the two roles: PR-attached
  legs (`pull_request_target`, `pull_request_review`, `status`, an opted-in
  `check_run`) run a new group-less `request-converge` relay that dispatches a
  converge pass and exits in seconds, and only `workflow_dispatch` /
  `schedule` — whose runs attach to the default-branch head — hold the writer
  group. Single-writer serialization, converge-all, and the write-ordering
  guard are unchanged; eviction marks simply land where nothing gates on them.
  The relay derives its own workflow file from `github.workflow_ref`, so a
  renamed consumer copy needs no new ADAPT. Its complete scope is
  `actions: write` (dispatch only — job-level permissions replace the
  workflow default rather than extend it) — the writer itself still holds no
  `actions` scope and never re-runs CI. On a
  fork `pull_request_review` the relay cannot dispatch (read-only token) and
  stays a green no-op, so fork review evidence converges on the cron floor
  exactly as before.
  The relay never reddens a PR to report its own trouble: it holds no
  `statuses` scope, so a failed dispatch cannot make the gate look converged
  — only leave it stale, which the cron floor already owns — while a red
  check would pin the PR at `UNSTABLE`, the very defect being fixed. It
  retries once after a wait floored at 60s and capped at 120s, plus up to 14s
  of jitter — nothing is clamped DOWN any more: a window beyond the cap is
  never slept and never retried, so the set of waits it can sleep is 5s or
  60-120s (a 5-second retry lands inside every secondary-rate-limit window; a
  plain transient still retries in 5s; a permanent answer — 400, 401, 404,
  405, 422, and 403 with no rate-limit evidence — is not retried at all, and
  neither is a named window beyond the cap, since both would pay for a retry
  that cannot succeed), then warns and exits 0. Rate-limit evidence is
  `retry-after`, an exhausted window, a secondary-limit body, or an HTTP 429,
  all classified at one site; the jitter exists because the relay is
  group-less, so without it N runs of one event burst compute the same wait
  from the same headers and re-POST in lockstep. `x-ratelimit-reset` counts
  as a wait instruction only when `x-ratelimit-remaining` is 0: it rides on
  every GitHub response, so reading it unconditionally silently disabled the
  entire retry. Its `env:` block is load-bearing in full — `GH_REPO` or
  `DISPATCH_REF` unbound makes it refuse to dispatch and name the binding,
  rather than expand to nothing inside a command substitution and report an
  API answer that never arrived — and with the `check_run` opt-in enabled it
  refuses events naming its own jobs, which the negative `if:` would
  otherwise relay back into itself. Every transient warning names its cause
  (target, HTTP status, gh exit, or a per-attempt timeout). It carries no
  escalation of its own: a
  sustained dispatch outage surfaces as gate staleness, which
  `pr-watch --heal` already reduces on across every open PR, rather than as
  N red PRs or a widened relay scope.
  **The relay never exits non-zero.** That is now the pinned invariant, not
  a property of one branch: it runs on PR-attached legs, so any red — or any
  hang long enough to be CANCELLED — is a failed check on the PR head and
  the original defect all over again. Every fault warns and exits 0
  (including an underivable `github.workflow_ref`, which is a *permanent*
  condition that would otherwise have pinned every open PR forever), and
  every wait is bounded: each dispatch attempt is wrapped in `timeout`, the
  backoff is floored and capped, and the job's `timeout-minutes` is asserted
  to outlast the worst case rather than merely stated to.
  The test harness now runs the extracted step under the shells the runner
  actually uses — `bash -e` (a `run:` block's default) and
  `bash -eo pipefail` (an explicit `shell: bash`) — and asserts exit 0 on
  every modeled path under both. Running it under plain `bash`, as it did
  before, modeled neither and hid two live reds: the underivable-ref path,
  and a no-match `grep` in the header helper that killed the step on the
  ordinary retry path under pipefail.
  A second, independent loop breaker lives inside the step: the
  workflow self-dispatches, nothing throttles a group-less relay, and the
  job `if:` is a line adoption docs invite consumers to hand-edit.
  **Residual, stated rather than papered over**: this removes
  *eviction-driven* cancelled checks, not every cancelled check — a relay
  hung to its `timeout-minutes` still leaves one. **Cost**: one
  billed-minimum, non-evictable run per PR-attached event, and one more
  runner allocation on the event-fast path.
  The workflow assertions now run against BOTH copies — the shipped template
  and this repo's self-adoption `.github/workflows/` copy, which is
  hand-maintained and previously had no guard at all. The relay's step script
  is extracted from each file and EXECUTED against a `gh` stub, and the two
  extracted steps are asserted byte-identical, so a template edit that is not
  mirrored fails loudly instead of silently proving a file CI never runs.
  **Consumer action required**: workflow YAML is repo-owned after adoption, so
  `vstack refresh` does not deliver this — each repo takes it as its own PR
  (migration steps, permissions delta, cost note, and the ruleset caveat:
  `skills/review-gate/references/adoption.md` § Updating an already-adopted
  copy).

- **second-opinion: a multi-lane review no longer loses its verdict when
  scratch space disappears mid-run** (VST-221 / #1229). The union merge used
  to re-wrap each lane's review into a `wrap-<lane>.json` file inside the
  run's `mktemp -d` directory and read those files back at the end. Anything
  clearing that directory while lanes ran — the reviewed repo's own agent CLI,
  a sandbox, a tmp reaper — made the parent report both healthy lanes as
  "unparseable" and exit 4 with no external verdict, even though valid lane
  artifacts sat intact beside the union path. Without `--output` the lane
  reviews lived in that directory too, so clearing it dropped a model's real
  findings while the union still published a pass.

  Lane scratch now has one owner and one rule: the run creates exactly one
  directory under `TMPDIR`, it holds nothing but the per-lane stderr captures,
  and each lane's review is held in memory from the moment it is reaped —
  never read back from that directory. Losing that directory costs the log
  replay (reported as such) and never a verdict. Where a lane's review sits
  until it is reaped depends on the mode: with `--output` it is the durable
  sibling `<output>.<target>.json`, without one a per-run file in the artifact
  home (VST-241 below) — neither is in temp space. A lane artifact and the
  sidecars beside it are written owner-only by the child that writes them,
  whatever the caller's umask; the union artifact at `--output` follows the
  caller's.

  Artifact handling got stricter in the same pass. An artifact is accepted
  only if it holds exactly one JSON object carrying the shape the union merge
  consumes: previously an artifact that held no JSON value at all merged as a
  phantom healthy lane (`jq` exits 0 printing nothing for it) and could
  publish a pass over a real blocker, while one carrying a malformed finding —
  `blockers: ["bad"]` — aborted the whole merge and delivered no union even
  when the other lane was fine. Both are now that lane answering unusably
  (exit 4, coverage degraded), and the healthy lanes still publish. Each lane
  artifact is read exactly once, so the reported cause is the one that
  actually rejected it. A lane that exits 0 with no usable artifact is
  recorded with the never-answered code 5 instead of a bare `exit 0`, and the
  "union of N lanes" line counts the lanes the written artifact carries.

- **orch: claude handoff lanes launch autonomous and verify brief delivery**
  (VST-191 / #1173). `open-terminal` now renders a permission argument into
  claude lane launch commands, sourced from the new
  `ORCH_LANE_CLAUDE_PERMISSION_ARG` `[env]` key and defaulting to
  `--dangerously-skip-permissions` — handoff is launch-only autonomy, and a
  session in prompting mode stalled on its first tool call with nobody
  attached. A prompting override still launches but warns loudly that handoff
  autonomy is void. On tmux lanes the launcher now verifies the CLI-arg brief
  actually reached the TUI (first-run dialogs were silently consuming it),
  re-sends it once into the composer if absent, and otherwise emits a
  per-lane failure and exits nonzero instead of reporting success — the
  claude-path sibling of the #976 codex kickoff fix.

- **agents: the skill-failure reporting blockquote is condensed to a
  three-line pointer** (VST-177). The full routing/attribution decision tree
  now lives in one canonical file, `docs/skill-failure-reporting.md`, which
  the CLI installs and refreshes at `.agents/skill-failure-reporting.md`
  (project scope) or `<platform config dir>/vstack/skill-failure-reporting.md`
  (global scope) whenever it generates agents. Source agent bodies carry a
  `{{VSTACK_FAILURE_REF}}` placeholder; generation substitutes the resolved
  path for the target scope, so generated files never embed a wrong-platform
  path. Regenerating agents shrinks every generated agent file by ~1.5 KB.

- **CLI: shared `all` key for `[agent-launch-instructions]`,
  `[agent-additional-instructions]`, and `[skill-instructions]`** (VST-178
  mechanism). The value under `all` (alias `"*"`) applies to every agent or
  skill; when an item also has its own entry, both render — shared first,
  then the item's own, separated by a blank line. In generated agent files
  the shared portion is wrapped in invisible HTML-comment markers
  (`<!-- vstack:shared-instructions:start/end -->`), so re-extraction drops
  it structurally even after the `all` value changes or is removed.
  **Breaking**: `all` is now a reserved item name — installing an agent,
  skill, or hook named `all` is rejected with an explanatory error.

- **second-opinion: `AGENTS.md` joined the default review-instruction globs**,
  and nested `AGENTS.md` files governing the changed paths are collected too
  (parents before children). **Migration note for existing installs**: skill
  seeding never overwrites an existing `SECOND_OPINION_REVIEW_INSTRUCTIONS`
  key, so a `vstack.settings.toml` that carries the previous default keeps the
  old list — update the pinned value to
  `"AGENTS.md review-bots.md .github/instructions/*.instructions.md .github/copilot-instructions.md"`
  (or delete the key to track the default) to pick up AGENTS.md coverage.

- **orch: local pre-PR review passes are budgeted per pushed head, not per
  submission** (VST-153, follow-up to the vstack#1141 `reviewed_head` artifact
  stamp). `submit-pr` § 1.2 checks the budget through the new
  `local-review-budget` helper: `pr_local_review.passes` now counts against
  `pr_local_review.reviewed_head` (recorded from the review artifact's
  `qa_metadata.reviewed_head` after each counted pass), and a head change
  resets the round — GitHub bots re-review every push, so a new head is a new
  round; the 2-pass cap binds only within a single head.

- **orch (breaking, removal): the legacy consumer script pair is gone.**
  `skills/orch/scripts/ci/{review-predicate.sh,approval-refire.sh}` and
  their tests existed only for pre-v2 hyprtrade, which completed its v2
  cutover; the canonical engine is the review-gate skill (predicate +
  single writer), vendored via `vstack refresh`. The orch DEVELOPMENT.md
  "CI Triggering Patterns" section (including its "Review-gate engine"
  bullet) is rewritten as v2 guidance and points there.

- **review-gate v2 (breaking, consumer CI): one writer, review-only gate.**
  The gate now answers exactly one question — has this exact head been
  reviewed? — and never polices CI; whether untested code can merge is
  branch protection's job (adoption precondition: a merge queue requiring
  the test aggregate, or no held-back jobs). One default-branch-defined
  workflow (`templates/review-gate-writer.yml`) replaces the four-workflow
  mesh; deleted with it: `approval-refire.sh`, the `approval-rerun.yml` /
  `approval-sweep.yml` templates, the post-approval rerun/proof machinery,
  and the `REVIEW_GATE_TRUST_PR_WORKFLOWS` / `REVIEW_GATE_MAX_RERUN_ATTEMPTS`
  keys. Consumers migrate per `references/adoption.md` ("Migrating a v1
  consumer"): writer workflow in, rerun/sweep and predicate-reading gate
  jobs out, docs moved to `REVIEW_GATE_OVERRIDE_CONTEXT` (legacy
  `REVIEW_GATE_OUTAGE_CONTEXT` still resolves). SECURITY: the predicate now
  reads the per-commit statuses LIST endpoint, so
  `REVIEW_GATE_STATUS_PUBLISHER_REJECT` actually rejects
  workflow-minted statuses (the combined endpoint nulled App creators and
  made the list inert); while the list is configured, a status with no
  creator login is not evidence. vstack's own CI adopts the fast/full
  split: heavy suites run only in the merge queue.

- **review-gate (breaking, consumer CI):** the `approval-sweep.yml` template
  now requests `issues: write` (previously `read`) for the sustained-failure
  escalation step's rolling incident issue. Consumers adopting the updated
  scaffold must grant the permission — or drop the escalation step to stay on
  `issues: read`.
