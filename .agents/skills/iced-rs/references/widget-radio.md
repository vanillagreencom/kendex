# Radio

> `iced::widget::radio` · iced 0.14.0

A circular button representing a mutually-exclusive choice. Put several radios together (all referencing the same selected value) to form a group.

## API

### `Radio` struct

```rust
pub struct Radio<'a, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where
    Theme: Catalog,
    Renderer: Renderer,
{ /* private fields */ }

impl<'a, Message, Theme, Renderer> Radio<'a, Message, Theme, Renderer>
where
    Message: Clone,
    Theme: Catalog,
    Renderer: Renderer,
{
    pub const DEFAULT_SIZE: f32 = 16f32;
    pub const DEFAULT_SPACING: f32 = 8f32;

    pub fn new<F, V>(
        label: impl Into<String>,
        value: V,
        selected: Option<V>,
        f: F,
    ) -> Self
    where
        V: Eq + Copy,
        F: FnOnce(V) -> Message;

    pub fn size(self, size: impl Into<Pixels>) -> Self;
    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn spacing(self, spacing: impl Into<Pixels>) -> Self;
    pub fn text_size(self, text_size: impl Into<Pixels>) -> Self;
    pub fn text_line_height(self, line_height: impl Into<LineHeight>) -> Self;
    pub fn text_shaping(self, shaping: Shaping) -> Self;
    pub fn text_wrapping(self, wrapping: Wrapping) -> Self;
    pub fn font(self, font: impl Into<<Renderer as Renderer>::Font>) -> Self;

    pub fn style(self, style: impl Fn(&Theme, Status) -> Style + 'a) -> Self;
    pub fn class(self, class: impl Into<<Theme as Catalog>::Class<'a>>) -> Self;
}
```

### `Status` enum

```rust
pub enum Status {
    Active   { is_selected: bool },
    Hovered  { is_selected: bool },
    Disabled { is_selected: bool },
}
```

### `Style` struct

```rust
pub struct Style {
    pub background: Background,
    pub dot_color: Color,
    pub border_width: f32,
    pub border_color: Color,
    pub text_color: Option<Color>,
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
pub fn radio<'a, Message, Theme, Renderer, F, V>(
    label: impl Into<String>,
    value: V,
    selected: Option<V>,
    f: F,
) -> Radio<'a, Message, Theme, Renderer>
where
    V: Eq + Copy,
    F: FnOnce(V) -> Message;

pub fn default(theme: &Theme, status: Status) -> Style;

pub type StyleFn<'a, Theme> = Box<dyn Fn(&Theme, Status) -> Style + 'a>;
```

## Patterns

### Radio group (multiple radios, one selected)

```rust
use iced::widget::{column, radio};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Choice { A, B, C }

column![
    radio("Option A", Choice::A, state.selected, Message::Select),
    radio("Option B", Choice::B, state.selected, Message::Select),
    radio("Option C", Choice::C, state.selected, Message::Select),
].spacing(8)
```

In `update`:

```rust
Message::Select(choice) => {
    state.selected = Some(choice);
}
```

### Horizontal group

```rust
use iced::widget::{row, radio};

row![
    radio("Low",    Quality::Low,    state.quality, Message::SetQuality),
    radio("Medium", Quality::Medium, state.quality, Message::SetQuality),
    radio("High",   Quality::High,   state.quality, Message::SetQuality),
].spacing(16)
```

## Gotchas

- The `value: V` type must implement `Eq + Copy`. Enums with `derive(Clone, Copy, PartialEq, Eq)` work naturally.
- Each radio takes the **full group's** `selected: Option<V>` — not a per-radio boolean. The widget compares its own value to `selected` internally.
- Radio does **not** have an `on_toggle_maybe`-style conditional API — unlike checkbox/toggler, there's no disabled-via-None pattern. To disable, wrap in a conditional (acceptable here because the whole radio is effectively one widget, not a composite of state).
- `DEFAULT_SPACING = 8.0` is the gap between the circle and the label; configure with `.spacing(...)` for denser/looser layouts.
- No separate "unselect" interaction — clicking an already-selected radio doesn't fire a message. Use checkbox if users need to toggle off.

## See also

- `widget-checkbox.md` — multi-select equivalent
- `widget-toggler.md` — boolean on/off switch
- `widget-pick-list.md` — compact alternative when option count is high
- `catalog.md` — styling pattern
