# Debug

> `iced::debug` · iced 0.14.0

Profiling and timing utilities for iced applications. Measure execution time of code blocks. Enable the `debug` feature for native developer tools.

Read when timing Iced work or using native developer tools.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/src/lib.rs) for public exports and the [timing implementation](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/debug/src/lib.rs) for span recording.

## Patterns

### Measure a code block

```rust
use iced::debug;

fn heavy_computation(&self) {
    let span = debug::time("heavy_computation");
    // ... work happens here ...
    span.finish(); // record timing explicitly
}
```

### Measure and return a value

```rust
use iced::debug;

let result = debug::time_with("parse_data", || {
    expensive_parse(&raw_data)
});
```

### Open the developer tools

With the `debug` feature on a native build, press F12 to toggle Comet. `iced::debug` exposes `time`, `time_with` and `Span`; it does not expose `enable` or `disable`. The [pinned developer-tool integration](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/devtools/src/comet.rs) owns Comet's compatible revision and installation route.

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

## Dev tools

Use Comet for debug metrics. The `hot` feature enables the experimental cargo-hot integration; see the [feature declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/Cargo.toml) and [cargo-hot project](https://github.com/hecrj/cargo-hot). Follow those owners for setup.

For stress testing, `ICED_PRESENT_MODE=immediate` requests immediate presentation, and `unconditional-rendering` requests rendering on runtime events. Measure before optimizing:

```rust
fn update(&mut self, message: Message) -> Task<Message> {
    iced::debug::time_with(format!("{message:?}"), || match message { /* ... */ })
}
```

## Gotchas

- Call `Span::finish()` to record a span. Dropping it does not finish timing.
- `time_with` records a span around one closure and returns the closure's result on ordinary completion.
- Timing is a no-op without debug support or on WebAssembly. Native recording also depends on the debugger's enabled state; use its UI to inspect metrics.

## See also

- [Application setup](application.md)
- `advanced-shell.md` -- `Shell::request_redraw` for frame timing
