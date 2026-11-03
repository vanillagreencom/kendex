# Application and daemon

Read when choosing or configuring an Iced 0.14.0 entrypoint. The pinned [application](https://github.com/iced-rs/iced/blob/0.14.0/src/application.rs), [daemon](https://github.com/iced-rs/iced/blob/0.14.0/src/daemon.rs) and [root run helper](https://github.com/iced-rs/iced/blob/0.14.0/src/lib.rs) own their signatures and builder methods.

## Entrypoints

Use `iced::run(update, view)` for a state with `Default` and default settings. Use `iced::application(boot, update, view)` when startup or configuration needs a builder. The bundled `examples/counter/src/main.rs` shows the update/view form.

Use `iced::daemon(boot, update, view)` for an application that controls its windows explicitly or runs without one. Its view receives both state and `window::Id`. A daemon opens no window by default and continues after all windows close. Open windows through window tasks and return `iced::exit()` when the daemon should terminate. The bundled `examples/multi_window/src/main.rs` shows per-window views and window tasks.

Choose one runtime entrypoint for the process. Manage additional windows through that runtime rather than starting another application loop.

## State and effects

Boot may return state alone or state with a startup task. Update may return no effect or a value convertible into `Task<Message>`. Keep side effects in these update/startup tasks and keep view construction pure.

Messages must satisfy the entrypoint's send/lifetime requirements. Read its current run bounds as well: developer-tool features can add message requirements beyond the constructor. Do not copy only a partial bound list into application code.

## Configuration

Set subscriptions, theme, style, scale and fonts on the selected builder. Inspect its own methods: application window setters are not a shared daemon builder API. Configure a daemon's individual windows when opening them.

An application title can be static or a function of state; a daemon title can also use the window ID. Use a theme function when the theme depends on state. `theme.md` owns the styling guidance.

The font builder adds bytes to the fonts loaded at startup. Runtime font loading uses the font task API. Neither choice alone proves asynchronous font processing or a first-paint cost; inspect the runtime and measure before making that claim.

## Related references

- `element.md`
- `task.md`
- `subscription.md`
- `theme.md`
- `window.md`
