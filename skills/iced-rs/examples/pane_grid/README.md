## Pane grid

A grid of panes that can be split, resized, and reorganized.

This example showcases the `PaneGrid` widget, which features:

* Vertical and horizontal splits
* Tracking of the last active pane
* Mouse-based resizing
* Drag and drop to reorganize panes
* Hotkey support
* Configurable modifier keys
* API to perform actions programmatically (`split`, `swap`, `resize`, etc.)

The __[`main`]__ file contains all the code of the example.

<div align="center">
  <img src="https://iced.rs/examples/pane_grid.gif">
</div>

These sources are a read-only copy. To run it, clone the upstream workspace at the release (`git clone --branch 0.14.0 https://github.com/iced-rs/iced`) and, from its root:
```
cargo run --package pane_grid
```

[`main`]: src/main.rs
