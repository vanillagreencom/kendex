# Toggler

> `iced::widget::toggler` · iced 0.14.0

An on/off switch — the iOS-style toggle. Behaviorally identical to a checkbox, but visually implies a live state (preferences, feature flags) vs. a form selection.

## API

### `Toggler` struct

```rust
pub struct Toggler<'a, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where
    Theme: Catalog,
    Renderer: Renderer,
{ /* private fields */ }

impl<'a, Message, Theme, Renderer> Toggler<'a, Message, Theme, Renderer>
where
    Theme: Catalog,
    Renderer: Renderer,
{
    pub const DEFAULT_SIZE: f32 = 16f32;

    pub fn new(is_toggled: bool) -> Self;

    pub fn label(self, label: impl IntoFragment<'a>) -> Self;

    pub fn on_toggle(self, on_toggle: impl Fn(bool) -> Message + 'a) -> Self;
    pub fn on_toggle_maybe(self, on_toggle: Option<impl Fn(bool) -> Message + 'a>) -> Self;

    pub fn size(self, size: impl Into<Pixels>) -> Self;
    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn spacing(self, spacing: impl Into<Pixels>) -> Self;

    pub fn text_size(self, text_size: impl Into<Pixels>) -> Self;
    pub fn text_line_height(self, line_height: impl Into<LineHeight>) -> Self;
    pub fn text_alignment(self, alignment: impl Into<Alignment>) -> Self;
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
    Active   { is_toggled: bool },
    Hovered  { is_toggled: bool },
    Disabled { is_toggled: bool },
}
```

### `Style` struct

```rust
pub struct Style {
    pub background: Background,
    pub background_border_width: f32,
    pub background_border_color: Color,
    pub foreground: Background,            // The sliding knob
    pub foreground_border_width: f32,
    pub foreground_border_color: Color,
    pub text_color: Option<Color>,
    pub border_radius: Option<Radius>,
    pub padding_ratio: f32,                // Knob inset as fraction of size
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
pub fn toggler<'a, Message, Theme, Renderer>(
    is_toggled: bool,
) -> Toggler<'a, Message, Theme, Renderer>;

pub fn default(theme: &Theme, status: Status) -> Style;

pub type StyleFn<'a, Theme> = Box<dyn Fn(&Theme, Status) -> Style + 'a>;
```

## Patterns

### Basic toggle

```rust
use iced::widget::toggler;

toggler(state.enabled)
    .label("Enable notifications")
    .on_toggle(Message::Toggle)
```

### Row of togglers

```rust
column(
    settings.iter().map(|s| {
        toggler(s.active)
            .label(&s.name)
            .on_toggle(move |b| Message::SettingChanged(s.id, b))
            .into()
    })
).spacing(8)
```

### Label on the left (trailing toggle)

```rust
toggler(state.enabled)
    .label("Dark mode")
    .text_alignment(iced::alignment::Horizontal::Left)
    .on_toggle(Message::DarkMode)
```

## Gotchas

- Without `on_toggle`, the toggler is disabled (exactly like checkbox). Use `on_toggle_maybe` for conditional enable.
- `DEFAULT_SIZE = 16.0` — the height of the track; the knob is derived proportionally via `padding_ratio`.
- `Status` variants carry `is_toggled` so your style closure can color on vs. off states. The default theme uses the theme's primary color for on.
- Visually, toggler implies **persistent state** (setting/preference), while checkbox implies **selection** (form field, multi-select). Prefer toggler for "take effect immediately" settings.
- `spacing` is between the switch and the label, not between the widget and its siblings.

## See also

- `widget-checkbox.md` — the alternative for form-like selection
- `widget-radio.md` — single choice from a group
- `catalog.md` — styling pattern
