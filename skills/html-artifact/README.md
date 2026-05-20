# HTML Artifact

Generate a standalone HTML file when a conversation, plan, approach, report, review, explainer, prototype, or custom editor should be read by humans instead of delivered as a long chat reply or Markdown file.

Use this skill to:

- Turn plans, reports, PR explanations, and research into readable pages.
- Compare options visually instead of stacking prose.
- Build small interactive demos, diagrams, slide decks, or editing interfaces.
- Open the finished artifact in the user's default browser and provide a `file://` link.

The templates in `templates/` are sourced from [The unreasonable effectiveness of HTML — examples](https://thariqs.github.io/html-effectiveness/), created by Thariq Shihipar of Anthropic.

## Templates

| Template | Use when |
|---|---|
| `01-exploration-code-approaches.html` | Compare code approaches side by side when direction or tradeoff is unclear. |
| `02-exploration-visual-designs.html` | Compare visual/layout directions before choosing one. |
| `03-code-review-pr.html` | Review a PR or diff with annotations, severity, and jump links. |
| `04-code-understanding.html` | Explain an unfamiliar module, package, call graph, or hot path. |
| `05-design-system.html` | Show design tokens, colors, type, spacing, and reusable UI rules. |
| `06-component-variants.html` | Review one component across variants, states, sizes, and intents. |
| `07-prototype-animation.html` | Tune motion/animation with sliders or live controls. |
| `08-prototype-interaction.html` | Prototype a small clickable flow across screens. |
| `09-slide-deck.html` | Turn a thread, plan, or report into an arrow-key presentation. |
| `10-svg-illustrations.html` | Create editable SVG figures, diagrams, or visual explanations. |
| `11-status-report.html` | Produce weekly/project status with highlights, slips, chart, and next steps. |
| `12-incident-report.html` | Write an incident/postmortem timeline with logs and follow-up checklist. |
| `13-flowchart-diagram.html` | Draw a process, pipeline, or workflow with clickable step details. |
| `14-research-feature-explainer.html` | Explain how a repo feature works with snippets, flow, FAQ, and gotchas. |
| `15-research-concept-explainer.html` | Teach a concept with interaction, glossary, comparison, and examples. |
| `16-implementation-plan.html` | Create implementation plan with milestones, data flow, mockups, risks, code snippets. |
| `17-pr-writeup.html` | Create reviewer-facing PR writeup: motivation, before/after, file tour, focus areas. |
| `18-editor-triage-board.html` | Build a drag/drop editor for prioritizing, bucketing, or triaging items. |
| `19-editor-feature-flags.html` | Build a constrained config/flag editor with dependency warnings and copy diff. |
| `20-editor-prompt-tuner.html` | Build a prompt/template tuner with live preview, variables, and copy output. |

Upstream templates are MIT licensed; see `templates/LICENSE.upstream`.
