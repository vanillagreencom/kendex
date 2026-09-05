# Rewrite a repository's markdown onto the convention

Rewrite, do not patch. Read the old files for facts and the code for truth, then write each new file from a blank page against [../SKILL.md](../SKILL.md). Delete old content that is neither an invariant, a boundary, a decision, a non-default convention, nor a pointer. The code, the tests, and git history hold it.

## Steps

1. Inventory every markdown file the repository owns, with its size and the kind of content it holds: the root `AGENTS.md`, every nested `AGENTS.md` or `CLAUDE.md`, every harness-specific instruction file, every file under `docs/architecture/` or a legacy `docs/ARCHITECTURE.md`, every `README.md`, `DEVELOPMENT.md`, `SKILL.md`, `workflows/*.md`, `agents/*.md`, and every reference doc.
2. Classify each claim: invariant, boundary, decision, non-default convention, pointer, or excluded. Verify every kept claim against the code and name the test or check that enforces it. A claim with no enforcer is either given one or dropped.
3. Write `docs/architecture/overview.md` from [../templates/overview.md](../templates/overview.md). Write a topic file from [../templates/topic.md](../templates/topic.md) for each subsystem [../SKILL.md](../SKILL.md) § Per file type admits one for.
4. Write the root `AGENTS.md` from [../templates/root-AGENTS.md](../templates/root-AGENTS.md). Keep the `## Code Review Rules` section the bot-instructions package renders.
5. Write a nested `AGENTS.md` from [../templates/nested-AGENTS.md](../templates/nested-AGENTS.md) in each directory with local rules. Delete hand-written `CLAUDE.md`, `.claude/rules`, and every other harness-specific instruction file.
6. Write each `README.md` from [../templates/README.md](../templates/README.md) and each `DEVELOPMENT.md` from [../templates/DEVELOPMENT.md](../templates/DEVELOPMENT.md). Move mechanics out of a README into its `DEVELOPMENT.md`.
7. Write each `SKILL.md` from [../templates/agent-SKILL.md](../templates/agent-SKILL.md) and each reference doc from [../templates/reference.md](../templates/reference.md). Move rationale out of a `SKILL.md` into `DEVELOPMENT.md` or a decision record.
8. Run `kendex refresh` so the shims are written, then `kendex verify`.
9. Reflow every tracked markdown file with the growth-guards `md-reflow` script, set `GROWTH_GUARDS_MD_SCOPE = "all"` in `kendex.settings.toml`, and run the `md-format`, `md-refs` and `prose` lanes over the whole tree. Put test fixtures whose bytes a suite pins, and a collated `CHANGELOG.md` whose Unreleased section the `changelog-entries` lane holds to HEAD, in `tools/md-excludes` with their reason.
10. Supersede any decision record the rewrite shows to be obsolete through the [`decider`](../../decider/SKILL.md) skill. Never delete one.
11. Remove every instruction the installed packages now enforce from the prose, and report anything portable the packages lack upstream through `kendex report`.
12. Run the repository's own validation and the size ratchet. A file over its class shrinks or freezes; it is never raised.
