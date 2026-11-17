# PaneGrid

> `iced::widget::pane_grid` · iced 0.14.0

Dynamic tiling layout. Users split, resize, drag, and reorganize panes. `State<T>` manages the pane tree; `Configuration<T>` describes the initial arrangement. Supports maximize/restore, programmatic split/swap/close.

## API

Iced 0.14.0 owns the declarations, bounds, feature gates and defaults: [widget/src/pane_grid.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/pane_grid.rs); [widget/src/pane_grid/state.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/pane_grid/state.rs); [widget/src/pane_grid/configuration.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/pane_grid/configuration.rs); [widget/src/pane_grid/content.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/pane_grid/content.rs); [widget/src/pane_grid/title_bar.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/pane_grid/title_bar.rs); [widget/src/helpers.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs).

## Patterns

### Basic pane grid

```rust
use iced::widget::{pane_grid, text};
use iced::Element;

struct State {
    panes: pane_grid::State<Pane>,
}

enum Pane {
    SomePane,
    AnotherKindOfPane,
}

#[derive(Debug, Clone)]
enum Message {
    PaneDragged(pane_grid::DragEvent),
    PaneResized(pane_grid::ResizeEvent),
}

fn view(state: &State) -> Element<'_, Message> {
    pane_grid(&state.panes, |_pane, state, _is_maximized| {
        pane_grid::Content::new(match state {
            Pane::SomePane => text("This is some pane"),
            Pane::AnotherKindOfPane => text("This is another kind of pane"),
        })
        .title_bar(pane_grid::TitleBar::new(text("Pane")))
    })
    .on_drag(Message::PaneDragged)
    .on_resize(10, Message::PaneResized)
    .into()
}
```

### Handle drag events

```rust
Message::PaneDragged(pane_grid::DragEvent::Dropped { pane, target }) => {
    state.panes.drop(pane, target);
}
```

### Handle resize events

```rust
Message::PaneResized(pane_grid::ResizeEvent { split, ratio }) => {
    state.panes.resize(split, ratio);
}
```

### Split a pane

```rust
if let Some((new_pane, _split)) = state.panes.split(
    pane_grid::Axis::Horizontal,
    existing_pane,
    MyPaneState::default(),
) {
    // new_pane is the identifier for the new pane
}
```

## Gotchas

- `State::new(state)` returns `(State<T>, Pane)` -- store the initial `Pane` identifier.
- `resize` takes a ratio in `[0.0, 1.0]`, not pixel values.
- `close` returns `Option<(T, Pane)>` -- the `Pane` is the closest sibling that should receive focus.
- `maximize` hides all other panes until `restore` is called.
- `on_resize(spacing, msg)` -- the first argument is the drag handle spacing in pixels, not the ratio.

## See also

- `widget-container.md`
- `widget-column-row.md`
- `catalog.md`
- `advanced-widget.md`
