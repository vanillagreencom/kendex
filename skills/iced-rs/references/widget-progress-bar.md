# ProgressBar

> `iced::widget::progress_bar` · iced 0.14.0

A non-interactive bar that visualizes the progress of a long-running operation. Use for downloads, imports, any determinate progress. For indeterminate progress, combine with an animation.

## API

Iced 0.14.0 owns the declarations, bounds, feature gates and defaults: [widget/src/progress_bar.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/progress_bar.rs); [widget/src/helpers.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs).

## Patterns

### Download progress

```rust
use iced::widget::progress_bar;

progress_bar(0.0..=100.0, state.percent_complete)
```

### Normalized 0-1 value

```rust
progress_bar(0.0..=1.0, state.fraction)
```

### Vertical (e.g., battery indicator)

```rust
progress_bar(0.0..=100.0, state.battery_level)
    .vertical()
    .length(100)  // height (vertical)
    .girth(20)    // width
```

### Style variants

```rust
progress_bar(0.0..=1.0, state.download)
    .style(progress_bar::success)

// Custom
progress_bar(0.0..=1.0, state.danger_level)
    .style(|theme| progress_bar::Style {
        background: theme.extended_palette().background.weak.color.into(),
        bar: theme.palette().danger.into(),
        border: border::rounded(4.0),
    })
```

## Gotchas

- `progress_bar` is **non-interactive** — no messages, no clicks. For a value picker use `widget-slider.md`.
- The `value` is clamped to the `range`. If `range = 0.0..=100.0` and you pass `150.0`, the bar shows full (100).
- Set `.girth(8.0)` for a compact bar; girth is the thickness in either orientation.
- Vertical progress bars fill from bottom to top. Changing the numeric range does not reverse this direction.
- For **indeterminate** progress (spinning), use a `Canvas` animation or pair with `iced::time::every` to sweep a synthetic value.

## See also

- `widget-slider.md` — interactive value picker
- `animation.md` — for indeterminate/looping progress patterns
- `catalog.md` — styling pattern
