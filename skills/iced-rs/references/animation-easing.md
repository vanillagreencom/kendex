# Animation & Easing

> `iced::Animation<T>` + `iced::animation::Easing` · iced 0.14.0

Read when choosing easing, retargeting motion, or configuring repetition for an Iced animation.

## API

See [`Animation<T>` and its builders](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/animation.rs) and the [easing variants in lilt 0.8.1](https://docs.rs/lilt/0.8.1/lilt/enum.Easing.html). For a custom animation state, implement the [`Float` trait](https://docs.rs/lilt/0.8.1/lilt/trait.FloatRepresentable.html) that Iced re-exports from lilt. Use `Easing::value(progress)` to evaluate a curve at a normalized progress value.

## Patterns

### Animate a bool toggle (expand/collapse)

```rust
use iced::{Animation, animation::Easing};
use iced::time::{Duration, Instant};

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
// Retarget the scalar animation at the current time.
anim.go_mut(new_target, Instant::now());
```

### Repeating animation (loading spinner)

```rust
let spinner = Animation::new(0.0_f32)
    .duration(Duration::from_secs(1))
    .easing(Easing::Linear)
    .repeat_forever()
    .auto_reverse()
    .go(1.0, now);
```

### Custom easing function

```rust
let anim = Animation::new(false)
    .easing(Easing::Custom(|t| t * t * (3.0 - 2.0 * t))); // smoothstep
```

## Gotchas

- Both `go` and `go_mut` use the current eased scalar progress as the origin when retargeting an active transition.
- `value()` returns the **target** state, not the interpolated value. Use `interpolate_with` for the current visual value.
- `interpolate` (bool-specific) and `interpolate_with` (generic) are different methods. Don't confuse them.
- `Animation` state must live in `widget::Tree::state` for custom widgets.
- Trading UI easing recommendations: see `animation.md` § Easing.

## See also

- `animation.md` -- framework-level animation rules, redraw scheduling, invalidation modes
- `advanced-shell.md` -- `Shell::request_redraw`, `request_redraw_at`
- `advanced-widget.md` -- widget lifecycle where animations are driven
- `advanced-tree.md` -- `Tree::state` where animation state is stored
