# Animation & Easing

> `iced::Animation<T>` + `iced::animation::Easing` · iced 0.14.0

Complete API reference for `Animation<T>` and `Easing` — every method and variant.

## API

### `Animation<T>` struct

```rust
pub struct Animation<T>
where
    T: Clone + Copy + PartialEq + FloatRepresentable,
{ /* private fields */ }
```

### Constructors and builders

```rust
impl<T: Clone + Copy + PartialEq + FloatRepresentable> Animation<T> {
    pub fn new(state: T) -> Animation<T>;

    // Easing curve
    pub fn easing(self, easing: Easing) -> Animation<T>;

    // Preset durations
    pub fn very_quick(self) -> Animation<T>;  // ~100ms
    pub fn quick(self) -> Animation<T>;       // ~200ms
    pub fn slow(self) -> Animation<T>;        // ~400ms
    pub fn very_slow(self) -> Animation<T>;   // ~600ms

    // Explicit duration
    pub fn duration(self, duration: Duration) -> Animation<T>;

    // Start delay
    pub fn delay(self, duration: Duration) -> Animation<T>;

    // Repetition
    pub fn repeat(self, repetitions: u32) -> Animation<T>;
    pub fn repeat_forever(self) -> Animation<T>;
    pub fn auto_reverse(self) -> Animation<T>;
}
```

### Transition methods

```rust
impl<T: Clone + Copy + PartialEq + FloatRepresentable> Animation<T> {
    // Consume and return new animation transitioning to new_state
    pub fn go(self, new_state: T, at: Instant) -> Animation<T>;

    // Mutate in-place to transition to new_state
    pub fn go_mut(&mut self, new_state: T, at: Instant);

    // Is the animation currently in progress?
    pub fn is_animating(&self, at: Instant) -> bool;

    // Current target state (not interpolated)
    pub fn value(&self) -> T;
}
```

### Interpolation methods

```rust
impl<T: Clone + Copy + PartialEq + FloatRepresentable> Animation<T> {
    // Project into an interpolated value via closure
    pub fn interpolate_with<I>(
        &self,
        f: impl Fn(T) -> I,
        at: Instant,
    ) -> I;
}

impl Animation<bool> {
    // Convenience: interpolate between start (false) and end (true) values
    pub fn interpolate<I>(
        &self,
        start: I,
        end: I,
        at: Instant,
    ) -> I;

    // Remaining duration of the animation
    pub fn remaining(&self, at: Instant) -> Duration;
}
```

### `Easing` enum (complete -- 32 variants)

```rust
pub enum Easing {
    // Linear
    Linear,

    // CSS standard curves
    EaseIn,
    EaseOut,
    EaseInOut,

    // Quadratic
    EaseInQuad,
    EaseOutQuad,
    EaseInOutQuad,

    // Cubic
    EaseInCubic,
    EaseOutCubic,
    EaseInOutCubic,

    // Quartic
    EaseInQuart,
    EaseOutQuart,
    EaseInOutQuart,

    // Quintic
    EaseInQuint,
    EaseOutQuint,
    EaseInOutQuint,

    // Exponential
    EaseInExpo,
    EaseOutExpo,
    EaseInOutExpo,

    // Circular
    EaseInCirc,
    EaseOutCirc,
    EaseInOutCirc,

    // Back (overshoot)
    EaseInBack,
    EaseOutBack,
    EaseInOutBack,

    // Elastic (spring-like)
    EaseInElastic,
    EaseOutElastic,
    EaseInOutElastic,

    // Bounce
    EaseInBounce,
    EaseOutBounce,
    EaseInOutBounce,

    // Custom function
    Custom(fn(f32) -> f32),
}

impl Easing {
    pub fn value(self, x: f32) -> f32;
}
```

### `FloatRepresentable` trait bound

`Animation<T>` requires `T: FloatRepresentable`. Implemented for `bool`, `f32`, and other numeric types. For custom types, implement this trait to enable animation.

## Patterns

### Animate a bool toggle (expand/collapse)

```rust
use iced::{Animation, animation::Easing};
use std::time::{Duration, Instant};

let mut anim = Animation::new(false)
    .duration(Duration::from_millis(250))
    .easing(Easing::EaseInOutCubic);

// Toggle
anim.go_mut(true, Instant::now());

// In draw: interpolate to get 0.0..1.0 progress
let t = anim.interpolate(0.0_f32, 1.0_f32, now);
```

### Animate an f32 value

```rust
let mut anim = Animation::new(0.0_f32)
    .duration(Duration::from_millis(300))
    .easing(Easing::EaseOutCubic);

anim.go_mut(100.0, now);

let current = anim.interpolate_with(|v| v, now);
```

### Retarget mid-animation

```rust
// go_mut retargets from the current interpolated position, no snap
anim.go_mut(new_target, Instant::now());
```

### Repeating animation (loading spinner)

```rust
let spinner = Animation::new(0.0_f32)
    .duration(Duration::from_secs(1))
    .easing(Easing::Linear)
    .repeat_forever()
    .auto_reverse();
```

### Custom easing function

```rust
let anim = Animation::new(false)
    .easing(Easing::Custom(|t| t * t * (3.0 - 2.0 * t))); // smoothstep
```

## Gotchas

- `go_mut` is interrupt-safe: mid-transition retargeting keeps the current eased value. Rapid toggles don't snap.
- `value()` returns the **target** state, not the interpolated value. Use `interpolate_with` for the current visual value.
- `interpolate` (bool-specific) and `interpolate_with` (generic) are different methods. Don't confuse them.
- `Animation` state must live in `widget::Tree::state` for custom widgets.
- No `Spring` or `Tween` types in iced 0.14 -- only `Animation<T>` and `Easing`.
- Trading UI easing recommendations: see `animation.md` § Easing.

## See also

- `animation.md` -- framework-level animation rules, redraw scheduling, invalidation modes
- `advanced-shell.md` -- `Shell::request_redraw`, `request_redraw_at`
- `advanced-widget.md` -- widget lifecycle where animations are driven
- `advanced-tree.md` -- `Tree::state` where animation state is stored
