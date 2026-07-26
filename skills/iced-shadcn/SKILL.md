---
name: iced-shadcn
description: "Plan, build, and audit shadcn-inspired Iced components: architecture, family decomposition, and parity audits."
license: MIT
dependencies:
  required: [iced-rs]
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "1.0.0"
---

# iced-shadcn

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

Component design skill for building shadcn Base UI-inspired components in Iced. Covers architecture decisions, family decomposition, implementation methodology, and parity audits.

## Resources

### ctx7 CLI

| Library | ctx7 ID | Use For |
|---------|---------|---------|
| Iced | `/websites/rs_iced_iced` | Widget API, overlay system, advanced traits |

### Web

| Source | URL | Use For |
|--------|-----|---------|
| shadcn Base UI | `https://ui.shadcn.com/docs/components/base/` | Component behavior truth |
| iced-shadcn crate | `https://github.com/FerrisMind/shadcn-rs/tree/master/crates/iced-shadcn` | Architecture patterns |

## Workflows

| Workflow | When to use |
|----------|-------------|
| [component-plan](workflows/component-plan.md) | Planning new components, family decomposition, architecture decisions, implementation |
| [parity-audit](workflows/parity-audit.md) | Post-implementation audit of leaf components against Base UI reference before closure |

## References

- Component families: `references/families.md`
- Foundation issue shape: `references/issue-structure.md`
- Parity checklist: `references/checklist.md`
- Viewer page template: `references/page-template.md`
- Issue guidance: `references/issue-guidance.md`

## Source Authority (ordered)

1. **shadcn Base UI docs** (`https://ui.shadcn.com/docs/components/base/`) — behavior truth, example coverage, interaction contracts
2. **Iced 0.14 docs via ctx7** (`/websites/rs_iced_iced`) — framework constraints, `iced::advanced` widget/overlay API. Consult the iced-rs skill's widget catalog before choosing built-in vs custom Widget impl.
3. **Project architecture docs** — overlay/menu system, token system, viewer/page ownership, widget patterns
4. **[iced-shadcn reference crate](https://github.com/FerrisMind/shadcn-rs/tree/master/crates/iced-shadcn)** — implementation ideas, architecture patterns. Never final authority.

## Reference Crate Patterns

From [iced-shadcn](https://github.com/FerrisMind/shadcn-rs/tree/master/crates/iced-shadcn) (43k lines, 80+ components):

- **Overlay module**: separate `positioning.rs`, `keyboard.rs`, `focus.rs` for clean separation
- **menu_primitives**: shared by `dropdown_menu` and `context_menu`
- **Props + State separation**: simple components use `Props` struct only; complex ones add `State` + custom `Widget` impl
- **Component dependency tree**: `overlay` → `popover` → `combobox`/`hover_card`/`tooltip`/`navigation_menu`; `menu_primitives` → `dropdown_menu`/`context_menu`

**Do not copy**: their theme/token system (use your project's tokens), their import structure, their lucide-icons dependency. Borrow architecture and algorithms only.

## Rules

- Do not make `iced-shadcn` a production dependency — reference crate is for study only
- Always use `find-docs` / ctx7 before coding advanced Iced behavior (overlays, custom widgets, keyboard handling)
- Prefer the shadcn **Base UI** tab; use Radix only when Base UI is absent
- Mirror Base UI example headings and ordering exactly before adding local extras. Extra or missing sections require explicit mapping-table justification.
- For menus/selects/comboboxes, capture interaction semantics in the widget layer, not viewer/preview code
- Parity work must record fine-grained deviations explicitly: whole-row hit targets, separator treatment, alignment, type hierarchy, focus/outline treatment, and per-example layout gaps
- When a component family needs distinct subpart behavior (trigger/body/icon/padding/surface), define semantic component tokens and roles instead of repeatedly selecting generic globals inside the widget
- When visual treatments differ by variant or surface (plain, bordered, card, inset, etc.), model those differences in the semantic component contract instead of forcing one token set to serve every variant
- When multiple components need the same animation pattern, extract a shared motion primitive instead of embedding per-component tween logic
- Every exposed variant must map end-to-end: widget API → preview state → viewer page → tests
- Do not scope installation instructions, CLI snippets, or docs-site chrome into parity work
- Update architecture docs when work changes overlay/menu/widget patterns
- Consult the iced-rs skill's widget catalog before implementing custom `Widget`/`overlay::Overlay` — prefer Iced built-ins per the Built-in First principle

