# Text Widget

> `iced::widget::text` · iced 0.14.0

The fundamental widget for displaying text. `Text` renders a single fragment; `Rich` renders styled spans with per-span formatting, links, and highlights. Not to be confused with `advanced::text` which covers the low-level `Renderer` trait.

## API

Iced 0.14.0 owns the declarations, bounds, feature gates and defaults: [widget/src/text.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/text.rs); [core/src/widget/text.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/widget/text.rs); [widget/src/text/rich.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/text/rich.rs); [core/src/text.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/text.rs); [widget/src/helpers.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs).

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
.on_link_click(iced::never)
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
- Span padding expands the background and border decoration; it does not add text layout spacing.
- `LineHeight::Relative(1.0)` means exactly the font size with no extra spacing.

## See also

- `advanced-text.md` -- low-level `text::Renderer`, `Paragraph`, cached text rendering
- `widget-text-editor.md` -- multi-line editable text
- `widget-text-input.md` -- single-line text input
- `alignment.md` -- `Alignment`, `Horizontal`, `Vertical`
- `catalog.md` -- the `Catalog` trait pattern
