# Scrollable

> `iced::widget::scrollable` · iced 0.14.0

Wraps content in a scrollbar-enabled viewport. Vertical by default; call `horizontal()` or `direction()` for other axes. Use `on_scroll(Viewport -> Msg)` to observe scrolling.

## API

Iced 0.14.0 owns the declarations, bounds, feature gates and defaults: [widget/src/scrollable.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/scrollable.rs); [widget/src/helpers.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs).

## Patterns

### Basic vertical scroll

```rust
use iced::widget::{column, scrollable, text};

scrollable(
    column((0..1000).map(|i| text!("Row {i}").into())).spacing(4)
).height(Length::Fill)
```

### Horizontal scroll

```rust
scrollable(row![/* wide content */]).horizontal()
```

### Both directions with custom scrollbars

```rust
use iced::widget::scrollable;

scrollable(content).direction(scrollable::Direction::Both {
    vertical: scrollable::Scrollbar::new().width(6).margin(2),
    horizontal: scrollable::Scrollbar::new().width(6).margin(2),
})
```

### Listen to scroll events

```rust
scrollable(content).on_scroll(Message::Scrolled)

// In update:
Message::Scrolled(viewport) => {
    state.offset = viewport.absolute_offset().y;
    // Normalize an overflowing axis with viewport.relative_offset()
    // viewport.bounds() for visible area
}
```

### Programmatic scroll

```rust
use iced::widget::{operation, Id};

let scroll_id = Id::new("my-scroll");
scrollable(content).id(scroll_id.clone())

```

In `update`, return the operation task:

```rust
operation::scroll_to(scroll_id, operation::AbsoluteOffset { x: 0.0, y: 500.0 })
```

## Gotchas

- `on_scroll` also checks the viewport on redraw, including after layout or programmatic scrolling. It suppresses unchanged viewports and emits nothing when content fits both axes. Use a `sensor` when you need size notifications without overflow.
- `spacing()` **embeds** the scrollbar into the layout (takes space). Without it the scrollbar floats over content.
- `anchor_bottom()` measures the vertical offset from the bottom. New content stays at the bottom while that offset is zero.
- `auto_scroll(true)` enables **middle-click auto-scroll** (cursor-follow scrolling); different from auto-scroll-to-bottom.
- `absolute_offset()` returns pixel offsets. `relative_offset()` divides each offset by that axis's overflow; an axis without overflow can produce a non-finite value. Check the bounds before using it as a percentage.

## See also

- `widget-sensor.md` — detecting layout changes inside scrollables
- `task.md` — `iced::widget::operation::scroll_to(id, offset)` / `scroll_by(id, offset)`
- `advanced-operation.md` — `Scrollable` operation trait for widgets that expose scroll state
- `catalog.md` — styling pattern
