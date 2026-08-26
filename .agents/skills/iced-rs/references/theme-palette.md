# Theme: Palette & Extended

> `iced::theme::Palette` + `iced::theme::palette::Extended` · iced 0.14.0

`Palette` is the 6-color seed (background, text, primary, success, warning, danger). `Extended` is the derived palette with weak/strong variants and `Pair` (surface color + readable text color). Access via `theme.extended_palette()`.

## API

### `Palette` struct

```rust
pub struct Palette {
    pub background: Color,
    pub text:       Color,
    pub primary:    Color,
    pub success:    Color,
    pub warning:    Color,
    pub danger:     Color,
}
```

### Built-in `Palette` constants

```rust
impl Palette {
    pub const LIGHT: Palette;
    pub const DARK: Palette;
    pub const DRACULA: Palette;
    pub const NORD: Palette;
    pub const SOLARIZED_LIGHT: Palette;
    pub const SOLARIZED_DARK: Palette;
    pub const GRUVBOX_LIGHT: Palette;
    pub const GRUVBOX_DARK: Palette;
    pub const CATPPUCCIN_LATTE: Palette;
    pub const CATPPUCCIN_FRAPPE: Palette;
    pub const CATPPUCCIN_MACCHIATO: Palette;
    pub const CATPPUCCIN_MOCHA: Palette;
    pub const TOKYO_NIGHT: Palette;
    pub const TOKYO_NIGHT_STORM: Palette;
    pub const TOKYO_NIGHT_LIGHT: Palette;
    pub const KANAGAWA_WAVE: Palette;
    pub const KANAGAWA_DRAGON: Palette;
    pub const KANAGAWA_LOTUS: Palette;
    pub const MOONFLY: Palette;
    pub const NIGHTFLY: Palette;
    pub const OXOCARBON: Palette;
    pub const FERRA: Palette;
}
```

### `Extended` struct

```rust
pub struct Extended {
    pub background: Background,
    pub primary:    Primary,
    pub secondary:  Secondary,
    pub success:    Success,
    pub warning:    Warning,
    pub danger:     Danger,
    pub is_dark:    bool,
}
```

- **`is_dark`** — Whether the derived palette should be treated as a dark
  theme. Useful for picking icons or inverting elements.

### `Pair` struct

```rust
pub struct Pair {
    pub color: Color,   // background color
    pub text:  Color,   // readable text color on top of `color`
}

impl Pair {
    pub fn new(color: Color, text: Color) -> Pair;
}
```

### `Background` struct

```rust
pub struct Background {
    pub base:      Pair,
    pub weakest:   Pair,
    pub weaker:    Pair,
    pub weak:      Pair,
    pub neutral:   Pair,
    pub strong:    Pair,
    pub stronger:  Pair,
    pub strongest: Pair,
}

impl Background {
    pub fn new(base: Color, text: Color) -> Background;
}
```

Eight elevation levels from base background, each with a readable text pair.

### `Primary`, `Secondary`, `Success`, `Warning`, `Danger`

Three-tier shape (weak/base/strong):

```rust
pub struct Primary {
    pub base:   Pair,
    pub weak:   Pair,
    pub strong: Pair,
}

impl Primary {
    pub fn generate(base: Color, background: Color, text: Color) -> Primary;
}
```

`Secondary`, `Success`, `Warning`, `Danger` follow the same three-tier pattern. `Extended::generate(palette)` auto-derives all tiers from a base `Palette`.

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
let bg = palette.background.base;
let text_color = bg.text; // already computed by iced for contrast
```


## Gotchas

- Prefer `.extended_palette()` over `.palette()` when styling widgets — the
  extended palette already contains the strong/weak variants and paired
  text colours, so you don't need to compute contrast yourself.
- `is_dark` is a hint, not a rule — some colour combos are borderline.
  Don't swap icons based on it; use it only when the rest of your theming
  can tolerate a flip.
- `Primary::generate(base, background, text)` takes the **background**
  too, because it contrast-adjusts against it. Don't pass a stale
  background when deriving variants.
- `Background` has eight levels (`weakest` through `strongest`), but the
  other accent structs only have three (`weak`/`base`/`strong`). Don't
  expect parallel level counts.
- `Extended` is plain data — it's cheap to clone, but it's usually
  accessed through `theme.extended_palette()` which returns a borrow.
- No API for partial overrides -- rebuild the full `Extended` via `custom_with_fn`.

## See also

- `theme.md`
- `catalog.md`
- `advanced-renderer.md`
