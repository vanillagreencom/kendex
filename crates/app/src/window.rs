//! Titlebar controls for the frameless window — the UI draws its own
//! chrome, so these replace what the OS window frame used to provide.

/// The window this app opens. `tauri.conf.json` names it explicitly: with
/// the window built hidden, this lookup is the only thing that shows it, and
/// leaning on tauri's default label would put the app's one window behind a
/// default that no test or compiler here would notice changing.
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

/// The window as the opening uses it. Named separately so the opening can
/// be driven without one: tauri's mock runtime answers for a window it
/// never draws, so a test that opens a real one can see neither the size
/// that was applied nor the order it was applied in.
trait Reveal {
    fn scale_to(&self, factor: f64) -> Result<(), String>;
    fn unhide(&self) -> Result<(), String>;
}

impl Reveal for tauri::WebviewWindow {
    fn scale_to(&self, factor: f64) -> Result<(), String> {
        self.set_zoom(factor).map_err(|e| e.to_string())
    }

    fn unhide(&self) -> Result<(), String> {
        self.show().map_err(|e| e.to_string())
    }
}

/// Size first, then reveal. The window is configured hidden so the saved
/// zoom lands before the first frame: showing at full size and rescaling a
/// moment later re-lays out the whole app in front of the person.
fn reveal_at(window: &impl Reveal, percent: u16) -> Result<(), String> {
    use std::io::Write;

    // A webview that will not zoom is a far smaller problem than a window
    // that never opens, so this is said out loud and the window still shows.
    if let Err(error) = window.scale_to(kendex_core::settings::zoom_scale(percent)) {
        let _ = writeln!(std::io::stderr(), "zoom not applied: {error}");
    }
    window.unhide()
}

pub fn show_at_zoom(app: &tauri::App, percent: u16) -> Result<(), Box<dyn std::error::Error>> {
    use tauri::Manager;

    let window = app
        .get_webview_window(MAIN)
        .ok_or("tauri.conf.json declares no window named `main`")?;
    reveal_at(&window, percent)?;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, PartialEq)]
    enum Told {
        ScaleTo(f64),
        Unhide,
    }

    /// A window that only remembers what it was asked to do, so both the
    /// size and the order it arrived in can be read back.
    #[derive(Default)]
    struct Recorder {
        told: std::cell::RefCell<Vec<Told>>,
        refuses_zoom: bool,
    }

    impl Reveal for Recorder {
        fn scale_to(&self, factor: f64) -> Result<(), String> {
            self.told.borrow_mut().push(Told::ScaleTo(factor));
            if self.refuses_zoom {
                return Err("no webview".to_owned());
            }
            Ok(())
        }

        fn unhide(&self) -> Result<(), String> {
            self.told.borrow_mut().push(Told::Unhide);
            Ok(())
        }
    }

    /// The saved size has to be the size the window is given, and it has to
    /// arrive before the window does: the whole reason the window is built
    /// hidden is that the person never sees it at the wrong size.
    #[test]
    fn the_saved_size_reaches_the_window_before_it_is_shown() {
        let window = Recorder::default();

        reveal_at(&window, 150).unwrap();

        assert_eq!(
            window.told.into_inner(),
            [Told::ScaleTo(1.5), Told::Unhide],
            "the saved percent, as a scale factor, then the reveal"
        );
    }

    /// Full size is what an unreadable settings file falls back to, so a
    /// reveal that always applied it would look right in exactly the case
    /// nothing was saved.
    #[test]
    fn a_size_away_from_full_is_the_one_applied() {
        for (percent, factor) in [(50u16, 0.5), (100, 1.0), (200, 2.0)] {
            let window = Recorder::default();
            reveal_at(&window, percent).unwrap();
            assert_eq!(window.told.into_inner()[0], Told::ScaleTo(factor));
        }
    }

    #[test]
    fn a_window_that_will_not_zoom_is_shown_anyway() {
        let window = Recorder {
            refuses_zoom: true,
            ..Recorder::default()
        };

        let opened = reveal_at(&window, 150);

        assert!(opened.is_ok(), "the window never opened: {opened:?}");
        assert_eq!(window.told.into_inner().last(), Some(&Told::Unhide));
    }
}
