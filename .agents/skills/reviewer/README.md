# Reviewer

The shared contract for every review specialist in an orchestrated cycle: the reviewer ethos, the code-review classification, the finding JSON schema, and the QA-label lifecycle. Each review agent's domain and probes live in its own agent file; this skill is what they all load. For a project that runs the `orch` skill and its reviewer agents.

## Install

```bash
kendex add vanillagreencom/kendex --skill reviewer
```

Needs `orch`, whose scripts the workflows run, and `code-quality` and `docs-writing`, the standards a finding is judged against; `linear` is optional. The kendex catalog's `code-review` bundle installs it beside the review agents.

## What it does

- A code-review workflow: diff, findings, JSON artifact, verdict.
- A whole-codebase audit workflow with no diff.
- A QA workflow triggered by a label on one PR.
- The rules a finding is judged by: verify before reporting, report the class not the instance, a claim needs the line that makes it true, plausible by default.

## How it works

The orchestrator delegates a review to each specialist agent; the agent loads this skill and its own agent file, reviews, writes a finding artifact in the shape of [schemas/review-finding.md](schemas/review-finding.md), and returns. The orchestrator accepts the artifact, never the chat message. Every workflow here runs orch scripts and does not stand alone.

## Customise

Nothing to configure. Project-specific review rules go in `[skill-instructions]` in `kendex.toml`; the agents' domains are the agent files, edited through `[agent-additional-instructions]`.
