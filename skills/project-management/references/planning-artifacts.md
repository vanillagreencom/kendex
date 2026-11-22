# Planning artifacts

- Read when a run writes, cites, hands over or cannot find a plan, research, roadmap or audit file.
- To publish artifacts after a run's planned tracker writes, follow [workflows/publish-artifacts.md](../workflows/publish-artifacts.md).

## Paths

Planning, research, roadmap and audit files are not repository content.

- A file goes to the path its caller names.
- With no caller-supplied path:
  - A plan or report lives at `tmp/plans/<slug>.md`.
  - A research report lives at `tmp/plans/<slug>-research.md`.
  - A roadmap lives at `tmp/roadmaps/roadmap-<feature>.md`.
  - None of them lives under a tracked `docs/` path.

The full rule is `agents/planner.md` § Plan Artifacts.

`[RESEARCH_DOCS_PATH]`, the directory the research workflows name, is `tmp/plans/research`. A research issue's assets and findings live under `tmp/plans/research/<ISSUE_ID>/`.

Research that is the evidence behind a constraint still in force stays attached to that constraint's issue. Other research is not kept.

## Where a plan lives and how a reader finds it

An artifact's durable home is its source issue: the issue it already sits on, else the issue it serves. When it serves several, the home is the first issue the run creates, or, in a run that creates none, the first open issue it updates. The local file is a working copy.

A reader given a cited path reads that file when it exists in its checkout. Otherwise it finds the artifact by the tracker:

- **Linear**: the link in the read issue's `**Artifacts**` list, which names the current copy, else an attachment on the source issue.
  - Read both through [linear patterns/workflow-actions.md § Resolve a cited artifact](../../linear/patterns/workflow-actions.md#resolve-a-cited-artifact).
- **GitHub Issues**: the text in the source issue's body, or the latest comment whose first line is the cited path, where [publish-artifacts.md § GitHub](../workflows/publish-artifacts.md#github) puts it.
  - Read both with `gh issue view [N] --repo [OWNER/REPO] --json body,comments`.
- **No tracker**: the caller's named path, else `tmp/`.
  - Nothing makes the file durable.
  - A missing one is reported missing.

An artifact this route does not find is missing, and the calling workflow's missing-file behavior applies.

## Handing over an artifact

A brief cites an artifact by its repository path. On Linear that path is the attachment name and the `**Artifacts**` link label. A brief whose own issue neither holds nor links the artifact also names its source issue.

Carry each artifact's repository reference, readable path and source issue separately:

- A same-checkout delegation receives the readable path for analysis and the reference for its output.
- A handoff to another checkout carries the reference and the source issue.
- The receiver resolves its own readable path by § Where a plan lives and how a reader finds it.
- Saved plans and tracker text hold references and source issues, never a machine's local paths.

A source issue identifies storage, not the roadmap's hierarchy origin.

With no published source issue, keep the existing local-until-creation flow.

## Unpublished artifacts

- On Linear, a run with no issue writes keeps its files locally until creation.
  - It creates no issue only to hold files.
- A run whose writes leave no open issue to hold them, such as one that only cancels, keeps its files locally and reports them as unpublished.
- On GitHub, report binary inputs that have no tracker upload route as incomplete.
  - Never claim that a local-only file is available to another lane.
