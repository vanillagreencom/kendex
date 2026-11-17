# Themer

> `iced::widget::themer` · iced 0.14.0

Applies a different `Theme` to a subtree of widgets. Useful when parts of your UI need a distinct theme (e.g., a dark sidebar inside a light app).

## API

Iced 0.14.0 owns the declarations, bounds, feature gates and defaults: [widget/src/themer.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/themer.rs); [widget/src/helpers.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs).

## Patterns

### Apply a different theme to a section

```rust
use iced::widget::{themer, column, text};
use iced::Theme;

themer(
    Some(Theme::Dark),
    column![
        text("This section uses the Dark theme"),
        text("Regardless of the parent theme"),
    ]
    .spacing(8),
)
```

### Custom text color and background

```rust
themer(Some(my_theme), content)
    .text_color(|theme| theme.palette().text)
    .background(|theme| theme.palette().background.into())
```

### None theme (default for parent mode)

```rust
// None selects the child Theme default for the parent light/dark mode
themer(None, content)
```

## Gotchas

- With `None`, drawing calls the child theme's `Base::default` with the parent theme's mode. It does not preserve a custom parent palette.
- `text_color` and `background` take `fn` pointers, not closures. This means they cannot capture local state.
- `Themer` creates a theme boundary -- widgets inside it use the provided theme for their `Catalog` lookups, while widgets outside are unaffected.
- If your `Theme` type does not implement `Base`, you cannot use `Themer`. The built-in `iced::Theme` implements `Base`.

## See also

- `theme.md` -- `Theme::custom`, `Theme::custom_with_fn`
- `theme-palette.md` -- `Palette`, `Extended`
- `catalog.md` -- how widgets resolve styles from themes
- `widget-container.md` -- container-level styling
