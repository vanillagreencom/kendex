# Checkbox

> `iced::widget::checkbox` · iced 0.14.0

A toggleable box showing a check mark when enabled. Use for boolean preferences, multi-select lists, or confirm-to-proceed interactions.

## API

### `Checkbox` struct

```rust
pub struct Checkbox<'a, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where
    Renderer: Renderer,
    Theme: Catalog,
{ /* private fields */ }

impl<'a, Message, Theme, Renderer> Checkbox<'a, Message, Theme, Renderer>
where
    Renderer: Renderer,
    Theme: Catalog,
{
    pub fn new(is_checked: bool) -> Self;

    pub fn label(self, label: impl IntoFragment<'a>) -> Self;

    pub fn on_toggle<F: 'a + Fn(bool) -> Message>(self, f: F) -> Self;
    pub fn on_toggle_maybe<F: Fn(bool) -> Message + 'a>(self, f: Option<F>) -> Self;

    pub fn size(self, size: impl Into<Pixels>) -> Self;
    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn spacing(self, spacing: impl Into<Pixels>) -> Self;
    pub fn text_size(self, text_size: impl Into<Pixels>) -> Self;
    pub fn text_line_height(self, line_height: impl Into<LineHeight>) -> Self;
    pub fn text_shaping(self, shaping: Shaping) -> Self;
    pub fn text_wrapping(self, wrapping: Wrapping) -> Self;
    pub fn font(self, font: impl Into<<Renderer as Renderer>::Font>) -> Self;

    pub fn icon(self, icon: Icon<<Renderer as Renderer>::Font>) -> Self;

    pub fn style(self, style: impl Fn(&Theme, Status) -> Style + 'a) -> Self
    where
        <Theme as Catalog>::Class<'a>: From<Box<dyn Fn(&Theme, Status) -> Style + 'a>>;

    pub fn class(self, class: impl Into<<Theme as Catalog>::Class<'a>>) -> Self; // feature = "advanced"
}
```

### `Status` enum

```rust
pub enum Status {
    Active   { is_checked: bool },
    Hovered  { is_checked: bool },
    Disabled { is_checked: bool },
}
```

### `Icon` struct

```rust
pub struct Icon<Font> {
    pub font: Font,
    pub code_point: char,
    pub size: Option<Pixels>,
    pub line_height: LineHeight,
    pub shaping: Shaping,
}
```

### `Style` struct

```rust
pub struct Style {
    pub background: Background,
    pub icon_color: Color,
    pub border: Border,
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
pub fn checkbox<'a, Message, Theme, Renderer>(
    is_checked: bool,
) -> Checkbox<'a, Message, Theme, Renderer>;

pub fn primary(theme: &Theme, status: Status) -> Style;
pub fn secondary(theme: &Theme, status: Status) -> Style;
pub fn success(theme: &Theme, status: Status) -> Style;
pub fn danger(theme: &Theme, status: Status) -> Style;

pub type StyleFn<'a, Theme> = Box<dyn Fn(&Theme, Status) -> Style + 'a>;
```

## Patterns

### Basic toggle

```rust
use iced::widget::checkbox;

checkbox(state.is_enabled)
    .label("Enable notifications")
    .on_toggle(Message::Toggle)
```

### Multi-select list

```rust
column(
    items.iter().enumerate().map(|(i, item)| {
        checkbox(item.selected)
            .label(&item.name)
            .on_toggle(move |b| Message::ItemToggle(i, b))
            .into()
    })
).spacing(4)
```

### Conditional enable

```rust
checkbox(state.accepted)
    .label("I accept the terms")
    .on_toggle_maybe(if state.can_change { Some(Message::AcceptTerms) } else { None })
```

### Custom check icon (FontAwesome, etc.)

```rust
use iced::widget::checkbox::Icon;
use iced::Font;

checkbox(state.checked)
    .label("Custom icon")
    .icon(Icon {
        font: Font::with_name("FontAwesome"),
        code_point: '\u{F00C}', // check
        size: Some(14.0.into()),
        line_height: 1.0.into(),
        shaping: Shaping::Advanced,
    })
    .on_toggle(Message::Toggle)
```

## Gotchas

- Omitting `on_toggle` disables the checkbox. Use `on_toggle_maybe(Option)` for conditional enable — do NOT conditionally wrap the widget.
- `Status` variants carry `is_checked` so your style closure can color filled vs. empty states: `checkbox::Style { background: if status.is_checked { ... } else { ... } }`.
- `icon` takes a `char` code point — not an SVG path. For arbitrary check glyphs, use a font with the glyph loaded.
- `spacing` is between the box and the label text, not padding around the widget.
- `on_toggle` receives the **new** state (not the old state) — so you set state directly to the parameter.

## See also

- `widget-toggler.md` — on/off switch alternative to checkbox
- `widget-radio.md` — single-choice from a group
- `catalog.md` — styling pattern
- `advanced-text.md` — `IntoFragment` trait used by `label`
