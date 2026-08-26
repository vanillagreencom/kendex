# Tooltip

> `iced::widget::tooltip` · iced 0.14.0

A hover-triggered popup that displays extra information over a hoverable element. Uses iced's built-in overlay layer — prefer this over writing a custom `Overlay` for hint text.

## API

### `Tooltip` struct

```rust
pub struct Tooltip<'a, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where
    Theme: Catalog,
    Renderer: Renderer,
{ /* private fields */ }

impl<'a, Message, Theme, Renderer> Tooltip<'a, Message, Theme, Renderer>
where
    Theme: Catalog,
    Renderer: Renderer,
{
    pub fn new(
        content: impl Into<Element<'a, Message, Theme, Renderer>>,
        tooltip: impl Into<Element<'a, Message, Theme, Renderer>>,
        position: Position,
    ) -> Self;

    pub fn gap(self, gap: impl Into<Pixels>) -> Self;
    pub fn padding(self, padding: impl Into<Pixels>) -> Self;
    pub fn delay(self, delay: Duration) -> Self;
    pub fn snap_within_viewport(self, snap: bool) -> Self;

    pub fn style(self, style: impl Fn(&Theme) -> Style + 'a) -> Self
    where
        <Theme as Catalog>::Class<'a>: From<Box<dyn Fn(&Theme) -> Style + 'a>>;

    pub fn class(self, class: impl Into<<Theme as Catalog>::Class<'a>>) -> Self; // feature = "advanced"
}
```

### `Position` enum

```rust
pub enum Position {
    Top,
    Bottom,
    Left,
    Right,
    FollowCursor,  // default
}
```

### `Style` struct

The tooltip's style type is re-exported from `container::Style`:

```rust
pub type Style = container::Style;
```

### `Catalog` trait

```rust
pub trait Catalog: container::Catalog {
    fn default<'a>() -> <Self as Catalog>::Class<'a>;
}
```

Styling delegates to `container::Catalog` — the tooltip's popup box is a container under the hood.

### Functions & type aliases

```rust
pub fn tooltip<'a, Message, Theme, Renderer>(
    content: impl Into<Element<'a, Message, Theme, Renderer>>,
    tooltip: impl Into<Element<'a, Message, Theme, Renderer>>,
    position: Position,
) -> Tooltip<'a, Message, Theme, Renderer>;

pub fn default(theme: &Theme) -> Style;

pub type StyleFn<'a, Theme> = Box<dyn Fn(&Theme) -> Style + 'a>;
```

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

- `FollowCursor` is the **default** if you don't specify `Position::...`. Most trading UIs prefer a fixed position (Top/Bottom) for consistency.
- `snap_within_viewport(true)` (the default) flips the tooltip to stay inside the window — e.g., a `Top` tooltip near the top edge becomes a `Bottom` tooltip.
- `delay(Duration::ZERO)` shows the tooltip immediately on hover. The default is a short delay to avoid flicker when the cursor just passes through.
- The `tooltip` element is another full `Element` — can be any widget, not just text. Use `container(...).style(container::rounded_box)` for a boxed popup.
- Nesting tooltips doesn't work well — the overlay layer only shows one tooltip at a time per hover path.

## See also

- `widget-container.md` — typical wrapper for the tooltip popup
- `widget-float.md` — for non-hover-triggered floating content
- `advanced-overlay.md` — if you need more control than `tooltip` provides
- `catalog.md` — styling pattern (tooltip delegates to container)
