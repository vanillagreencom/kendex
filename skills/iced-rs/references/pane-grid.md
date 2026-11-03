# PaneGrid

Read when building a split, resizable pane workspace in iced 0.14.0. The pinned [PaneGrid](https://github.com/iced-rs/iced/blob/0.14.0/widget/src/pane_grid.rs), [State](https://github.com/iced-rs/iced/blob/0.14.0/widget/src/pane_grid/state.rs) and [Configuration](https://github.com/iced-rs/iced/blob/0.14.0/widget/src/pane_grid/configuration.rs) declarations own the full API. The [bundled example](../examples/pane_grid/src/main.rs) shows state, view and interaction handling together.

## State

Keep each pane's mutable contents in `pane_grid::State<T>`. `State::new` returns both the grid state and the first pane identifier. Retain identifiers the application uses for selection or later operations. Use `Configuration` for an initial split tree.

Splitting returns optional identifiers for the new pane and divider. Closing returns the removed contents and a closest sibling when removal succeeds. Update application selection or focus explicitly from that result; returning a sibling does not focus a widget.

`maximize` renders only the selected pane until `restore`. Drag and resize callbacks are disabled while the state is maximized. Keep changes to the pane tree in application updates rather than reconstructing it in `view`.

## Interactions

Build pane content from the grid's pane/state/maximized callback. Register messages for the interactions the application supports:

```rust
use iced::widget::{pane_grid, text};

let grid = pane_grid(&state.panes, |_pane, pane_state, _maximized| {
    pane_grid::Content::new(text(&pane_state.title))
})
.on_drag(Message::PaneDragged)
.on_resize(10, Message::PaneResized);
```

This excerpt assumes pane state with a `title` and matching application message variants. Add a title bar when panes need a drag pick area. Follow the framework's [pane-grid rules](../SKILL.md#pane_grid) for tab capture, drag feedback and state ordering.

The callbacks report requests; the application's update applies them:

```rust
Message::PaneDragged(pane_grid::DragEvent::Dropped { pane, target }) => {
    state.panes.drop(pane, target);
}
Message::PaneResized(pane_grid::ResizeEvent { split, ratio }) => {
    state.panes.resize(split, ratio);
}
```

Handle picked/canceled drag messages as required by application feedback. `drop` uses the target region to swap or relocate panes. To create a new pane, call `split(axis, existing_pane, new_contents)` and handle `None`.

Resize ratios express divider position in the range `[0, 1]`, not pixels. `on_resize` takes extra grab leeway; the grabbable width includes both spacing and leeway. [Axis](https://github.com/iced-rs/iced/blob/0.14.0/widget/src/pane_grid/axis.rs) names the dividing line: Horizontal separates top/bottom and Vertical separates left/right.

Keep title content narrow enough to leave a pick area; [TitleBar::is_over_pick_area](https://github.com/iced-rs/iced/blob/0.14.0/widget/src/pane_grid/title_bar.rs) excludes title content and controls. Check narrow panes, tab interaction, dragging, resizing and focus in the target application. This source reference supplies no native layout or input result.

See [shell layout](shell-chrome.md), [containers](widget-container.md), [rows and columns](widget-column-row.md) and [catalogs](catalog.md).
