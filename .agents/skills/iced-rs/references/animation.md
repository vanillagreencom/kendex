# Animation

Read when implementing an Iced animation. Choose invalidation based on whether each step changes layout geometry.

## The two invalidation modes

### Paint-only animation

Properties changing: color, opacity, rotation-with-fixed-bounds, transform-with-fixed-bounds, any visual effect that does not alter the widget's **layout geometry**.

```rust
if state.animation.is_animating(now) {
    shell.request_redraw();
}
```

Request another redraw while the paint-only animation is active.

### Layout-affecting animation

Properties changing: size, position, expand/collapse, clipping bounds, child count (reveal/hide), anything that would change what `layout()` returns.

```rust
if state.animation.is_animating(now) {
    shell.request_redraw();
    shell.invalidate_layout();  // REQUIRED — otherwise paint at new size with old layout
}
```

If geometry updates on a second click, check whether the first state change invalidates layout.

The [runtime user interface](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/runtime/src/user_interface.rs) keeps the computed layout. Invalidate it when a widget changes geometry between view builds to avoid painting with stale bounds.

## Redraw vs rebuild

A redraw request on its own uses the existing widget tree. Messages published during redraw handling and widget invalidation can cause a view rebuild.

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
    Instant::now() + Duration::from_millis(16),
));
```

Requests a redraw at the given time. The Shell keeps the earliest pending request. Use a scheduled request to ask for a later frame when no immediate redraw is needed.

### Sustaining an animation loop

Use one redraw route per step while the animation is active:

```rust
if let Event::Window(window::Event::RedrawRequested(now)) = event {
    let state = tree.state.downcast_mut::<State>();
    if state.animation.is_animating(*now) {
        shell.request_redraw();
        // Also call shell.invalidate_layout() when the geometry changes.
    }
}
```

To request a later redraw, use `request_redraw_at` in place of `request_redraw`.

Stop requesting when the animation completes. Idle widgets must not pin the CPU.

## The `iced::Animation<T>` primitive

Use `Animation<T>` for a bool, f32, or custom state that implements `iced::animation::Float`:

```rust
use iced::{Animation, animation::Easing, time::Duration};

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
// Start a transition toward the new target.
state.progress.go_mut(new_target, Instant::now());
```

Both `go` and `go_mut` retarget from the current eased scalar progress. Use `go_mut` to update stored state in place.

### Querying

```rust
let active = state.progress.is_animating(now);
// For Animation<bool>, interpolate between false=0 and true=1:
let t = state.progress.interpolate(0.0_f32, 1.0_f32, now);
// For a separate Animation<f32>, read its current visual value:
let v = scalar.interpolate_with(|t| t, now);
```

### Where to store it

Always in `widget::Tree::state` for custom widgets. Use `tag()` + `state()` + `downcast_mut` to access.

For application-level state (fade-in modals, global transitions), store in `App::state` directly; no tree needed.

## Easing

See [animation-easing.md](animation-easing.md) for the declaration links and practical easing examples.

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
| `Animation<bool>` for fades and scale changes | [Gallery](../examples/gallery/src/main.rs) |
| Custom animation state and a widget redraw loop | [Circular spinner](../examples/loading_spinners/src/circular.rs) |
| Canvas arc driven by `window::frames` | [Arc](../examples/arc/src/main.rs) |
| Canvas updated by `time::every` | [Clock](../examples/clock/src/main.rs) |
| Canvas simulation driven by `window::frames` | [Solar system](../examples/solar_system/src/main.rs) |
| Notification overlay with timeout and dismissal | [Toast](../examples/toast/src/main.rs) |

Read the closest example before writing a new animation from scratch.

## Reusable animation widgets

Extract a reusable animation widget when 2+ components need the same reveal/collapse behavior. The widget owns its `Animation<T>` in tree state, handles `RedrawRequested`/`invalidate_layout` internally, and exposes only `fn new(content).expanded(bool)` — callers flip a bool in `update()`.

## See also

- `animation-easing.md`
- `advanced-shell.md`
- `subscription.md`
- `time.md`
- `guide-animated-layout.md` — measured positions, collapsed/expanded transitions, keyed identity, anti-patterns
- `guide-animation-debugging.md` — symptom→cause checklist for animation/render bugs
- `guide-custom-widgets.md` — draw order, hover stability, opacity completeness
