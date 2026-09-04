# bot-instructions

One review doctrine plus a per-repo `bot-instructions.toml`, rendered into the instruction file each GitHub review bot reads. For a repository that runs Codex, Copilot, CodeRabbit, Qodo or Macroscope review and wants every bot, in every repo, judging by the same rules.

## Install

```bash
kendex add vanillagreencom/kendex --skill bot-instructions
```

Needs Python 3.11 or newer. Then follow [references/checklist.md](references/checklist.md) § Adding a repo: one pass with every bot off, then one pass per bot that enables it, adopts its files and renders them.

## What it does

- Renders `AGENTS.md` § Code Review Rules, `.github/copilot-instructions.md`, `.github/instructions/*.instructions.md`, `.coderabbit.yaml`, `.pr_agent.toml` with `best_practices.md`, and the `.macroscope/` tree from one TOML.
- `check` re-renders and reports any file that differs, or that carries the package's marker without the TOML producing it; `--staged` makes it a pre-commit lane.
- `adopt` takes over a hand-written bot file once, printing what it replaced.
- A path-scoped `[[surface]]` or an exclusion is written once and reaches every bot that has a mechanism for it.

## How it works

```bash
scripts/bot-instructions render [--repo REPO] [--spec SPEC] [--dry-run]
scripts/bot-instructions check [--repo REPO] [--spec SPEC] [--staged]
scripts/bot-instructions adopt [--repo REPO] [--spec SPEC]
```

`render` validates in a scratch tree, then writes. Generated files are outputs: a hand edit is erased at the next render, and `check` reds before that happens. `render` refuses a file that does not carry this package's marker; `adopt` is the one verb that takes such a file over.

Three of the five bots read `AGENTS.md` § Code Review Rules, so that section is the doctrine root: a TOML turning Codex off while Copilot or CodeRabbit is on is a schema error. Bots read their instruction files from the pull request's head, so a pull request can weaken the review it is about to get; what a repo whose merge gate consumes bot output does about that is [SKILL.md](SKILL.md) § A pull request changing its own review.

## Customise

- `bot-instructions.toml`: every key and the glob dialect, [schemas/repo-toml.md](schemas/repo-toml.md).
- Which block lands in which file, and why each omission is deliberate: [schemas/renders.md](schemas/renders.md).
- Per-repo settings no file can configure: [references/checklist.md](references/checklist.md) § The settings.
