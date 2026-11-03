# Iced examples

Examples from the published Iced 0.14.0 release for people and agents learning the framework. Start with [Tour](tour) for standard widgets or [Counter](counter) for application state and messages.

## Install

```sh
git clone --branch 0.14.0 https://github.com/iced-rs/iced
cd iced
cargo run --package tour
```

## How it works

These sources are a read-only reference copy. They have no workspace manifest and do not build here. Run an example from the upstream workspace at the release, replacing `tour` in the command above with its package name. Upstream `master` can contain incompatible APIs. [SKILL.md](../SKILL.md) records this copy's source identity.

Each example's README describes it and gives its run command. Its `src/main.rs` is the starting point for reading the code.

## Examples

| Example | Use |
|---|---|
| [Tour](tour) | Explore standard widgets on native platforms or the web. |
| [Todos](todos) | Build a task list with text input, checkboxes and background saving. |
| [Game of Life](game_of_life) | Draw and interact with a simulation on a Canvas. |
| [Styling](styling) | Style widgets with light and dark themes. |
| [Bézier tool](bezier_tool) | Draw Bézier curves with a Canvas. |
| [Clock](clock) | Draw a clock and its hands with a Canvas. |
| [Color palette](color_palette) | Generate a palette from a root color. |
| [Counter](counter) | Connect state, messages, update logic and view logic. |
| [Custom widget](custom_widget) | Implement a widget that draws a circle. |
| [Download progress](download_progress) | Track asynchronous downloads. |
| [Events](events) | Display native events. |
| [Geometry](geometry) | Draw geometry with the bundled renderer. |
| [Integration](integration) | Use Iced in a wgpu application. |
| [Pane grid](pane_grid) | Split, resize and reorganize panes. |
| [Pick list](pick_list) | Choose from a dropdown list. |
| [Pokédex](pokedex) | Load a random entry and sprite from the PokéAPI. |
| [Progress bar](progress_bar) | Control a progress bar with a slider. |
| [Scrollable](scrollable) | Explore scroll direction, size and style. |
| [Sierpiński triangle](sierpinski_triangle) | Draw a triangle with a Canvas and slider. |
| [Solar system](solar_system) | Animate a Canvas with composed transforms. |
| [Stopwatch](stopwatch) | Listen to time and handle start, stop and reset. |
| [SVG](svg) | Render the Ghostscript Tiger. |
