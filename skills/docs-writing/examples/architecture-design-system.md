# The design system

Read before drawing a new screen, control or state.

## The approach

Every screen is built from the shared components in `ui/components/`, and every colour, size, radius and duration they draw comes from the token file `ui/theme/tokens.ts`. A new component lands in the gallery at `ui/gallery/` before a screen uses it.

## Why

One token file is the only place a value changes, so a palette or spacing change is one commit and every screen moves together. The gallery is where a component is seen in every state, light and dark, before a screen hides a state nobody drew.

## Rules

- Do build from `Button`, `TextField`, `ListItem`, `Dialog` and the other shared components. Compose them; never restyle one in a screen.
- Do take every value from the token file. A literal colour, pixel size or duration in a component is refused by the `no-literal-style` lint lane.
- Do add a gallery entry for a new component, with each state it can draw.
- Do close a sheet, a dialog and a toast through `dismiss()` from `ui/lib/dismiss.ts`, per `docs/decisions/D012-one-dismiss-pattern.md`.
- Do draw every component in light, dark and reduced motion. The gallery renders all three, and `npm test -- gallery` fails a component missing one.
- Never ship a component only one screen can use. Promote it to `ui/components/` or keep it in that screen's file.

## The canonical example

`ui/components/Badge.tsx`: every value from the token file, its label through the shared `Text` role, and a gallery entry for each tone. Copy it.

## Revisit when

A platform the shell must draw on cannot read the token file, or a screen needs a state the gallery cannot render.

## Not governed

What a screen says and where it places the components; a screen composes them as it needs, and copy follows the strings rule in `AGENTS.md`.

---

## Not this

> The stylesheet is plugins.omarchy.org `assets/css/style.css?v=20260923-01`, fetched with curl on 2026-09-29. Radix Themes 3.3.0 component sources supply switch and badge sizes.
>
> | Role | Reference rule | Reference value | Departs |
> |---|---|---|---|
> | `text.display` | `.page-header h1` | sans, 34 px, 700, -.02em, line height 1.15 | line height 1.3, a 44 px line box |
> | `text.h1` | `.market-contribute h2` | mono, 24 px, bold, line height 1.55 | sans, -.01em, line height 1.333, a 32 px line box |

A value table in a doc is a second copy of the token file that is wrong the day the file changes, and the fetch provenance is a fact no reader acts on.

### Display specification

> The account page shows a green badge beside connected accounts. It has an 8 px gap and says Connected. Clicking it opens the account dialog. The dialog puts Reconnect before Remove. A screen must use the shared status component so its error state remains readable in every theme.

Keep the principle in the architecture doc:

> Use the shared status component for account state. Draw its error state in every supported theme. Review holds the choice of component; the gallery holds the theme states.

Inspect the account component, its behavior tests and `ui/theme/tokens.ts`. Delete the badge behavior and mirrored spacing from the architecture doc when those sources hold them. Keep wording in the application's strings. If a required behavior lacks a test, record that test item through the tracker route. Move a user instruction such as how to reconnect to the app's account help after inspecting that help. A display specification does not become a principle by moving it to `references/`.

### Operating sequence

> Run the gallery, switch between light and dark, enable reduced motion, capture each state and attach the pairs to the pull request. The capture command loads the gallery and iterates over its entries.

Keep the rule that every component has a gallery entry for each supported state. Move the ordered review actions into the screenshot skill's `workflows/review-pass.md` after inspecting it. Delete the capture implementation account. The workflow routes to the screenshot record contract for its fields; the architecture doc keeps no copy of them.
