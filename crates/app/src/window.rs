//! Titlebar controls for the frameless window — the UI draws its own
//! chrome, so these replace what the OS window frame used to provide.

use std::sync::{Mutex, MutexGuard, PoisonError};

/// The window this app opens. `tauri.conf.json` names it explicitly: with
/// the window built hidden, this lookup is the only thing that shows it, and
/// leaning on tauri's default label would put the app's one window behind a
/// default that no test or compiler here would notice changing.
const MAIN: &str = "main";

/// The size the webview is at, and how it got there — held as the one
/// value the page reads, so there is no second copy of either fact to fall
/// out of step with it. The zoom belongs to the webview and survives a page
/// reload, while the page that comes back remembers nothing, so the page
/// asks here rather than working its size out from the settings file, which
/// holds a preference and not a fact.
pub struct WebviewZoom(Mutex<ZoomState>);

impl WebviewZoom {
    fn opened(state: ZoomState) -> Self {
        Self(Mutex::new(state))
    }

    /// A panic while the size was being read or written leaves the size,
    /// not the process: the window is at whatever it was last put at
    /// either way.
    fn held(&self) -> MutexGuard<'_, ZoomState> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn moved_to(&self, percent: u16) {
        self.held().percent = percent;
    }

    fn read(&self) -> ZoomState {
        self.held().clone()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct ZoomState {
    /// The size on screen. Every resize the window takes moves it, so a
    /// page that has just reloaded reads what it is looking at.
    pub percent: u16,
    /// The window would not take the saved size when it opened, so
    /// `percent` is the fallback and the saved size is not on screen. A
    /// fact about the opening: a resize that works later moves the size but
    /// does not make the opening have worked.
    pub launch_refused: bool,
}

/// What the webview is showing, for a page with no memory of its own.
#[tauri::command]
#[specta::specta]
pub fn window_zoom_state(zoom: tauri::State<'_, WebviewZoom>) -> ZoomState {
    zoom.read()
}

/// Zoom is set on the webview rather than by restyling the page: it holds
/// across reloads, and it scales the app's own titlebar along with
/// everything else, the way a browser scales a page. Holding across reloads
/// is also why the size is recorded here — the page forgets, the webview
/// does not.
#[tauri::command]
#[specta::specta]
pub fn window_set_zoom(
    window: tauri::WebviewWindow,
    zoom: tauri::State<'_, WebviewZoom>,
    percent: u16,
) -> Result<(), String> {
    resize(&window, &zoom, percent)
}

/// The parts of the window this module drives. Named separately so they can
/// be driven without one: tauri's mock runtime answers for a window it never
/// draws, so a test that opens a real one can see neither the size that was
/// applied nor the order it was applied in.
trait Drive {
    fn scale_to(&self, factor: f64) -> Result<(), String>;
    fn unhide(&self) -> Result<(), String>;
}

impl Drive for tauri::WebviewWindow {
    fn scale_to(&self, factor: f64) -> Result<(), String> {
        self.set_zoom(factor).map_err(|e| e.to_string())
    }

    fn unhide(&self) -> Result<(), String> {
        self.show().map_err(|e| e.to_string())
    }
}

/// The size and the record of it move together, off one clamped number.
/// `zoom_scale` clamps on its own, so a percent that went unclamped to the
/// record would name a size the window was never put at — and a record left
/// behind sends the next page that reloads back to a size nobody is at.
fn resize(window: &impl Drive, zoom: &WebviewZoom, percent: u16) -> Result<(), String> {
    let percent = kendex_core::settings::clamp_zoom(percent);
    window.scale_to(kendex_core::settings::zoom_scale(percent))?;
    zoom.moved_to(percent);
    Ok(())
}

/// Size first, then reveal. The window is configured hidden so the saved
/// zoom lands before the first frame: showing at full size and rescaling a
/// moment later re-lays out the whole app in front of the person.
///
/// Answers with the size the window ends up at, which is full size when it
/// would not take the saved one.
fn reveal_at(window: &impl Drive, percent: u16) -> Result<WebviewZoom, String> {
    use std::io::Write;

    let percent = kendex_core::settings::clamp_zoom(percent);
    // A webview that will not zoom is a far smaller problem than a window
    // that never opens, so this is said out loud and the window still shows.
    let opened = match window.scale_to(kendex_core::settings::zoom_scale(percent)) {
        Ok(()) => WebviewZoom::opened(ZoomState {
            percent,
            launch_refused: false,
        }),
        Err(error) => {
            let _ = writeln!(std::io::stderr(), "zoom not applied: {error}");
            WebviewZoom::opened(ZoomState {
                percent: kendex_core::settings::ZOOM.default,
                launch_refused: true,
            })
        }
    };
    window.unhide()?;
    Ok(opened)
}

pub fn show_at_zoom(app: &tauri::App, percent: u16) -> Result<(), Box<dyn std::error::Error>> {
    use tauri::Manager;

    let window = app
        .get_webview_window(MAIN)
        .ok_or("tauri.conf.json declares no window named `main`")?;
    app.manage(reveal_at(&window, percent)?);
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

    impl Recorder {
        fn refusing() -> Self {
            Self {
                refuses_zoom: true,
                ..Self::default()
            }
        }
    }

    impl Drive for Recorder {
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

    fn state(percent: u16, launch_refused: bool) -> ZoomState {
        ZoomState {
            percent,
            launch_refused,
        }
    }

    /// The saved size has to be the size the window is given, and it has to
    /// arrive before the window does: the whole reason the window is built
    /// hidden is that the person never sees it at the wrong size.
    #[test]
    fn the_saved_size_reaches_the_window_before_it_is_shown() {
        let window = Recorder::default();

        let zoom = reveal_at(&window, 150).unwrap();

        assert_eq!(zoom.read(), state(150, false));
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

    /// A window that refused the size is at full size, and the app has to
    /// be told that rather than the size it asked for: everything the person
    /// sees afterwards — the readout, the next step of the zoom — is
    /// measured from here.
    #[test]
    fn a_window_that_will_not_zoom_is_shown_at_full_size() {
        let window = Recorder::refusing();

        let zoom = reveal_at(&window, 150);

        assert_eq!(
            zoom.map(|z| z.read()),
            Ok(state(kendex_core::settings::ZOOM.default, true)),
            "the window never opened, or reported the size it refused"
        );
        assert_eq!(window.told.into_inner().last(), Some(&Told::Unhide));
    }

    /// The zoom outlives the page that set it, so a size the window took
    /// has to move the record too: a page reloading reads this to find out
    /// what it is looking at.
    #[test]
    fn a_size_the_window_takes_moves_what_a_reloaded_page_reads() {
        let window = Recorder::default();
        let zoom = reveal_at(&window, 100).unwrap();

        resize(&window, &zoom, 150).unwrap();

        assert_eq!(zoom.read(), state(150, false));
    }

    /// The scaling clamps whatever it is handed, so a record taken from the
    /// raw number would claim a size the window was never put at — and the
    /// page that reloads believes the record. Both ends of the range, and
    /// both ways in: the opening and a resize.
    #[test]
    fn a_size_outside_the_range_is_recorded_as_the_one_the_window_was_given() {
        for (asked, given) in [
            (5000u16, kendex_core::settings::ZOOM.max),
            (1, kendex_core::settings::ZOOM.min),
        ] {
            let window = Recorder::default();
            let zoom = reveal_at(&window, asked).unwrap();
            assert_eq!(zoom.read(), state(given, false), "the opening");
            assert_eq!(
                window.told.borrow()[0],
                Told::ScaleTo(kendex_core::settings::zoom_scale(given)),
                "the opening put the window at a different size than it recorded"
            );

            resize(&window, &zoom, asked).unwrap();
            assert_eq!(zoom.read(), state(given, false), "a resize");
            assert_eq!(
                window.told.borrow().last(),
                Some(&Told::ScaleTo(kendex_core::settings::zoom_scale(given))),
                "the resize put the window at a different size than it recorded"
            );
        }
    }

    /// A refused resize left recorded would send the next reload to a size
    /// the window never took.
    #[test]
    fn a_size_the_window_refuses_leaves_the_record_where_it_was() {
        let opened = Recorder::default();
        let zoom = reveal_at(&opened, 150).unwrap();

        let refusing = Recorder::refusing();
        assert!(resize(&refusing, &zoom, 160).is_err());

        assert_eq!(zoom.read(), state(150, false));
    }

    /// The refusal is about the opening. A resize that works afterwards
    /// moves the size, and the launch still did not honour the saved one —
    /// which is why the app compares the two rather than reading either
    /// alone.
    #[test]
    fn a_later_resize_does_not_undo_the_launchs_refusal() {
        let refusing = Recorder::refusing();
        let zoom = reveal_at(&refusing, 150).unwrap();

        let window = Recorder::default();
        resize(&window, &zoom, 150).unwrap();

        assert_eq!(zoom.read(), state(150, true));
    }
}
