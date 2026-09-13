# Sidebar notices + app updates, and the account surface

Two features, one plan, because they share the bottom of the sidebar:

1. **A notice card at the bottom of the sidebar** (Vercel-style), whose
   first and only producer is "a new version of kendex is available".
   (Written as "the right update action per install method"; that half
   was cancelled 2026-08-22 — see the descope section below.)
2. **The app knows who you are**: an account row at the very bottom of
   the sidebar, a login/avatar surface in the kendex.ai header, and
   "Your page" renamed to **My account**. (Written with a new Account
   page in the app showing the same things as the web page; cancelled
   2026-08-22 — the app's identity lives in Settings > Account.)

Written after reading ARCHITECTURE.md, the marketplaces plan, the
sidebar/nav/settings/account code in the app, the full kendex-web repo,
and researching updater practice (tauri-plugin-updater v2.10+, VS Code,
Zed, Discord anti-pattern, AUR norms). Owner gates marked **[owner]**.

Review: GPT 5.6 Sol adversarial pass, 2026-08-20 — 1 critical / 7 high
/ 4 medium, all verified against the code and folded in below. The
biggest turns: install provenance is a **marker file packages install**,
never a value baked into the shared AppImage (C1); the unsigned feed is
**discovery-only** and never supplies an install URL (H7); account
parity rides **one aggregate `GET /api/v1/me`** (H5); and devices need
a schema migration before any UI lists them (H3). Three of those four
turns describe work the 2026-08-22 descope cancelled. Only H7 still
holds, and trivially, because nothing self-updates.

## The update half shipped, 2026-08-28 — read this first

The 2026-08-22 descope of the update side was **reversed** by the owner on
2026-08-27, and the floor shipped the next day as KEN-715 (#1721, commit
`bdad8a1b9`). Every "cancelled 2026-08-22" marker below that concerns
updates is therefore stale as a decision — it is kept only as the reasoning
that produced the design. The account half's cancellations still stand.

What shipped, which is what to read the sections below against:

- A card at the foot of the sidebar naming both versions, muted by version,
  refused mid-install so a failure cannot be hidden behind a dismissal.
- Its action follows who owns the running bytes: **Update now** where kendex
  can replace them, the package manager's own command where it cannot, and
  the release-notes link alone where nothing could tell.
- Channel resolution reads the running path, resolved once at each shell's
  boundary. **No marker files** — §1.2's provenance design was not built;
  the AUR AppImage is distinguished by where it sits, not by what it
  carries. `APPIMAGE` is trusted only when the executable is inside
  `APPDIR`, because AppRun exports it to every child.
- `kendex update` makes the same judgement, and on a direct install updates
  the AppImage before the command — the command's version is the state
  marker for the whole install, so it is written last.
- Delivery is a minisign-signed `latest.json` beside `feed.json`; the feed
  stays discovery-only. §1.3's "the release-notes link is now the whole
  delivery path" no longer holds.
- The [owner] gate §1.5 records is live again and is now blocking rather
  than optional: an unset `TAURI_SIGNING_PRIVATE_KEY` fails the tag outright.

Follow-ups filed out of that work: KEN-718 (the CLI writes the AppImage on
TLS trust alone), KEN-719 (manifest tests transcribe staging), KEN-720 (the
managed early return is untested), KEN-721 (the updater rebuilds its install
path), KEN-722/723 (macOS test failures in a lane that gates nothing).

The 2026-08-24 audit folded the leftover single-child containers into their
parents; that still holds.

Still in scope from the original descope, unchanged:

| Issue | What ships |
|---|---|
| KEN-415 | app update check: typed feed struct, semver compare, one check per 6h, last result remembered |
| KEN-421 | notice store and sidebar card, muted by version, plus Settings' check-now and Notify again |
| KEN-418 | `GET /api/v1/me` returning identity only, `{name, github_login}` |
| KEN-420 | app-side me client, account-state enum, identity commands |
| KEN-416 | rotation-safe bearer helper extracted into `registry/client.rs` |
| KEN-435, KEN-437, KEN-443 | account-state store, sidebar account row, Settings > Account extended in place |
| KEN-433, KEN-434, KEN-442 | the My account rename, a Collections section on `/me`, the header account island |

Cancelled:

| Cut | Issues | Instead |
|---|---|---|
| ~~Install-provenance markers and the per-install-method card action~~ **reversed 2026-08-27** | KEN-419, KEN-429, KEN-439, KEN-441 | the per-install-method action shipped in #1721; the markers did not, and are not needed — the channel is read from the running path |
| ~~Signed self-update: tauri-plugin-updater, signed `latest.json`, the install.sh app+CLI flow~~ **reversed 2026-08-27** | KEN-425, KEN-438, KEN-444 | the updater and signed `latest.json` shipped in #1721; app-and-CLI-together lives in `kendex update`, not install.sh. The KEN-394 revisit gate is spent |
| The aggregate `GET /api/v1/me` with per-section errors and cross-repo contract fixtures | KEN-427, folded into KEN-418 | identity only, `{name, github_login}` |
| The avatar proxy and the app's hardened avatar cache | KEN-430, KEN-436 | initial-letter avatars, no remote image on either surface |
| Connected devices: the token-family migration, the devices section, `DELETE /api/v1/me/devices/{id}` | KEN-417, KEN-423 | device management served under 1% of users; `kendex logout` covers it |
| A separate Account page in the app | KEN-443, rewritten 2026-08-23 | Settings > Account grows in place. No new page, no nav entry |

The project also carries the packages Updates page family: KEN-447
(done), KEN-460, KEN-462, KEN-573. That is a different feature and this
doc does not describe it.

## Part 1 — Sidebar notices and "update available"

### 1.1 What the person sees

Bottom of the sidebar, above the (new) account row:

```
  ⚙ Settings

 ┌─────────────────────────────────┐
 │ Update available   v5.1.0    × │
 │ kendex 5.1.0 is ready — you     │
 │ have 5.0.1.                     │
 │ ┌─────────────────────────────┐ │
 │ │        Update now           │ │
 │ └─────────────────────────────┘ │
 │ View release notes              │
 └─────────────────────────────────┘
 ◉ vgmethod                        ← Part 2's account row
```

Post-descope the card has one action, **View release notes**, plus a
line saying to update the way you installed. The Update now button
drawn above was cancelled 2026-08-22 with self-update (KEN-425).

- One card, not a stack. Title + version badge, one sentence, one
  primary button, a quiet release-notes link, and × to dismiss.
- **Dismiss = mute that version.** `5.1.0` dismissed stays gone; `5.2.0`
  notifies again. Mirrors the existing `ignored_updates` pattern
  (`core/settings.rs`, "Notify again" copy) — the muted version is
  listed in Settings ("Update notices: 5.1.0 muted · Notify again").
- The card animates in once per session (session state owned by the
  store, never by a remounting component), never blocks anything, never
  interrupts. No launch wall ever (the Discord anti-pattern).

### 1.2 The primary action depends on how kendex was installed

> **Shipped 2026-08-28 (#1721), but not the way this section designs it.**
> The per-install-method action is real: Update now, the manager's own
> command, or the release-notes link. The marker files are not, and are not
> planned — the resolver reads the running path instead, so the table below
> is the right behavior reached by a different mechanism. Read it for the
> reasoning, not the implementation; `crates/core/src/install_channel.rs` is
> the implementation. The one design point here that survived intact is
> C1's premise: the AUR package repackages the released AppImage, so nothing
> about the channel can be baked at build time.

**Install provenance is a marker, not a baked value** (review C1). The
release workflow runs one app build per OS and every Linux bundle —
AppImage, deb, rpm — comes out of it, and the AUR `kendex-bin` package
downloads that exact release AppImage; a compile-time channel therefore
cannot tell an AUR install from a direct download. Instead:

- The binary bakes only a **default** (`selfupdate` for release builds,
  `none` with an explanation string for source builds — the
  `ZED_UPDATE_EXPLANATION` pattern).
- Each package installs a small root-owned marker beside the app
  (`/usr/lib/kendex/update-channel.json` for `kendex-bin`:
  `{kind:"aur", package:"kendex-bin"}`; deb/rpm ship their own kinds
  when they graduate to repos); `install.sh` writes a `selfupdate`
  marker in the user data dir. Markers parse as a **closed enum** —
  owner/type/size validated, never arbitrary command text.
- **Fail closed**: no marker + a bundle path the process cannot write
  (or that a package owns) → the action degrades to **View release
  notes**, never a self-update attempt against pacman-owned bytes.
- Runtime env (`APPIMAGE`) only refines *how* a selfupdate proceeds.
- Artifact-level tests launch the *same* AppImage under each
  marker/path combination and assert the resulting action.

| Install method | How we know | Button | What it does |
|---|---|---|---|
| Linux AppImage (install.sh or downloaded) | `selfupdate` marker (install.sh) or writable `$APPIMAGE`, no package marker | **Update now** | tauri-plugin-updater replaces the AppImage in place, button becomes **Restart to update** → relaunch |
| macOS .dmg / Homebrew cask | default channel, writable .app | **Update now** | plugin swaps the .app, restart; the cask declares `auto_updates true` so `brew upgrade` stays out of the way (sanctioned pattern) |
| Windows (NSIS/MSI) | default channel | **Update now** | plugin runs the installer passively; app exits into it and restarts |
| .deb / .rpm from our releases | `__TAURI_BUNDLE_TYPE` (bundler-baked per bundle) | **Update now** | plugin ≥2.10 installs via dpkg/rpm behind a pkexec prompt |
| **AUR (`kendex-bin`)** | the package's marker file | **Copy command** | copies one complete constant from a closed list — `paru -S kendex-bin` / `yay -S kendex-bin`, chosen by which helper is present on PATH; neither present → helper-neutral prose "update kendex-bin with your AUR helper". Only `kendex-bin` carries the app; the CLI-only AUR packages get no channel |
| Source / unknown / unwritable | fallback | **View release notes** | opens the GitHub release page |

**Why we never run the AUR helper for the person** (the one place this
plan deliberately differs from "offer to run it in a shell"): AUR
helpers must not run as root but need sudo mid-run, pacman holds a
global lock our invocation would collide with, and installing one
package without a full system upgrade is against Arch practice — every
serious app (VS Code, Zed) stops at instructions here, and the ones
that push harder (Discord) get routed around and resented. Copy-command
is the accepted ceiling, and it is one click + one paste.

**App and CLI move together, per install family** (review H1 —
install.sh, `kendex-bin` and the brew pair each install the CLI as a
separate file, and the app self-updating alone would leave terminal
automation on the old version):

- Package-managed installs (AUR, future deb/rpm repos, brew): the
  package updates both; the app never self-updates either half.
- install.sh installs: **Update now updates both** — the plugin swaps
  the app, and the same flow runs the CLI's existing feed download over
  the CLI binary before relaunch; failure of either half is reported
  and neither is left silently mismatched.
- Direct .dmg/.msi (no CLI on disk): app-only, nothing to skew.
- Tests pin `app_version == kendex --version` after each family's
  update path, plus both skew directions (older CLI reading state
  written by a newer app).

### 1.3 How the check works

> **Reduced 2026-08-22.** KEN-415 carries the typed feed struct, real
> semver compare, one check per 6h and a remembered last result. The
> signed-artifact half of this section went with KEN-425.

- **One strict feed schema, shared with the CLI** (review H7). The CLI
  already reads
  `https://github.com/vanillagreencom/kendex/releases/latest/download/feed.json`
  with a loose parser that accepts any strings and "updates" on mere
  version *inequality* — a downgrade. That parser moves into
  `core/app_update.rs` as a versioned, capped schema (body and field
  caps, unknown schema refused) that both shells consume; version
  compare is real semver (`semver` crate — one small new dep, justified
  in its commit) and **downgrades are refused** everywhere except an
  explicit CLI-only `--force`.
- **The feed is discovery-only.** It may say "5.1.0 exists"; it never
  supplies an install URL the app acts on. The release-notes link is
  synthesized from the validated version (`…/releases/tag/v5.1.0`),
  never taken from feed text. Signed delivery was cancelled 2026-08-22
  (KEN-425), so the release-notes link is now the whole delivery path.
  As written: self-update (U3) discovered and verified through
  tauri-plugin-updater's own **signed** `latest.json` (minisign,
  `createUpdaterArtifacts: true`), so an attacker who could swap the
  unsigned feed could at most show a card whose Update action then
  failed signature verification, not deliver bytes.
- `KENDEX_UPDATE_FEED` stays a CLI/dev affordance; **release GUI builds
  ignore it** (dev builds honor it for fixture tests).
- Transport is the existing `Fetch`/`CurlFetch` seam with a cache
  generation (ETag, TTL 6h) — but with an honest status model (review
  M2): `last_attempt_at`, `last_success_at`, served-feed age and a
  typed last error are stored separately, so Settings' "last checked"
  means one thing; a manual **Check for updates** reports its failure
  in Settings; automatic failures stay silent in the sidebar (the card
  only ever announces a real, currently-believed update, and a feed
  that rolls back clears the notice).
- Checked in the background after startup (never on the startup
  critical path), at most every 6h; auto-check has an **off switch**
  ("Check for app updates automatically"). Privacy: this is the app's
  only contact with github.com outside marketplace git fetches; said in
  Settings, and ARCHITECTURE's privacy note is amended in the same
  change.

### 1.4 Architecture (part 1)

```
crates/core/src/app_update.rs   NEW  strict shared feed schema + semver compare + channel
                                     resolution (marker > baked default, fail-closed) +
                                     cached generation with the M2 status fields
crates/cli/src/commands/update.rs   consumes the core schema; refuses downgrades sans --force
crates/app/src/commands.rs      app_update_check(refresh)
                                [cancelled: update_channel(), app_update_install(),
                                 app_update_restart()]
crates/core/src/settings.rs     AppSettings + muted_app_notice: Option<String>
                                + auto_update_check: bool (default true)
ui/src/stores/notice.ts         NEW  notice or null; dismiss(version); session animation state
ui/src/components/sidebar-notice.tsx  NEW  the card; rendered after <nav> in sidebar.tsx
ui/src/pages/settings.tsx       About: Check for updates + last-checked/status + auto switch
                                + muted-notice "Notify again"
.github/workflows/release.yml   feed.json (schema-versioned)
                                [cancelled: signed latest.json]
[cancelled] packaging/arch/kendex-bin/      installs the aur marker file
[cancelled] packaging/homebrew/kendex-cask.rb  auto_updates true
[cancelled] install.sh          writes the selfupdate marker; updates app+CLI together
```

Startup owns one parallel load (review M3): settings, update notice,
and the account snapshot join the existing side-by-side startup reads;
sidebar and Settings both subscribe to those stores —
no surface fires its own duplicate fetch, pinned by a test that
navigating between them still makes one account request and one feed
request.

ARCHITECTURE amendments (same change): the sidebar gains a notice
surface (one card, muted-by-version), and the privacy note gains the
update feed.

The pasteable-command exception below was **cancelled 2026-08-22** with
the AUR action (KEN-441): the "never emit a pasteable command line"
decision keeps its single drift-report exception, and nothing in the
notice card reaches the clipboard. What it would have said: the AUR
update instruction is one of a closed list of complete build-time
constants (`paru -S kendex-bin`, `yay -S kendex-bin`), chosen by helper
presence, reaching only the clipboard — no feed, source or error text
can ever reach it, pinned by test.

### 1.5 Phases (part 1)

> **Superseded 2026-08-28.** U1 shipped as written (KEN-415, KEN-426,
> KEN-428). U2 and U3 were cancelled, then reversed, and the outcome went in
> as one floor issue (KEN-715, #1721) rather than as these two phases: U3's
> updater, signed `latest.json` and app-and-CLI flow all shipped; U2's
> marker files did not and will not. The [owner] gate below is live and now
> blocks the tag rather than degrading it.

| # | Phase | Delivers | Tests that pin it |
|---|---|---|---|
| U1 | **Feed schema + notice** | shared strict feed schema in core (CLI ported onto it, downgrade refusal), `app_update.rs` check + status model, notice store + sidebar card, mute-by-version, Settings About rows + off switch, release-notes link synthesized from version | newer→notice / equal / older→none (both shells); malformed or unknown-schema feed is a typed error, no card; GUI ignores `KENDEX_UPDATE_FEED` in release builds; dismiss mutes exactly that version; TTL + M2 status fields under a controlled clock (stale-newer, 304, rollback clears notice, off→on); one feed request across surfaces; mock-driven agent-browser pass on the card |
| U2 | **Provenance** | marker files (PKGBUILD + install.sh), baked defaults, closed-enum parsing, fail-closed writability check, per-channel card copy (AUR closed-constant copy, `none` explanation) | same AppImage under each marker/path combination yields the asserted action; marker with junk content → fallback, never a command; AUR copy is byte-equal to a listed constant; clipboard never receives feed/source text |
| U3 | **Self-update** | tauri-plugin-updater (≥2.10), signed `latest.json` (independent discovery + verification), Update now → progress → Restart to update, Windows exit-into-installer, install.sh family updates app+CLI together | update applies from a signed local fixture; tampered signature fails and the app stays usable; post-update `app_version == kendex --version` per family; skew tests both directions; relaunch per OS in the release smoke checklist |

**[owner] gates:** one, live and blocking. The updater signing keypair was
generated for #1721 and its public half is pinned in
`crates/app/tauri.conf.json`; `TAURI_SIGNING_PRIVATE_KEY` and
`TAURI_SIGNING_PRIVATE_KEY_PASSWORD` must be set on the repository or the
next tag produces no release at all — the gate no longer degrades to an
unsigned build. A private key that does not match the pinned public half
builds a release every user's Update button then refuses. The KEN-394
revisit condition KEN-425 recorded is spent.

## Part 2 — The account surface, app + web

### 2.1 What exists already (so this part is mostly assembly)

- kendex.ai is live with GitHub sign-in (BetterAuth), a full device
  flow, opaque revocable tokens, and a signed-in page at `/me` titled
  **"Your page"** (name, email, GitHub connection, your marketplaces,
  sign out).
- The app + CLI already sign in: `kendex login|logout`, device-flow
  client (`core/registry/login.rs`), keychain storage, and a Settings →
  Account row with Sign in / Sign out (`account-section.tsx`).
- **The gaps** (verified in review): no identity anywhere in the app
  (`AccountStatus` is `{signed_in, endpoint}`); no login surface in the
  site header; `/me` lacks collections and devices; tokens carry no
  label or last-used column; device tokens hold only
  `submission:read/write` so collections would 401; the rotation-aware
  bearer helper is private to `submit.rs`; the site CSP blocks
  external avatar images by design.

### 2.2 App: sidebar account row + Account page

> **Amended 2026-08-22 / 2026-08-23.** The sidebar account row ships
> (KEN-437) with an initial-letter avatar and no remote image, and it
> opens **Settings > Account**, which grows identity, Sign out and the
> device-flow sign-in in place (KEN-443). The separate Account page and
> its marketplaces, collections and devices sections were cancelled.
> The account-state enum (KEN-435) survives unchanged.

Sidebar bottom (below the notice card when one is showing):

```
 signed in:                          signed out:
 ┌─────────────────────────────┐    ┌─────────────────────────────┐
 │ ◉ vgmethod                  │    │        Sign in              │
 └─────────────────────────────┘    └─────────────────────────────┘
```

- Signed in: avatar + GitHub handle, one row, click → **Account** page.
- Signed out: a quiet Sign in button, click → the same destination in
  its signed-out mode (post-descope, Settings > Account), which hosts
  the device flow: code shown, browser opened, polls — the flow
  `account-section.tsx` already runs.
- Account state is a real enum (review H2): `loading | signed_out |
  signed_in(identity) | offline(cached identity) | expired` — a
  credential in the keychain alone never renders as "signed in" while
  every request 401s; `expired` renders the row with a quiet
  "Sign in again".

**Account page** — **cancelled 2026-08-23** (KEN-443 rewritten). What it
would have been: a new `Page` member `account`; base page, no
breadcrumb; not in the NAV list — reached from the sidebar row and from
Settings → Account, which keeps its row but links here for the details:

```
Account
◉  vgmethod        Victor Method · legal@hyprtrade.io
   GitHub connected                              [Sign out]

Your marketplaces ────────────────────────────────
  vanillagreencom/kendex     Listed · @a1b2c3d    [View listing]
Collections ──────────────────────────────────────
  Starter set · unlisted                          [Open on kendex.ai]
Connected devices ────────────────────────────────
  CLI · this machine · signed in 2d ago           [Revoke]
```

Rows that only make sense in a browser (collection editing) would have
opened kendex.ai via `open_url`. What Settings > Account actually shows
is identity, Sign out, and the device-flow sign-in.

### 2.3 Web: header + My account

- **Header**: right side gains the account island — signed out a
  **Log in** link, signed in the avatar, click → `/me`. No dropdown
  menu (one destination, one click). The header stays a static server
  component: the island is a small client component fetching the
  aggregate below, the exact pattern `/me`, `/submit` and `/device`
  already use, so no page goes dynamic and the CSP stands.
- **Rename** (review M4 — the two real shipped occurrences): the `/me`
  H1 "Your page" (`me/page.tsx:82`) and the `/submit` link copy "your
  page" (`submit/page.tsx:119-124`) become **My account** / "my
  account"; the route comment in `me/accounts/route.ts` follows. The
  `/collections` link labeled "Sign in" is already correct and keeps
  its label. The copy test is **case-insensitive** over rendered
  user-facing strings, and also asserts the intended new labels.
- **Parity additions to `/me`**: a Collections section (KEN-434). The
  **Connected devices** section with per-row revoke was cancelled
  2026-08-22 (KEN-417, KEN-423), and the identity block's avatar is an
  initial letter, not a fetched image (KEN-430 cancelled).

### 2.4 Shared plumbing (what makes parity real)

> **Descoped 2026-08-22.** Of this section, only the bearer-helper
> extraction (KEN-416) and an **identity-only** `GET /api/v1/me`
> returning `{name, github_login}` (KEN-418) survive. The per-section
> error envelope, cross-repo contract fixtures, the devices migration
> and revoke contract, and the avatar proxy are all cancelled.

**One aggregate, both surfaces** — as written (review H5 — identity, marketplaces,
collections and devices live in three different routes today, so "two
APIs" was false and a heading-count parity test would lie):

- **New `GET /api/v1/me`** (web). Post-descope it returns identity
  only, `{name, github_login}`, session- and bearer-usable, with the
  lists staying on their existing routes; `github_login` comes from the
  GitHub provider row's immutable `accountId` mapping, validated, never
  parsed from free text. As written, and cancelled 2026-08-22:
  versioned `{identity{name, email, github_login, avatar_url},
  submissions[], collections[], devices[]}` with **independent
  per-section errors** (one failing join degrades its section, never
  the page), consumed by both `/me` the page and the app's Account
  page, with the parity gate being **shared response fixtures
  contract-tested in both repos**, not a heading list.
- **Devices need a schema migration first** (review H3) — **cancelled
  2026-08-22** (KEN-417); device management is worth less than the
  migration it costs. As written: token families
  gain a sanitized client label (captured at device-code creation:
  "kendex app" / "kendex CLI"), a rate-limited `last_used_at`, and a
  server-generated **opaque `device_id`** (raw family ids never become
  public handles). One row per family; rotation preserves identity;
  revoked/expired families drop out after a stated retention. Browser
  sessions have no family — the web page lists them as none (its own
  session is BetterAuth's, shown separately if at all).
- **Revoke is a second, authenticated contract** (review H4) —
  **cancelled 2026-08-22** (KEN-423); `kendex logout` stays the whole
  story, and the existing possession-based revoke is untouched. As
  written: the
  existing possession-based `POST /api/v1/tokens/revoke {token}` stays
  exactly as is (it is `kendex logout`). Device management adds
  `DELETE /api/v1/me/devices/{device_id}`: caller derived first,
  same-origin enforced for cookie auth, one
  `UPDATE … WHERE device_id AND user_id` mutation, identical
  status/body for absent, foreign, already-revoked and just-revoked ids
  (no oracle), per-user rate limit after auth. Revoking the device a
  bearer call arrived on returns `revoked_current_device` and the app
  clears its keychain credential atomically.
- **The bearer client becomes a shared core primitive** (review H2):
  the rotation-aware authenticated-call helper moves out of
  `registry/submit.rs` into `registry/client.rs` and every bearer API
  uses it — refresh on 401, one-use rotation respected, and the
  CLI-vs-app concurrent-refresh race tested (a lost race must not burn
  the family). Capabilities grow `collection:read` and `device:manage`;
  **already-issued tokens are never silently broadened** — an old
  credential that lacks a needed capability renders that section as
  "sign in again to see this", and one re-login (clearly worded)
  upgrades it.
- **Avatars cross a trust boundary and get a pipeline** (review H6) —
  **cancelled 2026-08-22** (KEN-430, KEN-436); both surfaces draw an
  initial-letter avatar and neither loads a remote image, so the trust
  boundary is never crossed and the CSP needs no proxy. As written:
  the site serves avatars **same-origin** — `GET /api/v1/me/avatar`
  proxies the GitHub avatar derived from the validated immutable
  GitHub account id (`avatars.githubusercontent.com/u/<id>` — host
  allowlisted, https only, redirects re-validated, byte + dimension
  caps, raster MIME only, no SVG, cached by content hash with TTL) —
  so CSP stays `img-src 'self' data:`. The app fetches through the
  same narrow rules via hardened curl into its cache (TTL, not
  fetch-once — a changed avatar follows), initial-letter fallback,
  and the webview never loads a remote image. Hostile-redirect,
  oversized, wrong-MIME, SVG and stale-cache tests on both sides.

Signed-out app behavior: everything keeps working (nothing new
requires an account — unchanged rule); the row is the only ask.

### 2.5 Phases (part 2)

> **Amended 2026-08-22.** A1 ships without the avatar proxy and with an
> identity-only endpoint; A2 is cancelled entirely; A3 ships without
> the avatar cache, without the Account page, and with Settings >
> Account extended in place.

| # | Phase | Delivers | Tests that pin it |
|---|---|---|---|
| A1 | **Web: identity + header + rename** | `GET /api/v1/me` (identity section + existing submissions/collections joins), avatar proxy route, header account island (Log in ↔ avatar → /me), the M4 rename | aggregate contract fixtures; per-section error degradation; avatar proxy's hostile-input battery; island renders both states; case-insensitive copy test; shell stays statically rendered |
| A2 | **Web: devices** | token-family migration (label, last_used_at, opaque device_id), devices section in `/api/v1/me` and on the page, `DELETE /api/v1/me/devices/{id}` | list scoped to the caller; rotation preserves device identity; concurrent use does not amplify writes; revoke: cross-user, CSRF, same-shape-response, current-device cases; family dead within one request |
| A3 | **App: account row + page** | `registry/client.rs` (shared rotation-safe bearer helper) + capability additions, `registry/me.rs` consuming the aggregate, account-state enum, avatar cache, sidebar row (all states), Account page (signed-in/out), Settings → Account links here, startup-owned load, mocks + bindings | concurrent CLI/app refresh never burns a family; hour-old token refreshes transparently; old-capability credential shows the per-section re-login ask, not a broken page; both repos' contract fixtures agree; identity cleared on logout; revoke-current clears the keychain; one account request across surfaces; agent-browser pass over row + page in every state |

Order: A1 → A3 (the app consumes A1's endpoint; A2 is cancelled).
Part 2 is independent of Part 1; the sidebar layout lands once (notice
card slot above account row) in whichever ships first.

## Decisions — say if you disagree

> Decisions 2, 4, 5 and the delivery half of 3 were **cancelled
> 2026-08-22**; decision 8 was reduced to an identity-only endpoint.
> They are kept below so the reasoning is not re-derived.

1. **Notify-first, self-update second.** The card ships before any
   signing key exists (U1/U2); tauri-plugin-updater lands behind the
   [owner] key gate (U3). Never a launch-blocking update.
2. **Provenance is the running path, not a marker.** Cancelled 2026-08-22,
   reversed 2026-08-27, and then shipped without the markers: #1721 resolves
   the channel from where the running bytes sit and whether they can be
   replaced. The fail-closed half held — an unrecognised install is told to
   update the way it was installed and is never replaced in place.
3. **The unsigned feed only discovers.** Downgrades refused; release
   GUI builds ignore the feed override. The "signed artifacts deliver"
   half is live again as of #1721: a minisign-signed `latest.json`,
   published beside the feed and verified independently of it.
4. **AUR gets a fixed command from a closed constant list, never an
   execution.** The closed list shipped (`paru -S <pkg>` / `yay -S <pkg>`,
   helper-neutral prose when neither is present). The clipboard did not:
   the card shows the command as text to read and copy by hand, so the
   pasteable-command exception was never needed.
5. **App and CLI update as one family.** Shipped in `kendex update`, not in
   install.sh: on a direct install it replaces the AppImage first and the
   command last, so the command's version is the state marker for the whole
   install and a failed half always retries.
6. **One notice card, muted by version** — not a notification center,
   until a second real producer exists.
7. **"My account" is the name on both surfaces; the web route stays
   `/me`.** Clicking the avatar goes straight there — no dropdown.
8. **`GET /api/v1/me` is the one identity endpoint both surfaces
   read**, returning `{name, github_login}`. The aggregate response and
   the cross-repo contract fixtures were cancelled 2026-08-22; the
   surfaces no longer show the same lists, so there is no parity gate.
9. **Tokens never silently widen.** New capabilities arrive by an
   explicit re-login; old credentials degrade per section, honestly.
10. Sign-in stays optional everywhere; the sidebar row is an offer,
    not a gate.
