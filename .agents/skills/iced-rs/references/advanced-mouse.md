# Mouse & Cursor

> `iced::advanced::mouse` · iced 0.14.0

`Cursor` enum for hit testing and cursor positioning in custom widgets. `Interaction` enum for system cursor selection. The cursor methods are available through `iced::mouse::Cursor` too; only the `iced::advanced` access path requires `advanced`.

Read when implementing or debugging mouse behavior in a custom widget or backend. Enable Iced’s `advanced` feature for the `iced::advanced` paths used here.

## Declarations

Pinned Iced 0.14.0 declarations, signatures, defaults and implementation:

- [core/src/mouse/cursor.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/mouse/cursor.rs).
- [core/src/mouse/interaction.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/mouse/interaction.rs).
- [core/src/mouse/click.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/mouse/click.rs).

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

- `Cursor::Unavailable` and `Cursor::Levitating(_)` both cause `is_over(bounds)` / `position_in(bounds)` to return `false` / `None` unconditionally. Use `land()` only when deliberately bringing a levitating cursor onto the current layer; it does not make an unavailable cursor available.
- `position_over` returns **absolute** coordinates and `position_in` returns **relative** coordinates. Mixing them up is a common bug.
- `is_over(bounds)` doesn't clip against the viewport — if the widget has been scrolled out of view but the cursor coincidentally hovers where it would be, this still returns `true`. Combine with a viewport rect check if you need strict visibility.
- `Interaction::None` is distinct from `Interaction::Idle` — `None` means "don't care, inherit from context", `Idle` means "explicitly the default cursor". Use `None` in most widgets.
- No built-in "cursor entered/left" helper -- diff between frames in widget state.

## Click detection

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

`Click::new` classifies consecutive clicks by button, position and elapsed time. Store the previous click yourself; after a triple click, another consecutive click becomes a double click.

## See also

- `mouse.md`
- `advanced-widget.md`
- `advanced-shell.md`
