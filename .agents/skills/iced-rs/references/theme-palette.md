# Theme: Palette & Extended

> `iced::theme::Palette` + `iced::theme::palette::Extended` · iced 0.14.0

`Palette` is the 6-color seed (background, text, primary, success, warning, danger). `Extended` is the derived palette with weak/strong variants and `Pair` (surface color + readable text color). Access via `theme.extended_palette()`. Iced 0.14 uses Oklch helpers where 0.13 used HSL.

Read when choosing palette roles or deriving custom variants.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/theme/palette.rs) for signatures and available types.

## Patterns

### Consume the extended palette in a custom widget

```rust
fn draw(&self, _tree: &Tree, renderer: &mut Renderer, theme: &Theme, ..., layout: Layout<'_>, ...) {
    let palette = theme.extended_palette();

    renderer.fill_quad(
        Quad {
            bounds: layout.bounds(),
            border: Border {
                color:  palette.background.strong.color,
                width:  1.0,
                radius: 4.0.into(),
            },
            shadow: Shadow::default(),
            snap: true,
        },
        Background::Color(palette.background.weak.color),
    );
}
```

### Build a palette from scratch

```rust
use iced::Color;
use iced::theme::Palette;

let palette = Palette {
    background: Color::from_rgb(0.07, 0.08, 0.12),
    text:       Color::WHITE,
    primary:    Color::from_rgb(0.42, 0.69, 1.00),
    success:    Color::from_rgb(0.35, 0.80, 0.40),
    warning:    Color::from_rgb(1.00, 0.78, 0.35),
    danger:     Color::from_rgb(1.00, 0.40, 0.40),
};
```

### Pick a readable text colour automatically

```rust
let bg = theme.extended_palette().background.base;
let text_color = bg.text; // already computed by iced for contrast
```

## Gotchas

- Prefer `.extended_palette()` over `.palette()` when styling widgets — the extended palette already contains the strong/weak variants and paired text colours, so you don't need to compute contrast yourself.
- `is_dark` is a hint, not a rule — some colour combos are borderline. Don't swap icons based on it; use it only when the rest of your theming can tolerate a flip.
- `Primary::generate(base, background, text)` mixes its weak variant with the background. Don't pass a stale background when deriving variants.
- `Background` has eight levels (`weakest` through `strongest`), but the other accent structs only have three (`weak`/`base`/`strong`). Don't expect parallel level counts.
- Read `theme.extended_palette()` by reference when choosing styles.
- For partial overrides, generate an `Extended` inside `custom_with_fn`, mutate its public fields, and return it.

## See also

- `theme.md`
- `catalog.md`
- `advanced-renderer.md`
