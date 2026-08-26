# Text Widget

> `iced::widget::text` · iced 0.14.0

The fundamental widget for displaying text. `Text` renders a single fragment; `Rich` renders styled spans with per-span formatting, links, and highlights. Not to be confused with `advanced::text` which covers the low-level `Renderer` trait.

## API

### `Text` struct

```rust
pub struct Text<'a, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where
    Theme: Catalog,
    Renderer: text::Renderer,
{ /* private fields */ }

impl<'a, Theme, Renderer> Text<'a, Theme, Renderer>
where
    Theme: Catalog,
    Renderer: text::Renderer,
{
    pub fn new(fragment: impl IntoFragment<'a>) -> Self;
    pub fn size(self, size: impl Into<Pixels>) -> Self;
    pub fn line_height(self, line_height: impl Into<LineHeight>) -> Self;
    pub fn font(self, font: impl Into<Renderer::Font>) -> Self;
    pub fn font_maybe(self, font: Option<impl Into<Renderer::Font>>) -> Self;
    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn height(self, height: impl Into<Length>) -> Self;
    pub fn center(self) -> Self;
    pub fn align_x(self, alignment: impl Into<Alignment>) -> Self;
    pub fn align_y(self, alignment: impl Into<Vertical>) -> Self;
    pub fn shaping(self, shaping: Shaping) -> Self;
    pub fn wrapping(self, wrapping: Wrapping) -> Self;
    pub fn style(self, style: impl Fn(&Theme) -> Style + 'a) -> Self;
    pub fn color(self, color: impl Into<Color>) -> Self;
    pub fn color_maybe(self, color: Option<impl Into<Color>>) -> Self;
    pub fn class(self, class: impl Into<<Theme as Catalog>::Class<'a>>) -> Self;
}
```

### `Rich` struct (rich text)

```rust
pub struct Rich<'a, Link, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
{ /* private fields */ }

impl<'a, Link, Message, Theme, Renderer> Rich<'a, Link, Message, Theme, Renderer> {
    pub fn new() -> Self;
    pub fn with_spans(spans: impl AsRef<[Span<'a, Link, Renderer::Font>]> + 'a) -> Self;
    pub fn size(self, size: impl Into<Pixels>) -> Self;
    pub fn line_height(self, line_height: impl Into<LineHeight>) -> Self;
    pub fn font(self, font: impl Into<Renderer::Font>) -> Self;
    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn height(self, height: impl Into<Length>) -> Self;
    pub fn center(self) -> Self;
    pub fn align_x(self, alignment: impl Into<Alignment>) -> Self;
    pub fn align_y(self, alignment: impl Into<Vertical>) -> Self;
    pub fn wrapping(self, wrapping: Wrapping) -> Self;
    pub fn on_link_click(self, f: impl Fn(Link) -> Message + 'a) -> Self;
    pub fn style(self, style: impl Fn(&Theme) -> Style + 'a) -> Self;
    pub fn color(self, color: impl Into<Color>) -> Self;
    pub fn color_maybe(self, color: Option<impl Into<Color>>) -> Self;
    pub fn class(self, class: impl Into<<Theme as Catalog>::Class<'a>>) -> Self;
}
```

### `Span` struct

```rust
pub struct Span<'a, Link, Font> {
    pub text: Cow<'a, str>,
    pub size: Option<Pixels>,
    pub line_height: Option<LineHeight>,
    pub font: Option<Font>,
    pub color: Option<Color>,
    pub link: Option<Link>,
    pub highlight: Option<Highlight>,
    pub padding: Padding,
    pub underline: bool,
    pub strikethrough: bool,
}

impl<'a, Link, Font> Span<'a, Link, Font> {
    pub fn new(fragment: impl IntoFragment<'a>) -> Self;
    pub fn size(self, size: impl Into<Pixels>) -> Self;
    pub fn line_height(self, line_height: impl Into<LineHeight>) -> Self;
    pub fn font(self, font: impl Into<Font>) -> Self;
    pub fn color(self, color: impl Into<Color>) -> Self;
    pub fn link(self, link: impl Into<Link>) -> Self;
    pub fn background(self, background: impl Into<Background>) -> Self;
    pub fn border(self, border: impl Into<Border>) -> Self;
    pub fn padding(self, padding: impl Into<Padding>) -> Self;
    pub fn underline(self, underline: bool) -> Self;
    pub fn strikethrough(self, strikethrough: bool) -> Self;
    pub fn to_static(self) -> Span<'static, Link, Font>;
}
```

### `Catalog` trait + `Style`

```rust
pub trait Catalog {
    type Class<'a>;
    fn default<'a>() -> Self::Class<'a>;
    fn style(&self, item: &Self::Class<'_>) -> Style;
}

pub struct Style {
    pub color: Option<Color>,
}

pub type StyleFn<'a, Theme> = Box<dyn Fn(&Theme) -> Style + 'a>;

// Built-in style functions
pub fn default(_theme: &Theme) -> Style;  // inherits color
pub fn base(theme: &Theme) -> Style;      // uses theme text color
```

### Text enums

```rust
pub enum Shaping {
    Auto,     // Basic for ASCII, Advanced otherwise (default)
    Basic,    // No shaping, no font fallback (fast)
    Advanced, // Full shaping + font fallback (expensive)
}

pub enum Wrapping {
    None,        // No wrapping
    Word,        // Word-level (default)
    Glyph,       // Glyph-level
    WordOrGlyph, // Word-level, fallback to glyph if word too long
}

pub enum LineHeight {
    Relative(f32),      // Factor of text size (default: 1.3)
    Absolute(Pixels),   // Fixed height in logical pixels
}
```

### Convenience macros and functions

```rust
// Free function
pub fn text<'a, Message, Theme, Renderer>(
    fragment: impl IntoFragment<'a>,
) -> Text<'a, Theme, Renderer>;

// Macro with format-string support
text!("Price: {:.2}", price)

// Rich text
pub fn rich_text<'a, Link, Message, Theme, Renderer>(
    spans: impl AsRef<[Span<'a, Link, Renderer::Font>]> + 'a,
) -> Rich<'a, Link, Message, Theme, Renderer>;

// Macro
rich_text![span("bold").font(Font::BOLD), span(" normal")]

// Span constructor
pub fn span<'a, Link, Font>(
    fragment: impl IntoFragment<'a>,
) -> Span<'a, Link, Font>;
```

## Patterns

### Simple text

```rust
use iced::widget::text;
text("Hello, world!").size(16)
```

### Formatted text with macro

```rust
use iced::widget::text;
text!("Balance: ${:.2}", balance).color(Color::WHITE)
```

### Rich text with styled spans

```rust
use iced::widget::{rich_text, span};
use iced::{color, Font, font};

rich_text![
    span("Error: ").color(color!(0xff4444)).font(Font {
        weight: font::Weight::Bold,
        ..Font::default()
    }),
    span("Connection lost"),
]
.size(14)
```

### Conditional text color

```rust
text!("{:+.2}%", change)
    .color_maybe(if change >= 0.0 {
        Some(Color::from_rgb(0.3, 0.85, 0.35))
    } else {
        Some(Color::from_rgb(1.0, 0.4, 0.4))
    })
```

## Gotchas

- `text::Style` has only one field: `color: Option<Color>`. `None` means inherit from parent.
- `Shaping::Basic` silently drops glyphs not in the font. Use `Auto` unless you control the content.
- `text!()` is a format-string macro (`text!("x: {}", val)`); `text()` is a function taking `IntoFragment`.
- `Rich` is generic over `Link` -- if you don't use links, the link type can be `()` or use `never` as the handler.
- `Span` fields like `highlight`, `padding`, `background`, `border` only affect the span's visual decoration, not layout.
- `LineHeight::Relative(1.0)` means exactly the font size with no extra spacing.

## See also

- `advanced-text.md` -- low-level `text::Renderer`, `Paragraph`, cached text rendering
- `widget-text-editor.md` -- multi-line editable text
- `widget-text-input.md` -- single-line text input
- `alignment.md` -- `Alignment`, `Horizontal`, `Vertical`
- `catalog.md` -- the `Catalog` trait pattern
