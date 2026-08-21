# Changelog

Notable changes, per [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries are written when a change lands, not batched at release. Breaking
changes carry a **Breaking** call-out with their migration note inline.

## [Unreleased]

### Added

- The app has its own icon. Every channel that installs the app shipped the
  old vstack chevron; the icon is now the `x` from the kendex wordmark, in
  the wordmark's green, at every size the desktop, dock, and installer use
  on Linux, macOS, and Windows. The CLI-only channels are unaffected — they
  install no app and so carried no icon either way.
- Releases now ship for Intel Macs and arm64 Linux (Raspberry Pi, Graviton)
  alongside Apple silicon, x86_64 Linux, and Windows. The installer script,
  `kendex update`, Homebrew, and the AUR packages all pick the build for
  your machine.
- A zoom control for the app. Settings has minus and plus buttons that step
  from 50% to 200%, and `Ctrl` `+`, `Ctrl` `-`, and `Ctrl` `0` — `Cmd` on a
  Mac — change it from anywhere in the app the way they change a page in a
  browser. The size you pick is remembered and applied before the window
  opens. It is also the fix for a display set to a fractional scale, which
  GTK rounds to a whole number. If the window cannot take your size, it
  opens at 100% and says so, and the size you chose is kept for next time.
- Marketplaces › Community: a listed marketplace opens in the app before
  you subscribe — its packages and bundles, each package's README, files
  and safety findings, and the About report — on the same pages a
  subscription gets. Subscribe from any of them and the page carries on as
  the subscription, Install and all. A Skills.sh hit opens its repository
  the same way. An unreachable repository says so on the page, with a way
  to try again.
- New ways to install. A one-line installer,
  `curl -fsSL https://kendex.ai/install.sh | sh`, that installs the app and
  the CLI on Linux and the CLI on macOS;
  `brew install vanillagreencom/kendex/kendex` and `yay -S kendex-bin`,
  which install the app and the CLI together; and CLI-only channels
  `brew install vanillagreencom/kendex/kendex-cli`, `yay -S kendex`, and
  `kendex-git`.
- The default catalog now offers curated bundles and tagged packages, so you
  can install a working set in one step: orchestration, code-review,
  research, and commit-guards.
- Catalog authors can settle a reviewed safety finding: `kendex dismiss
  --catalog <dir> --reason intended '<token>'` records the decision in a
  committed `kendex-reviews.toml`, and `kendex check --catalog` stops
  holding the catalog back for that exact finding on that exact content. The
  decision reaches whoever installs the item too: the finding stops counting
  for them, is still shown, and is labelled with the publisher's name and
  reason so it is clear whose judgement it is — and where the publisher
  decided differently for two tools, each decision is listed with its own
  reason and date rather than the first one standing in for both. It settles
  only what the publisher wrote — their occurrences rather than yours, each
  at the weight the installed copy gives it — so nothing a project adds to
  the item rides in on a reviewed finding however serious it reads, and no
  line your project injected is ever shown under a publisher's name. Adding
  instructions to a skill cannot cost the publisher their review either,
  even when the added bytes are what pushes the file past a tool's size
  limit and moves their line into `references/`. Neither can a project take
  the credit by writing the publisher's own sentence itself — not word for
  word, not with characters that only read the same, and not by spelling
  kendex's own end-of-block marker inside its instructions to make the rest
  look like the publisher's. Where a repeat cannot be told from the
  publisher's own line in an agent's instructions, neither copy is shown as
  reviewed and the report says the review settled nothing: an open finding
  is a question you can answer, where your own text under someone else's
  name is not. A review is only ever read out of the catalog that published
  it. Your install record keeps no copy: kendex rebuilds what each
  installation should be, from the catalog at the revision that installation
  came from — one package can sit at two revisions when a refresh goes
  through for one tool and not another — and reads the review there. A
  package you have not fetched, and content that is not what its catalog
  publishes, settle nothing. It can only carry reasons an author can give: a
  hand-written `trusted-source` record is refused on the installing machine.
  Any edit to the item, in the catalog or on the installed copy, brings the
  hold back, as does an edit to anything else the catalog renders it from —
  an agent's frontmatter overrides, or the set of skills it goes out with. A
  record that settles nothing where it lands — stale, refused, or naming a
  finding that is not there — says so rather than passing in silence. A hook
  cannot carry one: it is scored from its script before it installs and from
  the harness's settings file afterwards, two readings of different bytes,
  so `dismiss --catalog` refuses a hook token and says why — a hook author
  answers a false positive by narrowing the script or by getting the rule
  fixed, and there is no record they can write instead. `check --catalog`
  prints the token beside each finding it can be used on. A review in a
  publisher's name is worth more than your own dismissal — yours settles a
  question, theirs can lift a hold — so none of it is taken from a file your
  project commits: an installation whose content is not what its catalog
  publishes is told so plainly, and settles nothing.
### Changed

- The Updates page is a table with one row per package. A package out of
  date in several projects shows how many places, expands into a row per
  place — User level and each project by name — and each place has its
  own versions, Follow source switch, Preview, and Update, plus an
  "Update all" for that package. A place whose files you edited says
  "Customized here" and offers Keep as my own or Use new version, since
  an edit in one project says nothing about the copy in another. The
  subtitle counts packages and places, and the sidebar badge counts
  packages.
- The "Update automatically" switch is now "Follow source": nothing in the
  app applies updates on its own. A following package comes current when
  its project refreshes or you press Update; a held one waits until you
  choose. The package page's version menu and toasts say the same.
- `kendex updates` names the place — global or the project path — at the
  start of every line.
- The `dangerous-commands` check no longer reads a shell `case` arm's
  pattern list as a command: naming `sudo` among the words a parser should
  skip is not running it. Skills and hooks that parse command lines stop
  being flagged for the tokens they match on. Only the pattern is exempt —
  an arm that runs something on the same line still has that half read. This
  narrows what the check catches: a whole line written as a bare list of
  single words ending in `)` is no longer read as a command, which is the
  price of the class of false positive it removes.
- A safety finding's message now says what it fired on: which address a
  line actually runs — the command feeding the shell, however it is
  capitalized, and named by its own arguments when the address is not
  written out — which credential file a command sends away and by which
  command, which characters a file hides, and which unreadable content a
  file carries. Where a message stands in for something it cannot print, it
  does so at the same width the finding's own identity uses, so nothing can
  be ground into looking like a finding somebody already settled. Two different problems reading the same used to be
  one decision, and only one of them was ever shown.
- Safety findings are identified by the rule and the sentence it fired with,
  so a decision survives everything kendex does to an item on the way in —
  the line moving, the body being split into `references/` past a harness's
  size cap, a command being rendered as a skill. Recorded acceptances and
  dismissals made before this release no longer match and read as needing
  review again — the rule set version carries the change, so they are
  reported as "the safety rules changed since it was reviewed" rather than
  as a different set of problems. Re-accept or re-dismiss from the tokens
  `kendex findings` prints now.
- A project card on Projects opens that project's library. Clicking the
  card — Personal included — shows everything installed there, unfiltered.
  Seeing a whole project used to mean picking a kind you did not want and
  then clearing the filter. A screen reader names the folder each card
  opens, so two projects whose folders share a name — `/work/client` and
  `/personal/client` — are told apart by ear as well as on screen.
- Following a link into My Library starts from a clean filter strip. The
  whole strip — every picker, the search box and where the table is looking —
  is set to exactly what the link asked for, and nothing an earlier visit
  left narrowed carries over, so a count badge, Home's "Installed" tile and a
  recently-changed row each land on the list they name rather than on that
  list narrowed again by whatever was on screen last time.
- Scrolling surfaces are the app's own colour rather than the desktop's: a
  long list used to end in a stripe of system chrome, and the thumb is now
  drawn from the app's foreground with the track taken away, in light and
  dark. Nothing gives up any width for it, so nothing moves that did not
  move before. A system that does not let the app recolour its scrollbar
  keeps exactly the bar it draws today, and will pick the app's colour up on
  its own once it supports the setting.
- The app uses the Geist typeface, with titles and navigation in Geist Mono
  to match the website.
- **Breaking**: the default Homebrew install is now the app —
  `brew install vanillagreencom/kendex/kendex` installs the desktop app and
  the CLI together on macOS, and the CLI-only formula was renamed. Anyone
  on the old `kendex` formula migrates with `brew uninstall kendex &&
  brew install vanillagreencom/kendex/kendex-cli`.
- The project-management skill's roadmap pipeline is spec-driven and asks
  once: `roadmap plan feature @plan.md` accepts a finished, reviewed plan as
  the spec (issues derive from it and cite it), the plan-gate approval
  carries through to issue creation instead of being asked twice, and
  research runs inline by default — a tracker research issue exists only for
  research deferred as standalone work.

### Fixed

- A debug build no longer touches your real setup. A debug build is what
  `cargo build` and `tauri dev` produce — what a contributor or an agent
  runs from a branch — and it now keeps its own home under the platform data
  directory, so it cannot leave lock records, harness files, or caches that
  the kendex you installed will not read. That was the case that showed up
  as `lock.json was written by a newer kendex`. Your global skills and
  agents are not visible to such a build, and nothing it writes reaches
  them. Three things stay outside that boundary: a repository you point it
  at is the real one, so project-scoped work reads and writes it as usual; a
  harness folder set to an explicit absolute path is used as written; and
  programs kendex runs for you, `npm` among them, still see your real home.
  To point a debug build at your real setup deliberately, run it with
  `KENDEX_REAL_HOME=1` — only that exact value opts out. Release builds are
  unaffected, whether you installed one or built it with `--release`.

- "How a marketplace repo works" can be read from the keyboard. The document
  is longer than the box it opens in and had no tab stop of its own, so the
  only way in from the keyboard was a link near its end; `Tab` now reaches
  the document itself and the keyboard scrolls it.
- The project-management skill's issue pipeline creates Linear issues
  directly in Backlog instead of the team's Triage default. Pipeline output
  is already fully triaged — project, labels, priority, relations — and a
  Triage landing let triage automation re-route it into other projects.
- The Linux app draws at the right size on a HiDPI Wayland display. The
  AppImage always ran through XWayland, which reports a scale of 1 while the
  compositor drives the display at 2, so every element came out at half its
  size. The app now opens as a native Wayland client, falling back to X11 if
  the Wayland display cannot be opened. `GDK_SCALE` and `GDK_DPI_SCALE` are
  never touched, and a `GDK_BACKEND` you set is still yours — except inside
  the AppImage, where the bundle overwrites it before kendex starts, so
  `KENDEX_GDK_BACKEND` is how you choose a backend there. Set it to `x11` if
  your machine turns out to need what the bundle was pinning.
- Saving two things at the same moment can no longer leave a file
  half-written. Settings, manifests, locks, and snapshots each get their own
  temporary file, so two saves of one file cannot overwrite each other's
  bytes partway through.
- The app-menu entry now carries the app's window class, and every icon size
  kendex ships is installed, so launchers and docks match the running window
  to kendex and draw a sharp icon at any size. Both channels that write the
  entry are fixed: `curl … | sh` and `yay -S kendex-bin`.
- An agent now renders the skills it actually has. A skill you listed that
  the catalog does not carry was written into the agent's file anyway, and
  for a reviewer agent — whose list is kept under its base agent's name —
  a skill you removed came back on every apply.
- A note about a catalog it could not read no longer carries that catalog's
  own bytes to the terminal. A refused path, an unreadable source and a
  reviews file that will not parse all quote content a downloaded
  repository chose, and the escapes in it are now shown rather than acted
  on — the same guard names already had.
- A marketplace package's preview scores what installing it would write,
  not what the catalog holds: the same read budget as an install, and the
  body cap of whichever tool this package installs to reads it hardest. A
  long package could read held back on the page while its install went
  through with a warning, or warn while the install was held back, because
  a line past a tool's cap moves into `references/` where it weighs less and
  not every tool has a cap. `kendex check --catalog` reads under that budget too, so neither
  reports findings, or mints tokens for them, in content past the point any
  install stops reading; an item bigger than that says so instead, and the
  standing "reviewed findings do not appear in what this installs" warnings
  it caused are gone.
- Installing a security-adjacent package from a marketplace no longer held
  it back over findings the publisher had already reviewed. A skill that
  must name the flags it guards against — `growth-guards` and
  `--no-verify`, say — installed with seven findings and a warning on every
  session, in a fresh install of kendex's own default catalog. The
  publisher's recorded review now travels with the package, and the default
  catalog ships nothing its own check has not settled.
- Pi no longer halts every interactive start in a kendex-managed project.
  Pi has reserved the `hooks/` directory name beside its own roots: it
  warns whenever one exists, whatever is in it, and then waits for a
  keypress before the session opens — and the migration it suggests is one
  kendex's Pi hooks cannot take, since they are shell scripts a carrier
  extension runs, not Pi extensions. They now live under
  `.pi/kendex/hooks/` and `~/.pi/agent/kendex/hooks/`, and the next `kendex
  refresh` moves an existing install out of the reserved directory and
  takes the directory away with it — including for a hook you removed or
  switched off, which leaves nothing behind to keep firing. Nothing moves
  that kendex cannot account for: a file it did not write, one you edited
  after it was installed, anything that is not a plain file where the
  script was — a directory of your own, say — a hook registration you
  added, moved or duplicated by hand — moving one to another event holds
  the hook at both ends, so the entry you moved is never taken out and no
  second one is registered beside it — and a hook whose source is
  unreachable this run all stay exactly where they are, and that last one completes the move as soon
  as the source is back. A copy kendex cannot prove it wrote keeps its
  whole installation, not just the file — the old copy stays the one that
  runs, and nothing replaces it until you discard the edits — and
  discarding them, or removing the hook by name, finishes the move in that
  run, leaving one registration and nothing more to say. Each hold says
  which one it is, wherever it is reported, so a conflict offers to
  discard edits only where discarding edits is what settles it. And a finished
  move stays finished: kendex writes it down rather than working it out
  again, so nothing under the old name is kendex's afterwards — a script
  and a registration you put back there yourself both stay, however
  exactly they match what kendex used to write, and whatever else you
  change about the hook later. A hook held that
  way still shows up in `kendex list`, in the app, and in the safety scan,
  read from the old registry it fires from, so the copy that needs your
  attention is not the one you cannot see. A registration
  kendex cannot take out holds the script it names, so a hook is never left
  half-retired. Hooks that came in with a bundle move like any other. And a
  cleanup nobody asked for by name now leaves a hook's files alone when
  they are not the ones kendex wrote — the rule skills, agents and commands
  already followed. `refresh` now prints those reasons, which it previously
  worked out and dropped.
- On Linux, a helper command that ran past its time limit could take
  unrelated processes down with it: Ubuntu's `kill` misreads the negative
  process-group argument kendex passed, and for some process ids that
  meant signalling everything the user runs. The cleanup now spells the
  argument unambiguously, and the timed-out command's own processes are
  the only ones ended.
- Accepting a held-back update now actually installs it. `kendex findings`
  printed the accept flag for the copy already on disk rather than for the
  update being held back, so typing the instruction back did nothing; the
  flag it prints is now the one `--allow-unsafe` takes. An item the safety
  check refuses also keeps its install record when its files stay, so the
  next run still knows kendex wrote them instead of reporting the item as
  unmanaged forever.
- `kendex findings` reports the copy that is installed beside the update
  being held back, when the two differ, each saying which it is. An update
  stuck behind the safety check does not make what a tool is loading right
  now any safer, and only the installed copy's findings can be dismissed.
- `--allow-unsafe` naming something no longer there stops the run and says
  so, with the flag that accepts what the item says now. It used to be
  ignored in silence, leaving "nothing to do" as the only answer to a typed
  acceptance.
- `kendex apply` and `kendex refresh` now print what they cannot change and
  why. A blocked install left them reporting "nothing to do" with the reason
  never shown.
- `kendex adopt` now binds an adopted skill or agent to the tools that were
  actually reading it. It used to inherit the scope's full install defaults,
  which could install the item for tools you never gave it to.
- The review-gate package's test suite runs in projects that install it: it
  used to abort with "fixture source missing" outside the kendex source
  tree. The preflight package no longer flags a cross-repo citation like
  `kendex:docs/x.md` on code lines as a missing local file.
- `kendex import` finds a v1 install's global state on macOS. It probed a
  Linux-shaped path there, so Macs with a real v1 setup were reported as
  already migrated with nothing imported.
- Two more macOS path fixes: a repository reached through a symlinked
  location (anything under `/tmp`, or a linked project folder) can be read
  as a catalog again, and `kendex guard repair` no longer refuses a
  repository whose hooks receipt spells the same directory through a
  symlinked path.

## [5.0.1] — 2026-08-20

### Fixed

- Hardening from the release review: a collection link can no longer
  point kendex at a local directory (a member repository must be a
  GitHub `owner/repo`); a reused subscription installs the exact commit
  the collection pinned rather than the current branch head; a
  momentary network problem while refreshing your kendex.ai sign-in no
  longer signs you out; and the submit preflight's "everything is
  pushed" check now measures against the repository you're actually
  submitting.

## [5.0.0] — 2026-08-20

The first kendex release — the successor to vstack v4. The version
continues this repository's own lineage (vstack ended at 4.9), so
nothing ever collides with a v1-era tag. Everything
below is relative to vstack 4.x: the product, the binary and every file
kendex writes are renamed, a desktop app joins the CLI, and the
kendex.ai community (directory, publishing, sign-in, collections) ships
alongside. Existing vstack projects migrate with `kendex import` +
`kendex refresh`; the breaking changes are called out inline below.

### Removed

- **Breaking** — the v1 `project-skills-dir` setting is gone. kendex no
  longer maintains a separate "source" skills folder that gets linked
  into each harness's own folder; skills live where they are, and your
  repository's `.gitignore` decides what gets committed. Importing a v1
  project drops the key with a note; a manifest still carrying it gets a
  "remove it" finding from `kendex check`.

### Fixed

- Installed scripts run again: a skill's helper script used to land
  without its executable bit, so the skill's own hooks failed the first
  time they called it. Any installed file that opens with `#!` is now
  executable, everywhere trees are written. (Found migrating a real v1
  repository.)
- Unsubscribing with "keep the packages" now leaves the scope perfectly
  clean: a kept agent used to show as out of date right afterwards,
  because the marketplace's own skill and settings tables shaped how it
  was written and those tables left with the marketplace. Keeping now
  moves the effective values into your own kendex.toml, so what you
  kept keeps rendering exactly as it was installed.

### Changed

- **Breaking** — vstack is now **kendex**. The app, the CLI binary
  (`kendex`), the crates, and the app identifier are renamed. A `vstack`
  alias binary ships for one release cycle so repositories whose commit
  checks call `vstack guard run` keep committing; `kendex guard repair`
  rewrites those entrypoints to the new name. Project files keep loading
  under their old names and are renamed by a previewed plan step — never
  silently; settings files and catalog configs are read under both names.
  Global app data moves from the vstack2 folders to kendex on first
  launch. Environment variables are now `KENDEX_*`: `VSTACK_DRIFT_HOOK`,
  `VSTACK_EDITOR`, `VSTACK_UPDATE_FEED`, `VSTACK_GIT_BASE`, and
  `VSTACK_BACKGROUND_REFRESH` stop working — set the `KENDEX_*` spelling,
  or a drift hook you turned off comes back silently. Only the guard's
  variables (`VSTACK_GUARDS_*`, `VSTACK_GUARD_PRE_COMMIT_LOCAL`) are
  still read as a fallback during the alias cycle. The default catalog
  moved with the product: fresh installs subscribe to
  `vanillagreencom/kendex`, and a library that still points at
  `vanillagreencom/vstack` is pointed at the new repository by one
  previewed step on its next plan — nothing re-downloads, nothing needs
  the network for it, and everything already installed keeps working.

### Added

- Collections: share a curated set of packages across repositories with
  one link. Create it at kendex.ai/collections; anyone with the link
  runs `kendex add https://kendex.ai/c/<id>` and gets one preview that
  subscribes each repository and installs each member — at the exact
  commits the link resolved to, recorded in the lock, so later
  refreshes never need kendex.ai and deleting the collection only stops
  new installs. A repository you already subscribe to is reused when
  its revision matches the snapshot; when it doesn't, kendex refuses
  with both sides named rather than silently re-pinning what you have.
- Publish what you build. A Mine row's "Submit to community…" walks a
  preflight (check passes, licence, git state, everything pushed, the
  repository visible to the world — each row honest about what this
  machine can know), signs you in with GitHub the first time (a code, a
  browser tab, done — the app never sees a password), and submits to
  kendex.ai, which verifies you can actually push to that repository
  before anything is listed. The row then follows the outcome: in
  review, listed, or needs changes with the reviewer's written reason.
  Sign in/out lives in Settings → Account; the same flow is
  `kendex marketplace submit [--dry-run | --status]` in the terminal.
- Build your own marketplace. The Marketplaces → Mine tab creates a
  ready-to-publish repository (kendex.toml, README, licence, a CI
  workflow that runs the check), registers any folder you already have
  without changing a byte inside it, and imports packages from your
  machine — your own, ones found on disk, or ones from a marketplace
  you subscribe to, which ask you to confirm their licence before they
  copy. The same flows exist as `kendex marketplace new | use | mine |
  import`, one flag per question, and `docs/AUTHORING.md` (also
  rendered in-app) explains the format. `kendex check --catalog` now
  reads a repository exactly the way subscribing reads it, so a repo
  that checks clean installs clean — and `kendex init` marks its
  folder as a catalog so scaffolded hooks are actually offered.
- `kendex login` and `kendex logout`: sign in to kendex.ai from the
  terminal with a short code and a browser tab — the CLI never sees a
  password, the credential lives in your system keychain (with no silent
  plaintext fallback), and signing out kills that machine's access on
  the very next request.
- The Community tab is live: browse the kendex.ai directory (cached on
  your machine, shown with an "as of" line when you're offline — never
  blank), subscribe from a row, and search skills.sh's whole index
  directly, with Trending / Hot / Top charts served through kendex.ai. Installing a skills.sh result subscribes to its repository
  and opens the skill — locked, safety-checked and updatable like every
  other install. Only skills.sh sees your search; installs through
  kendex do not feed their leaderboard.
- The Marketplaces page: subscribe to any repository of skills and
  agents, browse every subscription's packages in one searchable table
  with a pre-install safety dot on each row, open a marketplace's own
  page (its curated sets, its packages, and what its catalog says about
  itself), install a whole set or a selection with a destination picker,
  and read a package's README, files, and safety findings before
  anything lands. A set member you removed shows as "Removed by you" with
  a Restore beside it, so your choice is visible and reversible in place.
  Unsubscribing asks the one question that matters — remove its packages,
  or keep them as your own. The Library is now
  **My Library**, gains a From column and filter saying which
  marketplace (or you) each installation came from, and browsing moved
  out of it to the new page. The community directory and authoring tabs
  say plainly that they arrive with kendex.ai.
- Any repository that holds skills is a marketplace. Subscribing reads
  the layouts the ecosystem already uses — `skills/`, each tool's
  project skills folder, category nesting, even a repo that is one
  skill — with no special file required; what was found where is
  reported per marketplace, and a broken catalog file makes the
  marketplace unusable with the reason named instead of quietly offering
  a different set of packages. Subscribe now takes full git URLs, GitHub
  tree links (the whole repository, with the branch resolved against its
  real branches), and skills.sh links; the same repository can't be
  subscribed twice under two names in one place; and installing into a
  project from a personal subscription subscribes the project in the
  same previewed step.
- Marketplaces are browsable from the core up: every package and bundle
  a subscription offers — hooks, commands and MCP servers included, from
  catalogs that declare them — with each row's installed state, a
  bundle's "partly installed (2 of 6)" counted live, a package preview,
  and a pre-install safety verdict computed on the marketplace's own
  bytes and cached per commit. Names can be qualified as
  `marketplace::name`; a bare name is found by searching everything you
  subscribe to, an ambiguous one is refused with the exact spellings to
  use, and a name nothing offers is "not found" — never a guess.
  Installing a whole bundle absorbs matching individual installs and
  leaves customized ones alone, saying why. `kendex index --json` and
  `kendex check --catalog --json` give the community directory the same
  answer subscribing gets.
- Custom hooks now run wherever a harness can run them. A hook for all
  agents registers in the harness's own hook configuration on Claude
  Code, Codex, Gemini, Copilot, and Pi (through its carrier) — before,
  every harness but Claude only read it as instructions. On Claude it
  registers in settings.json, so it covers the main session, not only
  subagents. Each hook's editor card now says exactly where it runs and
  where it is only guidance, computed from the same decision the
  installer makes; hooks also gain a name (picked from the command on
  first save, editable), a timeout, a per-harness install list, and an
  off switch. A hook aimed at specific agents stays enforced only on
  Claude Code, because no other harness can tell agents apart at runtime
  — the card says so instead of presenting a request as a guard.
- Custom hook commands pass the safety check installed hooks already
  passed. A dangerous command — fetch-and-run, secrets in plain sight —
  is held back before it lands anywhere, with the same review-and-accept
  flow, instead of being written unexamined into every agent file.
- Custom hooks are picked, not typed. The event comes from a searchable
  list of the events harnesses actually fire, each with a line saying when
  it fires, and a manifest naming an event nobody fires is now rejected
  with the valid names as its fix — before, a typo installed cleanly and
  simply never ran. The editor also says who runs these: Claude Code
  executes a hook written into an agent's file, and every other harness
  gets it as instructions that nothing enforces.

### Fixed

- A marketplace that holds only skills can no longer hand over a hook,
  command, or MCP server just because you name one: executable content
  installs only from a repository that declares kendex's layout, never
  guessed from a folder in a repo the About page says offers none.
- A one-skill repository installs the skill, not the whole repository —
  its `.git`, `node_modules`, and build folders stay out of what is
  scored, shown, and copied onto disk, so a repository's credentials and
  dependencies never ride in with the skill.
- One broken or hostile marketplace can no longer block installing by
  name from every other marketplace you subscribe to: a subscription
  whose catalog cannot be read is set aside and named, and the others
  still answer.
- A curated set whose author renamed or removed a member still opens: the
  missing member shows as no longer offered instead of breaking the whole
  set's page.
- A package already declared from one marketplace cannot be silently
  rebound to another before it is installed: naming it from a second
  marketplace is refused with the first one named, the same as an
  already-installed collision.
- Two directories in a repository that fold to one name are both set
  aside, so which one the repository happened to list first cannot decide
  which a person installs; the same skill offered under two harness
  layouts is recognized as one package, not a false clash.
- Package and marketplace names that carry invisible or
  direction-reversing characters are refused and shown as their escapes,
  so one marketplace's package can no longer wear another's name on
  screen while installing under a different one.
- Installing into a project from a personal subscription now lands the
  subscription and the packages in one step: if the install is refused,
  the project is not left subscribed to a marketplace it installed
  nothing from.
- `kendex marketplace browse` lists a subscription's packages from the
  command line, the non-interactive half of the app's Packages page.
- Installing a plugin from a plugin-registry marketplace now says when
  the plugin also ships hooks or MCP servers, which kendex does not
  install from a registry yet — so installing a plugin is never mistaken
  for installing all of it.
- Cursor no longer drops an agent's custom hooks without a word. A rule
  file has nowhere to register a hook, so the hook lands as instructions
  and the render warns that nothing there enforces it.
- A custom hook's matcher is said in each harness's own tool names, the
  way an installed hook's already was — a hook written against `Bash`
  reads as that harness's word for it instead of asking a model to match
  on a name it has never seen.

### Added

- A package's own page now carries what you have changed about it. Open
  anything from the Library and a **Customize** tab sits beside its
  overview: the instructions kendex writes into it, the skills an agent
  gets, and the per-tool settings that beat the catalog's — the same
  manifest the Customize page writes, sliced to the one package you are
  looking at. Its header says **Customized** when anything is set, the
  instructions that apply to everything are named where they land (with
  the way to them), and where a package is installed in more than one
  place you choose which one you are editing.
- The Library marks what you have changed: a row's icon turns orange when
  that package is customized where it lives, with the key printed above
  the table. Kinds a manifest cannot change — hooks, commands, MCP
  servers, plugins — carry no tab and no mark.

- Content a coding tool ships with itself is now labelled with who ships
  it, and left alone. Codex's bundled plugins are OpenAI's, Claude Code's
  are Anthropic's — nobody using kendex chose them or can change them, so
  they are listed in the Library with their vendor named and scored by
  nothing, asked about nowhere. Ownership is read off the marketplace a
  plugin names; a marketplace kendex doesn't recognise stays yours, so
  nothing real goes quiet.

- Agents no longer start sessions blind. `kendex check` is now the drift
  contract: exit 0 when everything is current, 1 when something drifted,
  2 when the state could not be read — with `--quiet` printing a short,
  bounded report (silent when clean) and `--json` the machine shape. Each
  line names its fix from a small fixed set of commands. Held and muted
  packages stay out of the report — a hold is a decision already made —
  and holding counts wherever the pin lives: on the item, on its source,
  or reaching it through a bundle or a dependency. The check itself is
  instant: it reads a per-project snapshot that the heavy commands
  (updates, refresh, apply) keep current, and quietly kicks off a
  background source refresh when the mirrors are older than six hours. A
  source that has been unreachable for over twelve hours becomes a report
  line dated from when it first went dark. The report travels into new
  sessions through a session-start hook — first-party content shipped
  inside kendex, offered when a project is registered (CLI:
  `kendex drift-hook`, or `kendex project add --drift-hook`), installed
  and removed like any other hook, disabled any time with
  `KENDEX_DRIFT_HOOK=off`, and never able to block a session.
- The Updates page now says when a package's standing could not be
  checked — a broken mirror or an unreachable source shows under
  "Couldn't be checked" instead of silently reading as up to date — and a
  package deleted from its catalog is flagged **No longer in its source**.
- Hooks now work on Pi, through the pi-hooks carrier. Installing a hook
  for Pi writes its script and a registry spoken in Pi's own event names,
  which the carrier extension executes — and every label tells the truth
  about it: an event Pi cannot fire installs nothing there, and a hook
  whose carrier isn't installed anywhere Pi looks is flagged as inert
  with the fix named, instead of quietly claiming protection. A carrier
  installed globally covers project hooks too, since Pi reads both. The
  session-start drift report rides along: Pi sessions get the same
  report, the same `KENDEX_DRIFT_HOOK=off` switch, and no repeats on
  resume or reload.
- Commit checks now guard every commit, whatever tool makes it. `kendex
  guard install` puts a kendex-owned hooks directory in front of git for a
  repository, so Claude Code, Codex, Cursor, and a plain terminal all walk
  through the same five checks before a commit lands: files that grew past
  their size budget (with a tighten-only baseline and `--seed` to start
  one), leftover TODO/FIXME/HACK/XXX markers, newly added files over
  200 KB, blanket lint-silencing pragmas (with a ratchet for the narrow
  ones), and non-conventional commit messages. Every check judges exactly
  what the commit will record — staged content, staged settings, staged
  baselines — so an unstaged edit can never change a verdict, and every
  check runs before the verdict so one attempt reports every blocker.
  Configuration lives in `[guards]` tables in `kendex.settings.toml`;
  repos with v1's settings convert once with `kendex guard import-v1`
  (baselines are read as-is, and imported exclusion patterns keep exactly
  the matching behavior they were written for). Removal is as careful as
  install: `kendex guard uninstall` takes back only what kendex wrote,
  leaves a hand-changed hooks setting alone, stays armed while another
  worktree still uses the checks, and refuses rather than half-removing
  around files it doesn't own. If the kendex binary is missing at commit
  time the checks fail closed with the bypass spelled out
  (`git commit --no-verify`).
- Seeded settings comments now stay current. When a skill improves the
  explanation above a `kendex.settings.toml` key it seeded, a refresh
  brings the new words in — but only while the comment is provably
  untouched: any hand edit freezes it forever, values are never touched,
  and another skill can never rewrite words a different skill seeded.
  Files keep their exact bytes outside the comment being refreshed
  (Windows line endings included), and repos migrated from v1 keep their
  edit-protection records instead of re-freezing everything.

- A safety finding that turns out not to be a problem can now be
  dismissed, so it stops asking. Pick why — **Not actually a problem**,
  **Does this on purpose**, or **From a source I trust** — and the
  decision is recorded against exactly that version of the content: any
  change to the file, or to the safety rules, brings the finding back.
  Trusting a source binds to that source, so the same content arriving
  from anywhere else asks again. Dismissing never unblocks a held-back
  item; those are settled by accepting or removing them. Decisions live
  in the same file as acceptances — your personal ones on this machine,
  a project's in its `kendex.toml`, where a teammate inherits them in
  plain sight. Removing an item takes its decisions with it. On the
  command line: `kendex findings` prints each finding with the token
  that dismisses it — a token names the finding, the exact content, and
  the project or personal file it belongs to, so one copied from
  elsewhere records nothing — `kendex dismiss <token> --reason …`
  records the decision, and `kendex decisions [--revoke <id>]` lists every recorded
  decision — active, out of date and why, or about an item that is gone
  — and takes one back. `kendex accepted` is folded into `kendex
  decisions`. The project file's format moves to version 5.
- The Review page's safety warnings each carry **Dismiss…** — one click
  per finding, or one for the same file seen through several tools, never
  one for twenty different plugins that happen to trip the same rule. Ask
  why, and it stops asking. The toast offers Undo, which takes back exactly
  what was just written. Counts follow: the sidebar badge, Home, the
  footer and each project's summary all say how many decisions are still
  waiting, and a project whose every finding is decided reads as in sync
  instead of warning forever. Findings already decided are tallied under
  the safety list rather than hidden.
- The Review page reads as two zones per project: **Needs your decision**
  — installs held back by the safety check, then findings waiting for a
  call — and **Ready to apply**, what the button does. An item you already
  accepted stays listed with its note but no longer counts as waiting on
  you, so the caption, the project summary and the sidebar badge agree.
- **Review one by one** walks a project's open findings worst-first — one
  item, one finding, the three reasons and Skip — so twenty plugins that
  trip the same rule are looked at as twenty things rather than muted with
  one click. Findings that are the same content seen through several tools
  are one step, since one decision honestly covers them.
- **Start managing** moves from the Review page to the Library's Installed
  tab, where the item already is: taking over something kendex didn't put
  there is an offer, not work the Review page owes, so Review now says how
  many such items a project has and points at the Library. Home's
  "aren't managed yet" row opens the Library too.
- Applying something the safety check flagged but did not hold back used
  to look like a clean install, with the findings only turning up under
  review afterwards. The apply preview now says how many things will be
  waiting for your decision once the content lands.
- Settings' **Accepted findings** grows into **Recorded decisions**: every
  acceptance and dismissal on the machine, each saying what it decided,
  when, and whose file it lives in — yours on this machine, or a
  project's shared `kendex.toml` — so a decision a teammate made is
  inherited in plain sight. A decision that no longer applies says why;
  one about an item that is gone says so; each has a way out. A project
  whose file cannot be read is named there with the error, never
  silently left off the list. A project's safety tally on the Review page
  links straight to it once anything there has been decided.
- A package's description renders light formatting, so a file name or a
  command an author wrote in backticks reads as one rather than as
  prose.

- A held-back item can now be accepted from the app. Every serious
  problem the safety check finds shows on the Review & apply page —
  including an install it stopped before anything reached your machine —
  and each one carries **Accept and install**: read the findings, accept
  them, and the item installs in the same step. The acceptance is written
  into that project's own `kendex.toml`, so on a shared repository the
  whole team inherits the decision, and it covers exactly the content
  that was read — any change to the file brings the block back. An
  acceptance that no longer matches (the content changed after you read
  it) stops the whole apply out loud rather than quietly installing
  everything else. Settings lists every recorded acceptance with a
  **Withdraw** button; the CLI mirrors it as `kendex decisions
  [--revoke]`.
- Taking over a skill that several tools share through links now works.
  When tools read one folder through symlinks, **Start managing** shows
  which folder that is and every tool reading it, then moves the
  folder's content into kendex's keeping (the original goes to the
  trash, recoverable) and points every tool at kendex's copy — the
  sharing survives, with updates and safety checks now applied. A link
  at anything that is not a skill folder, or at kendex's own files, is
  still refused, and a folder that changes between preview and apply
  stops the whole operation.
- The tools now wear their real logos — Anthropic's, OpenAI's, Cursor's,
  OpenCode's, Pi's, Gemini's and GitHub Copilot's own marks, from each
  vendor's own site, in the same per-tool colour the rest of the app
  uses. A tool that isn't installed shows its mark greyed. Sources and
  the exact edits are recorded beside the files.
- A `tags:` line in an agent's frontmatter now survives into every
  rendering whose format allows it, so a managed agent keeps saying what
  it is for on every tool.

- Everything you install is now read before it lands, and again after.
  Two separate scores come out of it, and they are never mixed together.
  The safety score answers "could this hurt me" — content that tells the
  model to ignore its instructions, a line that downloads a script and
  runs it, a command that reads your SSH key and sends it somewhere, a
  real credential left in a file, a server launched from a package name
  anyone could have registered. The quality score answers "is this well
  written" — does it say when to use it, is the detail behind a pointer
  instead of all in the front door, would it read the same on another
  tool. Only safety can hold anything back; quality is there to inform.
  Every finding names the file and line, says what it found in plain
  words, and comes with the fix. A command inside a code block in the file
  a tool actually loads counts in full — that is where skills put their
  commands, and the model reads them either way. What counts for less is
  writing that is plainly quoting rather than telling: a blockquote, and
  the test fixtures and reference pages a skill ships alongside it.
  Credentials count the same wherever they are. A leaked key is never
  repeated anywhere: you get a fingerprint,
  enough to tell two leaks apart and useless to anyone who sees it. Text
  carrying hidden characters, or letters chosen to look like other
  letters, is reported as such — content that needs decoding to look
  clean has told you something.
- `kendex check --catalog <dir>` validates a catalog the way an install
  would, and exits non-zero when something is wrong — so a repository can
  find out in its own CI rather than in someone else's install preview.
  It checks both halves: whether each tool's loader could actually hold
  the item (a name it will not accept, a SKILL.md that disagrees with its
  own folder, a body past the tightest size cap) and whether the content
  is safe. `--strict` also fails on advice. A reusable GitHub Actions
  workflow ships with it — catalog repositories point one line at
  `.github/workflows/catalog-check.yml` and get the gate. What `kendex
  init` scaffolds passes it on the first run.
- Install a whole set at once. A catalog can offer named bundles — a
  starter kit, a review workflow, the tools one team shares — and
  installing one brings in every agent, skill, command and hook it
  carries: `kendex add <catalog> --bundle <name>`, or the Install button
  now beside each catalog on the Catalogs page. Repositories that ship
  marketplace-style plugins need no extra authoring, because each plugin
  is already a set, with the version and description it publishes.
  Uninstalling is the half that usually goes wrong, so it says exactly
  what it will do before it does it: members you also asked for by name,
  members another installed bundle carries, and members something else
  still needs all stay, everything else goes, and every line comes with
  the reason it went or stayed. Removing a single member sticks too — a
  refresh will not quietly put it back, and the audit reports the bundle
  as installed with members held back rather than as complete. When a
  catalog changes its mind about what a bundle carries, the additions and
  removals appear in the refresh preview and wait for an answer before
  anything is installed or uninstalled.
- Skills can require other skills: a required companion installs with
  its parent (for the tools that support it, with a warning where one
  cannot), an optional companion is a real install-time choice that
  survives refresh and other machines, and removing something warns
  about what still needs it — with an optional sweep of leftovers
  nothing needs anymore. Removing a required companion sticks: it stays
  removed across refreshes and the parent shows a "missing required
  dependency" note instead of it silently coming back.
- **Breaking:** every installation records the reasons it exists —
  asked for directly, required by another item, or part of a bundle —
  and those reasons drive removal decisions. Migration: existing
  install records gain a single "asked for directly" reason, the only
  safe reading.
- **Breaking:** installing can now be refused. Anything the safety check
  rates as critical is held back on its own, and so is anything whose
  overall score falls below 60; between 60 and 80 it installs and warns.
  A held-back item shows up the way any other conflict does — it appears
  in the preview with what was found and why, and nothing about it is
  written. Migration: the two thresholds are yours to set in app
  settings, and nothing else changes for content that passes. If you have
  read the findings and want it anyway, the preview prints the exact
  command that installs it — `kendex apply --allow-unsafe <name>@<code>`,
  where the code stands for the content you were just shown — and records
  the review in your `kendex.toml`. The name on its own does nothing, so a
  line left in a script or a shell history cannot wave through content
  nobody has read. The record is bound to the exact content, the exact
  rules, and the exact problems you were shown; change any of them and it
  stops applying, the item is held back again, and the preview prints the
  new code. The record lives with the project rather than in a global list
  precisely so it cannot quietly become a permanent exemption.
- **Breaking:** `kendex refresh` no longer changes what is installed
  without asking. Regenerating what is already installed stays
  automatic; anything being added or removed (including dependencies a
  catalog gained or dropped) is shown first and needs confirmation or
  `--yes`. Scripts add `--yes`; a non-interactive run refuses before
  touching anything.

- **Breaking:** kendex can now be pointed at a marketplace-style
  catalog — a repository that ships its content one plugin at a time,
  with a `marketplace.json` listing what it offers — and install straight
  from it, alongside the plain catalogs it has always read. Nothing is
  guessed: a repository is read that way only when it carries that
  listing, and only the plugins the listing describes, kept inside the
  repository itself, are offered. An entry that points at some other
  repository or a web address is skipped and named, rather than quietly
  fetching something nobody asked for. Anything the catalog gets wrong is
  reported with what to do about it: a listing that does not parse, a
  plugin whose own details disagree with the listing about its name or
  version, a plugin describing files outside itself, and two names your
  filesystem cannot tell apart. Items from these catalogs are listed under
  the plugin they came from, so two plugins can each ship an `analyzer`
  without one hiding the other. *Migration:* nothing changes for catalogs
  already in use — a catalog with no listing installs exactly where it
  always did, under the names it always used. Items from a marketplace
  catalog are declared and shown as `<plugin>/<item>` (in `kendex.toml`,
  write the name in quotes), and each tool spells that its own way in the
  files it reads: `data-science__eda` for most, `data-science-eda` where
  the tool only accepts lowercase words joined by hyphens. If two
  declarations would end up as the same file — a namespaced name against a
  flat one already spelled that way, or two names that differ only by
  capitals or by how an accent is typed — neither is installed, and the
  conflict names both so you can rename one. Only agents, commands and
  skills come from these catalogs, so only those carry a plugin in their
  name: a hook or an MCP server is still written without a `/`, and a name
  that cannot be a file at all is refused when `kendex.toml` is read.

- **Breaking:** a source can now say which revision it reads, and
  downloaded catalogs are kept one folder per version instead of one
  working copy per repository that every refresh reset in place. Add
  `rev = "<commit, tag or branch>"` to a source in `kendex.toml`, or name
  it when adding one as `owner/repo@<rev>`. A full commit id is a pin —
  that exact content, forever, and it keeps working with no network once
  it has been downloaded. A tag or branch is followed instead: each
  refresh re-resolves it, and a tag that moved upstream shows up as a
  pending change to preview like any other, never as a silent rewrite.
  Two projects can now sit on different versions of the same catalog at
  once, and a refresh started in one window can no longer change files
  another window is reading. Being offline with a pin that was never
  downloaded is an error naming the pin; everything already installed
  keeps working. *Migration:* the download cache rebuilds itself on the
  next refresh — no user content is involved — and the old cache folders
  are left in place, still readable, rather than deleted. The new layout
  keeps one folder per version it has read, which is what lets two
  projects sit on different ones; a catalog you follow by branch therefore
  gains a folder each time it changes upstream, and nothing tidies them up
  yet. Deleting the whole cache folder is safe whenever it gets large — it
  is rebuilt on the next refresh. Nothing in `kendex.toml` has to change:
  a source with no `rev` follows its repository's default branch exactly
  as before.

- GitHub Copilot is now fully managed — agents, skills, hooks, and MCP
  servers install, switch on and off, and come off disk like every other
  tool, personally and per project. Each lands where Copilot actually
  reads it: agents as `.agent.md` files with a tools allowlist in
  Copilot's own tool names, skills in its skills folder, hooks as a hook
  file of their own that Copilot runs and honors the result of, servers
  keyed the way Copilot expects with the transport named on the entry.
  Copilot has no slash commands of its own, so kendex does not invent
  any. Because Copilot reads other tools' files too, three things are now
  said out loud rather than left to surprise you: a skill installed for
  Claude Code is reported as something Copilot already sees — one
  definition, never counted twice; a hook installs but is reported as
  doing nothing when hooks have been switched off anywhere Copilot looks,
  including Claude Code's own settings; and a skill or server your
  personal Copilot settings hold down is reported as something this
  project cannot switch back on, because Copilot only ever lets a
  repository add to that list. An agent pinned to a model the repository's
  allowed-models list refuses is flagged the same way. Which model Copilot
  uses is left to Copilot: its list changes monthly and depends on your
  plan and your organization, so kendex pins nothing it cannot promise.

- **Breaking:** a plugin now belongs to one tool. Copilot and Claude Code
  both keep a list of enabled plugins, and a declaration that named
  neither used to be written into every tool's settings — switching on
  software in one tool because it was installed in another. Every plugin
  declaration now carries the tool it belongs to. *Migration:* existing
  declarations are read as Claude Code's, which is the only tool kendex
  ever wrote a plugin switch for, and the next save records that in
  `kendex.toml`; nothing to change by hand. Add `harness = "copilot"` to
  a plugin declaration to aim it at Copilot instead.

- Gemini CLI is now fully managed — agents, skills, commands, hooks, and
  MCP servers install, switch on and off, and come off disk like every
  other tool, personally and per project. Each lands in the shape Gemini
  actually reads: agents as its own subagent files naming its own tools
  (`read_file`, `run_shell_command` — not the names other tools use),
  commands as Gemini command files, hooks registered under Gemini's own
  event names with the timeout in the units it reads. Two things about
  Gemini are said plainly instead of glossed over: whether an MCP server is
  switched on is recorded once for the whole machine, so a project can
  bring a server in but has to remove it rather than switch it off there;
  and an agent installed while Gemini's subagents are turned off is
  reported as installed-but-doing-nothing rather than as ready. Where the
  installed Gemini is older than the settings file kendex writes, or where
  a machine-wide settings file outranks what kendex puts in a project,
  kendex says so and leaves the file alone instead of writing something
  that would never be read. Gemini's extensions stay read-only: they
  install in one place for the whole machine and switch on through a rules
  file nobody has documented.

- kendex now sees Gemini CLI and GitHub Copilot setups, personally and per
  project, listed beside every other tool: Gemini's agents, skills,
  commands, hooks, MCP servers, and extensions, and Copilot's agents,
  skills, and MCP servers. Copilot's folder is found where Copilot
  actually keeps it, including a relocated one. Files the two tools borrow
  from each other, like Copilot reading Claude Code's skills, stay listed
  once under the tool they belong to instead of being counted twice.

- Every generated file is checked against its tool's real format before
  anything is written. A file that tool would not load — an unparseable
  Codex agent, an OpenCode agent whose mode or permissions it cannot read,
  a skill whose SKILL.md names a different skill than the folder it sits
  in, a name OpenCode's loader rejects like `My_Skill` — is blocked in the
  plan with the fix spelled out, instead of installing broken and going
  quiet. Only the tool that rejects it is blocked: the same item still
  installs everywhere its format is valid — except where tools read the
  same folder, where one file serves them all, so a refusal there covers
  every tool reading it. Files that load but not as written, like a Cursor
  rule carrying keys Cursor ignores, install with a warning rather than a
  block.

- **Breaking:** commands install on Codex, which retired its prompt
  directory in favor of skills. A declared command lands on Codex's skill
  surface as a generated skill — frontmatter, the generated-file banner,
  then the command body — at both scopes, and it toggles and comes off
  disk there like any skill. The install record keeps the name and paths
  the command actually took, so removal and refresh target what was
  written. A command whose name a skill already holds installs as
  `<name>__command`, or `<name>__cmd` when that is taken too, with a
  warning naming it. OpenCode and Cursor still only read commands.
  Migration: refresh creates these — no Codex command artifacts existed
  before, and `~/.codex/prompts` is still never written to.

- Agent instructions now speak each tool's own vocabulary. A body written
  in Claude's words — "use the Read tool" — is reworded as it installs on
  OpenCode, Cursor, and Pi, so the agent reading it gets an instruction
  about a tool it actually has instead of a name it does not recognize.
  Codex is narrower, because it names actions rather than tools: only a
  whole "use the Read tool" becomes "open the file", and every other
  mention stays as authored, since an action phrase dropped into a name's
  place turns the sentence into nonsense. Only unmistakable references are
  touched: code samples, links, generated skill paths, backtick-quoted
  names on Codex, and the project's own launch and additional instructions
  keep every byte. A custom or MCP tool name is never guessed at — it
  passes through as written, and the plan preview names both what was
  reworded and what was left alone.

- Catalog downloads are hardened against the repositories they fetch. A
  source repository can no longer redirect a refresh at files outside its
  own cache, no git call can stall the app waiting on a credential or SSH
  prompt, and every external command gives up with an error rather than
  hanging forever.

### Fixed

- Migrating from v1 now fails closed instead of guessing. A damaged v1
  install record refuses with its path named rather than being treated as
  absent and buried under a fresh empty one, and a stale v1 record can
  never be re-imported over a scope that already has live v2 installs —
  the refusal names the leftover to remove. The migration itself runs as
  one journaled, crash-safe transaction. A damaged app settings file now
  also stops a plan cold: safety thresholds you set are never silently
  swapped for defaults because the file could not be read. And upgrading
  an older project file's format now repairs a missing final newline
  exactly once, changing no other byte.

### Changed

- The coding tools kendex writes to are called **harnesses** now, in the
  sidebar, the Library's filter and column, and everywhere the words
  appeared. "Tool" was doing two jobs at once — Claude Code is one, and so
  is a thing an agent is allowed to call, which agent settings also list.
- Loading states are the shape of what's coming rather than grey slabs: the
  Library draws rows, Home draws its attention list, its recent items and
  its three tiles, and a wait with no shape to borrow gets a small spinner.
  Excess copy is gone with them — a count is a count, and the Review page
  no longer opens by explaining itself.
- The safety check got about seven times faster: a large project that took
  0.8 s to score now takes 0.11 s, and spends less processor time doing it.
  Each distinct file is read once and scored on its own core, phrase
  matching skips ahead instead of trying every position in every line, and
  content that is plain ASCII skips the pass that folds lookalike letters —
  there is nothing there for it to fold. The findings themselves are
  unchanged, byte for byte.
- The app no longer looks empty while it is still reading. The Library
  draws placeholder rows until the first scan lands, instead of claiming
  "Nothing installed yet", and Home says it is still checking rather than
  showing a blank space where what-needs-attention will appear. The four
  startup reads now run at the same time, so the Library — which needs
  only the quick one — no longer waits behind the safety pass over every
  installed file.
- Customize is now the page for what isn't about one package: the
  instructions every agent and skill inherits, your own hooks, and a
  project's skills folder — plus a list of every package you have
  customized, each row opening that package's page. The agent-by-skill
  grid and the stack of per-agent text boxes are gone; an agent's skills
  and settings are edited on the agent.
- Tools are marks rather than names wherever a row lists several of them —
  the Library's table and the not-managed-yet list. Six chips reading
  "Claude Code Codex OpenCode Cursor Pi" on every row pushed the columns
  that actually differ off the screen; the logo carries the tool, and the
  name is on hover. A package's own details still spell them out.
- The Library's status column is a dot — green active, amber switched
  off, red for a broken link — with the words on hover instead of in
  every row.
- Per-agent settings read as settings: **Model**, **Blocked tools**,
  **Reasoning effort** rather than the manifest's own key names, with an
  example in each empty field.
- Customizing no longer starts with a button. A scope with nothing
  written yet opens on an empty page you can type into, and the first
  save creates the file.

- Where an item lives is filtered on the Library, and nowhere else. The
  app-wide location picker in the sidebar narrowed every page, including
  pages that already state each row's location — so a count could
  disagree with the table under it with nothing on screen explaining
  why. Every other page now shows everything.

- Tools and Projects are two places in the sidebar instead of two tabs
  on one page. They answer different questions, and where a tool keeps
  its files is now edited on that tool's own row rather than in a second
  list of the same tools.

- Chrome reads more honestly: a border now means "you can act on this",
  so chips and badges are a quiet fill and a dismiss button never looks
  like a label; muted text is a real step in the hierarchy rather than
  decoration; a section with nothing in it isn't drawn at all; and the
  dialog that rules on a finding restates what it is deciding, since the
  row that opened it only showed a headline.

- Projects are cards, and adding one is a dialog. Personal and each
  project now use the same card, so the item counts sit in the same
  place on both — they used to be laid out differently, which made two
  identical facts look like two different ones. **Add a project** and
  **Scan a folder** are buttons at the top that open a dialog, rather
  than two stacked forms that took up more of the page than the projects
  did.

- The Library has its own search box, above the table it filters. It
  used to sit in the sidebar, where it did nothing at all on six of the
  seven pages — typing into it on Home changed nothing. `/` still
  reaches it from anywhere and now takes you to the Library with the
  cursor already in the box. Beside it, the pickers name what they
  filter once something is chosen (**Type: Agents**), a live count says
  how much is showing against how much there is, and **Clear filters**
  appears whenever anything is narrowing the list.
- Where an item lives is filtered once. The Library's own place-pills
  and the sidebar's project picker were two separate filters that
  stacked, so choosing one project in the sidebar and a different one in
  the pills emptied the table with nothing on screen to explain why.
  They are now the same setting and move together. **Trade-off:** the
  pills no longer multi-select, since the app-wide setting takes one
  project at a time.
- Counts mean things, not rows. The Review badge, the status footer and
  Home each added up one row per tool an item is installed for, so 45
  unmanaged items read as 171 while the page beside them said 45. They
  now count items, from one shared place so they cannot disagree again,
  and things kendex was never asked to manage are no longer counted as
  changes waiting to be applied — applying never touched them.
- A row's second line is a description or nothing. Plugins were showing
  a version folder name (`1.2.0`) where a description belongs, which
  identifies nothing and made a list of plugins read as a list of
  numbers. Hooks and MCP servers have nowhere to write a description, so
  they keep the command that distinguishes them but set it in monospace,
  as the literal it is.

- Back and forward now work the way they do in a browser. The side
  buttons on a mouse move through where you have been, a forward arrow
  sits beside the back arrow, and each greys out when there is nowhere
  to go that way. Opening anything new abandons the forward trail, as a
  browser does. The back button also grew to a normal size and now lines
  up with the title beneath it instead of sitting out to its left.
- A page's buttons sit beside its title rather than beside its
  description. On a package with eight lines of description they used to
  float in the middle of the page; the description now runs at a
  readable width underneath.
- Errors, warnings and notices share one treatment. Each was written by
  hand where it appeared, so they disagreed on colour, icon and weight —
  and the file preview's failure had no error styling at all, reading as
  ordinary grey text. All four states (error, warning, information,
  success) now draw on the same palette the rest of the app already
  used.

- The building blocks behind every control — menus, dialogs, switches,
  tabs, tooltips — were swapped for Base UI, their maintained successor.
  Nothing looks or behaves differently day to day; dropdown labels,
  keyboard navigation, and focus behavior were verified page by page
  against the previous build. The one deliberate change: arrowing
  through tabs now moves focus without switching the tab until you press
  Enter, which matches how tabs work across current apps.

- Keyboard focus now looks the same on every control: buttons and tabs
  had kept an older, heavier focus outline than the rest of the app, and
  the checkbox's error outline was too faint in dark mode.

- A held-back item is one entry now, however many tools it's on and
  however many places its problem appears. The same skill blocked on
  two tools used to print its full findings twice, and a rule firing
  at four lines repeated the same sentence and fix four times — now
  it reads once: the item, what's wrong in plain words, the fix, and
  the locations as a short list under their shared folder.

- On Review & apply, an item found on several tools is one row with
  the tools listed ("agent-browser · Skill · Claude Code, Pi") and
  one Start managing button that handles all of them; paths shorten
  to ~ and each section breathes with its count in its label.

- The Library detail panel is a full-height flyout now: the table
  keeps its full width, the panel slides over it with room to
  breathe, and closing is a click anywhere outside, Escape, or the X.
  Content previews got real treatment — code with syntax coloring in
  both themes, markdown rendered like a proper README, the file name
  pinned above with a copy-path button — and "Open in…" gives you a
  choice: the file browser, or your code editor (a skill opens as its
  whole folder; VSCodium, VS Code, Cursor, Zed, and Sublime are
  found automatically, or set KENDEX_EDITOR). The table's scrollbar
  also stopped painting over the last column.

- Safety findings finally read like sentences. Each one collapses to
  a single plain-English line — "Contains a command that could do
  real damage", "Installed from an untracked source, so updates
  can't be checked" — with a colored dot for how serious it is and a
  chip saying what it applies to ("14 hooks", "21 plugins"). The
  detail — exact message, file and line, the fix, the full list of
  affected items — opens on click instead of filling the page.

- Errors got a real home. Anything that fails when you click now
  opens a small dialog saying what failed, why (in the backend's own
  words), and the steps to fix it — with a Retry where that makes
  sense. Ongoing problems — a project kendex can't read, a scan that
  failed — stay visible as a red count in the bottom status bar for
  as long as they exist; clicking it opens a Problems page where
  each one carries its resolution actions (rescan, show the file,
  stop tracking the project). A project with a problem also says so
  on Review & apply instead of pretending to be clean.

- The Library's location filter became pills: All · Personal · one
  per project, multi-selectable with a click, replacing the dropdown
  — and they narrow within whatever the sidebar already shows.

- Home earned its place: what needs attention leads, a new "Recent
  activity" list shows the latest-changed items on your machine (each
  row jumps to the Library, filtered), and the count tiles moved
  below as an at-a-glance strip. The stray error line at the bottom
  is gone — errors show where they happen now.

- Review & apply explains itself now — "Changes kendex wants to make,
  and things it found; nothing touches your files until you apply" —
  and the page reads in order of urgency: held-back items in a tinted
  panel that is unmistakably first, then the changes applying would
  make, then safety notes worth a look, then items not managed yet
  (with a line on what managing does), then the all-clear. Clicking
  "Start managing" confirms itself ("Now managing …") instead of the
  row silently vanishing.

- Clicking an item in the Library opens a proper detail panel: close
  it with the X, Escape, or another click on the row. It shows the
  item's type, tools, where it lives, its file path, when it last
  changed, and where it came from — plus the item's own content,
  rendered nicely for text and shown as code for scripts — and a
  "Show in file browser" button opens the folder on disk. The table
  itself gained type icons, a "Where" column and filter (Personal or
  per project), a quiet "Updated" column, and one rule for the line
  under each name: it is always the item's description, never a
  version or commit hash — those now live in the panel and read as
  data, not prose. Both Library tabs share one content width.

- Anywhere a folder path can be typed — adding a project, scanning
  for projects, tool-folder overrides — a Browse… button now opens
  the system folder picker instead of making you type the path.

- Section headings inside cards got a real hierarchy: a small quiet
  label above the content instead of a heading the same size as
  everything else, with row titles and descriptions on a consistent
  scale across Settings and Tools & Projects.

- The app draws its own title bar now — the system frame is gone.
  Window controls sit top-right in the app's own style, the top edge
  is a drag handle (double-click to maximize), and the whole window
  looks the same in both themes instead of wearing the desktop's
  frame. The controls float inside the page rather than taking a bar
  of their own, so content starts higher, and the heavy divider lines
  under the old bar and under tab strips are gone.

- A quiet status strip runs along the bottom of the window: whether
  the last scan is current ("Up to date · scanned 2m ago"), and — when
  there's something to do — how many changes are pending and how many
  installs are held back, each a click away from Review & apply.

- The back arrow and breadcrumb now appear only after you follow a
  link from one page into another; opening a page from the sidebar
  shows neither.

- You can step back. Following a link across pages — a count on Home,
  a tool's badge into the Library — leaves a quiet back arrow and a
  breadcrumb ("Library / Installed") at the top of the page; clicking
  a section in the sidebar starts fresh.

- Long "affects" lists on Review & apply fold away instead of printing
  a wall of identifiers: you see the count and the first few names with
  a "+17 more" you can expand. And when several findings hit the exact
  same set of items, the set is shown once with those findings stacked
  above it — the same 21 plugin names no longer print twice.

- The app now summarizes instead of listing. Review & apply used to repeat
  an identical warning under every hook it touched — seven hooks sharing
  one settings file meant seven copies — and gave every clean plugin its
  own row; now a finding is said once with the items it affects listed
  under it, clean items collapse to one sentence, and internal
  identifiers and numeric scores stay out of the headlines. Home tells
  the truth at a glance: "changes ready to apply" and "items that aren't
  managed yet" are counted separately (they used to be lumped together as
  "out of date"), and the summary sentence at the bottom became three
  tiles — tools, installed, projects — that take you to the page they
  describe. Every page now shares one content width, tool cards became a
  compact list whose counts click through to the Library pre-filtered,
  the rarely-used folder override moved off every tool card into
  Settings, and inputs are sized to what they hold.

- The app has a considered look now instead of stock defaults: a
  near-black ground with a blue accent, and color that carries meaning —
  green means healthy, amber means worth attention, red means held back,
  blue means an update is waiting. Status dots and tinted pills replace
  the grey-on-grey badges, the one primary action on each screen is the
  one blue button, file paths and versions read in monospace, and both
  the light and dark themes got the same treatment. Pressing `/` now
  jumps to the Library search box, and the box says so.

- The safety check's caution level is a Settings control now (Strict /
  Balanced / Lenient) rather than a threshold with no way to set it.

- The app is reorganized around what you're trying to do, not around its
  internals: six sidebar destinations instead of eight. Home now leads
  with what needs your attention — out of date, held back for safety, or
  otherwise worth a look — each with its fix one click away, and a quiet
  all-clear when there's nothing to do. Sync is now Review & apply, the
  same preview-then-apply screen. Library and Catalogs merge into one
  Library, with Installed and Add from a catalog as its two modes;
  bundles — a catalog's ready-made sets — lead the add flow instead of
  hiding under each catalog's entry. Tools and Projects merge into one
  Tools & Projects, since both answer "where does my setup apply."

- **Breaking:** agent tool permissions are typed intent, preserved from
  source to every renderer and never widened. A missing `role:` no longer
  renders Codex `sandbox_mode = "danger-full-access"` (role-less agents get
  the sandbox their `tools:` list justifies); a source `tools:` allowlist
  renders natively on Claude, synthesizes an OpenCode permission block,
  infers the Codex sandbox, and is refused on Pi where honoring it is
  impossible; the v1 importer carries legacy `tools:` allowlists over as
  `allow-tools` overrides instead of dropping them. Migration: refresh
  regenerates installed agents; an agent that wants full access declares
  `role: engineer` explicitly.

- **Breaking:** model aliases resolve through one per-harness table
  (`fable`, `opus`, `sonnet`, `haiku`, `inherit`); `inherit` now survives
  every harness (OpenCode/Codex/Pi omit the field instead of emitting an
  invalid id such as `openai/inherit`), explicit vendor ids pass through
  untouched, and a bare unknown model warns where the harness's loader
  requires a `provider/model` form. Migration: refresh regenerates.

### Fixed

- A refresh no longer downloads catalogs you install nothing from, and
  one unreachable catalog no longer stops the rest. Every new
  configuration lists the built-in catalog whether or not anything ever
  came from it, and refresh fetched all of them — so a routine refresh
  paid for a repository no installed item needs, and because an
  unreachable catalog was a hard error, that one unused entry could fail
  the whole refresh. Refresh now fetches only catalogs something is
  actually installed from, and reports the ones it could not reach while
  refreshing everything it could. Browsing catalogs still loads them
  all.

- A Pi extension installed as a package shows what it is. The scan used
  the raw install spec as the description, so twenty extensions read as
  twenty near-identical folder paths — `./packages/@you/pi-caveman` —
  while the real description sat unread in the package's own
  `package.json`. Those packages now report their description, resolve
  to their own folder rather than to the settings file that lists them,
  and carry a real modification time instead of a dash.

- A package page can show the files of an item kendex did not install.
  It read only from the catalog an item was declared in, so every item
  already on your machine but not managed by kendex — and everything in
  a project whose `vstack.toml` is still v1 — failed with a message
  about version holds that had nothing to do with reading a file. It now
  falls back to the copy on disk, still through the same sealed read. A
  shared install reached through a symlink, which is how most shared
  skills are laid out, failed a second way underneath that and now
  works too.

- **Breaking.** Accepting a problem now covers the exact bytes it was
  shown with. It did not before: the safety check reads a summary of an
  item — it stops after the first 512 KB or 200 files of a skill, counts
  a binary file's size without looking inside it, and never opens a
  plugin's payload — and an acceptance was bound to that summary rather
  than to the content. So an accepted plugin's payload could be replaced
  with entirely different code of the same size, or a file past those
  limits rewritten, and the acceptance carried on covering it. It now
  binds to every byte of what was installed, so any change of any kind
  brings the block back and asks you to look again. Where the content
  cannot be read at all — a plugin that is only a switch in a settings
  file — an acceptance no longer counts as live, because nothing can
  show it still describes what is there. Migration: acceptances recorded
  before this change cannot prove what they covered, so they read as
  out of date and the item is held back until you review it once more.
  Accept it again and it is bound properly from then on. `kendex
  accepted` and Settings both show which acceptances need this. The
  project file's format moves on (to version 5, together with the
  dismissals above), so an older kendex refuses to read it rather than
  misreading an acceptance.
- An accepted skill installed as a shared link no longer reads as
  "changed since it was reviewed" the moment it lands: the safety
  check's idea of content identity no longer depends on which path the
  same bytes were read through, or on how much of a very large skill the
  audit sampled.


- A project carrying files from vstack v1 (or a corrupted kendex
  file) no longer breaks the Review & apply page with a raw error.
  A v1 project now shows read-only with a note saying it predates
  this version; a truly unreadable file shows as a problem for that
  one project, with the reason — other projects keep working either
  way.

- The checkboxes in Customize's agent-skills grid were collapsing
  into thin slivers — a leftover from the component-library switch
  that only this grid exercised. They render as proper checkboxes
  again.

- When something fails, you now hear about it where you clicked: a
  small notice appears in the corner with the reason, in plain words.
  Errors used to be easy to miss entirely — adding a project with a
  bad path, for instance, quietly printed its message on the Settings
  page and cleared what you typed. The input keeps what you typed on
  failure now, and adding a project confirms itself with a brief
  "Added" notice.

- Typing a folder the way a terminal spells it — `~/dev/my-project` —
  now works everywhere a path can be typed: adding a project, scanning
  a folder for projects, and tool-folder overrides. Before, the `~`
  was taken literally and the add failed.

- Applying from the app (and `kendex apply`) now performs the "Upgrade
  kendex.toml to the current format" step it promised. Before, the
  preview listed the upgrade but the apply quietly skipped it, so a v0.1
  setup file stayed old forever and the promise came back after every
  apply. Found by walking the real app through the migration, not by the
  test suite — the apply path planned from a copy of the file that no
  longer looked old. The upgrade also now finds the real `schema` line
  even when a comment mentions the same text or the spacing is unusual,
  and changes only that line — comments and formatting survive
  byte-for-byte. Applying a folder whose setup file was deleted out from
  under the preview now says so instead of silently succeeding.

- The safety check no longer flags ordinary code for reading its own
  settings. `process.env.API_URL`, `os.environ[...]`, `import.meta.env`
  and `Deno.env` are how every JavaScript and Python program reads the
  values you gave it, and every one of those lines was being reported as
  reading a credential file — enough of them to hold back any catalog
  with a single JavaScript skill in it. Naming a project's own `.env` in
  a README or opening it in a loader script says nothing either, so it no
  longer says anything. Reading a real key store and sending it somewhere
  — `cat ~/.ssh/id_rsa | curl …` — is still the most serious thing the
  check reports. Sweeping a 39-item catalog now returns twelve findings
  where it used to return two hundred and ninety-six.
- A command shown inside a code block in a SKILL.md is now treated as
  what it is: the instruction. It used to count for less, which meant the
  check held back the awkward way of writing an attack and let through
  the way anybody would actually write one. Test fixtures and reference
  pages that a skill ships alongside itself still count for less, because
  a test asserting on a dangerous command line is describing it, not
  issuing it.
- A single byte that is not text can no longer hide a whole file. Adding
  one to the end of a script used to make it invisible to every rule, and
  the item then scored a perfect hundred on content nobody had read. Such
  a file is now read as far as it can be, and the part that could not be
  read is reported so the score is not mistaken for a clean bill.
- The check now recognises far more letters that are drawn to look like
  English ones. It knew about Cyrillic and Greek capitals; a Greek `υ`, an
  Armenian `ո` or a small-capital `ᴜ` dropped into "ignore previous
  instructions" went through with nothing reported at all.
- Warnings about an MCP server's command line no longer quote the command
  back with an API key still in it. Any value the check repeats to you now
  goes through the same redaction as a key it found on purpose.
- The Audit page tells the truth about items you have accepted. An
  installed item whose findings you read and accepted was being shown as
  "held back" — the opposite of what was true — and an acceptance that no
  longer matched what is on disk was never shown as stale.
- Things the check could not look at now say so instead of disappearing.
  A plugin that is not installed yet, and an MCP server whose entry could
  not be read, used to score a silent hundred out of a hundred and then be
  dropped from the report entirely, so a row nobody had audited read as
  one that passed. MCP servers are now read out of the config file that
  holds them, so most of them are genuinely checked.
- Removing something while its catalog is unavailable now sticks. If the
  catalog was offline, moved, or not downloaded yet, the removal went
  through and then the next refresh quietly put the item back — silently,
  under `kendex refresh --yes` in a script. The removal now stands on what
  kendex already recorded about why the item was installed, so it stays
  removed when the catalog comes back, and the preview says out loud that
  a catalog it could not read may hold consequences it cannot show you.
- An item that is both asked for by name and marked as kept-removed now
  installs and reads as installed. Before, it was installed on disk while
  the audit called it a missing dependency and reported its bundle as
  incomplete. Asking for something by name is the stronger statement, so
  it wins, and the contradiction is reported once with how to clear it.
- A bundle you have switched on no longer installs its items switched off
  because some other, switched-off bundle happens to carry the same item.
  Whichever bundle sorts first used to decide, so the result depended on
  the names. An item two bundles carry is now on if either bundle is on,
  and anything else the two disagree about — which catalog it comes from,
  how it is installed — is reported with both bundle names instead of
  being settled silently.
- Two skills that require each other no longer report each of their
  findings twice in the audit.
- Bringing a Gemini MCP server into a project no longer switches that
  server back on for your whole machine. Gemini records whether a server
  is on in one file every project shares; a project now reads that file
  and says "declared here, but switched off for this machine" instead of
  rewriting it, and removing the server from a project leaves the
  machine-wide switch exactly where you set it. Switching a server on and
  off personally works as before.
- A safety hook written for Claude Code now matches on Gemini CLI and
  GitHub Copilot. Hooks name the tool they guard — "Bash" — and each tool
  has its own name for it, so the name is translated on the way in
  (`run_shell_command` on Gemini, `bash` on Copilot); before, the hook
  installed looking correct and never fired. A matcher kendex cannot
  translate — a regular expression rather than a plain name — installs
  exactly as written and is flagged as possibly matching nothing.
- Installing a safety hook on Cursor or OpenCode now says plainly that
  neither tool runs hooks: the plan marks it "(advisory)" and the report
  says it lands as text the model may ignore. Every tool's card also says
  whether it runs safety hooks at all.
- `kendex verify` no longer prints a clean tick for an installation that
  cannot do anything — a hook switched off machine-wide, a server Gemini
  gates out, an agent installed while subagents are off. The reason is
  printed beside the row; it still does not fail the run, because nothing
  is wrong with what was installed.
- A skill named in a way GitHub Copilot will not load is refused with the
  spelling that works, instead of installing where it is never listed.
- A skill installed for another tool is now reported as visible to Gemini
  CLI as well as to Copilot — both read the shared skills folder, and
  neither gains a phantom installation of its own.
- An item declared only for tools that cannot hold it — a slash command
  for Copilot, which has none — now says so instead of silently
  installing nowhere.
- One unreadable Pi package no longer empties the whole `update-pi`
  listing — it gets its own note and the healthy rows still print.
- A symlinked configuration file inside a catalog is refused loudly
  instead of being silently treated as absent, and plan rows for
  settings changes name the tool again.
- **Breaking:** a skill too large for Codex's loader now splits into a
  head plus `references/details.md` instead of silently truncating at
  load; tools without the cap keep the whole body on their own copy, and
  a command that installs as a Codex skill splits the same way. Nothing
  is refused for size unless the split itself is impossible — a single
  code block spanning the limit — and the message says so. Migration:
  refresh regenerates.
- The editor's skill list no longer breaks on a machine where nothing
  was ever adopted; the reserved local source reads as missing until
  adopt creates it.
- A catalog item refused for a hostile read now fails `kendex verify`
  and `kendex refresh` instead of printing a green tick.
- OpenCode agents pinned to a bare vendor model id keep loading: the id
  gains OpenCode's default `openai/` provider prefix as before.
- A project's identity no longer depends on how its path was spelled:
  the writer lock and every derived path key off the canonical root, so
  two differently-written paths to one project can never write
  concurrently.
- Two or more settings changes to the same configuration file now apply
  together in one write: installing two MCP servers (or a hook plus a
  server, or any mix of registrations and removals) into one settings
  file in one apply used to fail and roll back; each file now gets a
  single composed mutation with a single precondition.
- A tool refusing a skill no longer wedges the project. Where two tools
  read the same folder, the refusal used to plan the same removal twice,
  which failed and rolled the whole apply back — nothing in that project
  could be applied again until the catalog was hand-edited. The refusal
  also no longer takes the folder away from a tool that accepted the
  skill and is still reading it. Two tools pointed at one folder likewise
  no longer plan the same connection twice.
- A skill that grows past a tool's size limit, or shrinks back under it,
  now moves cleanly between the shared copy and a copy of its own. Tools
  with no limit used to keep reading the shortened copy through a stale
  link — exactly the truncation splitting exists to prevent — and the
  change was reported as a conflict with nothing the user could do about
  it.
- Two commands can no longer claim one generated name. Names are handed
  out in a fixed order, so a command keeps the same name from one check
  to the next instead of two commands swapping bodies on every apply.
- A command whose name a skill takes over, or gives back, no longer
  leaves its old copy behind for the tools to offer under a name nobody
  declared.
- A long skill now splits at any section heading, not only top-level
  ones, so what the tool reads stays a skill instead of becoming a
  pointer. A code block indented inside a list item is recognized as
  code: it is never cut through and never reworded.
- A command too long for Codex splits like any other skill instead of
  being refused with a fix its author could not make, and the plan says
  when the generated skill also lands where Pi reads.
- A command's one-line summary comes from its own `description`, not from
  one nested under another key, and its frontmatter no longer appears as
  literal text inside the generated skill.
- A custom `GIT_SSH_COMMAND` is extended rather than replaced, so a
  catalog that needs a particular SSH key keeps fetching.
- A command that outlives its timeout now takes everything it started
  with it, instead of leaving a stray process running behind it.

### Changed

- **Breaking:** the manifest schema and install-record version move to 2.
  v0.1 files still load; the first apply upgrades them in place through
  the normal journaled, previewed plan — the upgrade changes the schema
  line and nothing else, and an interrupted upgrade rolls back
  byte-identically. Files written by a newer kendex refuse to load
  instead of being corrupted. Migration: automatic on first apply;
  `kendex import` still covers v1.

### Added

- **Breaking:** installed skills follow the surface model: tools that
  read the same folder (Codex and Pi share `.agents/skills` in a
  project) get exactly one copy rendered to their combined limits, and a
  tool whose copy must differ gets its own — identical copies still
  collapse onto one tree through links, so today's layout is unchanged.
  Migration: refresh regenerates; the journaled apply moves anything
  that needs to move.
- Render and parse warnings are now first-class: each names its item and
  tool, says what happened, and carries the fix when there is one —
  shown in the plan preview, the Sync page, and every CLI verb that
  prints a plan.
- Every catalog read goes through one sealed API: reads resolve against
  the canonical source root, symlinks in a catalog are refused loudly (a
  hostile catalog can no longer pull host files into generated artifacts
  or recurse forever), and traversal carries depth, count, and byte
  budgets. One refused item degrades to a note; the rest of the scope
  still plans.
- Source frontmatter is parsed as real YAML (block scalars, arrays, nested
  maps) with adversarial-input bounds: aliases, duplicate keys, oversized or
  deeply nested frontmatter are refused, and unknown keys warn instead of
  silently vanishing.

## [0.1.0] - 2026-08-10

First v2 release: desktop app (Tauri) + `vstack` CLI over one engine,
replacing vstack v1.

### Added

- Scan → declare → diff → apply engine over per-scope `vstack.toml`
  manifests, with preview-first, journaled, transactional applies and
  crash recovery; removals go to a trash, never a hard delete.
- Five harnesses — Claude Code, Codex, OpenCode, Cursor, Pi — behind one
  adapter seam with a single capability table gating every operation.
- Agents and skills authored once, rendered per tool; hooks, commands,
  MCP servers, plugins, and Pi extensions managed where each tool
  supports them.
- Catalog sources as plain git repos or local paths, enabled per scope;
  adopt brings hand-made files under management.
- CLI verbs mirroring every core operation: `add`, `remove`, `adopt`,
  `apply`, `refresh`, `verify`, `list`, `check`, `source`, `project`,
  `report`, `update`, `update-pi`, `import`, `init`.
- Self-updating app and CLI via a tag-driven draft-release feed.

### Breaking

- **Breaking:** fresh manifest and lock schema; v1 files are not read.
  Migration: `vstack import` converts v1 manifests and locks in place
  (originals copied to the trash first), then `vstack refresh`
  regenerates every installation.
- **Breaking:** v1 extras and theme packs are not carried over.
