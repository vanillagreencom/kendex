# Checkbox

Read when binding a boolean preference, a multi-select item or a confirmation to a checkbox in Iced 0.14.0.

The checkmark shows the supplied checked value. Availability depends on the toggle handler. The [pinned implementation](https://raw.githubusercontent.com/iced-rs/iced/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/checkbox.rs) owns `Checkbox`, its label and text settings, `Icon`, `Status`, `Style`, `Catalog` and defaults. It requires a text renderer. The [widget helpers](https://raw.githubusercontent.com/iced-rs/iced/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs) own the `checkbox` constructor.

## Use

```rust
use iced::widget::checkbox;

checkbox(state.is_enabled)
    .label("Enable notifications")
    .on_toggle(Message::Toggle)
```

The callback receives the new checked value. Assign that value in `update`. Without `on_toggle`, the checkbox is disabled. Use `on_toggle_maybe` for conditional availability:

```rust
checkbox(state.accepted)
    .label("I accept the terms")
    .on_toggle_maybe(state.can_change.then_some(Message::AcceptTerms))
```

For a multi-select list, bind each item's bool and include its identity in the message:

```rust
use iced::widget::column;

column(items.iter().enumerate().map(|(index, item)| {
    checkbox(item.selected)
        .label(&item.name)
        .on_toggle(move |checked| Message::ItemToggle(index, checked))
        .into()
}))
.spacing(4)
```

Follow the skill's [widget tree consistency rule](../SKILL.md#widget-tree-consistency) for interaction wrappers. The checkbox publishes on a matching left-mouse or touch press over its bounds, with the inverse of the supplied checked value.

## Label and style

`spacing` separates the box from its label. It does not add outer padding. `label` accepts the [IntoFragment contract](advanced-text.md).

Status variants carry `is_checked`; `Status` has no `is_checked` field to access directly. Destructure `Active { is_checked }`, `Hovered { is_checked }` or `Disabled { is_checked }` in a custom style closure. The [Catalog reference](catalog.md) explains closure styling. `.class(...)` requires `advanced`.

The icon is a character from a font, not an SVG path. Load the font containing the glyph before using a custom icon. For example, with FontAwesome loaded:

```rust
use iced::widget::checkbox::Icon;
use iced::widget::text::Shaping;
use iced::Font;

checkbox(state.checked)
    .icon(Icon {
        font: Font::with_name("FontAwesome"),
        code_point: '\u{F00C}',
        size: Some(14.0.into()),
        line_height: 1.0.into(),
        shaping: Shaping::Advanced,
    })
    .on_toggle(Message::Toggle)
```

## Related references

- [Toggler](widget-toggler.md): a switch for an on/off value.
- [Radio](widget-radio.md): one choice from a group.
