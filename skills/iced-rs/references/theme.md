# Theme

> `iced::Theme` · iced 0.14.0

Use `Theme` to choose a built-in or custom palette. Provides `palette()` for base colors and `extended_palette()` for derived strong/weak variants. Custom themes via `Theme::custom(name, palette)`.

Read when choosing, switching, or constructing an Iced theme.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/theme.rs) for signatures and available types.

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

- Cloning `Theme::Custom` shares its palette through the `Arc`.
- `Theme::custom(name, palette)` auto-generates derived colours — if you need fine control over strong/weak variants, use `custom_with_fn`.
- `Theme::ALL` enumerates **built-in** themes only; your custom themes are not automatically added.
- Widgets query the theme via `theme.extended_palette()`. When building a custom `Catalog` implementation, prefer `Extended` fields over the raw `Palette` so you get the cohesive weak/strong variants.
- `Theme::custom_with_fn`'s `generate` closure runs **once** at construction, not on every lookup — don't rely on it being called per frame.
- Choose a light or dark theme from app state in the theme callback.
- Maintain a separate list for your app’s custom themes.

## See also

- `theme-palette.md`
- `catalog.md`
- `application.md`
- `widget-themer.md`
