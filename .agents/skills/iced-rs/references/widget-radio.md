# Radio

> `iced::widget::radio` · iced 0.14.0

A circular button representing a mutually-exclusive choice. Put several radios together (all referencing the same selected value) to form a group.

## API

Iced 0.14.0 owns the declarations, bounds, feature gates and defaults: [widget/src/radio.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/radio.rs); [widget/src/helpers.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs).

## Patterns

### Radio group (multiple radios, one selected)

```rust
use iced::widget::{column, radio};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Choice { A, B, C }

column![
    radio("Option A", Choice::A, state.selected, Message::Select),
    radio("Option B", Choice::B, state.selected, Message::Select),
    radio("Option C", Choice::C, state.selected, Message::Select),
].spacing(8)
```

In `update`:

```rust
Message::Select(choice) => {
    state.selected = Some(choice);
}
```

### Horizontal group

```rust
use iced::widget::{row, radio};

row![
    radio("Low",    Quality::Low,    state.quality, Message::SetQuality),
    radio("Medium", Quality::Medium, state.quality, Message::SetQuality),
    radio("High",   Quality::High,   state.quality, Message::SetQuality),
].spacing(16)
```

## Gotchas

- The `value: V` type must implement `Eq + Copy`. Enums with `derive(Clone, Copy, PartialEq, Eq)` work naturally.
- Each radio takes the **full group's** `selected: Option<V>` — not a per-radio boolean. The widget compares its own value to `selected` internally.
- Radio has no optional callback API for disabling it. Its constructor requires the selection message producer.
- `spacing` sets the gap between the circle and the label.
- Pressing an already-selected radio still publishes its selection message. The radio does not clear the selection.

## See also

- `widget-checkbox.md` — multi-select equivalent
- `widget-toggler.md` — boolean on/off switch
- `widget-pick-list.md` — compact alternative when option count is high
- `catalog.md` — styling pattern
