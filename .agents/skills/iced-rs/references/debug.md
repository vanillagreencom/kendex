# Debug

> `iced::debug` · iced 0.14.0

Profiling and timing utilities for iced applications. Measure execution time of code blocks and toggle the debug overlay.

## API

### Functions

```rust
/// Returns a `Span` that measures execution time until dropped.
/// Use as a scope guard: `let _span = debug::time("my_operation");`
pub fn time(name: impl Into<String>) -> Span;

/// Executes a closure, logs its execution time, and returns its result.
pub fn time_with<T>(name: impl Into<String>, f: impl FnOnce() -> T) -> T;

/// Enables the debug overlay (performance metrics, widget tree).
pub fn enable();

/// Disables the debug overlay.
pub fn disable();
```

### `Span` struct

A scope-guard type returned by `time()`. When dropped, it records the elapsed duration under the given name. The timing data is visible in the debug overlay.

## Patterns

### Measure a code block with scope guard

```rust
use iced::debug;

fn heavy_computation(&self) {
    let _span = debug::time("heavy_computation");
    // ... work happens here ...
    // timing recorded when `_span` is dropped
}
```

### Measure and return a value

```rust
use iced::debug;

let result = debug::time_with("parse_data", || {
    expensive_parse(&raw_data)
});
```

### Toggle debug overlay from a keyboard shortcut

```rust
use iced::keyboard;

// In update:
Message::ToggleDebug => {
    if self.debug_enabled {
        debug::disable();
    } else {
        debug::enable();
    }
    self.debug_enabled = !self.debug_enabled;
}
```

### Profile update function

```rust
fn update(&mut self, message: Message) -> Task<Message> {
    debug::time_with("update", || {
        match message {
            // ... handle messages ...
        }
    })
}
```

## Gotchas

- `time()` returns a `Span` scope guard. You must bind it to a variable (`let _span = ...`) or it will be dropped immediately, recording zero time.
- Timing data is only visible when the debug overlay is enabled. Call `debug::enable()` or press the built-in debug hotkey (F12 by default).
- These are lightweight wrappers -- safe to leave in production code. They become no-ops when the debug overlay is disabled.
- `time_with` is the simpler API when you just want to time a single expression.

## See also

- `application.md` -- debug overlay configuration in application settings
- `advanced-shell.md` -- `Shell::request_redraw` for frame timing
- `window.md` -- window settings including debug mode
