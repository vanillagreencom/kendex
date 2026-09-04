# Rewrite a repository's docs onto the convention

Rewrite, do not patch. The old files are read for facts and the code is read for truth; the new files are written from a blank page against [../SKILL.md](../SKILL.md) § What goes where. Old content that is neither an invariant, a boundary, a decision, a non-default convention, nor a pointer is deleted; the code, the tests, and git history hold it.

## Steps

1. Inventory what loads today: root `AGENTS.md`, every nested `AGENTS.md` or `CLAUDE.md`, every file under `docs/architecture/` or a legacy `docs/ARCHITECTURE.md`, and every harness-specific instruction file. List each with its size and what kind of content it holds.
2. For each claim in those files, classify it: invariant, boundary, decision, non-default convention, pointer, or excluded. Verify every kept claim against the code and name the test or check that enforces it; a claim with no enforcer is either given one or dropped.
3. Write `docs/architecture/overview.md` from [../templates/overview.md](../templates/overview.md). Write a topic file from [../templates/topic.md](../templates/topic.md) only for a subsystem with invariants or boundaries of its own, with a `Covers:` line naming its directories.
4. Write the root `AGENTS.md` from [../templates/root-AGENTS.md](../templates/root-AGENTS.md). Keep the `## Code Review Rules` section the bot-instructions package writes as it renders it.
5. Write a nested `AGENTS.md` from [../templates/nested-AGENTS.md](../templates/nested-AGENTS.md) in each directory with local rules; delete hand-written `CLAUDE.md`, `.claude/rules`, and every other harness-specific instruction file.
6. Run `kendex refresh` so the shims are written, then `kendex verify`.
7. Reflow every tracked markdown file with the growth-guards `md-reflow` script, set `GROWTH_GUARDS_MD_SCOPE = "all"` in `kendex.settings.toml`, and run the `md-format`, `md-refs` and `prose` lanes over the whole tree. Test fixtures whose bytes a suite pins, and a collated `CHANGELOG.md` whose Unreleased section the `changelog-entries` lane holds to HEAD, go in `tools/md-excludes` with their reason.
8. Supersede any decision record the rewrite shows to be obsolete through the `decider` skill; never delete one.
9. Remove every instruction the installed packages now enforce from the prose, and report anything portable the packages lack upstream through `kendex report`.
10. Run the repository's own validation and the size ratchet; a file over its class shrinks or freezes, it is never raised.
