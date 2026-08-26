# PickList

> `iced::widget::pick_list` · iced 0.14.0

A dropdown widget for selecting one value from a fixed list of options. Uses iced's built-in overlay layer, so no custom Overlay implementation is required.

## API

### `PickList` struct

```rust
pub struct PickList<'a, T, L, V, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where
    T: ToString + PartialEq + Clone,
    L: Borrow<[T]> + 'a,
    V: Borrow<T> + 'a,
    Theme: Catalog,
    Renderer: Renderer,
{ /* private fields */ }

impl<'a, T, L, V, Message, Theme, Renderer> PickList<'a, T, L, V, Message, Theme, Renderer>
where
    T: ToString + PartialEq + Clone,
    L: Borrow<[T]> + 'a,
    V: Borrow<T> + 'a,
    Message: Clone,
    Theme: Catalog,
    Renderer: Renderer,
{
    pub fn new(
        options: L,
        selected: Option<V>,
        on_select: impl Fn(T) -> Message + 'a,
    ) -> Self;

    pub fn placeholder(self, placeholder: impl Into<String>) -> Self;
    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn menu_height(self, menu_height: impl Into<Length>) -> Self;
    pub fn padding<P: Into<Padding>>(self, padding: P) -> Self;
    pub fn text_size(self, size: impl Into<Pixels>) -> Self;
    pub fn text_line_height(self, line_height: impl Into<LineHeight>) -> Self;
    pub fn text_shaping(self, shaping: Shaping) -> Self;
    pub fn font(self, font: impl Into<<Renderer as Renderer>::Font>) -> Self;
    pub fn handle(self, handle: Handle<<Renderer as Renderer>::Font>) -> Self;

    pub fn on_open(self, on_open: Message) -> Self;
    pub fn on_close(self, on_close: Message) -> Self;

    pub fn style(self, style: impl Fn(&Theme, Status) -> Style + 'a) -> Self;
    pub fn menu_style(self, style: impl Fn(&Theme) -> Style + 'a) -> Self;
    pub fn class(self, class: impl Into<<Theme as Catalog>::Class<'a>>) -> Self;
    pub fn menu_class(self, class: impl Into<<Theme as Catalog>::Class<'a>>) -> Self;
}
```

### `Status` enum

```rust
pub enum Status {
    Active,
    Hovered,
    Opened { is_hovered: bool },
}
```

### `Handle` enum

```rust
pub enum Handle<Font> {
    Arrow { size: Option<Pixels> },        // Default: ▼
    Static(Icon<Font>),                    // Fixed custom icon
    Dynamic { closed: Icon<Font>, open: Icon<Font> }, // Different per state
    None,                                  // No handle shown
}
```

### `Style` struct

```rust
pub struct Style {
    pub text_color: Color,
    pub placeholder_color: Color,
    pub handle_color: Color,
    pub background: Background,
    pub border: Border,
}
```

### `Catalog` trait

```rust
pub trait Catalog: menu::Catalog {
    type Class<'a>;
    fn default<'a>() -> <Self as Catalog>::Class<'a>;
    fn default_menu<'a>() -> <Self as menu::Catalog>::Class<'a>;
    fn style(&self, class: &<Self as Catalog>::Class<'_>, status: Status) -> Style;
}
```

Menu styling is delegated to `iced::widget::overlay::menu::Catalog`.

### Functions & type aliases

```rust
pub fn pick_list<'a, T, L, V, Message, Theme, Renderer>(
    options: L,
    selected: Option<V>,
    on_select: impl Fn(T) -> Message + 'a,
) -> PickList<'a, T, L, V, Message, Theme, Renderer>;

pub fn default(theme: &Theme, status: Status) -> Style;

pub type StyleFn<'a, Theme> = Box<dyn Fn(&Theme, Status) -> Style + 'a>;
```

## Patterns

### Basic selection

```rust
use iced::widget::pick_list;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Fruit { Apple, Orange, Strawberry }

impl std::fmt::Display for Fruit {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Apple => "Apple",
            Self::Orange => "Orange",
            Self::Strawberry => "Strawberry",
        })
    }
}

let fruits = [Fruit::Apple, Fruit::Orange, Fruit::Strawberry];
pick_list(fruits, state.favorite, Message::FruitSelected)
    .placeholder("Select a fruit...")
```

### Theme picker (using `Theme::ALL`)

```rust
pick_list(Theme::ALL, Some(state.theme.clone()), Message::ThemeSelected)
```

### Custom handle icon

```rust
use iced::widget::pick_list::{self, Handle};

pick_list(options, selected, Message::Selected)
    .handle(Handle::Arrow { size: Some(12.0.into()) })
```

### React to open/close

```rust
pick_list(options, selected, Message::Selected)
    .on_open(Message::DropdownOpened)
    .on_close(Message::DropdownClosed)
```

## Gotchas

- `T` must implement `ToString + PartialEq + Clone`. `Display` is the common source — implement `std::fmt::Display` to get `ToString` for free.
- The `options` parameter uses `Borrow<[T]>`, so it accepts `&[T]`, `Vec<T>`, `[T; N]`, `&'static [T]`, and similar.
- For a **searchable** dropdown, use `combo_box` instead (see `widget-combo-box.md`).
- The menu uses iced's internal overlay layer — don't wrap pick_list in a custom overlay, you'll get z-order conflicts.
- `menu_height` constrains the dropdown's max height; long lists scroll inside.
- `on_open` / `on_close` fire when the dropdown toggles open/closed — useful for suppressing background animations while the menu is open.

## See also

- `widget-combo-box.md` — searchable/filterable variant
- `theme.md` — `Theme::ALL` for theme pickers
- `catalog.md` — styling pattern
- `widget-container.md` — for wrapping pick_list with padding/border
