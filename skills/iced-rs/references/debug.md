# Debugging and timing

Read when measuring or inspecting an Iced 0.14.0 application. The pinned [root debug exports](https://github.com/iced-rs/iced/blob/0.14.0/src/lib.rs) expose `Span`, `time` and `time_with`. The [debug implementation](https://github.com/iced-rs/iced/blob/0.14.0/debug/src/lib.rs) owns recording, explicit span completion and feature/target behavior.

## Timing

Use `time_with` for an expression or update block whose result must be returned:

```rust
let result = iced::debug::time_with("parse_data", || parse_data(&raw_data));
```

For a wider scope, retain the span and finish it explicitly:

```rust
let span = iced::debug::time("heavy_computation");
heavy_computation();
span.finish();
```

The pinned span has no `Drop` completion implementation. Binding it alone does not finish the measurement. `time` takes a name; it does not accept the closure that belongs to `time_with`.

Enabled native recording sends timing events to the debug client. The no-recording feature/target branch provides empty span methods, but that does not prove every caller expression or name allocation is free. Measure the workload before optimizing or retaining instrumentation on a hot path.

## Tools

Enable the `debug` feature for the built-in developer tools; the pinned [feature declaration](https://github.com/iced-rs/iced/blob/0.14.0/Cargo.toml) describes the native F12 debugger. `iced::debug::enable` and `disable` are not public root exports. Check the selected tool's controls instead of calling those names through the root API.

| Tool | Task | Install route |
|---|---|---|
| [cargo-hot](https://github.com/hecrj/cargo-hot) | Experimental hot reload | `cargo install cargo-hot` |
| [Comet](https://github.com/iced-rs/comet) | Inspect and debug an application | `cargo install --locked --git https://github.com/iced-rs/comet.git` |

The external tool repositories are discovery sources. Confirm compatibility, controls and recording in the pinned application before relying on them.

For stress runs, the `unconditional-rendering` feature requests rendering on runtime events. The bundled `iced_wgpu/src/settings.rs::present_mode_from_env` owns `ICED_PRESENT_MODE`, including `immediate`. Record those settings with any measurement because they change its workload.

## Related references

- `application.md`
- `advanced-shell.md`
- `window.md`
