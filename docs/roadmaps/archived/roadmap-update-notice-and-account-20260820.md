# ROADMAP PLAN — update-notice-and-account

Created 2026-08-20. **Plan data**: docs/roadmaps/roadmap-update-notice-and-account.json

Research: docs/plans/update-notice-and-account.md (GPT 5.6 Sol-reviewed feature plan) · Origin: None · Hierarchy: none · Risk: medium (external gates on self-update; plan itself well-hardened)

## PROJECT: Update Notice & Account (new, team KEN, no initiative)

Sidebar update notice with per-install-method actions, signed self-update, and the account surface across app and kendex.ai — implements docs/plans/update-notice-and-account.md. One project for both parts; web (kendex-web) issues live in the same project. No project relations.

## ISSUES (30 total, 8 bundles; all containers, children ship as their own PRs)

| # | Title | Est | Agent | Pri | Parent | Deps |
|---|-------|-----|-------|-----|--------|------|
| 1 | App update check backend (bundle) | — | rust | P1 | — | — |
| 2 | Extract: rotation-safe bearer helper into registry/client.rs; capability-aware degradation | 2 | rust | P1 | — | — |
| 3 | Add: strict shared update-feed schema in core; CLI ported with downgrade refusal | 3 | rust | P1 | #1 | — |
| 4 | Migrate: device tokens gain label, rate-limited last_used_at, opaque device_id | 3 | generalist | P1 | — | — |
| 5 | Account API on kendex.ai (bundle) | — | generalist | P1 | — | — |
| 6 | Add: aggregate GET /api/v1/me with per-section errors + shared contract fixtures | 3 | generalist | P1 | #5 | — |
| 7 | Install provenance (bundle) | — | rust | P1 | — | blocked by #1 |
| 8 | Add: app update check — cache generation, status model, settings fields, app_update_check command | 3 | rust | P1 | #1 | #3 |
| 9 | Add: install-provenance channel resolution — closed-enum markers, baked default, fail-closed, AUR copy constants | 3 | rust | P1 | #7 | — |
| 10 | Add: avatar proxy GET /api/v1/me/avatar (allowlist, caps, no SVG, content-hash cache) | 3 | generalist | P1 | #5 | #6 |
| 11 | App account backend (bundle) | — | rust | P1 | — | blocked by #2 #5 #16 |
| 12 | Add: aggregate me client, account-state enum, identity commands | 4 | rust | P1 | #11 | — |
| 13 | Sidebar update notice surface (bundle) | — | generalist | P2 | — | blocked by #1 #7 |
| 14 | Add: notice store + sidebar update card (mute-by-version, startup-owned load, dev mocks) | 3 | generalist | P2 | #13 | — |
| 15 | App account surface (bundle) | — | generalist | P2 | — | blocked by #11 #16 #2 #5 |
| 16 | Add: devices section in /api/v1/me + DELETE /api/v1/me/devices/{id} (no-oracle, revoked_current_device) | 3 | generalist | P1 | — | blocked by #4 #5 #17 |
| 17 | Web account pages (bundle) | — | generalist | P1 | — | blocked by #5 |
| 18 | Rename: Your page to My account across shipped copy + case-insensitive copy test | 1 | generalist | P1 | #17 | — |
| 19 | Migrate: /me page onto the aggregate with avatar + Collections sections | 2 | generalist | P1 | #17 | #18 |
| 20 | Replace: boolean sign-in state with account-state enum store (single startup load, identity, mocks) | 3 | generalist | P2 | #15 | — |
| 21 | Add: hardened avatar fetch and cache in the app | 2 | rust | P2 | #11 | #12 |
| 22 | Add: sidebar account row (signed-in / signed-out / offline / expired) | 2 | generalist | P2 | #15 | #20 |
| 23 | Signed self-update delivery (bundle, owner-gated) | — | rust | P2 | — | blocked by #1 #7 |
| 24 | Add: tauri-plugin-updater self-update — install/restart commands, signed latest.json in release, cask auto_updates | 5 | rust | P2 | #23 | — |
| 25 | Ship: provenance marker files in PKGBUILD and install.sh | 1 | rust | P2 | #7 | #9 |
| 26 | Add: Settings About update rows (check now, last-checked status, auto switch, Notify again) | 2 | generalist | P2 | #13 | #14 |
| 27 | Render: per-install-method card action (Update now / Copy command / View release notes) | 2 | generalist | P2 | #13 | #14 |
| 28 | Add: header account island (Log in / avatar to /me), shell stays static | 2 | generalist | P2 | #17 | — |
| 29 | Add: Account page (signed-in/out modes, sections, revoke, device flow moves in) + Settings links here | 4 | generalist | P2 | #15 | #20 #22 |
| 30 | Update: install.sh family updates — app and CLI move together, skew tested | 3 | rust | P3 | #23 | #24 |

## EXISTING WORK AFFECTED

No duplicates, no cancellations. Two coexisting conflicts (confirmed by architecture review), recorded as `related` links:

| Issue | Interaction | Handling |
|-------|-------------|----------|
| KEN-394 (Mac app ad-hoc signed; Gatekeeper "damaged") | macOS self-update onto an ad-hoc-signed .app can re-trigger the damaged state | macOS self-update does not ship to users before KEN-394 closes; U3 smoke checklist exercises macOS relaunch |
| KEN-395 (no Intel-mac / linux-arm64 builds) | Feed carries no asset for some machines | Missing-platform asset degrades to "View release notes", never an error |

## ARCHITECTURE GAPS

None. Architecture-review deltas folded into issue scopes: CLI feed-fixture tests move with the schema port (#3); kendex-web releases.ts is a second feed parser (#3); server-side capability issuance (collection:read, device:manage) lives in #16; sign-in client-label capture touches registry/login.rs (#12); Settings account row updates with the binding change (#12). Ordering fix: App account surface no longer waits on the notice surface — the sidebar-bottom slot is created by whichever half lands first.

## BREAKING CHANGES

| Boundary | Impact | Migration |
|----------|--------|-----------|
| feed.json | Schema version field | Additive; shipped CLIs and kendex-web /download parser keep working |
| Account status TS binding | Boolean → 5-state enum | Settings account row updated in the same change |
| /api/v1/me/accounts | Superseded by aggregate /api/v1/me | Old route kept for existing CLIs |
| Device tokens | DB migration (label, last_used_at, device_id) | Wire shape unchanged |

## DECLINED (0)

All 22 proposals passed the creation bar.
