# ComboBox

> `iced::widget::combo_box` · iced 0.14.0

A searchable dropdown: a text input with an overlay list that filters options by what the user types. Use when the option list is long enough that `pick_list` becomes unwieldy.

## API

### `ComboBox` struct

```rust
pub struct ComboBox<'a, T, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where
    Theme: Catalog,
    Renderer: Renderer,
{ /* private fields */ }

impl<'a, T, Message, Theme, Renderer> ComboBox<'a, T, Message, Theme, Renderer>
where
    T: Display + Clone,
    Theme: Catalog,
    Renderer: Renderer,
{
    pub fn new(
        state: &'a State<T>,
        placeholder: &str,
        selection: Option<&T>,
        on_selected: impl Fn(T) -> Message + 'static,
    ) -> Self;

    pub fn on_input(self, on_input: impl Fn(String) -> Message + 'static) -> Self;
    pub fn on_option_hovered(self, on_option_hovered: impl Fn(T) -> Message + 'static) -> Self;
    pub fn on_open(self, message: Message) -> Self;
    pub fn on_close(self, message: Message) -> Self;

    pub fn padding(self, padding: impl Into<Padding>) -> Self;
    pub fn font(self, font: <Renderer as Renderer>::Font) -> Self;
    pub fn icon(self, icon: text_input::Icon<<Renderer as Renderer>::Font>) -> Self;
    pub fn size(self, size: impl Into<Pixels>) -> Self;
    pub fn line_height(self, line_height: impl Into<LineHeight>) -> Self;
    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn menu_height(self, menu_height: impl Into<Length>) -> Self;
    pub fn text_shaping(self, shaping: Shaping) -> Self;

    pub fn input_style(self, style: impl Fn(&Theme, text_input::Status) -> text_input::Style + 'a) -> Self;
    pub fn menu_style(self, style: impl Fn(&Theme) -> menu::Style + 'a) -> Self;
    pub fn input_class(self, class: /* ... */) -> Self;
    pub fn menu_class(self, class: /* ... */) -> Self;
}
```

### `State<T>` struct

```rust
pub struct State<T> { /* private */ }

impl<T: Display + Clone> State<T> {
    pub fn new(options: Vec<T>) -> State<T>;
    pub fn with_selection(options: Vec<T>, selection: Option<&T>) -> State<T>;

    pub fn options(&self) -> &[T];
    pub fn push(&mut self, new_option: T);
    pub fn into_options(self) -> Vec<T>;
}
```

### `Catalog` trait

```rust
pub trait Catalog: text_input::Catalog + menu::Catalog {}
```

Combo box styling delegates to both `text_input::Catalog` (for the input) and `menu::Catalog` (for the dropdown).

### Function

```rust
pub fn combo_box<'a, T, Message, Theme, Renderer>(
    state: &'a State<T>,
    placeholder: &str,
    selection: Option<&T>,
    on_selected: impl Fn(T) -> Message + 'static,
) -> ComboBox<'a, T, Message, Theme, Renderer>;
```

## Patterns

### Basic searchable dropdown

```rust
use iced::widget::combo_box;

struct State {
    fruits: combo_box::State<Fruit>,
    favorite: Option<Fruit>,
}

impl State {
    fn new() -> Self {
        Self {
            fruits: combo_box::State::new(vec![
                Fruit::Apple, Fruit::Orange, Fruit::Strawberry,
            ]),
            favorite: None,
        }
    }
}

fn view(state: &State) -> Element<'_, Message> {
    combo_box(
        &state.fruits,
        "Search fruits...",
        state.favorite.as_ref(),
        Message::FruitSelected,
    ).into()
}
```

### Handle hover / live search

```rust
combo_box(&state.items, "Search", state.selected.as_ref(), Message::Selected)
    .on_option_hovered(Message::HoverPreview) // Preview as user arrow-keys through
    .on_input(Message::QueryChanged)          // Observe current search text
```

### Appending options dynamically

```rust
// In update, on Message::AddItem(item):
state.items.push(item);
```

## Gotchas

- `State<T>` must live in your application state (not inside `view()`). This is because combo_box caches filter results between frames — rebuilding `State` every frame would lose the cached state.
- `T` must implement `Display + Clone`. The `Display` impl provides both the option label and the search match string.
- Unlike `pick_list`, **`combo_box` requires `&State<T>`** passed as the first argument, not a raw slice.
- `on_selected` receives `T` by value (requires `Clone`); it's called when the user explicitly picks an option from the menu. `on_input` fires on every keystroke.
- `on_close` fires when the user clicks outside the combo box — useful for "discard unsaved query" flows.
- Styling uses two separate style functions: `input_style(...)` for the text input and `menu_style(...)` for the dropdown menu.

## See also

- `widget-pick-list.md` — non-searchable variant (static options)
- `widget-text-input.md` — the underlying input component
- `catalog.md` — styling pattern
