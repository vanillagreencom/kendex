# Releasing

One workflow, tag-driven:

```
git tag v0.1.0 && git push origin v0.1.0
```

`.github/workflows/release.yml` builds on a native GitHub-standard runner
per target (Linux x86_64 and aarch64, macOS aarch64 and x86_64, Windows
x86_64; all free for a public repository) and publishes a **draft** GitHub
Release with:

- `kendex-<target>[.exe]` — the CLI binary, one per target, and the
  `<binary>.sig` a lane signs it into. These are what `kendex update`
  downloads, and it installs neither without the other: a signature the
  release key does not carry over those exact bytes is refused, so a lane
  that produced none fails the tag instead of publishing a command no
  client can verify.
- The desktop app bundles Tauri produces per platform (deb/rpm/AppImage,
  dmg, NSIS installer), and the `.sig` Tauri writes beside each updater
  bundle. `kendex update` fetches `<AppImage>.sig` straight from the
  release, so it is a published asset and not only an input to `latest.json`.
- `latest.json` — the manifest the app's Update button installs from, one
  `{signature, url}` per platform. The publish job writes it from the `.sig`
  files the lanes staged, and names any platform whose signature never
  arrived and fails rather than publishing a release without it. Nothing
  signs the manifest itself, which is what the digests below are for.
- `digests-<target>.json` and its `.sig` — what one lane published, signed
  under the release key: the version, the target, and the SHA-256 of that
  lane's command and app download (`tools/release-digests`). Both shells
  read the document for their own target from the channel they read their
  manifest from, hold it to the release and target they asked for, and
  install nothing whose hash it does not name. A signature proves the bytes
  it covers and not which release they are, so without this a feed or
  manifest that can be served or altered can offer a genuine older
  download, or another platform's, and it verifies.
- `feed.json` — the update feed `kendex update` reads from
  `releases/latest/download/feed.json`. Publishing the draft makes the
  version "latest". New feeds carry `schema: 1`, a SemVer `version`, and an
  `assets` map of HTTPS URLs keyed by Rust target triple. During the schema-1
  transition, readers treat a missing `schema` as 1 but reject any explicit
  unknown value. Keep these fields when adding data.

Review the draft, then publish it. That is the release.

`install.sh` is the exception and says so in its own comments: a machine
with nothing installed has neither the release key nor minisign, so the
script rests on TLS to kendex.ai and github.com. That is every run of it,
not only the first, because the script is the upgrade path too and a re-run
overwrites what is installed with another unchecked download. `kendex
update` is the path held to the key.

## Pre-releases

A tag whose version carries a SemVer pre-release identifier — `v1.0.0-rc1`
— runs the same workflow and takes two different turns at the end. It is
published outright, marked pre-release rather than left as a draft: a
draft's assets are unreachable, and a candidate nobody can download tests
nothing. Being marked pre-release is what keeps it to candidates, since
GitHub resolves `releases/latest` past every one of them.

That same resolution is why a candidate cannot reach the next one through
`releases/latest`. A `channel` job therefore overwrites `latest.json`
and `feed.json` on a fixed `prerelease` release, and a build whose own
version is a candidate reads its updates from there
(`update_channel::feed_url_for`, which the app and `kendex update` both
call with their baked version). A shipped `1.0.0` is on the release channel
and is never offered a candidate; nothing on the machine selects this.

The channel only ever moves forward while it carries a version to compare
against: `tools/release-channel-point` reads that version off its
`latest.json` and leaves the channel alone when it is ahead of the tag being
published, so re-running an older tag cannot roll every candidate back to it.
A channel carrying nothing has no such version, and any tag may take it.
Nothing the job could not establish counts as permission to write — a listing
it could not make, a channel carrying assets but no `latest.json`, a manifest
naming no version, a version that is not SemVer — each of those stops the job
with the channel as it was.

A partial upload is the one failure that leaves the channel changed, and the
job does not repair it. `gh release upload --clobber` deletes an asset before
uploading its replacement, and uploads in parallel, so what the channel
carries afterwards is some mixture of what was there and what landed, and the
run that failed does not read that back. The next tag run does, and the rule
above is the one it applies: a channel carrying assets it cannot read a
version off is refused and needs a person, anything else it takes. So the
failure says what the run did and sends you at that next run, rather than
naming a state it did not establish.

That guard is a job of its own, and the only one holding a concurrency group,
so two candidates cut close together cannot interleave their read and write of
the channel. The group is not a queue: it holds one run and one pending slot,
and each arrival replaces whatever is waiting in that slot. A burst therefore
costs every repoint but two. The first arrival runs, each one after it takes
the pending slot and loses it to the next, and the last is still waiting when
the group frees. Arrival order decides which two survive, not version order: a
`channel` job reaches the group only after its own build and publish, so a
slower older candidate arriving last takes the slot from a higher version
already waiting, and the channel is left behind a candidate that is already
published. Push the newest tag again to move it; the forward-only rule above
makes that safe. What a burst never costs is a release: every tag publishes
its own, outside the group, and a repoint takes seconds.

The channel keeps whatever the last repoint left on it, so a machine on
a candidate stays on candidates until it is moved to a full release by
hand. Cutting candidates for a release means cutting one more when the
final ships, or reinstalling those machines.

The workflow runs on tag push only, never on pull requests. Every lane
builds the CLI and the desktop app together; there is no build cache.
The Intel macOS lane uses `macos-15-intel`, supported until August 2027 —
revisit Intel support then.

## User-supplied gates

- **Updater signing** (`TAURI_SIGNING_PRIVATE_KEY`,
  `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` repo secrets): required. Every lane
  bundles an updater-enabled target, so an unset key fails bundling with
  "A public key has been found, but no private key" and the tag produces no
  release. The public half lives in two files that rotate together:
  `plugins > updater > pubkey` in `crates/app/tauri.conf.json` and
  `UPDATER_PUBLIC_KEY` in `crates/core/src/update_feed.rs`, held equal by
  `crates/app/tests/tauri_config.rs`. A private key that does not match
  signs every artifact of that release under a key nothing trusts, so the
  app refuses to install it and `kendex update` refuses both halves, the
  desktop app and the kendex command.
- **macOS signing + notarization** (the seven `APPLE_*` repo secrets:
  certificate p12 + password, signing identity, team id, and the App
  Store Connect API issuer/key-id/key): all seven set, the two mac lanes
  Developer-ID-sign and notarize the bundles; none set, they build
  unsigned; a partial set fails the lane before bundling.
  Material and gotchas are recorded in the owner's dotfiles AGENTS.md.
- **Windows code signing**: not configured; add a certificate before
  distributing outside GitHub Releases.

## Local packaging

`cd crates/app && ../../ui/node_modules/.bin/tauri build` produces
deb/rpm anywhere; the AppImage step needs FUSE2 for linuxdeploy and may
fail on non-Debian hosts — the release runner covers it. Bundling signs
updater artifacts, so set `TAURI_SIGNING_PRIVATE_KEY` or pass `--no-sign`.

## Changelog

Entries are written one file at a time, under
`changelog.d/<section>/<name>.md` (`changelog.d/README.md` has the format).
Nothing edits `CHANGELOG.md` by hand: the growth-guards `changelog-entries`
lane refuses a line under `## [Unreleased]` that HEAD does not already carry.

Before tagging, run `.agents/skills/growth-guards/scripts/changelog-entries
--collate`. It folds every fragment git carries into `## [Unreleased]` under
its section heading, in Keep a Changelog order and filename order within a
section, then deletes the fragments; no fragments is a no-op. Exit codes
follow the guard family: 0 clean, 1 a fragment or a record the judge refuses,
2 could not run — the fold is that same judging run writing what it just
accepted, so which paths are fragments, where the record's `## [Unreleased]`
section begins and ends, and which headings sit inside it are answers it
already has; nothing is written until every one passes, so `CHANGELOG.md` is
replaced whole or not at all. A record with no section, or one naming a
heading that is no Keep a Changelog section, is the judge's
refusal at the commit that wrote it rather than a surprise at the tag. It
reads each fragment, and `CHANGELOG.md` itself, from the working tree, so it
also refuses a `changelog.d` or a `CHANGELOG.md` the index and the disk
disagree about, rather than publishing an unstaged edit the judge never
measured. A nonzero exit halts the release: read the message, fix
the fragment or `CHANGELOG.md`, run it again. Then rename `## [Unreleased]` to
`## [X.Y.Z] - YYYY-MM-DD` and open a fresh empty one, which leaves the guard
nothing gained to refuse.

**The release commit carries `GROWTH_GUARDS_CHANGELOG_COLLATE=1`:**

```
GROWTH_GUARDS_CHANGELOG_COLLATE=1 git commit -m "chore(release): vX.Y.Z"
```

That declaration is what makes `CHANGELOG.md` count as the changelog entry
the commit owes. The release commit stages the version bump under `crates/`,
which `GROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS` names, and the fragments that
would otherwise be its entry were just deleted by the collator — deleting one
is not writing one. Without the declaration the `commit-msg` lane refuses the
release commit, and `[no-changelog]` would be a lie about a commit that ships
every entry there is.

The same declaration also stands the record scope's comparison down, which
matters when the guard or the commit runs while the collated entries are
still under `## [Unreleased]` — renaming that heading first leaves nothing
gained, so that half is usually already satisfied. It bypasses the comparison
alone, and is read at one point so that stays true: a record that is a
symlink, binary or not valid UTF-8, one carrying an unclosed fence or a
second `## [Unreleased]`, one staging that heading away, and one deleted
outright are all refused either way.

## Version bumps

The workspace version in `Cargo.toml` and `crates/app/tauri.conf.json`
must match the tag (minus the `v`). The publish job enforces it: it reads
the version back out of the CLI it just built and stops the tag when the
two differ, so a tag naming a version no artifact carries never publishes
a feed. `crates/app/tests/tauri_config.rs` holds the two config files to
one version, and Cargo refuses a version that is not SemVer, which is what
makes the version the tag is held to one the app can parse.
