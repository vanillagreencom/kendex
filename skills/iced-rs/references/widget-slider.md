# Slider

> `iced::widget::slider` · iced 0.14.0

A horizontal bar with a draggable handle for picking a numeric value from a range. For vertical orientation use `widget::vertical_slider`.

## API

Iced 0.14.0 owns the declarations, bounds, feature gates and defaults: [widget/src/slider.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/slider.rs); [widget/src/helpers.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs).

## Patterns

### Basic slider (f32 range)

```rust
use iced::widget::slider;

slider(0.0..=100.0, state.value, Message::ValueChanged)
```

### Integer slider with step

```rust
slider(0..=10i32, state.level, Message::LevelChanged)
    .step(1)
```

### Fine-grained with shift modifier

```rust
slider(0.0..=1.0, state.opacity, Message::OpacityChanged)
    .step(0.1)        // Arrow keys / normal drag: 0.1 increments
    .shift_step(0.01) // Shift+drag: 0.01 increments
```

### Release-only for expensive operations

```rust
slider(0.0..=100.0, state.threshold, Message::ThresholdPreview)
    .on_release(Message::CommitThreshold) // Fire final message on mouse up
```

### Reset with ctrl/cmd-click

```rust
slider(0.0..=1.0, state.value, Message::Changed)
    .default(0.5) // ctrl/cmd-click resets to 0.5
```

### Custom circular handle

```rust
slider(0.0..=1.0, state.value, Message::Changed)
    .style(|theme, status| {
        slider::default(theme, status).with_circular_handle(8.0)
    })
```

## Gotchas

- Use `on_change` for value changes during interaction. Capture a preview there and commit expensive work in `on_release`.
- `T` must be `Copy + From<u8> + PartialOrd`. Works with `f32`, `f64`, `i32`, `u32`, etc.
- Set `.height(8.0)` for a compact slider.
- The `default(value)` method enables ctrl-click (cmd-click on macOS) reset — useful for fine-tuning controls.
- `vertical_slider` is a separate widget with its own constructor; it doesn't reuse `Slider`.

## See also

- `widget-progress-bar.md` — display-only version of slider
- `catalog.md` — styling pattern
- `keyboard.md` — for shift modifier detection (handled internally by slider)
