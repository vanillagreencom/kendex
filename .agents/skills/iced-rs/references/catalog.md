# Widget Catalog Trait

> `widget::*::Catalog` · iced 0.14.0

Per-widget theming pattern. Each styleable widget defines `Style` (appearance fields), `Status` (runtime state), and `Catalog` (trait mapping `(Class, Status) -> Style`). The `Class` type is either a boxed closure or an enum of variants.

## API

### Generic shape

```rust
pub trait Catalog {
    type Class<'a>;

    // Required methods
    fn default<'a>() -> Self::Class<'a>;
    fn style(&self, class: &Self::Class<'_>, status: Status) -> Style;
}
```

- **`Class<'a>`** — The "style specifier" type the widget stores. Usually
  a boxed closure `Box<dyn Fn(&Theme, Status) -> Style + 'a>`, but can be
  a plain enum like `ButtonClass::{Primary, Secondary, Danger}`.
- **`default()`** — Returns the default class produced by the catalog.
  Used when the user doesn't pass `.style(...)` or a custom class.
- **`style(&self, class, status)`** — Returns the `Style` for the given
  class and status. This is what the widget calls in its `draw()`.

### The closure-based `Class`

Most built-in widgets use a closure-based `Class` so you can override style
inline:

```rust
impl Catalog for Theme {
    type Class<'a> = Box<dyn Fn(&Theme, Status) -> Style + 'a>;

    fn default<'a>() -> Self::Class<'a> {
        Box::new(|theme, status| Style::default())
    }

    fn style(&self, class: &Self::Class<'_>, status: Status) -> Style {
        class(self, status)
    }
}
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

## Patterns

### Inline style override

```rust
button("Click me")
    .on_press(Message::Clicked)
    .style(|theme, status| match status {
        button::Status::Hovered => button::Style {
            background: Some(Background::Color(theme.extended_palette().primary.strong.color)),
            ..button::default(theme, status)
        },
        _ => button::default(theme, status),
    })
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

- The `Catalog` trait is **not dyn-compatible** ( "This trait is
  not dyn compatible"). Consequently, widgets cannot store a `Box<dyn
  Catalog>` — they are generic over `Theme: Catalog` and the compiler
  monomorphises per theme.
- `Class<'a>` is generic over a lifetime, so the style closure can borrow
  from the view function's local state. The view function's `Element`
  lifetime becomes the upper bound.
- The enum-style `Class` (e.g. `ButtonClass::Primary`) is a great fit when
  you have a fixed palette of variants. The closure style is better when
  the user's style needs to depend on the theme's extended palette or
  dynamic state.
- `Style` structs have many fields; use `..Style::default()` or
  `..button::default(theme, status)` to inherit the baseline and override
  only the fields you care about.
- The `default()` function **doesn't mean "default value"** — it means
  "the default `Class` the widget starts with before any `.style(...)`
  override". Don't confuse with `Default::default()`.
- If your custom widget has asymmetric states (e.g. a `Status` variant
  that carries extra data like `is_checked`), make it part of the `Status`
  enum itself, not a separate parameter — that keeps the catalog shape
  uniform.
- No macro for building `Catalog` impls -- all hand-rolled.

## See also

- `theme.md`
- `theme-palette.md`
- `widget-button.md`
- `widget-container.md`
