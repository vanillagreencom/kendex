# Widget Catalog Trait

> `widget::*::Catalog` · iced 0.14.0

Per-widget theming pattern. A styleable widget defines a `Style` and `Catalog`. Status-bearing widgets such as buttons map `(Class, Status)` to a style; containers map only `Class`. Choose a class type for your catalog. The examples use a boxed closure or an enum.

Read when overriding a widget style or defining a custom widget catalog.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/button.rs) for button styling and the [container declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/container.rs) for status-free styling.

## Patterns

### Inline style override

```rust
button("Click me")
    .on_press(Message::Clicked)
    .style(|theme, status| match status {
        button::Status::Hovered => button::Style {
            background: Some(Background::Color(theme.extended_palette().primary.strong.color)),
            ..button::primary(theme, status)
        },
        _ => button::primary(theme, status),
    })
```

### The enum-based `Class` (button example)

```rust
#[derive(Debug, Default)]
pub enum ButtonClass {
    #[default]
    Primary,
    Secondary,
    Danger,
}

impl Catalog for MyTheme {
    type Class<'a> = ButtonClass;

    fn default<'a>() -> Self::Class<'a> {
        ButtonClass::default()
    }

    fn style(&self, class: &Self::Class<'_>, status: Status) -> Style {
        let mut style = Style::default();

        match class {
            ButtonClass::Primary => {
                style.background = Some(Background::Color(
                    Color::from_rgb(0.529, 0.808, 0.921),
                ));
            }
            ButtonClass::Secondary => {
                style.background = Some(Background::Color(Color::WHITE));
            }
            ButtonClass::Danger => {
                style.background = Some(Background::Color(
                    Color::from_rgb(0.941, 0.502, 0.502),
                ));
            }
        }

        style
    }
}
```

### Writing a `Catalog` for a custom widget

```rust
// my_widget/mod.rs

#[derive(Default)]
pub struct Style {
    pub background: Option<Background>,
    pub border:     Border,
    pub text_color: Color,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Status {
    Active,
    Hovered,
    Disabled,
}

pub trait Catalog {
    type Class<'a>;
    fn default<'a>() -> Self::Class<'a>;
    fn style(&self, class: &Self::Class<'_>, status: Status) -> Style;
}

pub type StyleFn<'a, Theme> = Box<dyn Fn(&Theme, Status) -> Style + 'a>;

impl Catalog for Theme {
    type Class<'a> = StyleFn<'a, Theme>;

    fn default<'a>() -> Self::Class<'a> {
        Box::new(|theme, status| match status {
            Status::Active  => Style { /* ... */ ..Style::default() },
            Status::Hovered => Style { /* ... */ ..Style::default() },
            Status::Disabled => Style { /* ... */ ..Style::default() },
        })
    }

    fn style(&self, class: &Self::Class<'_>, status: Status) -> Style {
        class(self, status)
    }
}

// widget struct stores `class: <Theme as Catalog>::Class<'a>`
// widget constructor sets class to `<Theme as Catalog>::default()`
// widget `.style()` setter wraps a closure in `Box::new(...)`
```

## Gotchas

- The `Catalog` trait is **not dyn-compatible** because it has a generic associated type. Make the widget generic over `Theme: Catalog`.
- `Class<'a>` is generic over a lifetime, so the style closure can borrow state for the lifetime of the returned `Element`.
- The enum-style `Class` (e.g. `ButtonClass::Primary`) is a great fit when you have a fixed palette of variants. The closure style is better when the user's style needs to depend on the theme's extended palette or dynamic state.
- `Style` structs have many fields; use `..Style::default()` or `..button::primary(theme, status)` to inherit the baseline and override only the fields you care about.
- The `default()` function **doesn't mean "default value"** — it means "the default `Class` the widget starts with before any `.style(...)` override". Don't confuse with `Default::default()`.
- If your custom widget has asymmetric states (e.g. a `Status` variant that carries extra data like `is_checked`), make it part of the `Status` enum itself, not a separate parameter — that keeps the catalog shape uniform.

## See also

- `theme.md`
- `theme-palette.md`
- `widget-button.md`
- `widget-container.md`
