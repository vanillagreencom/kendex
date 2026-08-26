# ProgressBar

> `iced::widget::progress_bar` · iced 0.14.0

A non-interactive bar that visualizes the progress of a long-running operation. Use for downloads, imports, any determinate progress. For indeterminate progress, combine with an animation.

## API

### `ProgressBar` struct

```rust
pub struct ProgressBar<'a, Theme = Theme>
where
    Theme: Catalog,
{ /* private fields */ }

impl<'a, Theme> ProgressBar<'a, Theme>
where
    Theme: Catalog,
{
    pub const DEFAULT_GIRTH: f32 = 30f32;

    pub fn new(range: RangeInclusive<f32>, value: f32) -> Self;

    pub fn length(self, length: impl Into<Length>) -> Self; // width for horizontal, height for vertical
    pub fn girth(self, girth: impl Into<Length>) -> Self;   // thickness
    pub fn vertical(self) -> Self;                           // flip orientation

    pub fn style(self, style: impl Fn(&Theme) -> Style + 'a) -> Self
    where
        <Theme as Catalog>::Class<'a>: From<Box<dyn Fn(&Theme) -> Style + 'a>>;

    pub fn class(self, class: impl Into<<Theme as Catalog>::Class<'a>>) -> Self; // feature = "advanced"
}
```

### `Style` struct

```rust
pub struct Style {
    pub background: Background,  // Background bar (unfilled)
    pub bar: Background,         // Filled portion
    pub border: Border,
}
```

### `Catalog` trait

```rust
pub trait Catalog {
    type Class<'a>;
    fn default<'a>() -> Self::Class<'a>;
    fn style(&self, class: &Self::Class<'_>) -> Style;
}
```

### Functions & type aliases

```rust
pub fn progress_bar<'a, Theme>(
    range: RangeInclusive<f32>,
    value: f32,
) -> ProgressBar<'a, Theme>;

pub fn primary(theme: &Theme) -> Style;
pub fn secondary(theme: &Theme) -> Style;
pub fn success(theme: &Theme) -> Style;
pub fn danger(theme: &Theme) -> Style;

pub type StyleFn<'a, Theme> = Box<dyn Fn(&Theme) -> Style + 'a>;
```

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
- `DEFAULT_GIRTH = 30.0` pixels — for compact layouts, set `.girth(8.0)` or similar.
- Vertical progress bars fill **from bottom to top** by default. Flip the visual range if you need top-to-bottom (e.g., use `range = -value..=max` trick).
- For **indeterminate** progress (spinning), use a `Canvas` animation or pair with `Subscription::time::every` to sweep a synthetic value.

## See also

- `widget-slider.md` — interactive value picker
- `animation.md` — for indeterminate/looping progress patterns
- `catalog.md` — styling pattern
