# Button

> `iced::widget::button` · iced 0.14.0

A clickable widget that produces a message when pressed. The canonical way to let users trigger actions. Press fires on mouse-up (release), not mouse-down.

## API

### `Button` struct

```rust
pub struct Button<'a, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where
    Renderer: Renderer,
    Theme: Catalog,
{ /* private fields */ }

impl<'a, Message, Theme, Renderer> Button<'a, Message, Theme, Renderer>
where
    Renderer: Renderer,
    Theme: Catalog,
{
    pub fn new(
        content: impl Into<Element<'a, Message, Theme, Renderer>>,
    ) -> Button<'a, Message, Theme, Renderer>;

    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn height(self, height: impl Into<Length>) -> Self;
    pub fn padding<P: Into<Padding>>(self, padding: P) -> Self;

    pub fn on_press(self, on_press: Message) -> Self;
    pub fn on_press_with(self, on_press: impl Fn() -> Message + 'a) -> Self;
    pub fn on_press_maybe(self, on_press: Option<Message>) -> Self;

    pub fn clip(self, clip: bool) -> Self;

    pub fn style(
        self,
        style: impl Fn(&Theme, Status) -> Style + 'a,
    ) -> Self
    where
        <Theme as Catalog>::Class<'a>: From<Box<dyn Fn(&Theme, Status) -> Style + 'a>>;

    pub fn class(
        self,
        class: impl Into<<Theme as Catalog>::Class<'a>>,
    ) -> Self; // feature = "advanced"
}
```

### `Status` enum

```rust
pub enum Status {
    Active,   // Can be pressed
    Hovered,  // Can be pressed and is being hovered
    Pressed,  // Is being pressed
    Disabled, // Cannot be pressed
}
```

### `Style` struct

```rust
pub struct Style {
    pub background: Option<Background>,
    pub text_color: Color,
    pub border: Border,
    pub shadow: Shadow,
    pub snap: bool,
}

impl Style {
    pub fn with_background(self, background: impl Into<Background>) -> Style;
}
```

### `Catalog` trait

```rust
pub trait Catalog {
    type Class<'a>;

    fn default<'a>() -> Self::Class<'a>;
    fn style(&self, class: &Self::Class<'_>, status: Status) -> Style;
}
```

### Constants

```rust
pub const DEFAULT_PADDING: Padding;
```

### Type aliases

```rust
pub type StyleFn<'a, Theme> = Box<dyn Fn(&Theme, Status) -> Style + 'a>;
```

### Functions

```rust
pub fn button<'a, Message, Theme, Renderer>(
    content: impl Into<Element<'a, Message, Theme, Renderer>>,
) -> Button<'a, Message, Theme, Renderer>
where
    Theme: Catalog + 'a,
    Renderer: Renderer;

pub fn primary(theme: &Theme, status: Status) -> Style;    // Main action
pub fn secondary(theme: &Theme, status: Status) -> Style;  // Complementary
pub fn success(theme: &Theme, status: Status) -> Style;    // Good outcome
pub fn danger(theme: &Theme, status: Status) -> Style;     // Destructive
pub fn warning(theme: &Theme, status: Status) -> Style;    // Risky
pub fn text(theme: &Theme, status: Status) -> Style;       // Link-style
pub fn background(theme: &Theme, status: Status) -> Style; // Background shades
pub fn subtle(theme: &Theme, status: Status) -> Style;     // Weak background
```

## Patterns

### Simple button

```rust
use iced::widget::button;

button("Press me!").on_press(Message::ButtonPressed)
```

### Disabled button (no `on_press`)

```rust
button("I am disabled!") // No .on_press(...) → disabled
```

### Conditional enable — never wrap conditionally

```rust
// RIGHT — always construct, conditionally enable
button("Save").on_press_maybe(if valid { Some(Message::Save) } else { None })
```

### Style variants

```rust
use iced::widget::button;

button("Delete").on_press(Message::Delete).style(button::danger)
button("OK").on_press(Message::Confirm).style(button::primary)
```

### Custom style closure

```rust
button("Custom")
    .style(|theme, status| button::Style {
        background: Some(match status {
            button::Status::Hovered => theme.palette().primary.into(),
            _ => theme.palette().background.into(),
        }),
        ..button::primary(theme, status)
    })
```

## Gotchas

- `button.on_press` fires on **mouse-up (release)** over the button. Use `mouse_area(content).on_press(msg)` if you need mouse-down semantics for drag initiation.
- Omitting `on_press` makes the button disabled — do NOT wrap the button in `if enabled { ... } else { ... }`. That changes tree shape and breaks event tracking. Use `on_press_maybe(Option<Message>)` instead.
- `on_press_with(|| expensive_message())` defers the message construction until press — useful when building the message is expensive.
- The `class` method requires the `advanced` crate feature. Most code should use `.style(fn)` instead.
- Default text color comes from the theme; don't override blindly or hover/disabled states will look wrong.

## See also

- `catalog.md` — the `Catalog` trait pattern for widget styling
- `widgets.md` — widget catalog with when-to-use rules
- `widget-mouse-area.md` — for press-on-mouse-down semantics
- `element.md` — `Element<'a, Message, Theme, Renderer>` (what `button` returns via `.into()`)
