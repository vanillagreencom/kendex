# kendex Architecture

Cross-platform desktop app (Rust + Tauri) managing AI coding-harness
customizations — agents, skills, hooks, commands, MCP servers, plugins, Pi
extensions — across global and per-project scopes. Claude Code first-class;
codex, opencode, cursor, pi, gemini, and copilot behind the same adapter
seam. No server; a thin CLI mirrors every core operation so consuming-repo
automation (refresh, report, …) keeps working.

## The one idea

Four verbs over one model: **scan → declare → diff → apply**.

- **Scan** — read harness-native directories in place, across all scopes.
  Useful read-only with zero adoption; nothing copies into a shadow store.
- **Declare** — a per-scope `kendex.toml` manifest is the only durable home
  of user intent.
- **Diff** — drift = declared vs observed. The Review & apply page is this
  diff.
- **Apply** — make disk match declaration, plan shown first. Adopt is the
  reverse arrow: record an observed item into the manifest. It lives on
  the Library's Installed tab, beside the item, because it is an offer a
  person takes up rather than work the diff owes; the Review page is for
  what needs deciding and what needs applying, and counts what it does
  not manage as a footnote pointing there.

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
   conflict naming its exits (keep it as a fork, or discard the edits),
   and no write, sweep, refusal, or re-shape touches it. Discarding is an
   explicit option (`overwrite_edited` / `--discard-edits`). The anchor
   is the lock's rendered hash — what apply last put on disk — and a
   record that cannot prove which bytes are whose holds too: one
   conflict, never one silent loss.
2. Write-only-if-absent: never clobber a user-set value; never re-add a
   user removal. This protects manifest values and unrelated
   structured-config keys — managed generated content is replaceable
   (invariant 1); the two never overlap.
3. Content hashes cover source bytes plus the manifest sections that shape
   an artifact — editing a shared key invalidates dependents.
4. Locks record durable provenance; same-source reinstall is a no-op,
   cross-source name collision is a hard error naming the original. A name
   is claimed by an install (a lock entry) or by a declaration not yet
   applied (a manifest entry) — both collide, so a declared name cannot be
   silently rebound to another marketplace before it is ever installed. The
   one sanctioned rebind is a recorded fork: remote to `local`, written
   into the manifest's `[forks.<kind>.<name>]` by the fork operation the
   user confirmed. A fork keeps the item's installed name, so dependents
   and bundles keep resolving.
5. Enable/disable is non-destructive and lossless: file-backed kinds
   toggle by rename; kinds embedded in shared config files toggle by a
   structured edit that preserves every unrelated key. Uninstalling the
   app changes nothing.
6. Never touch the unowned: unmanaged files are reported, never deleted;
   foreign symlinks are conflicts, not clobber targets; adoption merges
   content, never loses it. The one sanctioned exception is a link the
   user explicitly adopts: when it resolves to a real skill folder outside
   kendex's own trees, adopt captures that folder's content, trashes the
   folder (bound to the exact bytes captured) and every sibling link that
   read it, and the follow-up apply restores the sharing from kendex's
   copy — a link at anything else stays a conflict, and the confirm names
   the folder and every tool reading it, because links kendex cannot see
   will break. Ownership is what kendex wrote, read from the
   lock — including the paths an installation recorded writing under
   another kind's name. A position we put something at is ours to replace
   or clear, whichever entry holds it now; deriving ownership from the
   lock key alone calls our own output a stranger's. A link the user put
   at a shared config file or a manifest (dotfiles) is not foreign: the
   edit goes through it, link kept, and a precondition binds to the bytes
   reachable there — whether a link may sit at a position is decided at
   plan time, never by the write.
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
   in a disposable clone, where none of a live tree's states exist.
10. Writes are byte-faithful: a file kendex edits round-trips
    byte-identically except for the intended edit, trailing newline
    included. Change detection compares exact bytes — a comparison that
    ignores trailing whitespace pins the corruption it hides instead of
    letting the next write heal it.
11. Validation precedes mutation. Every input check for an operation
    runs before its first durable write — not merely before the apply
    it guards — and a rejected operation leaves manifest, lock, and
    install tree byte-identical. No failure path leaves persistent
    state changed. Output is checked on the same side of the write:
    every rendering is read back through the target harness's own
    format rules inside plan preview, and one the harness's loader
    would reject is refused there, with the fix, for that harness
    alone.
12. Verification compares content, not provenance. Installed artifacts
    are re-hashed against what they should be; a matching lock entry
    alone never reports OK, and an artifact kendex cannot compare is
    reported as uncompared, never as passing.
13. External processes are hardened by construction. One constructor
    builds every invocation: environment that can redirect it
    (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`) cleared, every
    prompt path closed (`GIT_TERMINAL_PROMPT=0`, SSH `BatchMode=yes`),
    a timeout on every call. Work inside a downloaded cache also pins
    `--git-dir` and `--work-tree` on the command line, which outranks
    config: a cached repository's own `core.worktree` cannot point a
    refresh at files outside its cache. An unhardened invocation is not
    constructible — the raw-`Command` pattern is guard-banned, because
    a per-call-site discipline reliably misses call sites.
14. An item is scored on its own bytes and nothing else. Where one
    surface lists many items — a plugin cache, a settings file — the
    scanner records where each item's files actually live, so a
    neighbour's contents can never land in this item's findings. A
    repo-root skill is the one place a skill's tree is the whole
    repository; its `.git`, `node_modules` and build dirs are not its
    bytes, and one shared constructor (`SealedSource::collect_skill_tree`)
    excludes them so score, preview, install and catalog-check all read the
    same files — a `.git/config`'s credentials never ride in with a skill.
    What decides the outcome is exactly kind, path and name
    (`quality::observe::same_reading`); no rule reads the harness, which
    is what lets one file installed for several tools be read once. The
    distinct readings share nothing, so they run on every core
    (`core/parallel.rs`) and come back in the order they were given — a
    scoring pass is a pure function of the disk, and two runs over the
    same disk produce byte-identical output. Two things keep the work
    itself small: phrase matching skips to the next byte that could begin
    a match rather than trying every position, and text that is ASCII
    from end to end takes no normalizing pass at all, since every
    invisible character, compatibility form and homoglyph lives outside
    ASCII.

15. An item says what it is for in its own header, from a closed
    vocabulary (`core/tags.rs`). Kind says what a thing *is*; a tag says
    what job it helps with, and that is the only axis — mixing it with
    subject matter or shape gives a filter that answers three questions
    at once and none of them well. Tags are never inferred from a name:
    an untagged item is untagged. A word that is not in the vocabulary is
    reported as a scan warning naming the real one, because the common
    case is a near-miss (`tests` for `testing`) that would otherwise look
    like a tag and do nothing.

## Decisions

- Tauri 2 · React 19 · Vite · Tailwind v4 · shadcn/ui · zustand ·
  tauri-specta · serde/toml.
- Vercel-inspired design language: monochrome, high contrast, minimal
  chrome. Light/dark/system only — no themes. Every color, space, and
  radius flows through design tokens (guard bans raw hex in UI code).
- A coding tool kendex writes to is a **harness**, in the code and on
  screen alike (`HarnessId` in core, "Harnesses" in the sidebar). "Tool"
  on screen would collide with the tools a model is allowed to call,
  which agent settings also name.
- Hue carries exactly one meaning: **which harness** an item belongs to
  (`--tool-*`, one per harness). Status keeps the semantic tokens it
  always had, and item kinds are told apart by icon — so no surface ever
  asks a reader to decode two colour languages at once. The Library's
  table is the single exception: a row's kind icon takes `--customized`
  when you have changed that package, and the table prints the key above
  itself. A colour that means something has to say what, on the same
  screen as the thing it marks.
- In a table, a harness is its mark, not its name. Every row carries the
  same five or six harnesses, so spelling them out is a column of repeated
  words crowding out the columns that differ; the logo and its hue tell
  them apart and the name arrives on hover and for screen readers. Where
  a tool is stated once rather than listed — a package's own details —
  the name stays written out.
- A status a colour can carry is a dot, and the words arrive on hover.
  Seven rows reading "Active" spend a column on a sentence the colour
  already told; the tooltip and a screen-reader line keep the words for
  anyone who needs them.
- Four type steps, and no page invents a fifth: page title (24
  semibold), section title (15 semibold, full contrast), row label (14
  medium), description (13 muted). `components/section.tsx` owns all
  four. A heading always outranks what it introduces — the old 11px
  uppercase grey label put a group's name below its own contents in the
  visual order.
- Space groups things; boxes are for objects. A settings or detail
  surface is `Section` + `SettingRow`, never a stack of cards. A `Card`
  means a discrete thing a person acts on as a unit — a bundle, a
  problem, an error.
- A border means "you can act on this". Buttons and inputs carry one;
  chips and badges are a quiet fill with no border, so a dismiss button
  never reads as a label. Nesting stops at the card: inside one, groups
  are made with dividers, a tinted band, and space — never another box
  inside a box.
- Muted text is a real step in the hierarchy, not decoration: the
  `--muted-foreground` token stays legible against card and page in both
  themes, and no surface dims it further with an opacity suffix.
- A finding is ruled on where it sits. The decision dialog restates what
  it is deciding, since the row that opened it only showed a headline.
- Three surface planes, back to front: sidebar, page, card. Every page
  draws its width and gutters from `lib/layout.ts` — two widths only, a
  reading measure and full-width for data-dense tables — so header,
  filters and body cannot drift out of alignment.
- One search box per page that lists things — the Library's table and the
  Marketplaces' Packages tab each keep their own above what they filter —
  and "/" focuses the one on screen; from a page with no box it still
  takes you to the Library. The box is never a cursor sitting over a list
  that isn't on screen, and a search never filters a page you can't see.
- Location filtering belongs to the Library's table, and nowhere else. An
  app-wide picker in the chrome silently narrowed pages that state each
  row's location anyway — a count that disagreed with the page under it,
  with no visible cause. Every other page shows every scope. The Packages
  tab's `Where ▾` is not that filter: it picks the destination a package
  installs to (each row installs into the scope its subscription lives
  in), so narrowing by it changes what a click will do, not what is
  hidden — which is why the Library's rule stands untouched beside it.
- My Library holds what is installed; Marketplaces holds what could be.
  The Library lost its "Add from a catalog" tab to the Marketplaces page
  (Subscribed / Packages / Community / Mine), because browsing what a
  subscription offers and managing what is already here are different
  errands with different tables. Its nested pages — a marketplace's
  detail, a curated set, an available package — are the only ones that
  carry a breadcrumb; a base page never does. The Library's From column
  and the package page's From line read one provenance join, so "where
  did this come from" has a single answer everywhere it is asked.
- Harnesses and Projects are two sidebar destinations, not two tabs on one
  page: they answer different questions and neither is a mode of the
  other. Where a harness keeps its files is edited on that harness's own
  row, not in a second list of the same harnesses.
- Content a tool ships with itself — Codex's bundled plugins, Claude
  Code's — belongs to that tool, not to the person running kendex.
  `core/vendor.rs` reads ownership off the plugin registry a plugin names, an
  unknown registry is always the user's, and vendor-owned content is
  scored by nothing and asked about nowhere: it is listed in the Library,
  labelled with who ships it, and left alone. A finding nobody can act on
  is noise that teaches people to ignore the ones they can.
- What you changed about a package is edited on that package's own page,
  under a Customize tab beside its Overview — instructions, the skills an
  agent gets, per-tool settings. The Customize page keeps only what is
  not about one package (the `all` row every agent or skill inherits,
  custom hooks, a project's skills folder) plus an index of everything
  customized, each row opening the package it belongs to. A grid of every
  agent against every skill made a person hunt for the row they came for;
  a package's own page is where they already are.
- Both surfaces edit one draft of one manifest per scope, held in
  `stores/editor.ts`. Two drafts of the same file would let the second
  save overwrite the first with no warning, so the Customize page reloads
  only when nothing is unsaved, and `lib/customization.ts` slices that
  one draft per package rather than fetching a second copy.
- Hook events have one vocabulary — Claude Code's names, in
  `core/hook.rs::EVENTS` — and every other harness's map is keyed by it.
  The picker offers that list, the validator rejects anything outside it,
  and the renderers read it: three surfaces that would otherwise drift,
  and an event nobody fires is a hook that installs cleanly and never
  runs.
- **One hook model, two authors, and delivery is decided by capability.**
  A catalog hook and a manifest `[[custom-hooks]]` entry both become a
  `HookSpec` (`core/hook/spec.rs`) — script-bodied for the catalog,
  command-bodied for the person — and one function,
  `core/hook/delivery.rs::delivery()`, says how a spec reaches each
  harness × scope: `Registered` (the harness's own hook file — enforced),
  `InAgentFile` (Claude's per-agent `hooks:` block — enforced, for scoped
  hooks), `Advisory` (prose in the agent file, matcher restated, warning
  attached), or `NotInstallable` with the reason. Every surface reads the
  same decision — the engine installs by it, the agent renderer filters by
  it (a registered hook never also renders as prose: that would be a
  second, weaker copy of the same rule), and the editor's per-hook line is
  computed from it, never hardcoded. What decides scoped enforcement is
  `agent_scoping()`: Claude carries hooks in the agent's own file;
  everything else is honest `None` until a vendor's payload reference
  proves the agent is named at runtime — a hook that fires for every agent
  when the person asked for one is worse than one that says it could not
  be enforced. An every-agent custom hook on Claude registers in
  `settings.json`, where it also covers the main session. A custom hook's
  name is its identity (lock key `hook:<name>:<harness>`, same shape as a
  catalog hook's); the editor derives one from command + event on first
  save and writes it back, and a script-less registration records its
  event + command in the lock so removal can reverse an entry whose
  manifest line is already gone. Custom hook commands pass the same safety
  gate as catalog hook scripts.
- A section with nothing in it is not rendered. An empty state earns its
  place only when the page would otherwise be blank.
- "Nothing here" and "not counted yet" are different sentences. A list
  whose data has not arrived draws skeleton rows; the empty state waits
  until the read that would fill it has finished. The startup reads —
  settings, scan, audit, updates — run side by side rather than in a
  chain, since the slowest of them (scoring every installed file) is one
  nothing else waits on.
- Commands that touch disk, git, or a subprocess are declared
  `#[tauri::command(async)]`. On Linux a synchronous command runs on the
  GTK main loop, so seconds of work reads to the window manager as a
  hung application. Only window operations, which must run on that
  thread, stay synchronous.
- No database: manifests, locks, and native dirs are the state; scans are
  in-memory views (startup, focus, watch); app prefs in one settings file.
- **The Linux app decides its own display environment, once, before GTK
  starts.** The AppImage's bundled GTK hook pins `GDK_BACKEND=x11`, which
  puts the window on XWayland, where a compositor driving the display at
  scale 2 tells the client the scale is 1 — so the whole app draws at half
  size. That pin is upstream's workaround for tauri-apps/tauri#8541, a
  GLib-GIO schema lookup that aborts the process on bundles built old and
  run new; it is a different failure from the WebKitGTK DMABUF crash, and
  the two fixes do not substitute for each other. The app reads the session
  and relaunches itself once (`crates/app/src/launch_env.rs`) with whichever
  of `GDK_BACKEND` and the WebKit DMABUF workaround that session needs, and
  not at all when it needs neither; the environment is never rewritten in
  place, because the workspace forbids `unsafe`. Only the AppImage is pushed
  onto a backend, and only onto `wayland,x11` — GDK's own ordered list, so a
  compositor whose Wayland display cannot be opened still gets an X11 window
  rather than none. That list is not a net under #8541: an abort kills the
  process after Wayland has been chosen, so the second entry never runs.
  Overriding the pin is a judgement, taken because upstream reports the
  abort does not occur for bundles built on current Ubuntu — which is what
  `release.yml` builds on — and because the released AppImage patched to
  this value came up native on a Wayland session with an empty log. The
  recourse if a host proves it wrong is `KENDEX_GDK_BACKEND=x11`, and the
  launch prints that name whenever it overrides the pin.
  Every other packaging is left alone: with the variable unset GDK already
  tries Wayland first. A backend the person named is honoured on any
  session and never overridden; inside the AppImage the `x11` sitting there
  is the hook's rather than theirs, so `KENDEX_GDK_BACKEND` names one
  instead. `GDK_SCALE` and `GDK_DPI_SCALE` are never written at all.
- **Zoom is the webview's, applied before the window is shown.** The window
  is configured hidden and revealed in `setup` once the saved zoom is on the
  webview, so the first frame is already the right size — a page restyle
  would re-lay out the app in front of the person. The range lives in core
  and reaches the UI as a generated constant. The floor and the ceiling bind
  the controls and the settings file alike — a value outside them is clamped
  on the way in and on the way out — while the step is the controls' alone,
  so a hand-edited 137 is honoured. This is also the answer to a compositor
  set to a fractional scale, which GTK3 and WebKitGTK round to a whole
  number: the person nudges the difference back by hand. A webview that
  refuses the size still opens, at full size. What the webview is at is kept
  beside it and read back on load, since the zoom outlives the page that set
  it, while the stored percent stays a preference and is left alone.
- **Zoom moves in steps, and writes once the stepping stops.** Nothing
  offers a continuous zoom: a held `Ctrl` `+` and a repeatedly clicked
  button are the two inputs, and both take one step per press. That is the
  whole reason the control has buttons rather than a slider — every step
  re-lays out the webview on the GTK thread, so a drag turned the app into a
  flicker while a keypress never did. The window follows every step so the
  control feels live, and the settings file is written once the steps stop.
  Both inputs start the same timer, so neither can rewrite the file per
  press. The window is asked for one size at a time, each press queued
  behind the last, so there is never a second reply to interleave with: a
  queue removes those orderings rather than reconciling them. The size still
  shows the moment it is pressed, so the control stays immediate and two
  presses in one frame cannot collapse into one. Three values track the
  size, each with a single writer: what the app shows moves on a press, what
  the window has taken moves only on the window's reply, and what the
  settings object holds moves only when the file does. The first two are
  kept out of that object because every settings action writes it whole — a
  preview sitting in it would be persisted, faithfully, by an unrelated
  save, and a reply that predates the last resize would put an older size
  back over one the window has taken. The size reaches the file through a
  command of its own for the same reason: it carries a percent and nothing
  else, so no other setting can ride back with it, and `update_settings`
  leaves the stored size exactly as it found it. At most one save is ever in
  flight, and asks made while it runs collapse into a single follow-up that
  writes whatever is on screen by then, so replies can never land out of
  order and put back a size the person has already moved past. A write waits
  for the resize before it reads what to write, so a size the window refuses
  is never offered to the file; a size the file refuses stays on screen,
  because taking it away would cost the person the size they are using to
  read the message. What the settle costs is the last size chosen before
  quitting: the write is IPC behind a promise chain, so unloading starts it
  but cannot wait for it, and a close can end the runtime first. The close
  is not held open to fix that — a window that will not shut while the
  webview is busy is worse than losing one zoom step, and a timeout on the
  wait brings the loss back anyway.
- **Every atomic write gets its own temp file.** `write_then_rename` names
  its temp file per write, not per process: the app saves from a thread
  pool, so two writes of one path really do overlap, and a shared name
  makes them truncate each other and lets the loser write its payload over
  the live file the winner just renamed into place.
- GUI + CLI are equal thin shells over `crates/core`; every core operation
  has a CLI verb. No CI until first release; `tools/guard` is the gate.
- Multi-harness kept (v1 fleet workflows depend on Pi). Every capability
  ships cross-harness through the capability table; a harness without
  native support for a kind is marked unsupported — never shimmed. Where
  a vendor has itself replaced one surface with another (Codex retired
  its prompt directory in favor of skills), the table names the kind the
  artifact is stored as and the lock records what was written: that is a
  native surface, not a shim.
- **The table says what a verb means, not only whether it exists.**
  Beside op × scope it carries whether a hook the tool loads is executed
  or only read as prose, and the MCP transports the tool speaks.
  `managed` never implied enforcement — a safety hook rendered as
  advisory text must not read as protection, so an advisory install says
  so in the plan preview, the report, and the tool's card. A column only
  earns its place if a verb reads it: what a tool's own configuration
  holds down elsewhere (Copilot's `disabledSkills`, which a repository
  may add to but never take from) is reported per item where it is read,
  because kendex's own switch is a rename it can undo either way and a
  column saying otherwise would forbid a working enable.
- **An adapter claims only its own namespace.** Tools reading each other's
  directories is now common (Copilot reads Claude Code's skills and
  settings). A file belongs to the tool whose namespace it sits in, and
  the cross-read is reported as an input to effective state — never as a
  second installation, which would count one file on disk twice.
- Fresh manifest schema + one-time v1 importer; no compat shims. v1
  extras/theme packs are not carried over.
- **The rename to kendex reads the old names as an import, not as a second
  format** — the one stated amendment to "no compat shims". A scope found
  only under the old file names (`vstack.toml`, `.vstack-lock.json`,
  `.vstack-local/`, `vstack.settings.toml`) loads read-only and gets a
  "Rename to kendex" plan op — a journaled rename, nothing else — as its
  first mutation, never a silent move; both generations present in one
  scope is a hard error naming both files. Managed-block markers, report
  tags and the opencode hook-file prefix write the new spelling and read
  both, because every consuming repo still carries the old bytes. Env vars
  are renamed outright to `KENDEX_*`, except the guard's
  (`VSTACK_GUARDS_<CHECK>_<KEY>`, `VSTACK_GUARD_PRE_COMMIT_LOCAL`),
  which are read as a fallback while the `vstack`
  alias binary ships — one release cycle, because consuming repos' git
  hook entrypoints hard-code `vstack guard run` and fail closed without
  it; `kendex guard repair` rewrites entrypoints under receipt, and the
  receiptless by-content ownership proof accepts both generations of
  entrypoint bytes. The old-name fallback reads retire at 3.0.
- **The default catalog's repository moved with the rename**
  (`vanillagreencom/vstack` → `vanillagreencom/kendex`; GitHub redirects
  the old URL). Fresh scopes seed source `kendex` at the new repo. A scope
  still naming the old repo plans as if it named the new one (`repo_move`)
  and the plan records the move — "Point kendex at its new repository" —
  rewriting every place the string lives in one write per file: the
  source's `repo` and `[forks.*].repo` in the manifest, `sources.*.repo`
  and every entry's `sourceRepo` in the lock (a partial rewrite would read
  as a per-package source rebind, a conflict each). Source *names* keep:
  a pre-rename `[sources.vstack]` stays `vstack` and is still found as
  the default, because the default is found by repo. The remote
  store adopts the old spelling's cache under the new key by a one-time
  directory rename (mirror, checkouts, fetch stamp), so an offline scope
  keeps resolving; report routing accepts both repo spellings as
  kendex-owned.
- **Commits walk through the guards whatever tool makes them.** The guard
  family (`core/guard/`) — size-ratchet, todo-ban, byte-ceiling,
  suppression-ban, commit-msg — judges the index git names for the commit
  (`GIT_INDEX_FILE`, captured once and threaded through a validated
  context; the one sanctioned redirect past invariant 13's scrubbing).
  Policy is read from the commit too: the `[guards]` tables in
  `kendex.settings.toml`, baselines, and excludes all resolve from the
  staged copy and nothing else — a file staged for deletion, or never
  staged at all, governs as absent — so a permissive unstaged edit can
  never authorize stricter staged content and an untracked file dropped
  on disk cannot flip a verdict; the process environment is the only
  machine-local override, and the chain's local extension point is configured
  machine-locally only — never from a committed file, where a branch
  switch could point it at a tracked malicious executable. Index states
  that cannot be judged — unmerged entries, intent-to-add — are refused
  loudly, never skipped; paths travel NUL-delimited end to end, and a name
  the configuration format cannot carry is a refusal, not a skip. Every
  enabled check runs before the verdict so one commit attempt reports
  every blocker; exit 1 (violations) and 2 (could not run) both block.
  Fleet compatibility is a conversion, not a similarity claim: baseline
  TSVs read as-is, while legacy env-style settings convert once through
  `guard import-v1` and imported excludes keep v1's legacy-glob dialect,
  marked as such — "same file, new matcher" would silently change what is
  excluded, and a pattern outside the documented dialect is a refusal.
- **kendex owns its hooks directory — provably, not declaratively.** The
  guards reach git through `<git-common-dir>/kendex-hooks/`, two
  entrypoints whose call surface (`kendex guard run <hook>`) is a stable
  contract, with `core.hooksPath` pointed at them in the repo's shared
  local config. Ownership is a recorded receipt: the exact files written,
  the exact config value set, and one lease per worktree that enabled the
  install — uninstall releases its own lease and disarms only when the
  last one goes, reaping leases git's registry no longer lists. Repair
  (`guard repair`) rewrites only receipt-listed files whose current
  bytes are provably ours — either generation's entrypoint — the upgrade
  path for entrypoints that call the retired `vstack` name — and never
  moves directories: an install the vstack-named binary made keeps its
  `vstack-hooks` directory, because the receipt and `core.hooksPath` both
  name it. Every verb resolves the live directory in one order — the one
  `core.hooksPath` names when it names either generation's path, else
  the one holding a receipt, else the old name only while it is the sole
  directory present — and works there in place, so a stray directory
  under the other name never shadows the armed one. Uninstall deletes
  only receipt-listed files and unsets `core.hooksPath` only while its
  current value still equals the receipt's (compare-and-swap both sides);
  a value naming either generation's path is ours by name even when its
  directory is gone. kendex never edits a hook file it did not create: a
  pre-existing or symlinked directory, a hand-edited entrypoint or a
  receipt naming a different directory at repair, a worktree resolving a
  foreign effective `hooksPath`, v1's shim, and foreign files found at
  uninstall are all refusals — a refused repo can
  still call `kendex guard run` from its own hook orchestration.
  Hook state is repository-common state: mutations take a common-dir lock
  after the scope lock (one fixed order), build their plan — refusals
  included — only once both are held, and journal into a common-dir
  journal that every common-lock holder and the app's launch pass
  recover. The one transaction engine runs scope and common applies
  alike, keyed by what it locks. A missing binary at commit time fails
  closed, naming the one-commit bypass and the two-step manual removal —
  no vendored runner, because copies drift — and the entrypoints refuse
  v1's shim at commit time as install refused it, so it cannot be chained
  by reappearing. Ownership without a receipt is proven by content: the
  config value is kendex's by name, and a receiptless directory holding
  nothing but kendex's own entrypoints byte for byte — either
  generation's bytes, since the vstack-named binary wrote real installs —
  is kendex's by construction — repaired by install, taken back by
  uninstall — while anything else in it stays where it is, named. A
  worktree git lists as prunable is dead here: its lease is reaped, its
  config never asked for.
- **Pi hooks are enforced through the carrier.** Pi has no per-hook
  artifact: the `pi-hooks` extension package hosts native listeners, and
  hook content rides in the registry kendex renders beside them
  (`hooks/<name>.sh` plus `hooks.json`, keyed by Pi's own listener names —
  tool call, tool result, turn end, session start). An event outside that
  map cannot fire on Pi and installs nothing there, said as a note —
  honesty over stale advisory prose. The capability row says what the
  mechanism supports; the surfaces that label an installation read carrier
  reality (`pi_ext::carrier`), and Pi loads project and global settings
  both, so a project-installed hook with only a global carrier is still
  enforced — the v1 #1407 lesson, carried as behavior. A scope with no
  carrier registered anywhere Pi loads gets the downgrade said per item.
  The session-start drift report rides the same mechanism: same script,
  same kill-switch, fire-and-forget into session start, and a reloaded or
  resumed session never repeats it.
- **A seeded settings comment refreshes only while provably unedited.**
  Skills seed `[env]` defaults into `kendex.settings.toml` write-if-absent;
  the lock keeps, per key, which skill seeded it and the FNV-1a hash of
  the comment block seeding last wrote (v1's algorithm, so imported
  ledgers verify without re-guessing). A template revision rewrites a
  key's comment only while its on-disk text still hashes to that record
  and the template belongs to the recorded owner — a hand edit or another
  skill's template is preserved forever. A v1 record names no owner and
  imports as none; a template earns it only when the comment on disk is
  provably what v1 seeded and matches the template word for word. When
  several skills ship one key, seeding writes the first declaration and
  the refresh listens to the recorded owner, so declaration order never
  shadows the ledger; a bare key is never adopted, and a skill the safety
  gate holds back seeds nothing. Value lines are never touched, and the
  merger is byte-faithful: comment-block bytes (and an inserted seed
  block) are the only bytes that change, so CRLF files and
  missing-terminator state survive untouched.
- **Schemas are versioned and migrations are applies.** The manifest and
  lock carry a format version; older files load, and the upgrade rides
  the normal journaled, previewed plan as a surgical edit (the version
  line changes, nothing else). Files from a newer kendex refuse to load
  — an older build never corrupts a newer file.
- **Old product names read as an import, not as a second format**
  (`crates/core/src/rename.rs`). New scopes write `kendex.toml` /
  `.kendex-lock.json` / `.kendex-local`; a scope found only under the
  vstack spellings loads normally, and its next engine plan leads with a
  journaled "Rename to kendex" prefix — the file renames, the
  `.gitignore` line kendex wrote for the local source, nothing else —
  with the rest of the plan retargeted to the renamed paths (a rename
  preserves bytes, so observed-hash preconditions carry over). Each
  artifact earns its op on its own evidence, so a scope whose manifest
  already moved still gets the rest renamed. Both spellings of one file
  (or of the local-source dir) in one scope root is a hard error naming
  both, raised at plan time; no arbitration. Foreign surfaces get a
  narrower rule: a catalog's own `kendex.toml` outranks its `vstack.toml`
  while the two agree or only the new one parses; two files that would
  each govern differently are an ambiguity error naming both — the
  catalog must say one thing; and old-name settings files and templates
  keep being read. The global
  `vstack2` config/cache/data dirs move under `kendex` once, on first
  launch of either shell, under a scope-style lock, never overwriting
  what the new dirs already hold and never following symlinks; whatever
  a collision keeps in place is reported, and a failed move stops the
  launch of either shell — proceeding would write fresh state beside
  the stranded old files and fork the library.
- **Permission intent is typed and never widens.** A source's tool
  allowlist survives parse, merge, and every renderer as
  `Unspecified | AllowOnly | DenyExtra`; explicit denies survive
  allowlist subtraction. A surface that cannot express the intent
  renders the most restrictive expressible form or refuses with a
  conflict row — and a refusal also removes the older, wider rendering.
  Converting an allowlist to a deny-list by complement is forbidden: it
  widens the moment the tool grows a new built-in.
- **Catalogs are adversarial input.** Every catalog read goes through
  one sealed API (`source_read`) that resolves against the canonical
  root, refuses symlinks, and carries depth/count/byte budgets; raw
  filesystem reads over catalog paths are guard-banned. Frontmatter
  parses as real YAML under the same posture (aliases and duplicate
  keys refused, bounds enforced), and every interpolated value in a
  generated file is quoted so foreign text cannot mint config lines.
- **The source store is immutable, and revisions are declared.** A downloaded
  catalog is never a mutable checkout: each commit is materialized once into a
  directory named after its object id, published by rename, and read unchanged
  from then on, while fetching touches only a bare mirror beside it. v0.1
  hard-reset one checkout per repository on every refresh — two scopes reading
  different revisions fought over it, and a refresh in one window could shift
  bytes under a render in another. A source declares which revision it reads:
  a full commit id is a pin (that commit and no other, and once cached it
  resolves without any network), a tag or branch is a tracking selector that
  re-resolves on each refresh and is previewed like any other upstream change.
  Losing the lock loses no intent either way — the manifest holds what is
  wanted, the lock only records which commit that came out as. Offline with an
  uncached pin is a hard error naming the pin; anything already installed
  keeps working from what is on disk. Materialization runs under a
  per-repository cache lock; a second resolver waits half a second — enough to
  ride out a neighbour that is only starting up — and is then told the cache
  is busy rather than left waiting on someone else's download. A refresh
  treats that as an error; a read does not — planning degrades to "not fetched
  yet" for that one source: a neighbour's download must not decide whether the
  rest of a scope can be planned. The lock's recorded commit is a fallback
  only for the exact declaration that produced it; a manifest naming another
  repository or revision is never served the previous one. An item declaration
  may hold its own `rev`, outranking the source's, always as a full commit id:
  `kendex pin` and the version picker resolve tags and branches at write time,
  since a hold a moved tag can move is no hold. Holds flow through derivation
  — a pinned bundle pins its members, a pinned skill's dependencies read the
  pinned catalog, and two parents demanding different revisions of one
  dependency are a conflict that writes nothing: one filesystem identity
  exists, and a silent winner would install content somebody pinned away from.
  Updates are a projection over the mirror, never drift: a held item hashes
  clean against its held tree, and the Updates page asks the mirror (pinned
  sources too — a pin says what installs, not what exists) what newer content
  exists; its timeline lists only commits that touched the package's files,
  tag-decorated, never tag-replaced. Rows are per package per scope; the page
  folds them by package and expands by place (each is decided per scope), and
  nothing applies on its own: followers come current on apply or refresh, held
  ones when their hold moves. Muting a package's update notifications is a
  machine-local settings entry, not manifest intent: a preference committed to
  a shared repository would silence a whole team. Reuse is verified against a
  publish receipt written outside the checkout: a full content hash of the
  tree, which costs a read of the catalog per plan and is the only check a
  same-size edit cannot fool. The pre-2.0 clones are read where the new layout
  has nothing yet, and deleted never. Neither are published commits: the store
  keeps one tree per commit it has ever resolved, so a tracked branch grows
  the cache by a catalog per upstream change, and nothing prunes it yet — the
  cache is rebuildable, so deleting it is the only cleanup there is.
- **A subscription reference is parsed, never guessed, and one repository
  subscribes once per scope.** Two validators sit side by side in
  `core/source_ref.rs`, one per trust level: the typed one (the Subscribe
  dialog, `marketplace subscribe`, `source add`, `add`'s positional source)
  keeps the full range a person may need — `owner/repo[@rev]`, any-host
  remote URLs kept as typed (an `ssh://` spelling can be what their auth
  requires), local paths, GitHub tree URLs, skills.sh package URLs — while
  the untrusted one (directory rows, collections, deep links) is GitHub-only
  and normalizes to `owner/repo`. Both refuse a leading `-`, `..` in
  repository components, and percent-escapes that would smuggle a separator,
  decoding exactly once. A tree URL always subscribes the whole repository
  and surfaces the package path as a lead to open, never an identity; its
  `<ref>` resolves against the mirror's real refs (branch names contain
  `/`), and two split points both naming refs, or a branch and tag sharing a
  name, refuse naming every candidate — offline, normalization is a refusal
  before any write. One repository per scope, compared by canonical identity
  (`.git`, case, and redirect spellings are one repo), with the refusal
  naming the existing subscription. The default marketplace is found by
  repo, never by name and never by sort order: the subscription whose repo
  is the default repo; two of them prefer the seeded name and otherwise
  refuse naming both; none is a typed error with no fallback — what the
  cross-source search catches rather than a guessed install. Installing into
  a project from a personal subscription copies the declaration into the
  project in that plan — exactly one scope mutated, the personal manifest
  read-only, the cache shared by construction.
- **A name says where it comes from, or the search does — never a
  fallback.** Every installable kind declares through `add`
  (`engine/ops/add`): agents, skills, hooks, commands, MCP servers; Pi
  extensions are carrier-only and a direct add is a typed refusal. The
  qualifier is `marketplace::name` (`add/place.rs`) — `::` never appears in
  an item name, so `/` keeps meaning `plugin/item` or, positionally,
  `owner/repo` — and it resolves against subscription aliases only, refusing
  with the subscribed list when nothing matches. A bare name searches every
  enabled subscription in the scope for its kind: one offer installs, two
  refuse printing the `::` spellings beside each subscription's canonical
  repo, and zero is not found with the fix named — the default subscription
  participates like any other, and `default_source` serves only requests
  that name no item at all (`--all`, a bare bundle). Installing a whole
  bundle subsumes, in the same plan, the previously-declared members whose
  effective options equal what the bundle derives (`add/subsume.rs`) — a
  member the user shaped keeps its declaration with the preview saying why —
  and `[bundles.<name>]` stays keyed by bare name, so a second marketplace's
  same-named bundle is refused naming the first.
- **A plugin-registry-shaped catalog is recognized, never guessed.** A
  source is read one plugin deep (`plugins/<name>/{agents,commands,skills}`)
  exactly when it carries `.claude-plugin/marketplace.json`; a `plugins/`
  directory on its own is not evidence, and guessing renames every item in a
  catalog that never asked for it. The registry, not the directory listing,
  decides what such a catalog offers: an item resolves only under a plugin
  the registry validated, and only entries pointing at a directory inside
  the repository are consumed — an entry naming another repository or a URL
  is skipped with a finding, since fetching it would be a second, unpinned
  download behind the one the user asked for. Everything the catalog gets
  wrong is a finding with a fix, cross-file included: a registry that
  disagrees with a plugin's own manifest about its name or version, a plugin
  describing parts that live outside itself, and two names one filesystem
  would fold together. Registry metadata (category, version, author,
  license, homepage, and the plugin's items as a named group) is read-side
  only — it feeds browsing and, later, installing a plugin as a unit; the
  manifest records what the user chose, never what a catalog says about
  itself.
- **Any repo holding skills is a marketplace — discovered from a closed
  table, never guessed wider.** `source/discover.rs` owns a versioned search
  table (`DISCOVERY_VERSION`, part of the safety-cache key): `skills/` and
  `skills/.curated`, each harness's project skills dir (pinned to the
  adapters by test), `<dir>/**/SKILL.md` up to three levels down for
  category nesting — stopping below a found skill, skipping `.git`,
  `node_modules` and friends — and a repo-root `SKILL.md` as a one-skill
  repo named by its validated frontmatter `name`, else by the repository
  leaf the caller passes, since a store directory is a commit id. The table
  yields skills only: hooks, MCP servers, commands and agents install from a
  declared kendex layout, `kendex.toml`, or a plugin registry — executable
  content is never discovered into existence, so a `hooks/` folder in an
  undeclared skills repo is tooling, not an offer. Precedence is fixed and
  fail-closed: a `.claude-plugin/marketplace.json` registry wins outright
  and root dirs are not read; else a parsed control file declares the fixed
  layout (`[catalog]` overriding which dirs) and the search table stays out
  — discovery exists for repos that never declared anything; else the search
  runs. A control file present but unreadable, or a wrong-typed `[catalog]`,
  makes the source unusable with a finding — presence selects the mode and
  breakage never falls through to another, since serving defaults would
  offer a catalog the author never published. Every probe goes through
  `SealedSource` (symlinks skipped, budgets held, hard caps on found
  skills); items dedupe by normalized repository-relative path, never
  `canonicalize`; two directories that fold to one name are **both** skipped
  with a finding naming both — identical bytes excepted, that being one
  skill served under two harness layouts — so the walk's order never decides
  which of two clashing skills installs. A frontmatter `name` disagreeing
  with its directory is a finding (the directory is the identity), and
  submodule or LFS pointers under a recognized root are findings, not
  hydrated. A name carrying an invisible or direction-reversing character is
  refused (`names::segment_problem`) and shown escaped (`names::shown`), so
  one marketplace's package cannot wear another's name on screen while
  installing under a different one; a declared-layout catalog lists only
  names that install, so the Packages table never draws a row `find_item`
  would refuse. The walk stops at its skill cap rather than reading the rest
  of a hostile tree, bounding the work, not just the output.
  `source/about.rs` renders the one typed report — what was found where,
  plus every finding — that the About tab and `kendex index` consume.
- **Browsing is a read-side join, and installed state is derived, never
  stored.** Every `source/browse.rs` read — packages across kinds, a bundle's
  members, a package's preview — takes a `Catalog`, `Subscription { scope,
  source }` or `Repo { repo }`, so a listed marketplace opens before anyone
  subscribes on the pages a subscription gets. Each row's state is joined from
  the scope's manifest and lock on every call — installed is a lock entry from
  this subscription, held-back-by-safety is asked-for content whose catalog
  bytes the gate's own verdict refuses, "partly installed (2 of 6)" is counted
  from a bundle's members — so no stored flag can drift from the records it
  summarizes; with no subscription the join answers Available and judges name
  clashes against the personal scope, where Subscribe lands. A name another
  source holds is surfaced on the row (`collision`) before the click; the
  refusal stays in the engine (invariant 4). A bare repository is fetched by
  `remote::sync` into the store a subscription reads from, under the canonical
  `owner/repo` every GitHub spelling folds to — the key Subscribe is prefilled
  with — so subscribing never downloads twice and the safety record is shared
  per commit; only GitHub opens blind (`NotBrowsable` otherwise), and a root
  skill's file list and file reads are confined to the skill tree scoring and
  install read, never the repository around it. `browse::summary`, a
  repository's first read, refreshes (a failure is a warning over the store's
  copy) and names an enabled, readable subscription this machine holds for it;
  `useCatalog` moves the page onto it at once, so "subscribe from here" keeps
  your place. Installing still needs a subscription; `RepoAction` offers the
  one step there: Subscribe when none declares the repository, Turn on when a
  declared one is off, Refresh when it is declared but unreadable, neutral
  until the live list has loaded. Pre-install safety (`browse/safety.rs`)
  scores catalog bytes with the rules an install runs and caches **findings
  and scores only**, beside the commit's receipt in the immutable store
  (`<key>/<commit>.safety/…`, never inside the receipt-signed checkout), keyed
  by the item's content hash plus the rule-set, discovery-table and
  record-format versions, each recomputed and verified before reuse. The
  warn/block verdict is derived from the current thresholds at read time —
  thresholds in the key would re-score on every settings change. Browse is a
  preview of the verdict, never a second gate. `library.rs` is the same join
  for the Library table, mapping each installation to its origin: a
  subscription, local content (with what a fork replaced), or
  observed-and-unmanaged.
- **A subscription's closure is derived by re-expansion, and unsubscribing
  removes or keeps exactly it.** `engine/detach.rs` computes what leaves
  with a marketplace by expanding the installed set with the source present
  and again with its declarations gone, then diffing — a derived dependency
  never names the source, so only the difference is true. A member another
  marketplace's bundle still carries is in both expansions, so it stays. It
  refuses while the source cannot be read. **Remove** drops the closure's
  declarations and sweeps their installations (orphan removal filtered to
  exact kind+name pairs); an edited installation is never swept without
  `--discard-edits`. **Keep** (`detach/keep.rs`) copies each installation's
  *source-form* bytes — read through the sealed catalog at the exact commit
  it installed from, a parent skill excluding any nested child skill — into
  the scope's local source, flips the declaration to `local` with fork
  provenance, and removes the subscription; the local writes are ordered
  before the manifest flip in one plan, so a failed apply rolls the
  conversion back (invariant 11). Keep refuses an edited package (fork or
  discard first; hooks are compared to what apply wrote) and preflights the
  local target: a symlink, a case/composition-folding sibling, or different
  bytes already there is a refusal, never a clobber (invariants 4 and 6).
  The local source lists a `plugin/item` name beside a plain `plugin`, so a
  detached plugin-registry package round-trips.
- **The machine seam reads through the same core installing reads through.**
  `check_catalog.rs` (core) owns the two authoring passes — structural
  (would each harness's loader hold this item) and safety (the rules an
  install runs) — so `kendex check --catalog [--json]`, the indexer's
  per-package verdicts, and authoring preflight ask one implementation; the
  CLI only prints, as lines or as a versioned envelope (`schema`, typed
  findings, counts, `ok`). `source/index.rs` emits the per-marketplace
  summary the community directory consumes (`kendex index [<dir>] --json`,
  schema 1, plain directory, no network): metadata from the catalog's own
  `[marketplace]` table (`source/meta.rs` — read-only, every string capped
  and control-char-safe), packages built from `list_items` so the summary
  offers exactly what subscribing finds (pinned by test), safety scores from
  the check passes, bundles with members, About rows, findings. Field order
  in both JSON shapes is the schema — serde structs, no maps.
  `kendex marketplace check` aliases `check --catalog --strict`, same exit
  codes. A maintainer's reviewed findings live in a committed
  `kendex-reviews.toml` at the catalog root (`check_catalog/dismissals.rs`):
  the same content-hash-bound dismissal records the install side keeps in a
  manifest, keyed `kind:name`, written by `dismiss --catalog` from the
  tokens `check --catalog` prints — for every kind whose review can travel,
  which is every kind but a hook. The check refuses what an install
  refuses, so a record a consumer would drop fails the maintainer's own run
  rather than their consumers' installs, and it reads an item under the
  same budget an install does, so it never mints a token for content no
  install can see. A dismissed finding stops counting and
  stays reported, marked — in the catalog's own passes and on the machines
  that install from it. What that record is worth on somebody else's
  machine is `quality/author.rs`, the neutral home for the travelling
  shape (`AuthorReview`) and for the one derivation of "a settled finding
  is reported and does not count" (`author::score`) that the authoring
  check, the gate, the audit and browsing all call. Three bounds, because
  the record arrives from content kendex does not control: it binds to
  bytes — the item's own plus the control-file tables an agent renders from
  (`SourceConfig::rendering_inputs`), so editing either stales it;
  it settles as many occurrences of a finding as the publisher's own bytes
  carried and at the weight each was read at, so nothing a project repeats
  rides in on a reviewed one, however heavy; and it carries only reasons
  an author can give — `trusted-source` is refused on read, not only on
  write, and a timestamp that is not a timestamp is refused with it.
  **The record never travels in a file this project commits.** The lock
  carries none, and the fourth bound is why: a record kept there would be a
  claim about a catalog, and every attempt to authenticate such a claim —
  its shape, the name it carries, the numbers beside it — answers a
  different question than the one that matters, which is what the content
  should be. So the audit rebuilds instead
  (`engine::desired::desired_as_installed`): the plan that produced what is
  on disk, each installation at the revision its own lock entry names — one
  item can sit at two revisions at once, since a refresh applies per
  installation, and is planned at both — and the record read out of *that*
  catalog, measured against the item rendered from the publisher's own
  inputs, which is the gate's own derivation on the gate's own bytes. A
  rebuild is looked up by the bytes it produced, so finding one is the proof,
  and content no rebuild produced is content the publisher never saw. The commit
  an entry names chooses which revision to rebuild from and asserts nothing;
  naming another produces another artifact, which is not what is installed.
  An item that cannot be rebuilt at all — a catalog not on this machine, a
  manifest that will not resolve — carries no review. No signing scheme
  here. A hook records none: the
  gate reads the script and the audit reads the shared settings file, two
  readings of different bytes by design — so the record is refused where
  it is read, `dismiss --catalog` refuses to write one, and `check
  --catalog` prints no token for a hook's finding. The audit matches an
  entry to an observation by the item and then by the bytes: its kind and
  name, or the kind and name of the artifact it emitted, and then a review
  hash sealed by what the artifact is on disk. Every settled finding is
  shown with the publisher recorded alongside it and their reason — under
  the line in the CLI, in its own row on a scope and beside the finding in
  the held-back panel in the app, and beside the finding on a marketplace
  package's page, which reads the same record through `browse/safety.rs` so
  the preview cannot promise a verdict the install will not give (and says
  when this project's own instructions are not in what it read). A record that settles nothing here is a note,
  never silence; and editing the item — in the catalog or on disk —
  stales it and the hold returns. Finding identity
  is the rule and the sentence it fired with, and nothing else
  (`Finding::fingerprint`). Which puts a standing obligation on every
  rule's message: it says what the rule fired *on* — the address the line
  actually runs, the characters a file hides — and never where it was
  found. Two different problems that read the same are one decision, and
  only one of them is ever displayed; naming the file instead would fix
  that by coupling identity to the thing rendering moves content between.
  Where a finding was found is carried by its location, and every location
  one decision covers is listed under it. Everything kendex's own rendering moves is
  deliberately out of it: the line, because rendering shifts lines; the
  file, because Codex renders a command as a skill tree and an over-cap
  body is split into `references/`; the severity, because a hit weighs one
  step less in a supporting file than in the body and the split moves
  content between exactly those two. What bounds it instead is the item —
  a fingerprint is only read within one item's records — the content hash
  every decision binds to, and, for a publisher's record, the number of
  occurrences the content they wrote actually carried
  (`author::Budget::earned`, counted against the render with the project's
  injected instructions taken back out).
- **The community directory is read like any remote: strictly, capped,
  and honest about staleness.** `registry/` (core) consumes what
  `source/index.rs` producers feed kendex.ai: `index.rs` re-parses the
  site's schema-1 payload under the site's own caps (a spoofed registry
  cannot grow a row), refusing structural problems whole and dropping only
  unusable rows; `cache.rs` holds one body and one meta line on disk
  (`Env::registry_cache_dir`) behind an ETag and a one-hour TTL, and a
  failed refresh serves the last fetch labeled stale with its real fetch
  time — the Community tab is never blank. All reads go through the `Fetch`
  trait (curl via `Hardened`, plain http only when an explicit `KENDEX_API`
  override asks); tests inject canned transports. `skillssh.rs` is the
  versioned adapter over their public search: pinned wire schema refused on
  mismatch, capped, kill-switched (`KENDEX_SKILLSSH=off`); a hit is a lead,
  never an identity, installing through the same subscribe path as any
  marketplace. Sign-in, collections and deep links arrive with W3/W4.
- **Intent in the manifest, closure in the plan, edges in the lock.** The
  manifest records choices and never their consequences: the items asked
  for, the bundles installed, which optional dependencies were taken, what
  stays removed. Everything those choices imply — a bundle's members, a
  skill's dependencies — is derived on every plan, so a derived
  installation can never read as a request and whatever brought it in can
  always take it away. The lock caches why each installation exists as a
  set of typed edges (`requested`, `required-by`, `member-of`) pointing at
  structured counterparts rather than sentences; losing the lock loses
  nothing, because the graph rebuilds from the manifest and the catalogs.
  Uninstalling a bundle therefore has exactly one answer: members whose
  only remaining edges came from that bundle go, and members that are also
  requested, required by a survivor, or carried by another installed
  bundle stay — with the preview naming both halves and the reason for
  each. A member the user takes away on their own is a suppression, the
  same durable removal a dependency gets: refresh honors it, and the audit
  reports the bundle as installed with members held back rather than
  pretending it is whole. Writing that suppression down asks both the lock
  and the catalogs, because either alone has a blind spot — the lock says
  nothing once it is deleted, the catalogs say nothing while they cannot be
  read — and anything either names is recorded, since a stale line costs
  the next `add` to clear while a missing one puts back what the user took
  away. A removal that names an installation is an instruction and goes
  even with its catalog unreadable; one nobody named is kept, because
  "nothing needs it anymore" is not something an unreadable catalog can
  say. A suppression only ever speaks for derived presence: declaring the
  item outranks it, so it installs and the contradiction is reported rather
  than leaving the item installed and called missing at the same time. Two
  installed sets can carry one member and ask for it differently — the
  tools are both, a set that is switched on installs it switched on, and
  what neither rule settles is a finding naming both sets, never whichever
  name sorts first. Authoring lives with the catalog —
  `[bundles.<name>]` in the source's own `kendex.toml`, or nothing at all
  for a plugin-registry-shaped catalog, where each plugin is a set already —
  and a set's members are its own catalog's items, since a bare name from
  another source names nothing stable.
- **A namespaced name is the identity; the separator is per tool.** Items
  from plugin-registry-shaped catalogs are named `<plugin>/<item>` in the
  manifest, the lock, and the UI, so two plugins can each ship an
  `analyzer`. The `/` never reaches disk: every loader in the fleet keys an
  item on the single directory or file name it finds and holds the item's
  own frontmatter to that name, so the two halves are joined instead —
  `__` by default, `-` where names must be lower-kebab and an underscore
  makes the item unloadable. The rule lives beside the name rule it is
  derived from (`harness/caps.rs`) and is checked against it. Rendered
  copies carry the installed name (SKILL.md and agent frontmatter are
  rewritten; the catalog keeps what it wrote), and two declarations that
  would land on one file — `a/b` against a literal `a__b`, or two names a
  filesystem folds together — install neither, naming both. Folding is
  what one filesystem would do to two names: case, trailing dots and
  spaces, and Unicode composition, since macOS hands a composed and a
  decomposed accent to the same file. Only the kinds a plugin registry offers
  — agents, commands, skills — may carry a plugin segment at all; a hook
  or an MCP server has no namespaced spelling anywhere, so a `/` in one of
  those names is a directory nothing would ever clean up. Names that
  cannot be a path at all (`..`, device names, trailing dots, overlong
  components, a stray `/`) are refused where they are written down, in
  `kendex.toml`. A catalog's own words travel into findings and onto a
  terminal, so control characters in them are shown, never acted on.
- **The surface model.** Rendered skills are per-harness variants,
  deduplicated by content hash. Harnesses that read the same physical
  directory form a surface group carrying exactly one variant rendered
  to the group's combined constraints (tightest byte cap wins); a
  variant whose bytes match the shared tree collapses onto it through a
  link, and a divergent one gets its own tree. The move runs both ways as
  the source grows and shrinks: a link gives way to a directory and a
  directory back to a link, each planned as a removal plus a write, since
  a variant left reading a stale link gets exactly the truncation the
  split exists to prevent. A refusal is per surface, not per tool — the
  members of a group all read one file — and it takes down only what the
  refusing installation alone holds. Format facts — byte caps, name
  rules — live in one table beside the op table (`harness/caps.rs`),
  never as renderer literals. A surface is one file per item, one
  directory per item, one structured file, or a directory of structured
  documents (Copilot loads every `*.json` in its hooks directory as a
  document of its own): where the entries inside are the items, a
  document holding none reports none, so an emptied registration cannot
  read as a live installation.
- One model-alias table for every harness: bare tiers resolve per
  harness, `inherit` is expressed in each tool's own dialect, explicit
  vendor ids pass through.
- **Propagation into consuming repos is local, never a pull request.**
  kendex detects drift and informs the agent at session start; the repo
  is brought current by a local refresh. Opening PRs in consumer repos
  is a permanent non-goal: the managed assets are gitignored there, so
  there is nothing to commit, and the attempt would mean mutating a
  live foreign working tree (invariant 9).
- **Session start reads a snapshot; the background job earns it.** The
  drift contract is `kendex check`: exit 0 clean / 1 drift / 2
  could-not-check (unknown outranks drift — an incomplete report must not
  claim completeness), `--quiet` bounded and silent when clean, `--json`
  for machines. The check reads the manifest, the lock, the per-scope
  drift snapshot (`core/drift/snapshot.rs`), and per-mirror fetch stamps —
  it materializes no source trees, hashes no catalogs, and fans out no
  per-package subprocesses. The deep work runs where time is free:
  `updates`, `refresh`, `apply`, and the detached
  `kendex source refresh --stale` the check spawns (TTL 6h, per-mirror
  lock, no stdio, never waited on) all re-derive the snapshot. A mirror
  that moved since its last evaluation reads as unevaluated — the honest
  "maybe", never a guessed verdict — and a fetch failure older than twice
  the TTL is a report line dated from a monotonic first-failure stamp.
  Held and ignored packages are silent in the agent report: a hold is a
  decision already made, and re-announcing it every session teaches
  agents to skim. Held-ness derives from the effective installation
  graph — an item's own pin, a pinned source, a pinned bundle, or a
  pinned dependency parent. Every read API under the report says when it
  cannot answer (typed warnings, never an empty result standing in for
  failure), because the report is only as honest as its inputs. The
  session-start hook that relays the report is first-party content
  shipped inside the binary and offered at project registration — never
  fetched from a catalog, since it injects into agent context — but still
  a declared, user-approved install per scope, rendered and removed like
  any other hook.
- Non-interactive is a mode, not a fallback. Every CLI verb completes
  without a TTY: selection flags suppress prompts rather than
  pre-filling them, and a verb that would need input on a non-TTY fails
  before its first write, naming the flag that answers it. Agent- and
  CI-driven runs are the normal case. Interactive selection lives in
  the GUI; the CLI has no pickers.
- **Two scores, never averaged, and only one of them gates.** Safety
  answers "is this dangerous" and can hold an install back; quality
  answers "is this well made" and never does. Averaging them would let a
  well-written attack outscore a clumsy honest skill on the number that
  decides. Safety is `100 − Σ deductions` (Critical 25 / High 15 /
  Medium 8 / Low 3), first hit per rule at full weight and repeats at a
  point each until they have cost as much again — a pattern being
  pervasive says something, and says it once. Quality is wshobson's
  weighted-dimension model, static layer only: no LLM judge, no
  simulation, no letter grades, because none of them fit a path where
  someone is waiting to install one skill.
- **The aggregate warns; a Critical blocks by itself.** Threshold
  arithmetic alone lets one Critical finding through at 75. Blocking is
  therefore per-finding *and* aggregate: any Critical, or a score below
  the block threshold (default 60; warn 80). Thresholds live in app
  settings, never in a manifest — a manifest travels with the repository
  it describes, and a catalog able to lower the bar it is measured
  against is not being measured.
- **Rules read typed per-kind inputs, and say when they cannot read.**
  There is no "content" field meaning a different thing per kind: a skill
  carries its tree and byte budgets, a hook its registration and script,
  an MCP server its command, args, env and headers, a plugin its manifest
  and lifecycle scripts. A rule whose bytes are not in this path's input
  reports itself not applicable, because silence would read as a pass.
  Bytes that will not decode as text are read lossily and what had to be
  replaced is reported, so one stray byte cannot hide a file from every
  rule. A matched token never appears in any message, log or record, only
  a fingerprint — that holds for every rule that quotes a value it found,
  not only the one that looks for keys.
- **The file a harness loads is scanned at full weight, fences included.**
  A fenced `sh` block in a SKILL.md is not an illustration of the
  instruction, it *is* the instruction, and it is the shape every real
  skill writes its commands in — discounting it would mean the gate blocks
  the unnatural spelling of an attack and waves through the natural one.
  What weighs one severity less is content that is plainly quoting rather
  than instructing: a blockquote, and every line of a skill's supporting
  files (`tests/`, `fixtures/`, `references/`), settled against a real
  catalog that ships tests asserting on dangerous command lines. Secrets
  never weigh less anywhere.
- **An override is permission for one decision, not for an item.** It
  binds to the installation, the review hash, the rule set version and the
  exact finding fingerprints that were reviewed; it is written into the
  manifest by the same transaction that installs what it unblocks; and it
  goes stale the moment any of those four move. The flag that grants one
  carries the review hash it was shown with (`--allow-unsafe name@hash`),
  so a bare name in a shell history, a Makefile or a CI job grants nothing.
  A one-time review must never become a standing bypass, and the audit
  reports an accepted item as accepted rather than as held back.
- **A decision binds to the bytes, not to the reading of them.** Two
  hashes, and they answer different questions. The *content hash* names
  what the rules read — a reduced representation, with the scan's byte and
  file budgets, symlinks stepped over, binary assets counted rather than
  kept, and text decoded lossily — and it is the right input for scoring
  and the wrong one for a decision: a plugin whose only file is a payload
  no rule reads reduces to nothing at all, so swapping that payload for
  different bytes of the same length would leave a decision speaking for
  content nobody reviewed. The *review hash* names every owned byte, or
  the exact config entry, with no budget and no decoding, and that is what
  a decision binds to. Where the bytes cannot be reached from here at all
  there is no review hash, and a decision with nothing to compare against
  never reads as live — the same rule that reports an artifact kendex
  cannot compare as uncompared rather than as passing. Budgets stay where
  they belong: they bound what is read for scoring, never what a decision
  covers, so content past a budget going unreviewable is said out loud
  instead of waved through.
- **A dismissal settles one finding; whose it is decides what it buys.**
  Beside the item-level acceptance sits the smaller decision: this one
  finding, on this one installation, is not the problem the rule says it
  is. There are two classes, and they are not interchangeable. The
  person's own dismissal unblocks nothing — it settles a question and is
  never offered on a held-back item at all. The publisher's committed
  review is read *before* the verdict, so a finding it settles stops
  counting toward the score and can therefore move an item out of Block;
  that is the whole point of a catalog reviewing its own content, and it is
  bounded by the checks above — every one of which is a question put to the
  catalog rather than to a file this project commits. The publisher's record
  does not live in the person's manifest and is not one of their revocable
  records: it lives in the catalog's committed `kendex-reviews.toml` and
  nowhere else, and an audit rebuilds the plan to read it — so it never
  appears in the Recorded decisions registry, which lists what the person
  can take back. It is shown instead wherever
  the finding is: the CLI prints the publisher and reason under the line,
  and the app gives them their own row on a scope and marks them inline in
  the held-back panel. A personal dismissal binds
  the same way — review hash and rule set — and it lives in the same place,
  the manifest of the scope the item belongs to: a personal decision stays
  on this machine, a project decision is committed and shows up in code
  review, which is what a security judgment should do. Because a project's
  file travels, a dismissal carries a reason from a closed vocabulary and
  never free text (`wrong-call`, `intended`, `trusted-source`) — every
  reason is a claim about the content that means the same thing to whoever
  reads it next, and none is one person's tolerance for risk. Trusting a
  source binds the source: the record names the provenance it trusted and
  goes stale when the same bytes arrive from anywhere else, a fork
  included. One snapshot per installation holds the proof once with each
  dismissal beneath it; a decision on newer content replaces the snapshot,
  since the older dismissals spoke for bytes that are gone. A held-back
  item cannot be dismissed into silence — it is decided by accepting or
  removing it — and an accepted item's findings already read as accepted.
  The UI never spells a decision key: the backend issues a token per
  finding (`kind:name:harness#fingerprint@review-hash/scope-digest`), and
  a dismiss re-audits before it writes, refusing the whole batch if any
  token no longer names what is installed or was minted for another
  scope's manifest. Trusting a source needs a source kendex itself
  resolved and recorded in the lock; a remote url found beside unmanaged
  files is not one, since the files could have written it. Every write is one journaled manifest
  op for one scope. Removing an item reaps its decisions; the registry
  (`kendex decisions`, Recorded decisions) reads every record against what
  is installed now — active, stale with the reason, or obsolete. An undo
  from the app takes back exactly the record it was shown, never a newer
  one at the same key; the CLI's revoke names the record by key.
  How the two decisions compose, written down so no surface has to guess:
  a held-back item's findings are decided by accepting or removing the
  item, so they are never offered for dismissal and the item stays visible
  with every finding whatever was decided about any of them; an active
  acceptance covers every finding on its item, so those read as accepted
  and cannot be dismissed on top; below that the person's own live
  dismissal answers, and below that the publisher's record — so a personal
  dismissal that has gone stale falls through to the publisher's rather
  than straight to open, and a finding nobody has ruled on is open; a
  threshold change that turns a warning
  into a block leaves the dismissals recorded but the item shows as held
  back with its findings in full, and one that turns a block into a warning
  leaves the acceptance covering the findings until it is withdrawn;
  withdrawing an acceptance uncovers the findings, and any dismissal made
  before it applies again. What still needs a person is one derivation
  (`lib/reviewable.ts`): held-back items, counted once each, plus open
  findings counted once per distinct evidence — the same bytes carrying the
  same finding through several tools, which one decision legitimately
  covers because no rule reads the tool. Everything else is presentation.
  Every count in the app — the sidebar, Home, the footer, a scope's
  summary, and whether the Review page is finished — reads that one number,
  so dismissing a finding moves all of them at once, and a scope whose every
  finding is decided reads as done rather than as warning forever.
  A dismissal is about installed bytes and is never made on a plan: the
  observed audit is what a tool would load right now, and that is what a
  decision has to bind to. What a plan would install is scored the same
  way, and the rows that will install with findings travel with the view
  as `queued`, so the apply preview says how many decisions will be waiting
  once the content lands — review-after-install, said before the install
  instead of discovered after it.
  Grouping on the page is presentation only. A concern row collapses one
  rule across everything it touched, which is how a person reads a list;
  a decision is made per piece of evidence, which is how a person is
  honest. Where a concern is one piece of evidence its row carries the
  verb; where it spans different content, each piece has its own, and the
  page offers a one-at-a-time walk through the scope's open evidence,
  worst first, rather than any button that would decide twenty different
  contents at once. There is no rule-level mute, no time-based snooze and
  no cross-scope action: a plan belongs to one scope and locks one scope.
- **Rule severities are calibrated against real catalogs, not inherited.**
  A Critical blocks an install on its own, so the tier is only worth
  something if it is precise. Patterns that fired only on legitimate
  content were retired with their evidence recorded beside them, and
  deobfuscation reports only what has no typographic use — invisible and
  bidirectional characters, letters chosen to imitate other letters —
  while normalizing emoji and compatibility forms silently so the other
  rules still read a plain string. The confusables table covers Cyrillic,
  Greek, Armenian, Cherokee and the Latin-extended, phonetic and
  small-capital letters that imitate ASCII; it is not the whole of
  Unicode's data and the module says so rather than implying coverage it
  does not have.
- kendex never emits a pasteable command line. Errors, hints, and
  recovery instructions present the verb and its parameters as data —
  cross-platform shell quoting is a cost the product declines to carry,
  and a hint built by concatenation is an injection surface. The one
  deliberate exception is the session-start drift report: it is written
  for an agent that can act, so each line may carry a remedy — built only
  from a fixed template set (refresh, remove, add, fork, findings) with
  validated identifiers in argument positions, while free text from
  sources or errors renders in quoted informational positions, never in
  a command position.
