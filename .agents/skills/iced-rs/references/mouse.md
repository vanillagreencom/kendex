# Mouse

> `iced::mouse` · iced 0.14.0

Mouse events, buttons, scroll deltas, cursor state, and system cursor icons. `Cursor` and `Interaction` are available through `iced::mouse`, including cursor-position helpers, without the `advanced` feature.

Read when handling pointer events, wheel units, or cursor coordinates.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/mouse.rs) for source module exports, [mouse events and scroll deltas](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/mouse/event.rs), [buttons](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/mouse/button.rs), and [click classification](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/mouse/click.rs).

## Patterns

### Listen to wheel events in a widget

```rust
fn update(
    &mut self,
    _tree: &mut Tree,
    event: &Event,
    layout: Layout<'_>,
    cursor: Cursor,
    _renderer: &Renderer,
    _clipboard: &mut dyn Clipboard,
    shell: &mut Shell<'_, Message>,
    _viewport: &Rectangle,
) {
    if let Event::Mouse(mouse::Event::WheelScrolled { delta }) = event {
        if cursor.is_over(layout.bounds()) {
            let y = match delta {
                mouse::ScrollDelta::Lines { y, .. }  => *y * 16.0,
                mouse::ScrollDelta::Pixels { y, .. } => *y,
            };
            shell.publish((self.on_scroll)(y));
            shell.capture_event();
        }
    }
}
```

### Handle a middle-click

```rust
if let Event::Mouse(mouse::Event::ButtonPressed(mouse::Button::Middle)) = event {
    if cursor.is_over(layout.bounds()) {
        shell.publish(Message::MiddleClick);
        shell.capture_event();
    }
}
```

### Global mouse listener via subscription

```rust
use iced::event::{self, Event};
use iced::mouse;

fn subscription(_: &State) -> Subscription<Message> {
    event::listen_with(|event, _status, _id| match event {
        Event::Mouse(mouse::Event::ButtonPressed(mouse::Button::Forward)) => {
            Some(Message::Forward)
        }
        _ => None,
    })
}
```

## Gotchas

- `ScrollDelta::Lines` and `ScrollDelta::Pixels` are both emitted by real devices — always handle both. A common mistake is to only match on `Lines` and silently drop trackpad scrolling.
- The example chooses 16 logical pixels per line. Document your multiplier; `Lines` does not prescribe a pixel distance.
- `CursorMoved { position }` is in **window** coordinates, not widget coordinates. Use `Cursor::position_in(layout.bounds())` inside a widget to get widget-relative coordinates.
- `position_over` keeps the cursor’s coordinates in the same space as the supplied bounds. `position_in` subtracts the rectangle origin to return local coordinates.
- `Button::Other(u16)` is platform-specific — don't assume any particular numeric code means a particular button.
- There is no `Event::DoubleClick` variant — double-click detection is done via the `iced::advanced::mouse::click::Click::new(position, button, previous)` helper. Pass the previous `Click` to use its timing, position and button checks.
- No `is_inside_window` helper -- track `CursorEntered`/`CursorLeft` yourself.

## See also

- `advanced-mouse.md`
- `keyboard.md`
- `events.md`
- `touch.md`
