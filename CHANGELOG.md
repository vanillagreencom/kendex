# Changelog

## Unreleased

### Breaking

- size-ratchet: the default `SIZE_RATCHET_THRESHOLD` drops from 1000 to 400
  (implementation 400, tests 800). Migration, in this order: declare
  `SIZE_RATCHET_CLASSES` for the repo's test layouts FIRST, then run the check
  and turn each `new offender` line into a `path<TAB>lines` baseline row.
  Freezing before declaring baselines files the test class then makes stale.
  Pinning `SIZE_RATCHET_THRESHOLD = "1000"` keeps the old number.
- hooks: a selected hook whose `event:` is absent from the execution contract
  is now REFUSED at install rather than written (VST-283).

### Added

- growth-guards: `scripts/install-git-hooks` writes the `.git/hooks` shims and
  the `vstack-guards` helper, so the guard chain runs at commit time.
- growth-guards: `install-git-hooks --check` reports read-only whether the
  shims are armed, and `vstack check` folds the verdict in (#1482).
- growth-guards: the pre-commit chain runs `preflight --staged` when that skill
  is installed beside it (VST-310).
- preflight: new `hardcoded-temp-path` lane — an added directory-creating call
  taking a literal `/tmp/…` or `/var/tmp/…` fails, since it escapes TMPDIR
  redirection and leaks (#1481).
- preflight: three added-line lanes — `unwired-suite`, `mktemp-trap` and
  `docs-cited-paths`.
- reviewer: five probes for classes that were being caught downstream instead
  of in review.
- size-ratchet: `--staged` counts index blobs, so growth staged then reverted
  on disk cannot pass a pre-commit gate.
- size-ratchet: per-class thresholds via `SIZE_RATCHET_CLASSES` (glob to
  threshold, first match wins).
- cli: `vstack check` is a process contract — exit `0` clean, `1` drift, `2`
  the check itself failed, with `--quiet`, `--json` and `--offline` (VST-258).
- hooks: one execution contract (an event × harness matrix) decides what
  installing a hook means; every install path, label and published table
  derives from it.
  A second vacuous path went with it: the presence check accepted any
  assignment while the value reader read only the quoted form, so a key
  written unquoted in BOTH templates parsed to an empty default on both sides
  and two different values compared equal. Presence now requires the quoted
  form the reader actually parses. New `settings-example-sync-controls.test.sh`
  drives the suite against planted trees and asserts its verdict, counts and
  skip lines: in-sync passes with `56 passed, 0 failed, 0 skipped`, an absent
  root reports `22 passed, 0 failed, 17 skipped`, and a drifted default, a
  dropped key, two drifted unquoted defaults, a stripped SECURITY caveat and
  an absent skill template each fail. Against the previous suite the absent-root
  and unquoted-drift fixtures both exited 0.
- growth-guards: a `git grep --cached` scan now refuses an UNMERGED index
  instead of reporting it clean (#1510). `git grep --cached` skips unmerged
  index entries entirely — no error status, no `error:` line on stderr — so
  `gg_grep_guard` saw a complete scan and `conflict-markers` printed
  `OK — no conflict markers in tracked files`, exit 0, over a work tree whose
  files carried the marker trio. That is the exact state the check exists for,
  and the state a developer or agent is in when they run a validation command
  mid-resolution. Every `--cached` scan now asks `git ls-files --unmerged`
  over the paths it is about to read and, finding any, exits 2 naming them and
  the only remedy there is: finish or abort the merge. The guard is scoped to
  the lane's own pathspec, so an unmerged path a lane does not scan leaves
  that scan complete. `byte-ceiling`'s index modes refuse too, for a
  different mechanism with the same shape: an add/add conflict is classified
  `U`, `--diff-filter=A` drops that record, and the run reported
  `OK — 0 staged addition(s) checked` — a file of any size past the ceiling. Same failure class as #1492 — a measurement that could
  not be taken must never report as a clean measurement.

- growth-guards: policy reads fail closed on a probe git could not answer, and
  a configured policy path is matched literally (#1508). `gg_policy_content`
  discarded the exit status of both its probes, so exit 1 ("no such path") and
  exit 128 (unreadable index, corrupt object, not a repository) were
  indistinguishable and both fell through — judging a commit against the
  unstaged worktree copy of a policy file, or against no file at all, while
  saying nothing. It now mirrors the classification `gg_settings_source`
  already applies: exit 1 is the answer, anything else is `gg_collection_error`,
  and HEAD is probed with `git ls-tree` rather than `cat-file -e`, which cannot
  tell an absent path from a broken repository. Both probes now pass
  `:(literal)`, so a policy path spelling a glob matches itself instead of
  whatever the glob reaches — before, a configured `tools/ex?.tsv` resolved
  `git show ":tools/ex?.tsv"` as a REVISION and loaded a commit diff as the
  exclusion list. `suppression-ban`'s baseline read carried the same two
  defects and gets the same treatment; a ratchet that cannot read its own
  baseline must not fall through to a looser one. `gg_load_excludes` now
  propagates the failure too: it reads the policy through a command
  substitution, where a `gg_collection_error` dies in the subshell and
  arrives as a bare status, so an unreadable list was becoming an EMPTY list
  and the gate then returned a verdict — reporting as a violation the very
  file the unread policy excluded.

- growth-guards: policy writes land by same-directory rename (#1502). The
  settings cache was materialized by redirecting straight onto its final path,
  so an interrupt left a TRUNCATED cache that the next run read as the
  complete staged copy — and a key resolving to an empty value means the check
  it names runs nowhere while the chain still reports OK. `suppression-ban
  --update` replaced the baseline with a `mv` from `$TMPDIR`, which degrades to
  copy-then-unlink across filesystems, leaving a truncated RATCHET file that
  silently loosens the gate rather than failing it. Both now write to a temp
  file beside the destination and rename. The staging file is created by
  `mktemp`, never at a name derived from the pid: it lands in a directory the
  repository controls, `cp` writes THROUGH a symlink, and a planted
  `.gg-install.<pid>.<name>` link would therefore redirect the write to any
  path the user can reach. Either way the destination carries the complete new
  bytes or the complete old ones, never a prefix of either.
  `suppression-ban` goes through a shared `gg_install_file` helper; the
  settings cache renames inline, because it answers a failure by returning 1
  for its caller to propagate rather than by the family's exit 2, and routing
  it through the helper would change that contract.
- growth-guards: the test harness scrubs git configuration carried in the
  ENVIRONMENT, not just on disk. A private `HOME`, `XDG_CONFIG_HOME` and
  `GIT_CONFIG_NOSYSTEM` do not stop `GIT_CONFIG_PARAMETERS` or the
  `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` family: either
  still sets `core.hooksPath` or `commit.gpgsign` for every fixture, and git
  exports `GIT_CONFIG_PARAMETERS` into hooks whenever the caller used
  `git -c` — which is exactly how a suite run from inside a hook inherits
  them. Verified both shapes running a foreign `pre-commit` against a fixture
  repo before the scrub, and neither reaching it after, with the unscrubbed
  control alongside so the assertion cannot pass vacuously.
  `install-git-hooks.test.sh`, the one suite that had isolated itself, is
  migrated to the harness: it set `HOME`, `XDG_CONFIG_HOME` and
  `GIT_CONFIG_NOSYSTEM` and was still not hermetic — under an injected
  `GIT_CONFIG_COUNT` it exited 128 with a foreign `pre-commit` running twenty
  times. The adoption pin now requires an actual `.` of the harness rather
  than a grep for either token, which a comment satisfied.

- growth-guards: a green suite run is silent (#1503). `todo-ban.test.sh`
  redirected into `stagedx/tools/` before that directory existed and recovered
  through a fallback, so every passing run printed a `No such file or
  directory` line — the one message that would announce a genuine
  fixture-setup failure, taught to readers and log scanners as noise. The
  directory is created first, and the other suites were swept for the same
  class: all now emit nothing on stdout beyond their assertions and nothing at
  all on stderr, except `install-git-hooks.test.sh`, which passes real hook
  output through.

- growth-guards: `cleanup-scope.test.sh` asserts cleanup over a scratch root
  the suite owns instead of counting entries in the shared temp namespace
  (#1501). The old count compared `gg-todo-ban.*` entries in `$TMPDIR` before
  and after the run, so any concurrent process creating or removing one moved
  the number, and the `find` that took it exited nonzero when a sibling's
  directory vanished mid-traversal — under `set -euo pipefail` that aborted
  the run before it reached its own summary. Measured 18-up on a loaded
  machine: 0, 6 and 0 of 18 runs passed before; 18, 18 and 18 after. The
  harness now points `TMPDIR` inside each suite's own scratch root, which is
  where the check under test creates its directory, and the count is a glob
  over that root paired with a decoy control proving it can see one.

- growth-guards: every test suite now runs against a neutralized git
  configuration, from one shared `tests/lib/harness.bash` rather than four
  lines repeated per file (#1500). Nine of the ten suites ran `git init` and
  `git commit` against fixture repos while inheriting the caller's global and
  system configuration, so a machine carrying `core.hooksPath` executed the
  developer's own hooks against generated fixtures, `init.templateDir` seeded
  them, and `commit.gpgsign` failed the commits outright — measured against a
  hostile global config, `byte-ceiling`, `suppression-ban` and `commit-msg`
  went red while nothing in the diff had changed. The harness points `HOME`,
  `XDG_CONFIG_HOME`, `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` at the
  suite's own scratch dir, exports `GIT_CONFIG_NOSYSTEM`, and clears
  `GIT_TEMPLATE_DIR`, the `GIT_AUTHOR_*`/`GIT_COMMITTER_*` family and the
  repo-location variables (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` and
  siblings) that git exports into every hook — so a suite run from inside a
  commit hook operates on its fixture, not on the committing repository.
  Adoption is pinned by `tests/harness-adoption.test.sh`, which fails when a
  suite neither sources the harness nor isolates itself: the tenth suite
  cannot forget. The harness is `.bash`, not `.sh`, because runners and the
  exec-bit lint glob `tests/*.sh` and git's pathspec matches nested paths.
- growth-guards: `install-git-hooks --check` recognizes a hand-wired
  `core.hooksPath` directory by a CLOSED grammar, and answers `2` for anything
  outside it. An earlier pass read the hook line by line and armed on the
  entry point wherever it stood in command position; that still reported
  `armed`, exit 0, for `if false; then exec …/pre-commit; fi`, for the same
  line inside a function nothing calls, and for a `<<-` heredoc whose
  terminator is indented — three clones whose commits git does not gate at
  all, each confirmed by a `git commit` that went straight through. Deciding
  which lines a shell reaches needs a shell parser, and the failure direction
  of guessing is OPEN, which is the one direction this answer must never
  fail in. `--check` now accepts a hook that is a shebang, comments, and
  exactly one command that is this skill's entry point (through `exec` or
  not, quoted or not), plus the delegating line the installer itself writes
  beside its helper. Anything else is `2`, `could not determine`, naming the
  recognized shape — not `1`, because a hook that runs `set -e` before the
  entry point does gate and calling it ungated is the same lie reversed. The
  accepted TAIL is checked too, not just the command word: `exec
  …/pre-commit --help` and `…/pre-commit "$@" || true` both name the entry
  point in command position and both let every violation through. The
  accepted forms are per hook — `pre-commit` takes no arguments, `commit-msg`
  needs git's message-file path — because swapping them breaks the gate
  rather than loosening it: `pre-commit "$1"` exits 2 on the argument it
  refuses and a bare `commit-msg` reads inherited stdin and calls every
  message empty, so both reject valid commits while validating nothing.
  `armed` additionally requires that the entry point resolve to a real
  executable — a path shaped like one but pointing at a moved install leaves
  git answering every commit with command-not-found — and that the hook's
  shebang carry no interpreter option, since `#!/bin/sh -n` syntax-checks the
  body, exits 0, and runs no guard while every violating commit passes. Where the command is the
  entry point and only its argument list is unrecognized, the answer is `2`
  rather than `1`: `exec …/pre-commit "$@" # run the guard` does gate, and
  calling it ungated would be the same false answer this fix exists to
  remove. `1` is reserved for a single command that is not the entry point,
  or an entry-point path with nothing executable at it. The accepted-tail
  comparison escapes its own pattern metacharacters, since an unescaped `?`
  matched `|| exit $#` as though it were `|| exit $?` — and git gives
  pre-commit no arguments, so that is `exit 0` and swallowed every
  pre-commit failure while `--check` reported armed. An entry-point path
  whose final component is a SYMLINK is unverifiable for the same reason the
  suffix alone never was enough — two links to `/bin/true` passed every file
  test and reported `armed` while every commit bypassed the guard. The
  candidate is now compared by PHYSICAL LOCATION against this install's own
  entry point rather than by the shape of its path — a path is a name, and a
  regular executable copy of `/bin/true` can wear it — while a symlinked
  parent directory still resolves to the real install and stays armed. A tail must
  be separated from the command by a real blank, since the shell concatenates
  `"…/commit-msg""$1"` into one unrunnable word; and only blanks are trimmed,
  because `[[:space:]]` would eat a trailing CR that the shell keeps as part
  of the word. The shebang grammar uses blanks for the same reason: a
  `#!/bin/sh` line ending in CR makes the kernel look for an interpreter
  named `/bin/sh\r`, so git cannot run the hook at all and a clean commit
  dies with `cannot exec`. The interpreter itself is checked by full path
  against a short trusted list, since `#!/tmp/fake/sh` can be a copy of
  `/bin/true` — git runs it, ignores the hook body, and gates nothing — and
  an `env` shebang resolves through PATH, which is no more knowable. A listed path must also EXIST and be executable:
  `/bin/dash` and `/bin/ksh` are absent from plenty of hosts, and git answers
  `cannot exec` for every commit there rather than running the hook. A shim in
  `.git/hooks` carrying the guard line somewhere other than line 2 is `2`
  rather than `1`: it still gates, and calling a gated repository ungated is
  the same false answer pointing the other way. The
  delegating shape's helper is verified the same way: outside the
  installer-owned hooks directory it is a copy someone made, and the marker
  it was recognized by is a comment anyone can type — an executable
  `# vstack growth-guards git hooks` plus `exit 0` carried it while bypassing
  every guard. The bytes are now compared against the helper this installer
  generates, through one `helper_body` that the writer and the verifier
  share, so the two cannot drift apart. That comparison applies in
  `.git/hooks` too, not only in a redirected directory: `--check` is
  READ-ONLY, so "the installer rewrites this file" says nothing about the
  copy sitting there now, and a marker-carrying stub in the ordinary install
  reported `armed` while every violation went through. The interpreter is
  judged in `.git/hooks` for the same reason: a shim rewritten to
  `#!/bin/sh -n` reads the guard line and executes nothing, and that is the
  ordinary install, not a hand-wired one. The
  suite asserts the property directly rather than the wording: exit 0 is
  claimed only where a real violating commit is really blocked AND a clean
  one still passes, which is the half that separates a working gate from a
  hook that refuses everything.

- growth-guards: `install-git-hooks --check` now probes the directory
  `core.hooksPath` redirects git to, instead of judging a redirected clone
  solely by `.git/hooks` (#1509). The installer stands down under
  `core.hooksPath` and prints hand-wiring instructions, but `--check` never
  read the directory those instructions name: a clone wired exactly as told
  was reported `dormant … commits are NOT gated` and exited 1, and a
  consumer with `--check` first in its canonical verify command was
  permanently red for the configuration the tool itself prescribed. The
  redirect target is resolved through git, so an absolute, `~`-prefixed or
  work-tree-relative value all land where git lands, including when
  `--check` runs from a subdirectory. Hooks there that run this skill's
  `pre-commit` and `commit-msg` — by naming the entry point, or by carrying
  the delegating line beside a helper in that same directory — are `armed`
  and exit 0, and the verdict names the directory the gating comes from.
  Everything short of that stays exit 1 with the hand-wiring remedy, which
  is then accurate: a target that is missing, empty, wired to another tool,
  wired for only one of the two hooks, or left without the executable bit.
  A target that cannot be read is exit 2, not a verdict — the remedy would
  otherwise tell the user to wire a directory that may already be wired and
  merely unreadable. Only executable lines count as wiring: a comment, a
  heredoc body, an argument to another command, and anything past an
  unconditional `exit` name the entry point without ever running it, and a
  check that read a mention as wiring would report gating that no commit
  gets. The unredirected case is untouched.

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

  The remedy is offered only where it is true. A wiped entry beneath a source
  recorded at `<entry>/<subdir>` is NOT offered the repository identity: an
  identity names the repository, not a directory inside it, and installing the
  root over the recorded subtree either fails outright or — where the root
  carries a same-named item — exits 0, rewrites `source` to the repository and
  reports green with the item propagating from a subtree nobody chose. A
  refusal that a re-add provably clears now names it: an entry redirecting
  elsewhere still yields a remote, and `vstack add <that path>` installs from
  the remote's own entry instead, where the report used to say nothing and
  leave a permanent exit 1. And a clone that cannot be READ is reported as
  that — `Path::exists` answers false for a permission error exactly as for a
  missing file, so an unreadable entry was refused as "not one of its clones"
  with advice to delete it. That probe is now the only one: the sibling
  answering the same question for URL-recorded sources still collapsed the two,
  so one directory with one permission bit read as unreadable or as absent
  depending only on how the lock spelled it — and the absent spelling
  prescribed a `vstack add` that failed by telling the user to delete a valid
  clone, pointing a local permission problem at their credentials.

  `add` resolves a remembered relative source against the PROJECT ROOT, which
  is where every reader resolves one. Bound to the process CWD, running from a
  subdirectory that held a same-named source installed one tree and hashed
  another with every surface green. The rule the recorded string follows is
  stated where it lives now: it must name the tree that was read, resolved the
  way later readers will resolve it — recording the spelling is what that
  requires for a local source, not the rule itself.

  `check`, `verify` and `refresh` name the same command for the same state.
  Only `check` used to name one; the cause and the remedy are separate pieces
  now, composed by each surface, so `check` also stopped printing the same
  `vstack add` twice in one line. No command is offered where none can be both
  correct and safe: a source whose display has to redact part of itself is
  never handed back as a pasteable argument, and a lock that recorded no
  source at all is not offered `vstack add ''`. That filter lives in
  `restore_source_argument`, so it holds for the report `check` builds as well
  as the lines `verify` and `refresh` print — `check` composed its own argument
  and leaked a token the other two withheld. The redactor behind it stopped
  asking whether a PARSER can use a spelling, which is not the same question as
  whether one carries a secret: `https:/TOKEN@host/repo` parses as neither URL
  nor scp-like, so it fell to bare escaping and reached a report header and a
  paste-ready command in full while the same string rendered redacted two
  clauses away. A local path keeps its `?` and `#`, which are ordinary
  characters there and were being redacted into a directory that does not
  exist — the bare relative spelling included, which the gate asks the
  resolver's own predicates about so the two cannot drift. Every surface that
  prints a `vstack add` now takes its argument from the one place that decides
  whether a string may be one: the offer to install an available item was
  composing its own, so a healthy source directory named `cat?x` was offered as
  `vstack add 'cat?<redacted>'` — a paste-ready command naming a directory that
  does not exist.

  The command every surface prints carries the scope it repairs. Pasted from a
  global entry's `verify` or `refresh` output, a remedy without `-g` installs
  into the PROJECT scope, exits 0, and leaves the entry exactly as broken.

  Two diagnoses stopped pointing at the wrong thing. A cache entry a clone
  cannot be written into is refused as what it is — a directory in the way with
  no `.git` — rather than under `add`'s private-repo access hint, which sent
  users to check `gh auth login` about a folder on their own disk. And a
  remembered source no reader can resolve (`a/b/c`, which only `./…`, `../…`,
  `.` and bare names are recorded resolvably as) is named instead of walked
  past: silently reaching the next source installed from one the project never
  chose and failed with an error naming it.

- preflight: installed-artifact subtrees are now out of scope for every lane
  that judges how a file is AUTHORED, not just `docs-cited-paths`. The
  `vendored_mirror` classification already knew those paths are upstream
  bytes a `vstack refresh` rewrites wholesale, but only the citation lane
  read it, so `mktemp-trap`, `fail-open`, `unwired-suite` and
  `masked-returns` still judged them — and a consumer repo that TRACKS a
  vendored skill had no way out: preflight reads no settings file, has no
  exclusion list, no lane selector and no inline suppression, and editing
  the vendored file is reverted by the next refresh. The live case was
  `growth-guards/scripts/install-git-hooks`, whose four `mktemp` sites clean
  up per branch with `rm -f` instead of `trap … EXIT`: a required check red
  on an upstream authoring choice the consumer cannot change. Lanes that
  judge what those bytes DO to the repo carrying them are unchanged and
  still fire inside a mirror — `shell-syntax`, `shellcheck-errors`,
  `data-syntax`, `workflow-run-syntax`, `hardcoded-temp-path`, `todo-links`,
  `reviewer-attribution` — because a mirror is no reason a broken parse, a
  malformed config, a leaked temp directory or an unreferenced work marker
  becomes invisible. Both directions are pinned in `precision.test.sh`, per
  guard. (#1498)

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
  acceptance boxes (VST-318).
- pi-agents-tmux: the Agents popup Transcript tab is an event timeline rather
  than raw JSONL; `e` opens the raw file in `$VISUAL`/`$EDITOR` (VST-327).

### Changed

- settings templates: every key's comment condensed to one-line intent plus
  landmines, 922 → 545 lines, zero value changes (VST-317).
- Skill `description:` frontmatter is one or two sentences again across the
  catalog; the longest fell from 810 to 214 characters.
- The `--` rule now names which paths it governs: values from configuration,
  argv or the environment, never a path the script built itself.
- orch: PR-comment triage batches fix rounds per fully-reviewed head, since a
  push restarts every reviewer.
- review-gate: the `/dev/null` force-defaults handle is answered in
  `rg_setting` ahead of every source rather than by an exemption in the
  source-shape check. Behavior unchanged.
- pi-agents-tmux: Monitor task rows show elapsed/total run-time instead of a
  local clock, and timestamps render local human time (VST-316).

### Fixed

- cli: a lock `source` inside `~/.vstack/cache/` resolves as the remote that
  entry clones, not as a local checkout. Every freshness mechanism had been
  skipped at once while each command still reported success (#1495).
- cli: shared configs are read with the parser their own harness uses, never
  the one the file extension suggests.
- cli: structured files are parsed rather than text-matched, so answers no
  longer depend on how a value was spelled.
- cli: commands vstack prints for you to paste are POSIX-quoted, so a source or
  package spelled with shell syntax is passed literally rather than executed.
- growth-guards: a `git grep --cached` scan refuses an unmerged index instead
  of reporting it clean — `conflict-markers` had printed OK mid-conflict, and
  `byte-ceiling` reported zero staged additions (#1510, #1492).
- growth-guards: policy reads fail closed when a git probe cannot answer, and a
  configured policy path is matched literally (#1508).
- growth-guards: policy writes land by same-directory rename, so an interrupt
  cannot leave a truncated settings cache or ratchet baseline (#1502).
- growth-guards: settings resolved from the index no longer read a failing
  `git` as "untracked", which had silently reverted committed policy to the
  built-in default.
- growth-guards: the pre-commit shim reads `size-ratchet --staged`'s outcome, so
  a consuming repo's own replacement skips with a note instead of blocking
  every commit (VST-362).
- growth-guards: every test suite runs against neutralized git configuration
  from one shared `tests/lib/harness.bash`, including config carried in the
  environment (#1500).
- growth-guards: `cleanup-scope.test.sh` asserts over a scratch root the suite
  owns instead of the shared temp namespace, which flaked under concurrency
  (#1501).
- growth-guards: a green suite run prints nothing (#1503).
- preflight: installed-artifact subtrees are out of scope for every lane that
  judges how a file is authored, not just `docs-cited-paths` — the finding
  named an upstream choice the consuming repo cannot fix (#1498, VST-312).
- review-gate: `settings-example-sync.test.sh` can no longer report success for
  comparisons it never made (#1507).
- review-gate: the teardown suite no longer fails when a runner launches it in
  the background; the cause was signal disposition, not process groups (#1506).
- size-ratchet: three fail-closed fixes — `--seed` stays bootstrap-only against
  the committed baseline, and two collector paths that could read as clean.
- size-ratchet: seven fixes absorbed from the forked copy drovr had been
  running, including `--update` converging in one run (DRO-201).
- size-ratchet: `--seed` writes the first baseline from the gate's own
  collector and refuses a live one (VST-328).
- hooks: registered commands resolve from any working directory in a project
  that is not a git repository.
- hooks: a Codex registration is recognised by the script it runs, not the
  literal command string, so a moved project no longer accumulates a second
  handler.
- hooks: one predicate per harness decides which registered command is
  vstack's, and install, removal and presence reports all ask it.
- hooks: `vstack add` checks every selected hook's event against the contract
  before its first write (VST-283).
- hooks: `block-unsafe-rm` declares `harnesses:` without `pi`, which has no
  port of it (VST-283).
- worktree: `create` installs npm dependencies only where npm is the package
  manager, so a pnpm workspace no longer starts dirty (VST-340).
- linear: a truncated `cache issues list` announces itself on stderr with both
  counts instead of returning a bare array that reads as complete (VST-320).
- merge-queue ejection alert: the intake issue is reason-aware — deliberate
  dequeues and conflict re-evaluations get a PR comment only.
- pi-agents-tmux: the idle-stall watchdog skips panes with a pending rate-limit
  retry instead of condemning a throttled agent as stalled (VST-361).

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
