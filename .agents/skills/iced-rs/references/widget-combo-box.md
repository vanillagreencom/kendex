# ComboBox

Read when users need to search a list before selecting an option in Iced 0.14.0.

`combo_box` combines a text input with a filtered menu. The [pinned implementation](https://raw.githubusercontent.com/iced-rs/iced/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/combo_box.rs) owns `ComboBox`, its persistent `State`, callbacks, input/menu styling and catalog defaults. The [widget helpers](https://raw.githubusercontent.com/iced-rs/iced/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs) own the constructor.

## Keep the options and selection

Keep `combo_box::State<T>` in application state. It retains the query, matchers and filtered options between interactions. Keep the selected value separately and pass a reference to it:

```rust
use iced::widget::combo_box;

struct State {
    fruits: combo_box::State<Fruit>,
    favorite: Option<Fruit>,
}

// Initialize once with the available options:
let fruits = combo_box::State::new(vec![
    Fruit::Apple,
    Fruit::Orange,
    Fruit::Strawberry,
]);

// In view:
combo_box(
    &state.fruits,
    "Search fruits...",
    state.favorite.as_ref(),
    Message::FruitSelected,
)
```

Options implement `Display + Clone`. Display supplies labels and search text. Converting the widget to an Element also requires `T: 'static` and a cloneable message. Selection callbacks receive an owned option; store it in `update`. Use `State::with_selection` when initializing the search state from a selection. Add an option in `update` with `state.fruits.push(fruit)`; this also updates the retained search results.

## Observe input and selection

```rust
combo_box(&state.items, "Search", state.selected.as_ref(), Message::Selected)
    .on_option_hovered(Message::HoverPreview)
    .on_input(Message::QueryChanged)
```

`on_input` observes text changes emitted by the input. It is not a callback for every physical key. `on_option_hovered` reports keyboard navigation and can also report an available initial option when the input gains focus. The user can select with Enter or through the menu.

`on_open` and `on_close` report focus transitions when that update has not already published a selection or hover notification. Do not rely on a separate close message after every selection or outside press.

## Style

Use `input_style` for the text input and `menu_style` for the dropdown. Their closures have different contracts: the input receives a theme and text-input status; the menu receives a theme. The catalog combines the input and menu catalogs and supplies their defaults. `input_class` and `menu_class` require `advanced`; see [Catalog](catalog.md).

## Related references

- [Pick list](widget-pick-list.md): selection without searching, using options directly.
- [Text input](widget-text-input.md): the underlying input component.
