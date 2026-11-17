# Tooltip

> `iced::widget::tooltip` · iced 0.14.0

A hover-triggered popup that displays extra information over a hoverable element. Uses iced's built-in overlay layer — prefer this over writing a custom `Overlay` for hint text.

## API

Iced 0.14.0 owns the declarations, bounds, feature gates and defaults: [widget/src/tooltip.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/tooltip.rs); [widget/src/helpers.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs).

## Patterns

### Basic tooltip

```rust
use iced::widget::{container, tooltip, text};

tooltip(
    button("Save"),
    container(text("Save the document (Ctrl+S)"))
        .padding(8)
        .style(container::rounded_box),
    tooltip::Position::Bottom,
)
```

### Follow cursor

```rust
tooltip(
    chart,
    text("Cursor-relative tooltip"),
    tooltip::Position::FollowCursor,
).delay(Duration::from_millis(200))
```

### Delayed tooltip

```rust
tooltip(
    icon_button,
    text("Tooltip after 500ms hover"),
    tooltip::Position::Top,
)
.delay(Duration::from_millis(500))
```

### Fixed with gap and padding

```rust
tooltip(
    content,
    text("Hint"),
    tooltip::Position::Right,
)
.gap(8)        // Space between content and tooltip
.padding(10)   // Padding inside the tooltip popup
```

### Custom styled tooltip

```rust
tooltip(
    content,
    text("Warning: unsaved changes"),
    tooltip::Position::Top,
)
.style(|theme| container::Style {
    background: Some(theme.palette().danger.into()),
    text_color: Some(Color::WHITE),
    border: border::rounded(4.0),
    ..container::Style::default()
})
```

## Gotchas

- The constructor requires a `Position`. Choose `FollowCursor` explicitly to place the tooltip relative to the cursor.
- `snap_within_viewport(true)` constrains the popup to the viewport and shifts its bounds at an edge; it does not switch `Top` to `Bottom`.
- The default delay is `Duration::ZERO`. Set a positive delay when hover should wait before showing the tooltip.
- The `tooltip` element is another full `Element` — can be any widget, not just text. Use `container(...).style(container::rounded_box)` for a boxed popup.

## See also

- `widget-container.md` — typical wrapper for the tooltip popup
- `widget-float.md` — for non-hover-triggered floating content
- `advanced-overlay.md` — if you need more control than `tooltip` provides
- `catalog.md` — styling pattern (tooltip delegates to container)
