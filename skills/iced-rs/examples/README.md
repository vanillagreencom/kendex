# Iced 0.14 examples

These example files come from the [Iced 0.14.0 release](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/Cargo.toml). Open an example below to read its source and choose how to run it. Run the examples in the upstream workspace with Rust 1.88 or later.

## Install

```sh
git clone --branch 0.14.0 https://github.com/iced-rs/iced
cd iced
```

## Examples

| Example | What it shows |
|---|---|
| [Arc](arc/README.md) | Use Canvas to draw a rotating arc |
| [Bézier tool](bezier_tool/README.md) | Draw Bézier curves on an interactive Canvas |
| [Checkbox](checkbox/README.md) | Toggle checkboxes and compare built-in and custom styles |
| [Clock](clock/README.md) | Draw a clock face and hands on Canvas and update them on timer ticks |
| [Color palette](color_palette/README.md) | Choose a base color and view the derived palette |
| [Combo box](combo_box/README.md) | Search and select options in a menu positioned relative to the combo box |
| [Counter](counter/README.md) | Increment or decrement a value with two buttons |
| [Custom widget](custom_widget/README.md) | Draw a circle from a custom widget |
| [Download progress](download_progress/README.md) | Start several downloads and show each one’s progress |
| [Events](events/README.md) | Use the checkbox to turn event logging on or off |
| [Exit](exit/README.md) | Select Exit, then confirm to close the window |
| [Game of Life](game_of_life/README.md) | Pan, zoom, and edit the grid without fixed edges while the simulation advances in the background |
| [Geometry](geometry/README.md) | Draw an indexed mesh from a custom widget |
| [wgpu integration](integration/README.md) | Draw an Iced interface inside a wgpu application |
| [Loading spinners](loading_spinners/README.md) | Show animated circular and linear spinners for work without a known completion percentage |
| [Pane grid](pane_grid/README.md) | Split panes horizontally or vertically, resize them with the mouse, and drag them to rearrange the grid |
| [Pick list](pick_list/README.md) | Select an option from a menu positioned relative to the pick list |
| [Pokédex](pokedex/README.md) | Load a random Pokédex entry and its sprite |
| [Progress bar](progress_bar/README.md) | Use a slider to change the progress bar’s value |
| [QR code generator](qr_code/README.md) | Enter text and preview the corresponding QR code |
| [Scrollable](scrollable/README.md) | Compare scroll directions, alignment, and scrollbar dimensions |
| [Sierpiński triangle](sierpinski_triangle/README.md) | Draw a Sierpiński triangle on Canvas |
| [Slider](slider/README.md) | Select a value with a horizontal or vertical slider |
| [Solar system](solar_system/README.md) | Animate a solar system on Canvas using rotation and translation |
| [Stopwatch](stopwatch/README.md) | Start, stop, and reset a stopwatch |
| [Styling](styling/README.md) | Compare widget styles across Iced themes, including light and dark |
| [SVG](svg/README.md) | Display the Ghostscript Tiger with Iced’s SVG widget |
| [Todos](todos/README.md) | Manage and filter a task list |
| [Tooltip](tooltip/README.md) | Reveal a tooltip on hover |
| [Tour](tour/README.md) | Try Iced widgets in a single app that runs on desktop and in a browser |
| [WebSocket](websocket/README.md) | Send messages through a WebSocket connection to a local echo server |

## Coffee

[Coffee](https://github.com/hecrj/coffee), an experimental 2D game engine, was an early Iced user. Its [basic GUI pull request](https://github.com/hecrj/coffee/pull/35) opened in May 2019.

![Coffee’s game interface](https://iced.rs/examples/coffee.gif)

## Licence

[Iced’s MIT licence and copyright notice](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/LICENSE)
