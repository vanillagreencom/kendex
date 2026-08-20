//! Titlebar controls for the frameless window — the UI draws its own
//! chrome, so these replace what the OS window frame used to provide.

/// The window this app opens, as named by `tauri.conf.json`.
const MAIN: &str = "main";

/// Zoom is set on the webview rather than by restyling the page: it holds
/// across reloads, and it scales the app's own titlebar along with
/// everything else, the way a browser scales a page.
#[tauri::command]
#[specta::specta]
pub fn window_set_zoom(window: tauri::WebviewWindow, percent: u16) -> Result<(), String> {
    window
        .set_zoom(kendex_core::settings::zoom_scale(percent))
        .map_err(|e| e.to_string())
}

/// The window is configured hidden so the saved zoom lands before the first
/// frame: showing at full size and rescaling a moment later re-lays out the
/// whole app in front of the person.
pub fn show_at_zoom(app: &tauri::App, percent: u16) -> Result<(), Box<dyn std::error::Error>> {
    use std::io::Write;

    use tauri::Manager;

    let window = app
        .get_webview_window(MAIN)
        .ok_or("tauri.conf.json declares no window named `main`")?;
    // A webview that will not zoom is a far smaller problem than a window
    // that never opens, so this is said out loud and the window still shows.
    if let Err(error) = window.set_zoom(kendex_core::settings::zoom_scale(percent)) {
        let _ = writeln!(std::io::stderr(), "zoom not applied: {error}");
    }
    window.show()?;
    Ok(())
}

#[tauri::command]
#[specta::specta]
pub fn window_minimize(window: tauri::Window) -> Result<(), String> {
    window.minimize().map_err(|e| e.to_string())
}

#[tauri::command]
#[specta::specta]
pub fn window_toggle_maximize(window: tauri::Window) -> Result<(), String> {
    let maximized = window.is_maximized().map_err(|e| e.to_string())?;
    if maximized {
        window.unmaximize().map_err(|e| e.to_string())
    } else {
        window.maximize().map_err(|e| e.to_string())
    }
}

#[tauri::command]
#[specta::specta]
pub fn window_close(window: tauri::Window) -> Result<(), String> {
    window.close().map_err(|e| e.to_string())
}
