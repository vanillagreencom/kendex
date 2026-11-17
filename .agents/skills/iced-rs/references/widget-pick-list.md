# PickList

> `iced::widget::pick_list` · iced 0.14.0

A dropdown widget for selecting one value from a fixed list of options. Uses iced's built-in overlay layer, so no custom Overlay implementation is required.

## API

Iced 0.14.0 owns the declarations, bounds, feature gates and defaults: [widget/src/pick_list.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/pick_list.rs); [widget/src/helpers.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs).

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
- `menu_height` sets the dropdown menu height; the menu uses a scrollable for its options.
- `on_open` / `on_close` fire when the dropdown toggles open/closed — useful for suppressing background animations while the menu is open.

## See also

- `widget-combo-box.md` — searchable/filterable variant
- `theme.md` — `Theme::ALL` for theme pickers
- `catalog.md` — styling pattern
- `widget-container.md` — for wrapping pick_list with padding/border
