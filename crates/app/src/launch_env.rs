//! What the environment must say before GTK and WebKit start.
//!
//! Both fixes here are for how the Linux app is packaged and how WebKitGTK
//! behaves on Wayland. The whole decision is a pure function of strings, so
//! it can be tested without a display or a bundle.

/// Choose a backend for the AppImage, where `GDK_BACKEND` cannot be heard.
/// Nothing in the bundle writes this one.
const OUR_BACKEND: &str = "KENDEX_GDK_BACKEND";

/// The value the AppImage's bundled GTK hook writes, always and exactly.
const BUNDLED_BACKEND: &str = "x11";

/// GDK's own ordered list: open Wayland where the compositor is, and fall
/// back to X11 rather than failing to start, so a compositor the Wayland
/// backend cannot talk to still gets a window.
const WAYLAND_THEN_X11: &str = "wayland,x11";

/// Set on the relaunch below, so a session relaunches at most once.
const RELAUNCHED: &str = "KENDEX_DISPLAY_ENV";

/// What the environment said when this process started.
#[derive(Debug, Default, Clone, Copy)]
struct Session<'a> {
    session_type: Option<&'a str>,
    wayland_display: Option<&'a str>,
    webkit: Option<&'a str>,
    /// `KENDEX_GDK_BACKEND`.
    ours: Option<&'a str>,
    /// `GDK_BACKEND`.
    gdk: Option<&'a str>,
    /// The bundled GTK hook has run, so `GDK_BACKEND` is the bundle's.
    in_appimage: bool,
    relaunched: bool,
}

/// A value only counts as said if there is something in it.
fn said(value: Option<&str>) -> Option<&str> {
    value.filter(|said| !said.trim().is_empty())
}

/// Whether a Wayland compositor is there to talk to. `XDG_SESSION_TYPE` is
/// the usual answer but is not always set — a compositor started from a tty
/// leaves it saying `tty` — and a Wayland socket to connect to settles it
/// either way.
fn wayland_session(session_type: Option<&str>, wayland_display: Option<&str>) -> bool {
    session_type == Some("wayland") || said(wayland_display).is_some()
}

/// WebKitGTK's DMABUF renderer crashes the window outright on several
/// Wayland compositors (GDK protocol error 71 on Hyprland). Disabling it
/// costs GPU-accelerated rendering but always shows a window; a user who
/// has set the variable themselves keeps their choice. This one is not
/// packaging-specific — the crash is WebKitGTK's, whatever installed it.
fn webview_env(wayland: bool, current: Option<&str>) -> Option<&'static str> {
    match (wayland, current) {
        (true, None) => Some("1"),
        _ => None,
    }
}

/// The backend the person chose, as far as it can be known.
///
/// Inside an AppImage the bundled GTK hook has already overwritten
/// `GDK_BACKEND` with `x11` before any kendex code runs, so that exact
/// value there carries no information about what they wanted and is
/// ignored. It is the one preference the packaging makes unhearable, which
/// is why `KENDEX_GDK_BACKEND` exists: nothing in the bundle writes it, so
/// it says what `GDK_BACKEND` cannot. Everywhere else — a `.deb`, an
/// `.rpm`, a build from source — `GDK_BACKEND` is still theirs and wins.
fn chosen_backend<'a>(session: Session<'a>) -> Option<&'a str> {
    if let Some(chosen) = said(session.ours) {
        return Some(chosen);
    }
    let chosen = said(session.gdk)?;
    if session.in_appimage && chosen == BUNDLED_BACKEND {
        return None;
    }
    Some(chosen)
}

/// The backend to start with, or `None` when the environment already says
/// it.
///
/// The AppImage's bundled GTK hook exports `GDK_BACKEND=x11` before the app
/// starts, to dodge a crash (tauri-apps/tauri#8541) that `webview_env`
/// already handles here. The cost is that the shipped app always lands on
/// XWayland, and a Wayland compositor reports a scale of 1 to an XWayland
/// client while driving the display at 2 — so the whole window comes out at
/// half size. No other packaging needs the push: with the variable unset,
/// GDK already tries Wayland before X11.
fn gdk_backend(wayland: bool, session: Session<'_>) -> Option<String> {
    let wanted = match chosen_backend(session) {
        Some(chosen) => chosen.to_owned(),
        None if wayland && session.in_appimage => WAYLAND_THEN_X11.to_owned(),
        None => return None,
    };
    // Relaunching to set what is already set changes nothing.
    (session.gdk != Some(wanted.as_str())).then_some(wanted)
}

/// Everything that has to change before GTK and WebKit start; empty when
/// nothing does, which is the common case and means no relaunch.
fn plan(session: Session<'_>) -> Vec<(&'static str, String)> {
    if session.relaunched {
        return Vec::new();
    }
    let wayland = wayland_session(session.session_type, session.wayland_display);
    let mut vars = Vec::new();
    if let Some(value) = webview_env(wayland, session.webkit) {
        vars.push(("WEBKIT_DISABLE_DMABUF_RENDERER", value.to_owned()));
    }
    if let Some(backend) = gdk_backend(wayland, session) {
        vars.push(("GDK_BACKEND", backend));
    }
    vars
}

/// Whether the bundle's pinned backend is about to be overridden — true
/// only where nobody said anything, so the person who did say something is
/// never told their choice was ignored.
fn overriding_the_bundle(session: Session<'_>) -> bool {
    session.in_appimage
        && chosen_backend(session).is_none()
        && said(session.gdk) == Some(BUNDLED_BACKEND)
}

/// Relaunch with the fixes in the environment. Setting them in this process
/// instead would need `unsafe` — the workspace forbids it, and changing the
/// environment in place is not thread-safe — and relaunching is already how
/// the WebKit fix has always been delivered.
#[cfg(target_os = "linux")]
fn relaunch_with(vars: &[(&'static str, String)]) {
    use std::io::Write;
    use std::os::unix::process::CommandExt;

    let exe = match std::env::current_exe() {
        Ok(exe) => exe,
        Err(error) => {
            let _ = writeln!(std::io::stderr(), "display fixes skipped: {error}");
            return;
        }
    };
    let mut command = std::process::Command::new(exe);
    command
        .args(std::env::args_os().skip(1))
        .env(RELAUNCHED, "1");
    for (name, value) in vars {
        command.env(name, value);
    }
    let error = command.exec();
    // exec only returns on failure; running without the fixes still beats
    // not starting at all.
    let _ = writeln!(std::io::stderr(), "display fixes skipped: {error}");
}

/// Read the session, decide, say what changed, and relaunch if anything did.
#[cfg(target_os = "linux")]
pub(crate) fn apply() {
    use std::io::Write;

    let session_type = std::env::var("XDG_SESSION_TYPE").ok();
    let wayland_display = std::env::var("WAYLAND_DISPLAY").ok();
    let webkit = std::env::var("WEBKIT_DISABLE_DMABUF_RENDERER").ok();
    let ours = std::env::var(OUR_BACKEND).ok();
    let gdk = std::env::var("GDK_BACKEND").ok();
    let session = Session {
        session_type: session_type.as_deref(),
        wayland_display: wayland_display.as_deref(),
        webkit: webkit.as_deref(),
        ours: ours.as_deref(),
        gdk: gdk.as_deref(),
        // The AppImage runtime sets both; a hand-extracted AppDir sets only
        // APPDIR, from the bundled hook's own first line.
        in_appimage: std::env::var_os("APPIMAGE").is_some() || std::env::var_os("APPDIR").is_some(),
        relaunched: std::env::var_os(RELAUNCHED).is_some(),
    };

    let vars = plan(session);
    if vars.is_empty() {
        return;
    }
    // Said out loud because the person who set any of these is at a
    // terminal; a launcher-started app has no stderr and pays nothing.
    let mut stderr = std::io::stderr();
    let setting = vars
        .iter()
        .map(|(name, value)| format!("{name}={value}"))
        .collect::<Vec<_>>()
        .join(" ");
    let _ = writeln!(stderr, "display: starting with {setting}");
    if overriding_the_bundle(session) {
        let _ = writeln!(
            stderr,
            "display: the AppImage pins GDK_BACKEND={BUNDLED_BACKEND}, which puts the window \
             on XWayland at half size; set {OUR_BACKEND} to choose a backend yourself"
        );
    }
    relaunch_with(&vars);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A Wayland session with nothing set — the shape every case varies.
    fn wayland() -> Session<'static> {
        Session {
            session_type: Some("wayland"),
            ..Session::default()
        }
    }

    fn appimage() -> Session<'static> {
        Session {
            in_appimage: true,
            gdk: Some(BUNDLED_BACKEND),
            ..wayland()
        }
    }

    fn backend(session: Session<'_>) -> Option<String> {
        plan(session)
            .into_iter()
            .find(|(name, _)| *name == "GDK_BACKEND")
            .map(|(_, value)| value)
    }

    #[test]
    fn a_wayland_socket_counts_even_when_the_session_type_does_not_say_so() {
        assert!(wayland_session(Some("wayland"), None));
        assert!(wayland_session(Some("tty"), Some("wayland-1")));
        assert!(!wayland_session(Some("x11"), None));
        assert!(!wayland_session(None, Some("")));
        assert!(!wayland_session(None, None));
    }

    #[test]
    fn wayland_gets_the_dmabuf_workaround_whatever_installed_the_app() {
        assert_eq!(
            plan(wayland()),
            [("WEBKIT_DISABLE_DMABUF_RENDERER", "1".to_owned())]
        );
        // A person who set it themselves keeps their choice.
        assert!(
            plan(Session {
                webkit: Some("0"),
                ..wayland()
            })
            .is_empty()
        );
    }

    #[test]
    fn the_appimage_stops_pinning_the_window_to_xwayland() {
        assert_eq!(
            plan(appimage()),
            [
                ("WEBKIT_DISABLE_DMABUF_RENDERER", "1".to_owned()),
                ("GDK_BACKEND", WAYLAND_THEN_X11.to_owned()),
            ]
        );
    }

    /// GDK already tries Wayland before X11 when the variable is unset, so
    /// pushing the same order onto a deb, an rpm, or a source build buys
    /// nothing and costs a relaunch.
    #[test]
    fn no_other_packaging_is_pushed_onto_a_backend() {
        assert_eq!(backend(wayland()), None);
        assert!(
            plan(Session {
                webkit: Some("0"),
                ..wayland()
            })
            .is_empty()
        );
    }

    #[test]
    fn our_variable_chooses_a_backend_the_appimage_would_not_let_through() {
        for chosen in ["wayland", "broadway"] {
            assert_eq!(
                backend(Session {
                    ours: Some(chosen),
                    ..appimage()
                }),
                Some(chosen.to_owned()),
                "{chosen}"
            );
        }
    }

    /// The one value that needs no push: it is already what the bundle set.
    #[test]
    fn choosing_the_backend_the_environment_already_has_changes_nothing() {
        assert_eq!(
            backend(Session {
                ours: Some(BUNDLED_BACKEND),
                ..appimage()
            }),
            None
        );
        assert_eq!(
            backend(Session {
                gdk: Some("broadway"),
                ..wayland()
            }),
            None
        );
    }

    #[test]
    fn our_variable_is_heard_on_a_session_that_is_not_wayland() {
        assert_eq!(
            backend(Session {
                session_type: Some("x11"),
                ours: Some("wayland"),
                ..Session::default()
            }),
            Some("wayland".to_owned())
        );
    }

    #[test]
    fn a_backend_the_person_chose_is_left_alone() {
        assert_eq!(
            backend(Session {
                gdk: Some("x11"),
                ..wayland()
            }),
            None
        );
        assert_eq!(
            backend(Session {
                ours: Some(" "),
                gdk: Some("x11"),
                ..wayland()
            }),
            None
        );
    }

    #[test]
    fn the_relaunched_process_decides_nothing_a_second_time() {
        assert!(
            plan(Session {
                relaunched: true,
                ..appimage()
            })
            .is_empty()
        );
    }

    #[test]
    fn only_an_ignored_bundle_pin_is_explained() {
        assert!(overriding_the_bundle(appimage()));
        // Their own choice was heard, so there is nothing to apologise for.
        assert!(!overriding_the_bundle(Session {
            ours: Some("wayland"),
            ..appimage()
        }));
        assert!(!overriding_the_bundle(wayland()));
    }
}
