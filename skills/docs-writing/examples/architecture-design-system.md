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
- Do close a sheet, a dialog and a toast through `dismiss()` from `ui/lib/dismiss.ts`, so Escape, the close control and a backdrop click agree.
- Do draw every component in light, dark and reduced motion. The gallery renders all three, and `npm test -- gallery` fails a component missing one.
- Never ship a component only one screen can use. Promote it to `ui/components/` or keep it in that screen's file.

## The canonical example

`ui/components/Badge.tsx`: it reads `tokens.badge` for its size and padding and `tokens.color` for its tones, draws its label through the shared `Text` role, and `ui/gallery/badge.tsx` shows it in each tone, light and dark. Copy it.

## Revisit when

A platform the shell must draw on cannot read the token file, or a screen needs a state the gallery cannot render.

---

## Not this

> The stylesheet is plugins.omarchy.org `assets/css/style.css?v=20260923-01`, fetched with curl on 2026-09-29. Radix Themes 3.3.0 component sources supply switch and badge sizes.
>
> | Role | Reference rule | Reference value | Departs |
> |---|---|---|---|
> | `text.display` | `.page-header h1` | sans, 34 px, 700, -.02em, line height 1.15 | line height 1.3, a 44 px line box |
> | `text.h1` | `.market-contribute h2` | mono, 24 px, bold, line height 1.55 | sans, -.01em, line height 1.333, a 32 px line box |

A value table in a doc is a second copy of the token file that is wrong the day the file changes, and the fetch provenance is a fact no reader acts on.
