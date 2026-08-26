# PaneGrid

> `iced::widget::pane_grid` · iced 0.14.0

Dynamic tiling layout. Users split, resize, drag, and reorganize panes. `State<T>` manages the pane tree; `Configuration<T>` describes the initial arrangement. Supports maximize/restore, programmatic split/swap/close.

## API

### Key types

- `State<T>` -- Pane tree state. Public fields: `panes: BTreeMap<Pane, T>`, `internal: Internal`.
- `Configuration<T>` -- `Split { axis, ratio, a, b }` or `Pane(T)`.
- `Pane` / `Split` -- Opaque identifiers (`Copy`, `Hash`, `Eq`, `Ord`).
- `Axis` -- `Horizontal` or `Vertical`.
- `Direction` -- `Up`, `Down`, `Left`, `Right`.
- `DragEvent` -- `Picked { pane }`, `Dropped { pane, target }`, `Canceled { pane }`.
- `ResizeEvent` -- `{ split: Split, ratio: f32 }`.
- `Content` / `TitleBar` / `Controls` -- Pane content wrappers.

### `State<T>` methods

```rust
impl<T> State<T> {
    pub fn new(first_pane_state: T) -> (State<T>, Pane);
    pub fn with_configuration(config: impl Into<Configuration<T>>) -> State<T>;
    pub fn len(&self) -> usize;
    pub fn get(&self, pane: Pane) -> Option<&T>;
    pub fn get_mut(&mut self, pane: Pane) -> Option<&mut T>;
    pub fn iter(&self) -> impl Iterator<Item = (&Pane, &T)>;
    pub fn adjacent(&self, pane: Pane, direction: Direction) -> Option<Pane>;
    pub fn split(&mut self, axis: Axis, pane: Pane, state: T) -> Option<(Pane, Split)>;
    pub fn split_with(&mut self, target: Pane, pane: Pane, region: Region);
    pub fn drop(&mut self, pane: Pane, target: Target);
    pub fn swap(&mut self, a: Pane, b: Pane);
    pub fn resize(&mut self, split: Split, ratio: f32);
    pub fn close(&mut self, pane: Pane) -> Option<(T, Pane)>;
    pub fn maximize(&mut self, pane: Pane);
    pub fn restore(&mut self);
    pub fn maximized(&self) -> Option<Pane>;
}
```

### `Configuration<T>` enum

```rust
pub enum Configuration<T> {
    Split {
        axis: Axis,
        ratio: f32,
        a: Box<Configuration<T>>,
        b: Box<Configuration<T>>,
    },
    Pane(T),
}
```

## Patterns

### Basic pane grid

```rust
use iced::widget::{pane_grid, text};

struct State {
    panes: pane_grid::State<Pane>,
}

enum Pane {
    SomePane,
    AnotherKindOfPane,
}

enum Message {
    PaneDragged(pane_grid::DragEvent),
    PaneResized(pane_grid::ResizeEvent),
}

fn view(state: &State) -> Element<'_, Message> {
    pane_grid(&state.panes, |pane, state, is_maximized| {
        pane_grid::Content::new(match state {
            Pane::SomePane => text("This is some pane"),
            Pane::AnotherKindOfPane => text("This is another kind of pane"),
        })
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
