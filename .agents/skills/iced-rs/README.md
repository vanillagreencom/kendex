# Iced 0.14

A reference skill for building or debugging a GUI on the Iced 0.14 Rust framework: custom widgets through `iced::advanced`, overlays, Canvas, Shader, `pane_grid`, theming, subscriptions and the Elm architecture, with every upstream example and the full API reference bundled. For a project whose agents write Iced code and must not generate 0.14 APIs from memory.

## Install

```bash
kendex add vanillagreencom/kendex --skill iced-rs
```

## What it does

- A surface-selection guide that picks the right primitive before any code is written.
- Guides for custom widgets, custom overlays, animated layout, and animation debugging.
- A widget catalog naming the canonical example for each widget.
- Every upstream Iced 0.14 example under `examples/`.
- The framework invariants that cause panics and render bugs when broken, stated as rules.

## How it works

An agent loads [SKILL.md](SKILL.md), classifies the surface it is building, reads the canonical example for it, then the guide. The full list of references is [references/INDEX.md](references/INDEX.md), loaded on demand.

## Customise

Nothing to configure.
