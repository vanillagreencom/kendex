# Scrollable

> `iced::widget::scrollable` · iced 0.14.0

Wraps content in a scrollbar-enabled viewport. Vertical by default; call `horizontal()` or `direction()` for other axes. Use `on_scroll(Viewport -> Msg)` to observe scrolling.

## API

### `Scrollable` struct

```rust
pub struct Scrollable<'a, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where
    Theme: Catalog,
    Renderer: Renderer,
{ /* private fields */ }

impl<'a, Message, Theme, Renderer> Scrollable<'a, Message, Theme, Renderer>
where
    Theme: Catalog,
    Renderer: Renderer,
{
    pub fn new(content: impl Into<Element<'a, Message, Theme, Renderer>>) -> Self;
    pub fn with_direction(
        content: impl Into<Element<'a, Message, Theme, Renderer>>,
        direction: impl Into<Direction>,
    ) -> Self;

    pub fn horizontal(self) -> Self;
    pub fn direction(self, direction: impl Into<Direction>) -> Self;

    pub fn id(self, id: impl Into<Id>) -> Self;
    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn height(self, height: impl Into<Length>) -> Self;

    pub fn on_scroll(self, f: impl Fn(Viewport) -> Message + 'a) -> Self;

    pub fn anchor_top(self) -> Self;
    pub fn anchor_bottom(self) -> Self;
    pub fn anchor_left(self) -> Self;
    pub fn anchor_right(self) -> Self;
    pub fn anchor_x(self, alignment: Anchor) -> Self;
    pub fn anchor_y(self, alignment: Anchor) -> Self;

    pub fn spacing(self, new_spacing: impl Into<Pixels>) -> Self;
    pub fn auto_scroll(self, auto_scroll: bool) -> Self;

    pub fn style(self, style: impl Fn(&Theme, Status) -> Style + 'a) -> Self
    where
        <Theme as Catalog>::Class<'a>: From<Box<dyn Fn(&Theme, Status) -> Style + 'a>>;

    pub fn class(self, class: impl Into<<Theme as Catalog>::Class<'a>>) -> Self; // feature = "advanced"
}
```

### `Direction` enum

```rust
pub enum Direction {
    Vertical(Scrollbar),
    Horizontal(Scrollbar),
    Both { vertical: Scrollbar, horizontal: Scrollbar },
}

impl Direction {
    pub fn horizontal(&self) -> Option<&Scrollbar>;
    pub fn vertical(&self) -> Option<&Scrollbar>;
}
```

### `Anchor` enum

```rust
pub enum Anchor {
    Start,  // Scroller anchored to start of viewport
    End,    // Content aligned to end of viewport
}
```

### `Status` enum

```rust
pub enum Status {
    Active,
    Hovered {
        is_horizontal_scrollbar_hovered: bool,
        is_vertical_scrollbar_hovered: bool,
    },
    Dragged {
        is_horizontal_scrollbar_dragged: bool,
        is_vertical_scrollbar_dragged: bool,
    },
}
```

### `Scrollbar` struct

```rust
pub struct Scrollbar { /* private */ }

impl Scrollbar {
    pub fn new() -> Scrollbar;
    pub fn hidden() -> Scrollbar;
    pub fn width(self, width: impl Into<Pixels>) -> Scrollbar;
    pub fn margin(self, margin: impl Into<Pixels>) -> Scrollbar;
    pub fn scroller_width(self, scroller_width: impl Into<Pixels>) -> Scrollbar;
    pub fn anchor(self, alignment: Anchor) -> Scrollbar;
    pub fn spacing(self, spacing: impl Into<Pixels>) -> Scrollbar;
}
```

### `Viewport` struct

```rust
pub struct Viewport { /* private */ }

impl Viewport {
    pub fn absolute_offset(&self) -> AbsoluteOffset;
    pub fn absolute_offset_reversed(&self) -> AbsoluteOffset;
    pub fn relative_offset(&self) -> RelativeOffset;
    pub fn bounds(&self) -> Rectangle;
    pub fn content_bounds(&self) -> Rectangle;
}
```

### `AbsoluteOffset` / `RelativeOffset` structs

```rust
pub struct AbsoluteOffset { pub x: f32, pub y: f32 }
pub struct RelativeOffset { pub x: f32, pub y: f32 }
```

### `Style`, `Rail`, `Scroller`, `AutoScroll` structs

```rust
pub struct Style {
    pub container: container::Style,
    pub vertical_rail: Rail,
    pub horizontal_rail: Rail,
    pub gap: Option<Background>,
    pub auto_scroll: AutoScroll,
}

pub struct Rail {
    pub background: Option<Background>,
    pub border: Border,
    pub scroller: Scroller,
}

pub struct Scroller {
    pub color: Color,
    pub border: Border,
}

pub struct AutoScroll {
    // Visuals of the autoscroll cursor overlay
}
```

### `Catalog` trait

```rust
pub trait Catalog {
    type Class<'a>;
    fn default<'a>() -> Self::Class<'a>;
    fn style(&self, class: &Self::Class<'_>, status: Status) -> Style;
}
```

### Functions & type aliases

```rust
pub fn scrollable<'a, Message, Theme, Renderer>(
    content: impl Into<Element<'a, Message, Theme, Renderer>>,
) -> Scrollable<'a, Message, Theme, Renderer>;

pub fn default(theme: &Theme, status: Status) -> Style;

pub type StyleFn<'a, Theme> = Box<dyn Fn(&Theme, Status) -> Style + 'a>;
```

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
    // viewport.relative_offset() is 0.0-1.0
    // viewport.bounds() for visible area
}
```

### Programmatic scroll

```rust
// Uses scrollable::Id + Task::scroll_to / scroll_by
let scroll_id = scrollable::Id::new("my-scroll");
scrollable(content).id(scroll_id.clone())

// In update: return Task
Task::done(Message::ScrollTo(scrollable::AbsoluteOffset { x: 0.0, y: 500.0 }))
// Then: Task::scroll_to(scroll_id, offset)
```

## Gotchas

- `on_scroll` fires only on **user-initiated scroll**, not on initial render or programmatic scrolling. To detect the initial scroll position (or container resize), wrap contents in a `sensor` and combine `sensor.on_show` with `scrollable.on_scroll`.
- `spacing()` **embeds** the scrollbar into the layout (takes space). Without it the scrollbar floats over content.
- `anchor_bottom()` makes newly appended content scroll into view automatically — use this for log/console views.
- `auto_scroll(true)` enables **middle-click auto-scroll** (cursor-follow scrolling); different from auto-scroll-to-bottom.
- The viewport returned in `on_scroll` has `absolute_offset()` (pixels from top) and `relative_offset()` (0.0-1.0 normalized). Use relative for percentage indicators; absolute for pixel-precise positioning.

## See also

- `widget-sensor.md` — detecting layout changes inside scrollables
- `task.md` — `Task::scroll_to(id, offset)` / `Task::scroll_by(id, offset)`
- `advanced-operation.md` — `Scrollable` operation trait for widgets that expose scroll state
- `catalog.md` — styling pattern
