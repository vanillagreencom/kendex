# Slider

> `iced::widget::slider` · iced 0.14.0

A horizontal bar with a draggable handle for picking a numeric value from a range. For vertical orientation use `widget::vertical_slider`.

## API

### `Slider` struct

```rust
pub struct Slider<'a, T, Message, Theme = Theme>
where
    Theme: Catalog,
{ /* private fields */ }

impl<'a, T, Message, Theme> Slider<'a, T, Message, Theme>
where
    T: Copy + From<u8> + PartialOrd,
    Message: Clone,
    Theme: Catalog,
{
    pub const DEFAULT_HEIGHT: f32 = 16f32;

    pub fn new<F>(range: RangeInclusive<T>, value: T, on_change: F) -> Self
    where
        F: 'a + Fn(T) -> Message;

    pub fn default(self, default: impl Into<T>) -> Self;
    pub fn on_release(self, on_release: Message) -> Self;

    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn height(self, height: impl Into<Pixels>) -> Self;

    pub fn step(self, step: impl Into<T>) -> Self;
    pub fn shift_step(self, shift_step: impl Into<T>) -> Self;

    pub fn style(self, style: impl Fn(&Theme, Status) -> Style + 'a) -> Self
    where
        <Theme as Catalog>::Class<'a>: From<Box<dyn Fn(&Theme, Status) -> Style + 'a>>;

    pub fn class(self, class: impl Into<<Theme as Catalog>::Class<'a>>) -> Self; // feature = "advanced"
}
```

### `Status` enum

```rust
pub enum Status {
    Active,
    Hovered,
    Dragged,
}
```

### `Style`, `Rail`, `Handle`, `HandleShape`

```rust
pub struct Style {
    pub rail: Rail,
    pub handle: Handle,
}

impl Style {
    pub fn with_circular_handle(self, radius: impl Into<Pixels>) -> Style;
}

pub struct Rail {
    pub backgrounds: (Background, Background), // (filled, unfilled)
    pub width: f32,
    pub border: Border,
}

pub struct Handle {
    pub shape: HandleShape,
    pub background: Background,
    pub border_width: f32,
    pub border_color: Color,
}

pub enum HandleShape {
    Circle { radius: f32 },
    Rectangle { width: u16, border_radius: Radius },
}
```

### `Catalog` trait

```rust
pub trait Catalog {
    type Class<'a>;
    fn default<'a>() -> Self::Class<'a>;
    fn style(&self, class: &Self::Class<'_>, status: Status) -> Style;
}
```

### Functions & type aliases

```rust
pub fn slider<'a, T, Message, Theme>(
    range: RangeInclusive<T>,
    value: T,
    on_change: impl Fn(T) -> Message + 'a,
) -> Slider<'a, T, Message, Theme>;

pub fn default(theme: &Theme, status: Status) -> Style;

pub type StyleFn<'a, Theme> = Box<dyn Fn(&Theme, Status) -> Style + 'a>;
```

### Vertical variant

```rust
// iced::widget::vertical_slider
pub struct VerticalSlider<'a, T, Message, Theme> { /* ... */ }

pub fn vertical_slider<'a, T, Message, Theme>(
    range: RangeInclusive<T>,
    value: T,
    on_change: impl Fn(T) -> Message + 'a,
) -> VerticalSlider<'a, T, Message, Theme>;
```

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

- `on_change` fires **while the slider is being dragged** — every mouse move while the handle is held. If that's too many events (e.g., triggering expensive computation), capture only the preview in `on_change` and commit in `on_release`.
- `T` must be `Copy + From<u8> + PartialOrd`. Works with `f32`, `f64`, `i32`, `u32`, etc.
- `DEFAULT_HEIGHT = 16.0` pixels — for denser UIs, set `.height(8.0)` or similar.
- The `default(value)` method enables ctrl-click (cmd-click on macOS) reset — useful for fine-tuning controls.
- `vertical_slider` is a separate widget with its own constructor; it doesn't reuse `Slider`.

## See also

- `widget-progress-bar.md` — display-only version of slider
- `catalog.md` — styling pattern
- `keyboard.md` — for shift modifier detection (handled internally by slider)
