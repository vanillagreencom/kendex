# Animation

Framework-level animation rules for Iced 0.14. Covers redraw scheduling, layout invalidation, and the two animation primitives (`iced::Animation<T>` and hand-rolled Instant math).

## The two invalidation modes

Every animating widget falls into one of two buckets.

### Paint-only animation

Properties changing: color, opacity, rotation-with-fixed-bounds, transform-with-fixed-bounds, any visual effect that does not alter the widget's **layout geometry**.

```rust
if state.animation.is_animating(now) {
    shell.request_redraw();
}
```

That's it. One call per frame. No `invalidate_layout`.

### Layout-affecting animation

Properties changing: size, position, expand/collapse, clipping bounds, child count (reveal/hide), anything that would change what `layout()` returns.

```rust
if state.animation.is_animating(now) {
    shell.request_redraw();
    shell.invalidate_layout();  // REQUIRED — otherwise paint at new size with old layout
}
```

**Diagnostic**: "only updates on the second click" → add `invalidate_layout()` to the state-flip handler.

### Why it matters

`iced_wgpu` caches layout per widget tree. Without invalidation, iced repaints at the new visual state but positions using old layout bounds. Result: overlap, clipping, dead space. Symptom: visuals "jump" on the second interaction, rubber-band back, or leave ghost trails.

## Redraw vs rebuild — critical invariant

`request_redraw()` repaints the current widget tree. It does **not** call `view()` to rebuild widget structs.

| State location | Redraw behavior | Correct for animation? |
|---|---|---|
| `widget::Tree` state | Read fresh values on each paint | **Yes** |
| Widget struct fields (set in `view()`) | Fields are stale until next `view()` | **No** — animation paints frozen values |
| App state (set in `App::update()`) | Not re-read until next `view()` | **No** — need message-driven rebuild |

**Rule**: animation state that changes every frame must live in `widget::Tree` state. Widget struct fields are frozen between `view()` calls.

If animation depends on values computed in `App::update()`, drive it with messages/tasks that trigger `update()` → `view()`, not bare `request_redraw()` loops.

See `guide-animation-debugging.md` check #1.

## Scheduling redraws

Two API variants on `Shell`:

### `request_redraw()` — "as soon as possible"

```rust
shell.request_redraw();
```

Queues a redraw on the next available frame.

### `request_redraw_at(request)` — scheduled tick

```rust
use iced::window::RedrawRequest;
use std::time::{Duration, Instant};

shell.request_redraw_at(RedrawRequest::At(
    Instant::now() + Duration::from_millis(16)
));
```

Schedules a redraw at a specific future time. The runtime coalesces multiple `_at` requests and aligns with vsync. Use for animation loops that should tick at a specific cadence.

### Sustaining an animation loop

Animations are self-driving — the widget must keep requesting frames until complete:

```rust
if let Event::Window(window::Event::RedrawRequested(now)) = event {
    let state = tree.state.downcast_mut::<State>();
    if state.animation.is_animating(*now) {
        // Paint-only path
        shell.request_redraw();

        // OR layout-affecting path
        // shell.invalidate_layout();
        // shell.request_redraw();

        // Optional: schedule the NEXT frame at a deterministic tick
        shell.request_redraw_at(RedrawRequest::At(
            *now + std::time::Duration::from_millis(16)
        ));
    }
}
```

Stop requesting when the animation completes. Idle widgets must not pin the CPU.

## The `iced::Animation<T>` primitive

Iced ships a generic animation helper for bool/f32/enum interpolation:

```rust
use iced::{Animation, animation::Easing};
use std::time::Duration;

pub struct State {
    progress: Animation<bool>,  // or Animation<f32>
}

impl Default for State {
    fn default() -> Self {
        Self {
            progress: Animation::new(false)
                .duration(Duration::from_millis(300))
                .easing(Easing::EaseInOut),
        }
    }
}
```

### Transitioning

```rust
// Start transitioning toward the new target from the current interpolated value
state.progress.go_mut(new_target, Instant::now());
```

`go_mut` is the interrupt-safe version: mid-transition changes keep the current eased value and retarget from there, so rapid toggles don't snap.

### Querying

```rust
// Is the animation still moving?
state.progress.is_animating(Instant::now())

// Interpolated value (for f32/custom)
let v = state.progress.interpolate_with(|t| t, Instant::now());

// For Animation<bool>, interpolate between false=0 and true=1:
let t = state.progress.interpolate_with(|b| if *b { 1.0 } else { 0.0 }, now);
```

### Where to store it

Always in `widget::Tree::state` for custom widgets. Use `tag()` + `state()` + `downcast_mut` to access.

For application-level state (fade-in modals, global transitions), store in `App::state` directly; no tree needed.

## Easing

`iced::animation::Easing` ships standard curves:

- `Linear`
- `EaseIn`, `EaseOut`, `EaseInOut`
- Variants: `Quadratic`, `Cubic`, `Quartic`, `Quintic`, `Sinusoidal`, `Exponential`, `Circular`, `Back`, `Elastic`, `Bounce`

For trading UI: `EaseInOut` for state transitions, `EaseOutCubic` for arrival animations. Avoid `Bounce`/`Elastic` on trading surfaces.

## Hand-rolled animation

When you need more control than `Animation<T>`, store `Option<Instant>` + target values and compute progress manually:

```rust
pub struct State {
    started_at: Option<Instant>,
    from: f32,
    to: f32,
    current: f32,
}

impl State {
    pub fn start(&mut self, to: f32) {
        self.from = self.current;
        self.to = to;
        self.started_at = Some(Instant::now());
    }

    pub fn advance(&mut self, now: Instant, duration: Duration) -> bool {
        let Some(started) = self.started_at else { return false; };
        let elapsed = now.saturating_duration_since(started);
        if elapsed >= duration {
            self.current = self.to;
            self.started_at = None;
            return false; // done
        }
        let t = elapsed.as_secs_f32() / duration.as_secs_f32();
        let eased = ease_in_out_cubic(t);
        self.current = self.from + (self.to - self.from) * eased;
        true // still animating
    }
}

fn ease_in_out_cubic(t: f32) -> f32 {
    if t < 0.5 { 4.0 * t * t * t }
    else { 1.0 - (-2.0 * t + 2.0).powi(3) / 2.0 }
}
```

Hand-rolled gives you: per-frame-value inspection, arbitrary easing, custom interrupt handling, and applying one animation value across multiple state fields.

## Canonical examples in `examples/`

| Pattern | Example |
|---|---|
| Minimal `Animation<bool>` + float-scale-in UI | `examples/gallery/src/main.rs` |
| `Animation<f32>` + `RedrawRequested` loop inside a custom Widget | `examples/loading_spinners/src/circular.rs` |
| Hand-rolled arc tween with `canvas::Cache` inside a custom Widget | `examples/arc/src/main.rs` |
| `Subscription::time::every` driving a Canvas animation | `examples/clock/src/main.rs`, `examples/solar_system/src/main.rs` |
| Toast notification with animated lifetime + fade-out overlay | `examples/toast/src/main.rs` |

Read the closest example before writing a new animation from scratch.

## Easing Variants (complete list)

`iced::animation::Easing` has 32 variants (31 named + 1 custom):

| Variant | Category | Description |
|---|---|---|
| `Linear` | Linear | Constant speed, no acceleration |
| `EaseIn` | CSS standard | Slow start (cubic-bezier) |
| `EaseOut` | CSS standard | Slow end |
| `EaseInOut` | CSS standard | Slow start and end |
| `EaseInQuad` | Quadratic | Accelerate (t^2) |
| `EaseOutQuad` | Quadratic | Decelerate |
| `EaseInOutQuad` | Quadratic | Accelerate then decelerate |
| `EaseInCubic` | Cubic | Accelerate (t^3) |
| `EaseOutCubic` | Cubic | Decelerate -- good for "arrival" |
| `EaseInOutCubic` | Cubic | Smooth state transitions |
| `EaseInQuart` | Quartic | Accelerate (t^4) |
| `EaseOutQuart` | Quartic | Decelerate |
| `EaseInOutQuart` | Quartic | Accelerate then decelerate |
| `EaseInQuint` | Quintic | Accelerate (t^5) |
| `EaseOutQuint` | Quintic | Decelerate |
| `EaseInOutQuint` | Quintic | Accelerate then decelerate |
| `EaseInExpo` | Exponential | Sharp accelerate |
| `EaseOutExpo` | Exponential | Sharp decelerate |
| `EaseInOutExpo` | Exponential | Sharp both |
| `EaseInCirc` | Circular | Circular accelerate |
| `EaseOutCirc` | Circular | Circular decelerate |
| `EaseInOutCirc` | Circular | Circular both |
| `EaseInBack` | Back | Overshoot start |
| `EaseOutBack` | Back | Overshoot end |
| `EaseInOutBack` | Back | Overshoot both |
| `EaseInElastic` | Elastic | Spring-like start |
| `EaseOutElastic` | Elastic | Spring-like end |
| `EaseInOutElastic` | Elastic | Spring-like both |
| `EaseInBounce` | Bounce | Bouncing start |
| `EaseOutBounce` | Bounce | Bouncing end |
| `EaseInOutBounce` | Bounce | Bouncing both |
| `Custom(fn(f32) -> f32)` | Custom | User-supplied timing function |

`Easing::value(self, x: f32) -> f32` evaluates the curve at position `x` (0.0..1.0).

## Reusable animation widgets

Extract a reusable animation widget when 2+ components need the same reveal/collapse behavior. The widget owns its `Animation<T>` in tree state, handles `RedrawRequested`/`invalidate_layout` internally, and exposes only `fn new(content).expanded(bool)` — callers flip a bool in `update()`.

## Rules summary

1. Paint-only → `request_redraw()`. Layout-affecting → `request_redraw()` + `invalidate_layout()`.
2. Animation state lives in `widget::Tree::state` for custom widgets, not in the widget struct.
3. Call `shell.request_redraw()` every frame an animation is moving; stop when done.
4. Prefer `request_redraw_at` for scheduled ticks — lets the runtime coalesce redraws.
5. Use `Animation::go_mut` (not `set`) to retarget mid-transition without snapping.
6. If a widget "only updates on the second click," you forgot `invalidate_layout()`.
7. Idle widgets must not request redraws — that pins the CPU.
8. `request_redraw()` repaints the tree but does **not** call `view()`. Animation state must live in Tree state, not widget struct fields — see § "Redraw vs rebuild" above.

## See also

- `animation-easing.md`
- `advanced-shell.md`
- `subscription.md`
- `time.md`
- `guide-animated-layout.md` — measured positions, collapsed/expanded transitions, keyed identity, anti-patterns
- `guide-animation-debugging.md` — symptom→cause checklist for animation/render bugs
- `guide-custom-widgets.md` — draw order, hover stability, opacity completeness
