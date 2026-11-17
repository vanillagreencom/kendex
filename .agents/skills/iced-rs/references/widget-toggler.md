# Toggler

> `iced::widget::toggler` · iced 0.14.0

An on/off switch for a boolean value, such as a preference or feature flag.

## API

Iced 0.14.0 owns the declarations, bounds, feature gates and defaults: [widget/src/toggler.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/toggler.rs); [widget/src/helpers.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs).

## Patterns

### Basic toggle

```rust
use iced::widget::toggler;

toggler(state.enabled)
    .label("Enable notifications")
    .on_toggle(Message::Toggle)
```

### Row of togglers

```rust
column(
    settings.iter().map(|s| {
        toggler(s.active)
            .label(&s.name)
            .on_toggle(move |b| Message::SettingChanged(s.id, b))
            .into()
    })
).spacing(8)
```

### Label text alignment

```rust
toggler(state.enabled)
    .label("Dark mode")
    .text_alignment(iced::alignment::Horizontal::Left)
    .on_toggle(Message::DarkMode)
```

## Gotchas

- Without `on_toggle`, the toggler is disabled (exactly like checkbox). Use `on_toggle_maybe` for conditional enable.
- `size` sets the track height; `padding_ratio` controls the knob inset.
- `Status` variants carry `is_toggled` so your style closure can color on vs. off states. The default theme uses the theme's primary color for on.
- Visually, toggler implies **persistent state** (setting/preference), while checkbox implies **selection** (form field, multi-select). Prefer toggler for "take effect immediately" settings.
- `spacing` is between the switch and the label, not between the widget and its siblings.

## See also

- `widget-checkbox.md` — the alternative for form-like selection
- `widget-radio.md` — single choice from a group
- `catalog.md` — styling pattern
