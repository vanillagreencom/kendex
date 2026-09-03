# crates/app/

Tauri commands over `kendex-core`, one module per page domain. A command reads, invokes core and answers; no domain logic lives here.

- A command that touches disk, git or a subprocess is `#[tauri::command(async)]`; only window operations stay synchronous. Not mechanically enforced.
- The command surface, the constants the UI reads and the runtime every `Result`-returning command answers through are declared in `specta_builder` (`src/lib.rs`); `ui/src/bindings.ts` is regenerated with `cargo test -p kendex-app -- --ignored regenerate_bindings` and byte-checked by `tests/bindings.rs`.
- Two raw spawns are sanctioned and exempt from the process constructor: the self re-exec in `src/launch_env.rs` and the detached editor launch in `src/native.rs`; anything else goes through core's `process::Hardened`.
- A whole-file write (the Customize tab's manifest, the Settings page's app settings) carries the `Base` its copy was read at and answers different bytes on disk with `WriteRefused` (`src/whole_file.rs`), never a silent overwrite.
- The window opens hidden and is shown in `setup` once the saved zoom is applied; the zoom range is a core constant reaching the UI through the bindings; the close is never held for an in-flight settings write. Enforced by `tests/tauri_config.rs::the_window_opens_hidden_so_the_saved_zoom_lands_first`.
- On Linux the display environment is decided once, before GTK starts, by relaunching (`src/launch_env.rs`); `KENDEX_GDK_BACKEND` is honoured on any session and never overridden, and `GDK_SCALE` and `GDK_DPI_SCALE` are never written. Enforced by the tests in `src/launch_env/tests.rs`.
- Launch recovery rolls back pending journals in every registered project under the scope lock. Enforced by `tests/recovery.rs`.
