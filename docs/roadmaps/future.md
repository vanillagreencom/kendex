# Future considerations

Ideas deliberately out of scope for the current cycle. This file outlives
plan cycles; prune entries when they ship or die.

## Browsable marketplace registries

v0.2 consumes marketplace-shaped repos as catalogs (add a repo, browse
its bundles in the existing Sources/Library pages, install). A dedicated
store-like browsing experience is future work:

- **Multiple registries side by side** — the wshobson-style
  `marketplace.json` registries, the Vercel skills marketplace, and
  other community indexes as first-class browsable sources.
- **Add-your-own registry** — point vstack at any repo or index URL and
  get the same browse/install experience as the built-ins.
- **Store UX** — categories, search, version display, author/license
  surfacing, per-item quality/safety scores (the Phase 5 scoring
  framework already computes these; a registry view would display them
  pre-install).
- **Trust model** — registries are third-party content; the safety
  scoring gate and provenance rules apply before anything installs.

## Instruction-file management

`CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md` and friends
are not an ItemKind. If this ever changes, it is its own cycle: these are
files users hand-edit daily — the riskiest ground the never-clobber
invariant covers.

## Distro release pipelines

The `.claude/skills/app-deploy` skill holds the release seam; Arch,
Fedora, Ubuntu (and Homebrew/winget) pipelines grow there.
