# Animation and easing

Read when choosing interpolation or transition controls for Iced 0.14.0. The pinned [animation declaration](https://github.com/iced-rs/iced/blob/0.14.0/core/src/animation.rs) owns the signatures, duration presets, trait bounds and re-exported `Easing`. Use `animation.md` for state ownership, invalidation and redraw scheduling.

## Transitions

Create an `Animation` with its initial state. Set its easing, explicit duration or duration preset, and optional delay. Retarget it with consuming `go` or mutable `go_mut`. Check that interrupted transitions remain continuous under rapid toggles.

`value()` returns the target state. Use interpolation to obtain the visual value at an instant. Generic `interpolate_with` takes its state by value and projects keyframes into an interpolable result. `Animation<bool>::interpolate` supplies false/true endpoints directly; its `remaining` method reports the remaining duration.

```rust
use iced::{Animation, animation::Easing};
use iced::time::{Duration, Instant};

let mut fade = Animation::new(false)
    .duration(Duration::from_millis(250))
    .easing(Easing::EaseIn);

let now = Instant::now();
fade.go_mut(true, now);
let opacity = fade.interpolate(0.0_f32, 1.0_f32, now);
```

The bundled `examples/gallery/src/main.rs` demonstrates bool transitions and visual interpolation. For a numeric state, project the value with `interpolate_with(|value| value, now)`. Custom states must satisfy the exported `Float` bound and the result must satisfy `Interpolable`; inspect those traits before implementing them.

## Repetition and curves

`repeat` adds repetitions after the initial play, so one repetition plays twice. `repeat_forever` removes the finite end, and `auto_reverse` reverses repeated transitions. Start a transition toward a different state before expecting motion; constructing an animation alone supplies its initial value.

Use the re-exported `Easing` for standard curves or a custom `fn(f32) -> f32`; evaluate a curve with `value`. The declaration's upstream re-export owns the variant inventory. Do not infer a complete list from these examples.

Keep custom-widget animation state in `Tree::state`, as `animation.md` requires. The redraw loop advances the visible result; builders alone do not schedule frames. The package's trading UI easing guidance also stays in that reference.

## Related references

- `animation.md`
- `advanced-shell.md`
- `advanced-widget.md`
- `advanced-tree.md`
