# Themer

> `iced::widget::themer` · iced 0.14.0

Applies a different `Theme` to a subtree of widgets. Useful when parts of your UI need a distinct theme (e.g., a dark sidebar inside a light app).

## API

### `Themer` struct

```rust
pub struct Themer<'a, Message, Theme, Renderer = Renderer<Renderer, Renderer>>
where
    Renderer: Renderer,
{ /* private fields */ }

impl<'a, Message, Theme, Renderer> Themer<'a, Message, Theme, Renderer>
where
    Theme: Base,
    Renderer: Renderer,
{
    pub fn new(
        theme: Option<Theme>,
        content: impl Into<Element<'a, Message, Theme, Renderer>>,
    ) -> Self;

    pub fn text_color(
        self,
        f: fn(&Theme) -> Color,
    ) -> Self;

    pub fn background(
        self,
        f: fn(&Theme) -> Background,
    ) -> Self;
}
```

### `Base` trait (required by Theme)

The `Theme` type parameter must implement `Base`, which provides the foundational styling methods that `Themer` uses to set default text color and background.

### Widget implementation

`Themer` implements `Widget<Message, AnyTheme, Renderer>` where both `Theme: Base` and `AnyTheme: Base`. This means it can be embedded in any parent theme context.

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

### None theme (inherit parent)

```rust
// Passing None means the parent theme is inherited unchanged
themer(None, content)
```

## Gotchas

- The `theme` argument is `Option<Theme>`. Passing `None` means the parent theme passes through unchanged.
- `text_color` and `background` take `fn` pointers, not closures. This means they cannot capture local state.
- `Themer` creates a theme boundary -- widgets inside it use the provided theme for their `Catalog` lookups, while widgets outside are unaffected.
- If your `Theme` type does not implement `Base`, you cannot use `Themer`. The built-in `iced::Theme` implements `Base`.

## See also

- `theme.md` -- `Theme::custom`, `Theme::custom_with_fn`
- `theme-palette.md` -- `Palette`, `Extended`
- `catalog.md` -- how widgets resolve styles from themes
- `widget-container.md` -- container-level styling
