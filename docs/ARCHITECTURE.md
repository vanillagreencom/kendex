# kendex Architecture

Cross-platform desktop app (Rust + Tauri) managing AI coding-harness
customizations — agents, skills, hooks, commands, MCP servers, plugins, Pi
extensions — across global and per-project scopes. Claude Code first-class;
codex, opencode, cursor, pi, gemini, and copilot behind the same adapter
seam. No server; a thin CLI mirrors every core operation.

## The one idea

Four verbs over one model: **scan → declare → diff → apply**.

- **Scan** — read harness-native directories in place, across all scopes.
  Read-only with zero adoption; nothing copies into a shadow store.
- **Declare** — a per-scope `kendex.toml` manifest is the only durable home
  of user intent.
- **Diff** — drift = declared vs observed. `kendex apply --plan` and the
  audit every app page reads are this diff.
- **Apply** — make disk match declaration, plan shown first. Adopt is the
  reverse arrow: record an observed item into the manifest. It lives behind
  a place's card on Projects — the app's one mention of unmanaged content —
  and behind `kendex adopt`. Taking over files already sitting where a
  declared item goes is `kendex apply --replace-unmanaged` scope-wide, or
  `replace_unmanaged_item` per item (revalidated against a fresh read,
  running the scope's whole plan), which Problems wires beside adopt on
  every row core reports an exit for.

Every page and every CLI verb is a projection of these four; none owns
logic.

## Vocabulary

Scope (global | project) · Harness (adapter + capability table) · ItemKind
(agent, skill, hook, command, mcp-server, plugin, pi-extension) ·
Item (logical: kind + name from a source) · Installation (item × harness ×
scope — what locks, drift rows, and applies track) · Bundle (a curated set a
catalog offers under one name, installed as one declaration) · Source (path |
git; registry reserved post-release) · Manifest · Lock (provenance + hash) ·
Observation (scanner truth) · Drift. Core modules mirror the verbs: `model`, `scan`,
`manifest`, `diff`, `apply`, `source`, `harness/` (one file per harness).

## Layout

`crates/core` — pure domain, with `quality/` holding the content rules and
both scores, disjoint from render and engine. `crates/app` — Tauri
commands, one module per page domain; events stream scan progress.
`crates/cli` — thin verbs over the same core. `ui/` — React 19 + Tailwind v4 +
shadcn/ui + zustand over generated bindings (tauri-specta). Adapters in
`core/harness/` own paths and rendering only; what each harness supports
lives in one capability table read by core and UI.

## Invariants — what the product guarantees

1. Generated artifacts are always overwritable — by us. Refresh
   regenerates from scratch and re-merges the manifest, but bytes no
   apply ever wrote are the user's: an edited installation becomes a
   conflict naming its exits (keep it as a fork, or discard the edits) —
   the Updates row offers a third, keeping the fork under a new name
   beside the source's version — and no write, sweep, refusal, or
   re-shape touches it. Discarding is an
   explicit option (`overwrite_edited` / `--discard-edits`). The anchor
   is the lock's rendered hash; a record that cannot prove which bytes
   are whose is one conflict, never one silent loss.
2. Write-only-if-absent: never clobber a user-set value; never re-add a
   user removal. This covers manifest values and unrelated
   structured-config keys; managed generated content is replaceable
   (invariant 1). The two never overlap.
3. Content hashes cover source bytes plus the manifest sections that shape
   an artifact — editing a shared key invalidates dependents.
4. Locks record durable provenance; same-source reinstall is a no-op,
   cross-source name collision is a hard error naming the original. A name
   is claimed by a lock entry or by a not-yet-applied manifest entry —
   both collide. The one sanctioned rebind is a fork the user confirmed: remote
   to `local`, recorded in `[forks.<kind>.<name>]`. A fork keeps the installed
   name so dependents and bundles resolve; one made beside (`fork_beside`)
   takes a chosen name, `name:` rewritten to match, leaving the original on its
   source. An agent's bytes come from its published file at the installed
   commit, with the catalog's tables and the person's own overrides; a rendering
   restricting it further is refused. The new name is proven free before the
   first durable write — no declaration, lock entry, folding neighbour, or
   occupied destination — and a namespaced one neither nests inside a local
   package nor reaches its slot through a link.
5. Enable/disable is non-destructive and lossless: file-backed kinds
   toggle by rename; kinds embedded in shared config files toggle by a
   structured edit that preserves every unrelated key. Uninstalling the
   app changes nothing.
6. Never touch the unowned: unmanaged files are reported, never deleted;
   foreign symlinks are conflicts, not clobber targets; adoption merges
   content, never loses it. A declaration landing on files kendex never
   wrote is a conflict with two exits:
   - **Adopt** keeps the files and rewrites the declaration around them —
     every tool the item is blocked for in one plan; tools holding
     different copies under one name refuse. Keeping declares the tools
     that had files and never narrows a declaration. A plain project skill
     moves to `.agents/skills/<name>` under source `in-place` — the tree is
     the content of record; a hook's script moves to `.agents/hooks`, its
     registration rewritten. Kinds and shapes it cannot take are refused.
   - **Take-over** (`--replace-unmanaged` scope-wide, or the per-item
     `replace_unmanaged_names` behind the app's `replace_unmanaged_item`)
     keeps the declaration and moves the files to the trash first, bound
     to the bytes the plan read. A link is never its target, nor is a
     position any install recorded writing. Whole or not at all, and both
     forms refuse: named per item, a place nothing can settle refuses the
     run; scope-wide, one swept item nothing can settle refuses it too,
     naming each with the place that blocks it, and nothing is planned or
     written. One refused at every link is named the same way: its rows
     stand, nothing replaced. The app offers adopt for unmanaged items,
     and both exits on the Problems page for a declared item's conflict.
   The row names every position in the way, which exits apply, and — where a
   position can be read in full — how it compares with the install it blocks.
   The CLI names the verb and flag under it. A foreign link pointing at a real
   skill folder several tools read offers keeping only. Exception: a link the user
   explicitly adopts that resolves to a real skill folder outside kendex's trees —
   adopt captures the folder's content, trashes the folder (bound to the exact
   bytes captured) and every sibling link reading it, and the follow-up apply
   restores the sharing from kendex's copy; the confirm names the folder and every
   tool reading it. A link at anything else stays a conflict.
   Ownership is what kendex wrote, read from the positions lock entries
   wrote (recorded for skills and codex commands, derived elsewhere) —
   never from the lock key alone, from an entry merely on the books, or
   from a project record another root wrote or naming a position outside its own root. A link the user put at a shared config file or a manifest
   (dotfiles) is not foreign: the edit goes through it, link kept, and the
   precondition binds to the bytes reachable there; whether a link may sit
   at a position is decided at plan time, never by the write.
7. Applies are transactional: preconditions revalidate against observed
   hashes immediately before mutation; pre-images are journaled first; any
   failure rolls back and interrupted applies recover on next launch.
   Removals go to a trash, never straight to delete.
8. One writer per scope: every apply (app or CLI) holds an OS-level scope
   lock; journal recovery runs under the same lock; a busy scope is a
   clear error, never an interleaved write.
9. Never mutate a working tree kendex does not own. Managed scopes are
   the only writable surface; kendex never stages, commits, or resets in
   a repository it did not create. Work that must produce a commit runs
   in a disposable clone.
10. Writes are byte-faithful where kendex edits in place: a structured
    edit changes the keys it names and nothing else, newline included,
    and a file it cannot read is refused, not rewritten. Change detection
    compares exact bytes. kendex.toml is not edited in place: a write
    serializes the manifest kendex read, losing comments and key order.
11. Validation precedes mutation. Every input check for an operation runs
    before its first durable write, and a rejected operation leaves
    manifest, lock, and install tree byte-identical. Every rendering is
    read back through the target harness's own format rules inside plan
    preview; one the harness's loader would reject is refused there, with
    the fix, for that harness alone.
12. Verification compares content, not provenance. Installed artifacts
    are re-hashed against what they should be; a matching lock entry
    alone never reports OK, and an artifact kendex cannot compare is
    reported as uncompared, never as passing.
13. External processes are hardened by construction. One constructor
    builds every invocation: redirecting environment (`GIT_DIR`,
    `GIT_WORK_TREE`, `GIT_INDEX_FILE`) cleared, every prompt path closed
    (`GIT_TERMINAL_PROMPT=0`, SSH `BatchMode=yes`), a timeout on every
    call. Work inside a downloaded cache also pins `--git-dir` and
    `--work-tree` on the command line. The raw-`Command` pattern is
    guard-banned.
14. An item is scored on its own bytes and nothing else. Where one surface
    lists many items (a plugin cache, a settings file) the scanner records
    where each item's files live. A repo-root skill's `.git`, `node_modules`
    and build dirs are not its bytes; one constructor
    (`SealedSource::collect_skill_tree`) excludes them so score, preview,
    install and catalog-check read the same files. The outcome is a function
    of exactly kind, path and name (`quality::observe::same_reading`), plus
    the harness for a hook in a shared config file, whose parser is the
    harness's; no rule reads the harness. Distinct readings run on every
    core (`core/parallel.rs`), returning in the order given; two runs over
    one disk give byte-identical output. Phrase matching skips to the next
    byte that could begin a match; all-ASCII text takes no normalizing pass.
15. An item says what it is for in its own header, from a closed
    vocabulary (`core/tags.rs`). Kind says what a thing *is*; a tag says
    what job it helps with — the only axis. Tags are never inferred from
    a name: an untagged item is untagged. A word outside the vocabulary
    is a scan warning naming the real one (`tests` for `testing`).
16. A debug build gets its own machine. Every root `core/env.rs` resolves
    hangs off `Env::home`; a build with `debug_assertions` roots that at
    `<data>/kendex-dev`. Inherited vars naming a harness root are dropped
    with it (`env/sandbox.rs`); vars naming a git host or a read-only
    policy file are kept. `KENDEX_REAL_HOME=1`, and only that value, opts
    back out.

    Three things ask `env/sandbox.rs` directly: the OS credential store's
    service name carries the sandbox (keyed by name, not path); its
    transaction lock uses the same service-plus-endpoint identity under
    the real home, so XDG relocation cannot split one credential family;
    and the real home stays reachable as `Env::real_home()`. Project
    discovery stops there, and a typed `~` means the person's home.
    Anything new that is keyed by name, or that answers a question about
    the person rather than this build's state, belongs on that list.

    Three things sit outside the boundary: a project path handed to a
    debug build is still that project (`--scope project` reads and writes
    the repository it was pointed at); a harness root set to an explicit
    absolute path is used as written; a child process inherits this
    process's environment (`process/mod.rs`), so `npm` run for a Pi
    package sees the real home.
17. One spelling per path, in and out (`paths.rs`). A root is fixed on entry —
    `Scope::canonical` in `manifest_path`, `lock_path`, `SealedSource::open`,
    `source::resolve`, `Plan::landed`, refusing an inside spelling landing
    outside the root — and never re-spelled: no comparison meets two spellings
    (macOS fronts `/var` with `/private/var`), git gets the repository's own.
    `canonical` drops `\\?\` only where a plain spelling names the same file,
    so a root may still carry one; `slashed` writes it with `/`.

## Decisions

- Tauri 2 · React 19 · Vite · Tailwind v4 · shadcn/ui · zustand ·
  tauri-specta · serde/toml.
- Vercel-inspired design language: monochrome, high contrast, minimal
  chrome. Light/dark/system only — no themes. Every color, space, and
  radius flows through design tokens (guard bans raw hex in UI code).
- A coding tool kendex writes to is a **harness**, in code and on screen
  (`HarnessId` in core, "Harnesses" in the sidebar). Never "tool" on screen.
- Hue carries exactly one meaning: **which harness** (`--tool-*`, one per
  harness). Status keeps the semantic tokens; item kinds are told apart by
  icon. One exception: a kind icon takes `--customized` where the package
  is changed, on a Library row and on its own page; the table prints the key.
- In a table, a harness is its mark (logo + hue), name on hover and for
  screen readers. Where a tool is stated once — a package's own details —
  the name is written out.
- A status a colour can carry is a dot; words on hover and in a screen-reader line.
- Four type steps, no fifth: page title (24 semibold), section title (15
  semibold, full contrast), row label (14 medium), description (13 muted).
  `components/section.tsx` owns all four. A heading outranks what it introduces.
- Space groups things; boxes are for objects. A settings or detail surface
  is `Section` + `SettingRow`, never a stack of cards. A `Card` is a discrete
  thing a person acts on as a unit — a bundle, a problem, an error, a place.
- A border means "you can act on this": buttons and inputs carry one; chips
  and badges are a quiet fill with no border. Nesting stops at the card:
  inside one, groups use dividers, a tinted band, and space.
- `--muted-foreground` stays legible against card and page in both themes;
  no surface dims it further with an opacity suffix.
- Three surface planes, back to front: sidebar, page, card. Every page
  draws width and gutters from `lib/layout.ts` — two widths only, a reading
  measure and full-width for data-dense tables.
- One search box per page that lists things (Library table, Marketplaces'
  Packages tab); "/" focuses the one on screen, or goes to the Library from
  a page with none. A search never filters a page you can't see.
- Location filtering belongs to the Library's table only; every other page
  shows every scope. The Packages tab's `Where ▾` picks the destination a
  package installs to, not a filter.
- My Library holds what is installed; Marketplaces (Subscribed / Packages /
  Community / Mine) holds what could be. Only Marketplaces' nested pages — a
  marketplace's detail, a curated set, an available package — carry a
  breadcrumb. The Library's From column and the package page's From line
  read one provenance join.
- Harnesses and Projects are two sidebar destinations. Where a harness
  keeps its files is edited on that harness's own row.
- Content a tool ships with itself (Codex's and Claude Code's bundled
  plugins) belongs to that tool. `core/vendor.rs` reads ownership off the
  plugin registry a plugin names; an unknown registry is the user's.
  Vendor-owned content is scored by nothing and asked about nowhere: listed
  in the Library, labelled with who ships it, left alone.
- A package's page tabs `Overview · Projects · Safety score · Customize`; Customize
  is last, the only tab a kind can lack. Projects lists each place installed in,
  with its update and removal; the header's `Delete` takes every copy. Safety score
  carries the automated check's finding. Customize edits instructions, the skills an
  agent gets, per-tool settings, and a skill's own declared settings; the Customize
  page keeps what is not about one package (the `all` row, custom hooks, a project's
  skills folder) plus an index of what is customized there. Both edit one manifest
  draft per scope; the package page adds a settings draft, and one Save bar writes
  both as one transaction (`stores/editor.ts`; reloads only when nothing is unsaved).
  `lib/customization.ts` slices it, `lib/settings-rows.ts` the rows.
- A place is customized by settings, a settings value off its package default, a
  hand edit, or a fork, and `lib/customized-places.ts::placeStandings` is the one
  answer, over a `PlacesSource` only `placesSource` builds. Its readers are what
  `grep -rn placeStandings ui/src` finds, the Customize index
  (`lib/customized-here.ts`) among them: it reads the drafts open for its place and calls
  nothing customized until every read lands (`lib/updates-read-state.ts`: pending is checking, failed is packages missing).
- Hook events have one vocabulary — Claude Code's names, in
  `core/hook.rs::EVENTS`; every other harness's map is keyed by it. The
  picker offers that list, the validator rejects anything outside it, the renderers read it.
- **One hook model, two authors, delivery decided by capability.** A
  catalog hook and a manifest `[[custom-hooks]]` entry both become a
  `HookSpec` (`core/hook/spec.rs`) — script-bodied for the catalog,
  command-bodied for the person — and `core/hook/delivery.rs::delivery()`
  says how a spec reaches each harness × scope: `Registered` (the harness's
  own hook file — enforced), `InAgentFile` (Claude's per-agent `hooks:`
  block — enforced, for scoped hooks), `Advisory` (prose in the agent file,
  matcher restated, warning attached), or `NotInstallable` with the reason.
  Engine, agent renderer (a registered hook never also renders as prose) and
  editor all read that one decision. `agent_scoping()` decides scoped
  enforcement: Claude carries hooks in the agent's own file; everything else
  is `None` until a vendor's payload reference proves the agent is named at
  runtime. An every-agent custom hook on Claude registers in
  `settings.json`. A custom hook's name is its identity (lock key
  `hook:<name>:<harness>`); the editor derives one from command + event on
  first save and writes it back; what it registered is recorded like any
  other hook's. Custom hook commands are scored by the same safety rules as
  catalog scripts.
- A section with nothing in it is not rendered; an empty state appears only
  when the page would otherwise be blank, its read done. Skeletons draw
  mid-read; a failed read shows its error with a retry, kept figures headed
  as the last kendex could check, never a definite count — least of all
  zero. Every read the app starts with runs beside the others.
- **Discovery is unsigned; one pinned key covers a document binding each
  download to its release and target.** Off the launch path, one check at a
  time machine-wide reads the feed six-hourly at most, keeps the last
  document, follows no final link; nothing gates it; debug builds alone honor
  `KENDEX_UPDATE_FEED`. Replacing needs the running path writable, outside a
  system prefix; a package prefix names its command, the card says which,
  anything else neither. Either shell carries its own command, marker last.
- Commands that touch disk, git, or a subprocess are
  `#[tauri::command(async)]`. Only window operations stay synchronous.
- No database: manifests, locks, and native dirs are the state; scans are
  in-memory views (startup, focus, watch); app prefs in one settings file.
- **The Linux app decides its display environment once, before GTK
  starts.** It reads the session and relaunches itself once
  (`crates/app/src/launch_env.rs`) with whichever of `GDK_BACKEND` and the
  WebKit DMABUF workaround the session needs, or not at all; the
  environment is never rewritten in place (the workspace forbids `unsafe`).
  Only the AppImage is pushed onto a backend, and only onto `wayland,x11`,
  overriding the bundled hook's `GDK_BACKEND=x11` pin and printing the
  override's name. `KENDEX_GDK_BACKEND` is honoured on any session and never
  overridden (`KENDEX_GDK_BACKEND=x11` is the recourse). `GDK_SCALE` and
  `GDK_DPI_SCALE` are never written.
- **Zoom is the webview's, applied before the window is shown.** The
  window is configured hidden and revealed in `setup` once the saved zoom
  is on. The range lives in core and reaches the UI as a generated
  constant. Floor and ceiling bind controls and settings file alike (values
  outside are clamped both ways); the step is the controls' alone, so a
  hand-edited 137 is honoured. A webview that refuses the size opens at full
  size. The size on screen is read back from the webview on load; the
  stored percent stays a preference.
- **Zoom moves in steps and writes once the stepping stops.** Two inputs,
  one step per press: held `Ctrl` `+` and a clicked button (no slider). The
  window follows every step; the settings file is written once the steps
  stop, both inputs sharing one timer. The shown size moves on press, ahead
  of the window's reply. Two values, each with one writer: what the app
  shows (on press, and back from the window on a refusal) and what the
  settings object holds (when the file does); the first stays out of the
  settings object. The size reaches the file through its own command
  carrying only a percent; a copy read before a resize is refused as stale.
  At most one save in flight; asks during it collapse into one follow-up.
  A commit waits for every resize still out and then asks the window what
  size it is at, so a size the window refused never reaches the file; a
  size the file refuses stays on screen. The close is not held for an
  in-flight write.
- **A whole-file write carries the base of the file its copy came from.**
  The Customize tab's `kendex.toml` and the Settings page's app
  `settings.toml` are read as content plus a `Base` (`kendex_core::base`,
  the hash of the bytes read) and written back with it; different bytes on
  disk refuse the write as `stale` (`WriteRefused`), which the page renders
  as a choice, never a silent overwrite. The manifest write binds the base
  into its plan op's precondition (`PlanOptions::manifest_base`); every
  settings write, whole-file or targeted, runs under one OS file lock
  shared by the app's threads and the CLI, so the check and the write
  cannot be split.
- **Every atomic write gets its own temp file.** `write_then_rename` names
  its temp file per write, not per process.
- GUI + CLI are equal thin shells over `crates/core`; most core ops are
  reachable from the CLI, two are app-only — install-beside
  (`fork_beside`) and per-package update (`package::update_one`). The CLI
  reaches neither; `refresh` and `updates --apply` bring a whole place
  current through `engine::plan_apply`. The guard chain gates commits; the
  review gate and the merge queue's suites gate PRs.
- Every capability ships cross-harness through the capability table; a
  harness without native support for a kind is marked unsupported — never
  shimmed. Where a vendor stores one surface as another (Codex: prompts as
  skills), the table names the stored kind and the lock records what was
  written.
- **The table says what a verb means, not only whether it exists.** Beside
  op × scope it carries whether a hook the tool loads is executed or only
  read as prose, and the MCP transports the tool speaks. `managed` never
  implies enforcement: an advisory install says so in the plan preview, the
  report, and the tool's card. A column exists only if a verb reads it;
  what a tool's own config holds down (Copilot's `disabledSkills`) is
  reported per item where it is read.
- **An adapter claims only its own namespace.** A file belongs to the tool
  whose namespace it sits in; a cross-read (Copilot reading Claude Code's
  skills and settings) is an input to effective state, never a second
  installation.
- Fresh manifest schema, no importer and no compat shims: a manifest or
  lock from any other version is refused, moved aside by hand, install fresh.
- **One spelling per artifact.** A scope is `kendex.toml`,
  `.kendex-lock.json`, `.kendex-local/`, `kendex.settings.toml`; env vars
  are `KENDEX_*`; managed-block markers, report tags and the opencode
  hook-file prefix write and read that one spelling. No older product
  name is read anywhere, and nothing converts one.
- **The default catalog's repository is `vanillagreencom/kendex`.** Fresh
  scopes seed source `kendex` at it. Subscriptions are matched by what a
  declaration names, never by literal spelling
  (`source_ref::owner_repo`/`repo_identity`, which fold `.git`, case and
  URL shape); the remote store keys its cache off the clone URL instead,
  so two hosts serving one `owner/repo` never share a mirror.
- **Commits walk through the guards whatever tool makes them.** The checks
  are the growth-guards package's shell scripts, committed under
  `.agents/skills` — size-ratchet, todo-ban, byte-ceiling, suppression-ban, conflict-markers, changelog-entries,
  prose, commit-msg, and preflight's staged lanes. git's own `.git/hooks` shims run them: no kendex binary is in the
  path at commit time, and since git clones no hooks, a clone carries the scripts and one `guard install`
  arms them. kendex implements no check — `guard install`/`guard uninstall` run the installer, every CLI verb
  that drops a package runs its declared uninstaller before the files go (`engine_common::apply_report`, the one
  executor of an `EngineReport`), and `guard run <hook>` execs its script with git's redirects passed through, the
  one child not scrubbed because it is a hook body naming the snapshot judged. `guard check` asks the package too.
  `kendex check` relays that same `--check`: the package's sentence and exit where it has something to report, a
  clean result folding into kendex's own all-clear. It asks only where a project's lock enables the skill AND the
  helper is already in `.git/hooks` — git clones none, so that file is the local arming that licenses the run.
  So there is one implementation of every verdict and one policy dialect:
  the flat `GROWTH_GUARDS_*` / `SIZE_RATCHET_*` keys, baselines and
  excludes the scripts read from the commit. Every enabled check runs
  before the verdict; exit 1 (violations) and 2 (could not run) both block,
  and a measurement that fails is exit 2 rather than a silent pass. Which
  repository a commit targets is git's question, answered where the target
  has an armed hook: the `pre-commit-check` PreToolUse hook reads a commit
  out of a command's whitespace-separated words, defers where both git hooks of
  its own working directory carry the marker and run, and refuses the commit
  otherwise rather than running the repository's own scripts on its behalf:
  arming is the local act that asks for that, and a clone carries no hooks.
  Sidestepping an armed one is refused, whether by the no-verify flag, a cluster
  holding its letter, or a word carrying a `core.hooksPath` key: git skips
  commit-msg too, unjudgeable here. It reads no shell, but first removes what
  bash removes while assembling a word — quotes, an unquoted backslash, a line
  continuation, brace-expansion braces — and splits on bash's own
  metacharacters, so the word judged is the word bash would hand git: a bypass in a message, a heredoc or a comment
  reads as one, and a bypass assembled any other way, through an alias or an
  `include.path`, does not.
  It gates its working directory only, naming the one it judged where it cannot
  defer; an unreadable payload is a refusal, as is unarmed.
- **kendex carries no migration machinery.** Breaking changes are a
  changelog entry and a fresh install, never compatibility code: a path
  kept for a population nobody measured is machinery that has to be
  correct forever for nobody. Earlier generations armed commits through a
  hooks directory inside the git directory with `core.hooksPath` pointed at
  it, and converted v1 settings on demand; neither is detected, undone, or
  converted here. `guard install` runs the package's installer, which
  stands down and reports when `core.hooksPath` is set to any value at all,
  its own hooks directory included — whoever set it undoes it, and
  the changelog says which artifacts an old install left behind.
- **A registration is reconciled, not added to.** What a hook registered
  is recorded (`engine::item_record`); a catalog moving it to another event
  retires the recorded entry where the document still has it, applies what
  is rendered, records that. A first install retires nothing, and neither
  does an answer short of certainty: an entry moved, duplicated, or
  unnamed by the record is the person's to keep, and the pass registers
  under the identity it renders beside it (`item_record::retire_previous`).
  Pi holds instead: its registry is kendex's own file, so an entry there
  the record cannot place is a question the hook waits on. Removal reads
  the same record; an editor rewrites only its own registration; an entry
  no edit of kendex's can reach is neither reconciled nor retired — proven
  by applying and reading back.
- **Pi hooks are enforced through the carrier.** The `pi-hooks` extension
  package hosts native listeners; hook content rides in the registry
  kendex renders beside them (`kendex/hooks/<name>.sh` plus
  `kendex/hooks.json`, keyed by Pi's listener names — tool call, tool
  result, turn end, session start). Pi reserves `hooks/` beside every root
  it loads, so storage sits under `kendex/` and nothing reads or writes a
  registry beside the root — [docs/adapters/pi.md](adapters/pi.md) carries
  the rules in full. The capability row says what the mechanism supports;
  labels read carrier reality (`pi_ext::carrier`), and Pi loads project
  and global settings both, so a project-installed hook with only a global
  carrier is still enforced. The session-start drift report rides the same
  mechanism: same script, same kill-switch, fire-and-forget into session
  start; a reloaded or resumed session never repeats it.
- **A settings template applies once, when its skill arrives.**
  A skill's `# required` keys are written into `kendex.settings.toml` when it
  arrives, write-if-absent, and arrival is the consumer's `kendex.toml` gaining
  the declaration — committed state, so a clone carrying no lock re-arrives
  nothing. Nothing else writes there but a save from the app, which inserts
  the key it names with its comment block so the value has somewhere to land;
  a block already in the file is the consumer's, and no revision follows it
  in. Seeding never touches a value; an edit rides that write, its span alone.
  The rules an author works to — the marker, the presence check, conflicting
  defaults — are [docs/authoring/settings.md](authoring/settings.md).
- **Schemas are versioned and nothing converts them.** Manifest and lock
  carry a format version, and this build reads exactly the one it writes.
  A file from an older kendex is refused as unreadable, left byte-for-byte
  as written, with the move-it-aside-and-install-fresh remedy in the
  message; one from a newer kendex refuses to load for the same reason in
  the other direction.
- **Permission intent is typed and never widens.** A source's tool
  allowlist survives parse, merge, and every renderer as
  `Unspecified | AllowOnly | DenyExtra`; explicit denies survive allowlist
  subtraction. A surface that cannot express the intent renders the most
  restrictive expressible form or refuses with a conflict row, and a
  refusal also removes the older, wider rendering. Converting an allowlist
  to a deny-list by complement is forbidden.
- **Catalogs are adversarial input.** Every catalog read goes through
  `source_read`: resolves against the canonical root, refuses symlinks,
  carries depth/count/byte budgets; raw filesystem reads over catalog
  paths are guard-banned. Frontmatter parses as real YAML (aliases and
  duplicate keys refused, bounds enforced); every interpolated value in a
  generated file is quoted.
- **The source store is immutable; revisions are declared.** Each commit
  is materialized once into a directory named after its object id,
  published by rename, read unchanged thereafter; fetching touches only a
  bare mirror beside it. A full commit id is a pin (once cached, no
  network); a tag or branch is a tracking selector re-resolved on each
  refresh and previewed like any upstream change. The manifest holds what
  is wanted; the lock records which commit that came out as, a fallback
  only for the exact declaration that produced it. Offline with an uncached
  pin is a hard error naming the pin; installed content keeps working.
  Materialization runs under a per-repository cache lock; a second resolver
  waits half a second, then gets "cache busy" — an error for a refresh,
  "not fetched yet" for a read of that one source. An item declaration may
  hold its own `rev`, outranking the source's, always a full commit id:
  `kendex pin` and the version picker resolve tags and branches at write
  time. Holds flow through derivation — a pinned bundle pins its members, a
  pinned skill's dependencies read the pinned catalog, two parents
  demanding different revisions of one dependency conflict and write
  nothing. A held item hashes clean against its held tree; the Updates page
  asks the mirror (pinned sources too) what newer content exists, its
  timeline listing only commits that touched the package's files,
  tag-decorated, never tag-replaced. `UpdatesReport::last_fetched` dates
  the standing — the newest successful fetch among the sources the scope
  installs from, the newest across scopes in the overview — so "Everything
  is up to date" is dated too. Rows are per package per scope, folded by
  package and expanded by place; `PlanOptions::update_only` names what a row's
  Update or a place's Update all moves; apply and refresh a whole place. Flipping
  Follow source is one row's state change, its write settling behind it
  (`ui/src/stores/updates-follow.ts`): the switch takes its position from
  the click, pending until every scope's standing is read again — every
  landing wears it, so a read cannot bounce it — over its own scope's rows
  only (`lib/updates-read-state.ts::rowUnsettled`), the apply reaching only
  what is installed there. A refused write says so at once and puts the
  switch back where the click moved it from; the next landing carries the
  engine's own answer. An edited place is never updated over:
  its row says so and offers the install beside it where a newer version
  the source still carries can land, and a
  link to the package page otherwise; the fork-or-discard choice lives on
  the package page. Commit ids stay behind the table's `…` menu. Muting a
  package's update notifications is a machine-local settings entry. Reuse
  is verified against a publish receipt outside the checkout: a full
  content hash of the tree and the rules that materialized it, so a
  checkout an older kendex wrote is rebuilt rather than reused. Pre-2.0
  clones are read where the new layout has nothing yet, never deleted.
  The store keeps one tree per resolved commit; nothing prunes it;
  deleting the cache is the only cleanup.
- **A subscription reference is parsed, never guessed; one repository
  subscribes once per scope.** Two validators in `core/source_ref.rs`: the
  typed one (Subscribe dialog, `marketplace subscribe`, `source add`,
  `add`'s positional source) accepts `owner/repo[@rev]`, any-host remote
  URLs kept as typed, local paths, GitHub tree URLs, skills.sh package
  URLs; the untrusted one (directory rows, collections, deep links) is
  GitHub-only and normalizes to `owner/repo`. Both refuse a leading `-`,
  `..` in repository components, and percent-escapes that would smuggle a
  separator, decoding exactly once. A tree URL subscribes the whole
  repository and surfaces the package path as a lead, never an identity;
  its `<ref>` resolves against the mirror's real refs (branch names contain
  `/`); two split points both naming refs, or a branch and tag sharing a
  name, refuse naming every candidate; offline, normalization refuses
  before any write. One repository per scope by canonical identity
  (`repo_identity` folds `.git`, a trailing slash, every GitHub spelling,
  and host case), the refusal naming the existing subscription. The default marketplace is found by repo: two
  prefer the seeded name, else refuse naming both; none is a typed error.
  Installing into a project from a personal subscription copies the
  declaration into the project in that plan — one scope mutated, the
  personal manifest read-only, the cache shared.
- **A name says where it comes from, or the search does — never a
  fallback.** Every installable kind declares through `add`
  (`engine/ops/add`): agents, skills, hooks, commands, MCP servers; Pi
  extensions are carrier-only and a direct add is a typed refusal. The
  qualifier is `marketplace::name` (`add/place.rs`) — `::` never appears in
  an item name; `/` means `plugin/item` or, positionally, `owner/repo` —
  resolving against subscription aliases only, refusing with the
  subscribed list on no match. A bare name searches every enabled
  subscription in the scope for its kind: one offer installs, two refuse
  printing the `::` spellings beside each subscription's canonical repo,
  zero is not found with the fix named. `default_source` serves only
  requests naming no item (`--all`, a bare bundle). Installing a whole
  bundle subsumes, in the same plan, already-declared members whose
  effective options equal what the bundle derives (`add.rs`); a
  member the user shaped keeps its declaration, the preview saying why.
  `[bundles.<name>]` is keyed by bare name; a second marketplace's
  same-named bundle is refused naming the first.
- **A plugin-registry-shaped catalog is recognized, never guessed.** A
  source is read one plugin deep (`plugins/<name>/{agents,commands,skills}`)
  exactly when it carries `.claude-plugin/marketplace.json`; a `plugins/`
  directory alone is not evidence. An item resolves only under a plugin the
  registry validated, and only entries pointing at a directory inside the
  repository are consumed; an entry naming another repository or a URL is
  skipped with a finding. A registry disagreeing with a plugin's own
  manifest about name or version, a plugin describing parts outside
  itself, and two names one filesystem would fold together are findings
  with a fix. Registry metadata (category, version, author, license,
  homepage, the plugin's items as a named group) is read-side only.
- **Any repo holding skills is a marketplace — discovered from a closed
  table.** `source/discover.rs` owns a versioned search table
  (`DISCOVERY_VERSION`, part of the safety-cache key): `skills/` and
  `skills/.curated`, each harness's project skills dir (pinned to the
  adapters by test), `<dir>/**/SKILL.md` up to three levels down —
  stopping below a found skill, skipping `.git`, `node_modules` and
  friends — and a repo-root `SKILL.md` as a one-skill repo named by its
  validated frontmatter `name`, else by the repository leaf the caller
  passes. The table yields skills only; hooks, MCP servers, commands and
  agents install from a declared kendex layout, `kendex.toml`, or a plugin
  registry. Precedence, fail-closed: `.claude-plugin/marketplace.json`
  wins outright and root dirs are not read; else a parsed control file
  declares the fixed layout (`[catalog]` overriding which dirs) and the
  search table stays out; else the search runs. A control file present but
  unreadable, or a wrong-typed `[catalog]`, makes the source unusable with
  a finding. Every probe goes through `SealedSource` (symlinks skipped,
  budgets held, hard caps on found skills); items dedupe by normalized
  repository-relative path, never `canonicalize`; two directories folding
  to one name are **both** skipped with a finding naming both, identical
  bytes excepted. A frontmatter `name` disagreeing with its directory is a
  finding (the directory is the identity); submodule or LFS pointers under
  a recognized root are findings, not hydrated. A name with an invisible or
  direction-reversing character is refused (`names::segment_problem`) and
  shown escaped (`names::shown`); a declared-layout catalog lists only
  names that install. The walk stops at its skill cap. `source/about.rs`
  renders the one typed report the About tab and `kendex index` consume.
- **Browsing is a read-side join; installed state is derived, never
  stored.** Every `source/browse.rs` read takes a `Catalog`,
  `Subscription { scope, source }` or `Repo { repo }`, so a listed
  marketplace opens before anyone subscribes. Each row's state is joined
  from the scope's manifest and lock on every call — installed is a lock
  entry from this subscription, "partly installed (2 of 6)" is counted
  from a bundle's members; with no subscription the join answers Available
  and judges name clashes against the personal scope. A name another source holds is surfaced on
  the row (`collision`); the refusal stays in the engine (invariant 4). A
  bare repository is fetched by `remote::sync` into the store under the
  canonical `owner/repo` every GitHub spelling folds to — the key Subscribe
  is prefilled with; only GitHub opens blind (`NotBrowsable` otherwise); a
  root skill's file list and reads are confined to the skill tree.
  `browse::summary` refreshes (a failure is a warning over the store's
  copy) and names an enabled, readable subscription this machine holds;
  `useCatalog` moves the page onto it. Installing needs a subscription;
  `RepoAction` offers the one step: Subscribe when none declares the
  repository, Turn on when a declared one is off, Refresh when declared
  but unreadable, neutral until a read has landed or left rows. Pre-install
  safety (`browse/safety.rs`) scores catalog bytes with the rules an
  install runs and caches **findings and scores only**
  (`<key>/<commit>.safety/…`, never inside the receipt-signed checkout),
  keyed by content hash plus rule-set, discovery-table and record-format
  versions, each verified before reuse. Advisory like every reading of the
  score — a preview, never a gate. `library.rs` is the same join for the
  Library table: subscription, local content (with what a fork replaced),
  or observed-and-unmanaged.
- **A subscription's closure is derived by re-expansion; unsubscribing
  removes or keeps exactly it.** `engine/detach.rs` expands the installed
  set with the source present and again with its declarations gone, then
  diffs; a member another marketplace's bundle carries stays. It refuses
  while the source cannot be read. **Remove** drops the closure's
  declarations and sweeps their installations (orphan removal filtered to
  exact kind+name pairs); an edited installation is never swept without
  `--discard-edits`. **Keep** copies each installation's *source-form*
  bytes — read through the sealed catalog at the exact commit it installed
  from, a parent skill excluding any nested child skill — into the scope's
  local source, flips the declaration to `local` with fork provenance, and
  removes the subscription; local writes are ordered before the manifest
  flip in one plan (invariant 11). Keep refuses an edited package (fork,
  install beside, or discard first; hooks are compared to what apply wrote)
  and preflights the local target: a symlink, a case/composition-folding
  sibling, or different bytes there is a refusal (invariants 4 and 6). The
  local source lists a `plugin/item` name beside a plain `plugin`.
- **The machine seam reads through the same core installing does.**
  `check_catalog.rs` owns three authoring passes — structural (would a loader
  hold this), settings (a template, read to the shell loaders' grammar, one
  corpus pinning both) and safety (install rules) — behind `kendex check
  --catalog [--json]`, indexer scores and preflight; the CLI prints lines or
  a versioned envelope (`schema`, findings, counts, `ok`). Breakage fails the
  check, settings findings under `--strict`; safety never.
  `source/index.rs` emits the per-marketplace summary the community
  directory reads (`kendex index [<dir>] --json`, schema 2, plain directory,
  no network): metadata from the catalog's `[marketplace]` table
  (`source/meta.rs` — read-only, strings capped, control-char-safe),
  packages from `list_items` (pinned by test), check-pass safety scores,
  bundles with members, About rows, findings. Field order in both JSON
  shapes is the schema: serde structs, no maps. `kendex marketplace check`
  aliases it with `--strict`, same exit codes. A finding's message says what
  the rule fired *on*, never where: location is its own field, since
  rendering moves content between files (Codex renders a command as a skill
  tree). A digest for unprintable content is `DIGEST_CHARS` wide.
- **The community directory is read like any remote: strictly, capped,
  honest about staleness.** `index.rs` re-parses the schema-1 payload
  `source/index.rs` feeds kendex.ai under the site's own caps, refusing
  structural problems whole, dropping only unusable rows. `generation.rs` is
  the one cache mechanism: an endpoint-keyed generation written atomically
  under `Env::registry_cache_dir`, a failed refresh serving the last fetch as
  stale. `cache.rs` adds the directory's one-hour TTL; the identity (`me.rs`)
  has none, is keyed to its sign-in, and is forgotten on sign-in, sign-out and
  expiry. All reads go through the `Fetch` trait (curl via `Hardened`, plain
  http only under `KENDEX_API`); tests inject transports. Bearer calls route
  through `registry/client.rs`: one named cross-process lock serializes login,
  logout and refresh rotation, saving rotations before retry. `skillssh.rs`
  pins its public wire schema and kill switch (`KENDEX_SKILLSSH=off`); a hit
  is a lead, never an identity, and installs through the same subscribe path.
  Collections and deep links arrive with W3/W4.
- **Intent in the manifest, closure in the plan, edges in the lock.** The
  manifest records choices, never consequences: items asked for, bundles
  installed, optional dependencies taken, what stays removed. A bundle's
  members and a skill's dependencies are derived on every plan. The lock
  caches why each installation exists as typed edges (`requested`,
  `required-by`, `member-of`); losing it loses nothing. Uninstalling a
  bundle: members whose only edges came from it go; members also requested,
  required by a survivor, or carried by another installed bundle stay — the
  preview names both halves and the reason. A member the user removes is a
  suppression, as a dependency's is: refresh honors it, while
  `--keep-declaration` writes none and refresh puts it back; the audit
  reports the bundle with members held back. Writing it asks the lock and
  the catalogs, recording anything either names. A removal naming an
  installation goes even with its catalog unreadable; one nobody named is
  kept. Declaring the item outranks a suppression: it installs, reported.
  Two sets carrying one member and asking for it differently: the tools are
  both, a set switched on installs it switched on, anything else is a
  finding naming both. Authoring lives with the catalog — `[bundles.<name>]`
  in the source's own `kendex.toml`, or nothing for a plugin-registry-shaped
  catalog — and a set's members are its own catalog's items.
- **A namespaced name is the identity; the separator is per tool.** Items
  from plugin-registry-shaped catalogs are `<plugin>/<item>` in manifest,
  lock and UI. The `/` never reaches disk: the halves are joined — `__` by
  default, `-` where names must be lower-kebab — by a rule beside the name
  rule in `harness/caps.rs` and checked against it, and rendered copies
  carry the installed name (SKILL.md and agent frontmatter rewritten; the
  catalog keeps what it wrote). Two declarations landing on one file — `a/b`
  against a literal `a__b`, or two names a filesystem folds (case, trailing
  dots and spaces, Unicode composition) — install neither, naming both. Only
  agents, commands and skills may carry a plugin segment; a `/` in a hook or
  MCP server name is refused. `kendex.toml` refuses any name that cannot be
  a path (`..`, device names, trailing dots, overlong components, a stray
  `/`). Control characters in a catalog's words are shown, never acted on.
- **The surface model.** Rendered skills are per-harness variants
  deduplicated by content hash. Harnesses reading one physical directory
  form a surface group carrying one variant, validated against every
  member's loader; a variant whose bytes match the shared tree collapses
  onto it through a relative — committable — link, a divergent one gets its
  own tree, and the move runs both ways as a removal plus a write. No
  harness caps a SKILL.md body, and every harness but Claude Code reads a
  project's `.agents/skills`, so one tree serves all; copy delivery writes
  each harness's own directory. A refusal is per surface; name rules live in
  `harness/caps.rs`, never literals. A surface is one file per item, one
  directory per item, one structured file, or a directory of structured
  documents (Copilot loads every `*.json` in its hooks directory); where
  entries inside are the items, a document holding none reports none.
- One model-alias table for every harness: bare tiers resolve per harness,
  `inherit` is expressed in each tool's own dialect, explicit vendor ids
  pass through.
- **Propagation into consuming repos is local, never a pull request.**
  kendex reports drift to the agent at session start and a local refresh
  brings the repo current; opening PRs there is a permanent non-goal
  (invariant 9).
- **Session start reads a snapshot; the background job earns it.** The drift
  contract is `kendex check`: exit 0 clean / 1 drift or unevaluated / 2
  could-not-check (unknown outranks drift), `--quiet` bounded and silent
  when clean, `--json` for machines. It reads manifest, lock, the per-scope
  drift snapshot (`core/drift/snapshot.rs`) and per-mirror fetch stamps — no
  source trees materialized, no catalogs hashed, the guards' `--check` the
  only per-package subprocess. A declaration with no lock entry whose files sit in
  place gets its own section, stating what a stat proves and carrying the
  plan as remedy. `updates`, `refresh`, `apply` and the detached `kendex
  source refresh --stale` it spawns (TTL 6h, per-mirror lock, no stdio,
  never waited on) re-derive the snapshot. A mirror that moved since its
  last evaluation is unevaluated; a fetch failure older than twice the TTL
  is a report line dated from a monotonic first-failure stamp. Held and
  ignored packages are silent in the agent report, held-ness deriving from
  the effective installation graph — own pin, pinned source, pinned bundle,
  pinned dependency parent — and every read API says when it cannot answer
  (typed warnings, never an empty result). The hook relaying it is
  first-party, shipped in the binary, offered at project registration, never
  fetched from a catalog, and still a declared, user-approved per-scope
  install rendered and removed like any other hook.
- **One presentation layer, two renderings** (`crates/cli/src/ui.rs`). Every
  human line is escaped there, a payload is not, and stdout stays clean;
  `ui::intro` arms the framed rendering, so a verb that opened none prints
  the plain lines scripts parse. Framing needs a terminal on *both* streams;
  `KENDEX_UI=plain|pretty` overrides. Non-interactive stays a mode, not a
  fallback: every verb completes without a TTY, selection flags suppress
  prompts, one needing input fails naming the flag before its first write,
  and `add` picks harnesses and delivery at a TTY, its flags saying the same
  without one. A writing run closes on the outcome ledger
  (`commands/ledger.rs`): wrote, skipped, flagged, a next step under each
  nonzero part.
- **Two scores, never averaged; both advisory.** Safety answers "is this
  dangerous"; quality answers "is this well made". Neither holds anything
  back: severity is named in words, never color-only, and install, update
  and apply proceed regardless. Every surface shows the score with its
  findings; the CLI prints a score line then one per finding, no fix line.
  Safety is `100 − Σ deductions` (Critical 25 / High 15 / Medium 8 / Low
  3), first hit per rule at full weight, repeats a point each up to as much
  again. Quality is wshobson's weighted-dimension model, static layer only:
  no LLM judge, no simulation, no letter grades. `quality::AuditResult`
  (safety, quality, findings, skipped, ruleset) is what every scored shape
  embeds: `engine::ItemSafety` for planned and installed rows
  (`engine/scoring.rs`, `engine/observed.rs`), `PackageSafety`
  (`browse/safety.rs`) and `CheckedItem` for what is not installed; the
  bound shapes flatten it, so TS reads their fields at top level.
- **Rules read typed per-kind inputs and say when they cannot read.** A
  skill carries its whole tree, a hook its registration and script, an MCP
  server its command, args, env and headers, a plugin its manifest and
  lifecycle scripts. A rule whose bytes are not in this path's input
  reports itself not applicable. Bytes that will not decode as text are
  read lossily and the replacements reported. A matched token never
  appears in any message, log or record — only a fingerprint.
- **The file a harness loads is scanned at full weight, fences included.**
  A fenced `sh` block in a SKILL.md *is* the instruction, and a switch
  counts wherever it stands as code rather than in a markdown code span.
  One severity less for content that is plainly quoting: a blockquote, and
  a skill's supporting files (`tests/`, `fixtures/`, `references/`).
  Secrets never weigh less anywhere.
- **Rule severities are calibrated against real catalogs.** Deobfuscation
  reports only what has no typographic use — invisible and bidirectional
  characters, letters imitating other letters — while normalizing emoji
  and compatibility forms silently. The confusables table covers Cyrillic,
  Greek, Armenian, Cherokee and the Latin-extended, phonetic and
  small-capital letters that imitate ASCII; it is not the whole of
  Unicode's data and the module says so.
- kendex never emits a pasteable command line: errors, hints, and recovery
  instructions present the verb and its parameters as data. The one
  exception is the session-start drift report: each line may carry a
  remedy built only from a fixed template set (refresh, remove, add, fork,
  apply --plan) with validated identifiers in argument positions;
  free text from sources or errors renders in quoted informational
  positions, never a command position.
