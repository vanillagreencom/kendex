# Theme

> `iced::Theme` · iced 0.14.0

Default theme enum with 22 built-in variants plus `Custom(Arc<Custom>)`. Provides `palette()` for base colors and `extended_palette()` for derived strong/weak variants. Custom themes via `Theme::custom(name, palette)`.

## API

### `Theme` enum (the default theme)

```rust
pub enum Theme {
    Light,
    Dark,
    Dracula,
    Nord,
    SolarizedLight,
    SolarizedDark,
    GruvboxLight,
    GruvboxDark,
    CatppuccinLatte,
    CatppuccinFrappe,
    CatppuccinMacchiato,
    CatppuccinMocha,
    TokyoNight,
    TokyoNightStorm,
    TokyoNightLight,
    KanagawaWave,
    KanagawaDragon,
    KanagawaLotus,
    Moonfly,
    Nightfly,
    Oxocarbon,
    Ferra,
    Custom(Arc<theme::Custom>),
}
```


### Methods

```rust
impl Theme {
    pub const ALL: &'static [Theme];

    pub fn custom(
        name: impl Into<Cow<'static, str>>,
        palette: Palette,
    ) -> Theme;

    pub fn custom_with_fn(
        name: impl Into<Cow<'static, str>>,
        palette: Palette,
        generate: impl FnOnce(Palette) -> Extended,
    ) -> Theme;

    pub fn palette(&self) -> Palette;
    pub fn extended_palette(&self) -> &Extended;
}
```

- **`ALL`** — A `&'static` slice of every built-in theme, useful for
  building theme pickers.
- **`custom(name, palette)`** — Creates a `Theme::Custom` variant from a
  name and a base `Palette`. Iced auto-generates the `Extended` palette.
- **`custom_with_fn(name, palette, generate)`** — Same, but lets you
  override the auto-generator. Use this when you want precise control over
  the derived (weak/strong) variants.
- **`palette()`** — Returns the base `Palette` (6 colours: background,
  text, primary, success, warning, danger).
- **`extended_palette()`** — Returns an `&Extended` reference exposing the
  derived (background/primary/secondary/success/warning/danger with
  strong/weak variants and is_dark flag).

### `Custom` struct

```rust
pub struct Custom { /* private */ }

impl Custom {
    pub fn new(name: String, palette: Palette) -> Custom;

    pub fn with_fn(
        name: impl Into<Cow<'static, str>>,
        palette: Palette,
        generate: impl FnOnce(Palette) -> Extended,
    ) -> Custom;
}
```

## Patterns

### Use a built-in theme

```rust
pub fn main() -> iced::Result {
    iced::application(new, update, view)
        .theme(|_| Theme::TokyoNight)
        .run()
}
```


### Dynamic theme based on state

```rust
fn theme(state: &State) -> Theme {
    if state.dark_mode {
        Theme::Dark
    } else {
        Theme::Light
    }
}
```

### A custom theme

```rust
use iced::{Color, Theme};
use iced::theme::Palette;

let palette = Palette {
    background: Color::from_rgb(0.05, 0.05, 0.10),
    text:       Color::WHITE,
    primary:    Color::from_rgb(0.40, 0.70, 1.00),
    success:    Color::from_rgb(0.30, 0.85, 0.35),
    warning:    Color::from_rgb(1.00, 0.80, 0.30),
    danger:     Color::from_rgb(1.00, 0.40, 0.40),
};

let my_theme = Theme::custom("Midnight", palette);
```

### A custom theme with manual `Extended` generation

```rust
let my_theme = Theme::custom_with_fn(
    "Midnight",
    palette,
    |palette| {
        // Produce a fully custom `Extended` from the base palette
        iced::theme::palette::Extended::generate(palette)
    },
);
```

### Theme picker

```rust
pick_list(Theme::ALL, Some(state.theme.clone()), Message::ThemeSelected)
```

## Gotchas

- `Theme::Custom` wraps the `Custom` in an `Arc`, so cloning a `Theme` is
  cheap.
- `Theme::custom(name, palette)` auto-generates derived colours — if you
  need fine control over strong/weak variants, use `custom_with_fn`.
- `Theme::ALL` enumerates **built-in** themes only; your custom themes
  are not automatically added.
- Widgets query the theme via `theme.extended_palette()`. When building a
  custom `Catalog` implementation, prefer `Extended` fields over the raw
  `Palette` so you get the cohesive weak/strong variants.
- `Theme::custom_with_fn`'s `generate` closure runs **once** at
  construction, not on every lookup — don't rely on it being called per
  frame.
- Iced doesn't have a built-in "theme variants" mechanism — to switch
  between dark and light of the same theme you manually branch on state.
- No public API for iterating custom themes -- maintain that list yourself.

## See also

- `theme-palette.md`
- `catalog.md`
- `application.md`
- `widget-themer.md`
