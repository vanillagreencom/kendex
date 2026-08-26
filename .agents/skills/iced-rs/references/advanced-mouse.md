# Mouse & Cursor

> `iced::advanced::mouse` · iced 0.14.0

`Cursor` enum for hit testing and cursor positioning in custom widgets. `Interaction` enum for system cursor selection. The `position_*`/`is_over` methods require the `advanced` crate feature.

## API

### `Cursor` enum

```rust
pub enum Cursor {
    Available(Point),
    Levitating(Point),
    Unavailable,
}
```

- **`Available(Point)`** — The cursor has a defined position on the current
  layer.
- **`Levitating(Point)`** — The cursor has a defined position, but it is
  "levitating" over a layer above — for example, an overlay is above the
  normal widget tree and the cursor belongs to the overlay layer, not the
  normal widget. Normal widgets should treat this like `Unavailable` unless
  they deliberately want to peek through the overlay.
- **`Unavailable`** — The cursor is currently out of bounds or busy.

### Cursor methods (advanced only)

```rust
impl Cursor {
    pub fn position(self) -> Option<Point>;
    pub fn position_over(self, bounds: Rectangle) -> Option<Point>;
    pub fn position_in(self, bounds: Rectangle) -> Option<Point>;
    pub fn position_from(self, origin: Point) -> Option<Point>;

    pub fn is_over(self, bounds: Rectangle) -> bool;
    pub fn is_levitating(self) -> bool;

    pub fn levitate(self) -> Cursor;
    pub fn land(self) -> Cursor;
}
```

- **`position()`** — Absolute position of the `Cursor`, if available.
- **`position_over(bounds)`** — Returns the **absolute** position of the
  cursor if it is inside `bounds`, otherwise `None`.
- **`position_in(bounds)`** — Returns the **relative** position of the cursor
  inside `bounds` (subtracting `bounds.position()`), or `None` if the cursor
  is not over the bounds. This is what you usually want for drawing hover
  indicators or computing fractional position inside a widget.
- **`position_from(origin)`** — Returns the relative position of the cursor
  from the given `origin`, if available.
- **`is_over(bounds)`** — Returns `true` if the cursor is over `bounds`.
  Convenience shortcut for `position_over(bounds).is_some()`.
- **`is_levitating()`** — Returns `true` if the cursor is on a layer above
  the current one.
- **`levitate()`** — Returns a copy of the cursor that is "levitated" onto a
  layer above the current one.
- **`land()`** — Returns a copy that is "landed" back onto the current layer.

### `Interaction` enum

```rust
pub enum Interaction {
    None,
    Hidden,
    Idle,
    ContextMenu,
    Help,
    Pointer,
    Progress,
    Wait,
    Cell,
    Crosshair,
    Text,
    Alias,
    Copy,
    Move,
    NoDrop,
    NotAllowed,
    Grab,
    Grabbing,
    ResizingHorizontally,
    ResizingVertically,
    ResizingDiagonallyUp,
    ResizingDiagonallyDown,
    ResizingColumn,
    ResizingRow,
    AllScroll,
    ZoomIn,
    ZoomOut,
}
```

27 variants. Common ones: `None` (default), `Pointer`, `Text`, `Grab`/`Grabbing`, `Crosshair`, `ResizingHorizontally`/`ResizingVertically`, `NotAllowed`.

## Patterns

### Hit-test a widget

```rust
if cursor.is_over(layout.bounds()) {
    // highlight
}
```

### Get a relative position inside the widget

```rust
if let Some(local) = cursor.position_in(layout.bounds()) {
    // local.x and local.y are in widget-local coords (0,0 top-left)
}
```

### Return a custom interaction

```rust
fn mouse_interaction(
    &self,
    _tree: &Tree,
    layout: Layout<'_>,
    cursor: Cursor,
    _viewport: &Rectangle,
    _renderer: &Renderer,
) -> Interaction {
    if cursor.is_over(layout.bounds()) {
        mouse::Interaction::Pointer
    } else {
        mouse::Interaction::None
    }
}
```


## Gotchas

- `Cursor::Unavailable` and `Cursor::Levitating(_)` both cause
  `is_over(bounds)` / `position_in(bounds)` to return `false` / `None` for
  most widgets. If you are writing an overlay, call `cursor.land()` on the
  cursor you get so it behaves as "available" relative to the overlay layer.
- `position_over` returns **absolute** coordinates and `position_in` returns
  **relative** coordinates. Mixing them up is a common bug.
- `is_over(bounds)` doesn't clip against the viewport — if the widget has
  been scrolled out of view but the cursor coincidentally hovers where it
  would be, this still returns `true`. Combine with a viewport rect check if
  you need strict visibility.
- `Interaction::None` is distinct from `Interaction::Idle` — `None` means
  "don't care, inherit from context", `Idle` means "explicitly the default
  cursor". Use `None` in most widgets.
- No built-in "cursor entered/left" helper -- diff between frames in widget state.

## Click detection

### `Click` struct

```rust
pub struct Click { /* private fields */ }

impl Click {
    /// Creates a new Click. Pass the previous Click to enable
    /// double/triple-click detection based on timing and position.
    pub fn new(
        position: Point,
        button: Button,
        previous: Option<Click>,
    ) -> Click;

    /// Returns the Kind of click (Single, Double, Triple).
    pub fn kind(&self) -> Kind;

    /// Returns the position where the click occurred.
    pub fn position(&self) -> Point;
}
```

### `Kind` enum

```rust
pub enum Kind {
    Single,
    Double,
    Triple,
}
```

### Click detection pattern

```rust
use iced::advanced::mouse::click::{Click, Kind};
use iced::mouse::Button;

// Store `last_click: Option<Click>` in widget state.
// On mouse press:
let click = Click::new(position, Button::Left, self.last_click);
match click.kind() {
    Kind::Single => { /* select */ }
    Kind::Double => { /* select word */ }
    Kind::Triple => { /* select line */ }
}
self.last_click = Some(click);
```

The runtime promotes `Single` to `Double` to `Triple` based on position proximity and timing threshold.

## See also

- `mouse.md`
- `advanced-widget.md`
- `advanced-shell.md`
