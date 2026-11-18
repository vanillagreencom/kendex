# Pane grid

Split panes horizontally or vertically, resize them with the mouse, and drag them to rearrange the grid. The app tracks the focused pane and provides keyboard shortcuts.

![An interface with resizable, draggable panes](https://iced.rs/examples/pane_grid.gif)

The keyboard handler uses Iced’s command modifier. The [pane state API](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/pane_grid/state.rs) lets callers split, swap, and resize panes from application code.

Read the [example source](src/main.rs).

## Run

Run from the root of the [Iced 0.14.0 workspace](../README.md#install).

```sh
cargo run --package pane_grid
```
