//! What the environment must say before GTK and WebKit start.
//!
//! Both fixes here are for how the Linux app is packaged and how WebKitGTK
//! behaves on Wayland, and both are decided from strings so they can be
//! tested without a display.

/// Choose a backend for the AppImage, where `GDK_BACKEND` cannot be heard.
/// Nothing in the bundle touches this one.
pub const OUR_BACKEND: &str = "KENDEX_GDK_BACKEND";

/// The value the AppImage's bundled GTK hook writes, always and exactly.
const BUNDLED_BACKEND: &str = "x11";

/// Set on the relaunch below, so a session relaunches at most once.
pub const RELAUNCHED: &str = "KENDEX_DISPLAY_ENV";

/// Whether a Wayland compositor is there to talk to. `XDG_SESSION_TYPE` is
/// the usual answer but is not always set — a compositor started from a tty
/// leaves it saying `tty` — and a Wayland socket to connect to settles it
/// either way.
pub fn wayland_session(session_type: Option<&str>, wayland_display: Option<&str>) -> bool {
    session_type == Some("wayland") || wayland_display.is_some_and(|socket| !socket.is_empty())
}

/// WebKitGTK's DMABUF renderer crashes the window outright on several
/// Wayland compositors (GDK protocol error 71 on Hyprland). Disabling it
/// costs GPU-accelerated rendering but always shows a window; a user who
/// has set the variable themselves keeps their choice.
pub fn webview_env(wayland: bool, current: Option<&str>) -> Option<&'static str> {
    match (wayland, current) {
        (true, None) => Some("1"),
        _ => None,
    }
}

/// The AppImage's bundled GTK hook exports `GDK_BACKEND=x11` before the app
/// starts, to dodge a crash (tauri-apps/tauri#8541) that `webview_env`
/// already handles here. The cost is that the shipped app always lands on
/// XWayland, and a Wayland compositor reports a scale of 1 to an XWayland
/// client while driving the display at 2 — so the whole window comes out at
/// half size. `wayland,x11` is GDK's own ordered list: it opens Wayland
/// where the compositor is, and falls back to X11 rather than failing to
/// start, so a compositor the Wayland backend cannot talk to still gets a
/// window.
pub fn gdk_backend(wayland: bool, chosen: Option<&str>) -> Option<&'static str> {
    match (wayland, chosen) {
        (true, None) => Some("wayland,x11"),
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
pub fn chosen_backend<'a>(
    ours: Option<&'a str>,
    gdk: Option<&'a str>,
    in_appimage: bool,
) -> Option<&'a str> {
    fn said(value: Option<&str>) -> Option<&str> {
        value.filter(|chosen| !chosen.trim().is_empty())
    }
    if let Some(chosen) = said(ours) {
        return Some(chosen);
    }
    let chosen = said(gdk)?;
    if in_appimage && chosen == BUNDLED_BACKEND {
        return None;
    }
    Some(chosen)
}

/// Relaunch with the fixes in the environment. Setting them in this process
/// instead would need `unsafe` — the workspace forbids it, and changing the
/// environment in place is not thread-safe — and relaunching is already how
/// the WebKit fix has always been delivered.
#[cfg(target_os = "linux")]
fn relaunch_with(vars: &[(&str, &str)]) {
    use std::io::Write;
    use std::os::unix::process::CommandExt;

    let Ok(exe) = std::env::current_exe() else {
        return;
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

/// Read the session, decide, and relaunch if anything needs changing.
#[cfg(target_os = "linux")]
pub fn apply() {
    if std::env::var_os(RELAUNCHED).is_some() {
        return;
    }
    let wayland = wayland_session(
        std::env::var("XDG_SESSION_TYPE").ok().as_deref(),
        std::env::var("WAYLAND_DISPLAY").ok().as_deref(),
    );
    let webkit = std::env::var("WEBKIT_DISABLE_DMABUF_RENDERER").ok();
    let ours = std::env::var(OUR_BACKEND).ok();
    let gdk = std::env::var("GDK_BACKEND").ok();
    // Set by the AppImage runtime and by nothing else.
    let in_appimage = std::env::var_os("APPIMAGE").is_some();

    let mut vars = Vec::new();
    if let Some(value) = webview_env(wayland, webkit.as_deref()) {
        vars.push(("WEBKIT_DISABLE_DMABUF_RENDERER", value));
    }
    if let Some(value) = gdk_backend(
        wayland,
        chosen_backend(ours.as_deref(), gdk.as_deref(), in_appimage),
    ) {
        vars.push(("GDK_BACKEND", value));
    }
    if !vars.is_empty() {
        relaunch_with(&vars);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_wayland_socket_counts_even_when_the_session_type_does_not_say_so() {
        assert!(wayland_session(Some("wayland"), None));
        assert!(wayland_session(Some("tty"), Some("wayland-1")));
        assert!(!wayland_session(Some("x11"), None));
        assert!(!wayland_session(None, Some("")));
        assert!(!wayland_session(None, None));
    }

    #[test]
    fn wayland_gets_the_dmabuf_workaround_unless_the_user_chose() {
        assert_eq!(webview_env(true, None), Some("1"));
        assert_eq!(webview_env(true, Some("0")), None);
        assert_eq!(webview_env(false, None), None);
    }

    #[test]
    fn wayland_opens_natively_with_x11_left_as_the_fallback() {
        assert_eq!(gdk_backend(true, None), Some("wayland,x11"));
        assert_eq!(gdk_backend(false, None), None);
    }

    #[test]
    fn a_backend_the_person_chose_is_left_alone() {
        assert_eq!(gdk_backend(true, Some("x11")), None);
        assert_eq!(gdk_backend(true, Some("broadway")), None);
    }

    #[test]
    fn the_appimage_stops_pinning_the_window_to_xwayland() {
        // What the shipped app has in its environment on a Wayland session:
        // the bundled hook's x11, and nothing the person set.
        let chosen = chosen_backend(None, Some("x11"), true);
        assert_eq!(gdk_backend(true, chosen), Some("wayland,x11"));
    }

    #[test]
    fn inside_the_appimage_the_bundlers_x11_is_not_a_choice() {
        assert_eq!(chosen_backend(None, Some("x11"), true), None);
        // Anything else there did not come from the bundled hook.
        assert_eq!(
            chosen_backend(None, Some("broadway"), true),
            Some("broadway")
        );
    }

    #[test]
    fn our_own_variable_says_what_gdk_backend_cannot() {
        assert_eq!(chosen_backend(Some("x11"), Some("x11"), true), Some("x11"));
        assert_eq!(chosen_backend(Some(" "), Some("x11"), true), None);
    }

    #[test]
    fn outside_the_appimage_the_variable_is_the_persons_choice() {
        assert_eq!(chosen_backend(None, Some("x11"), false), Some("x11"));
        assert_eq!(chosen_backend(None, None, false), None);
        assert_eq!(chosen_backend(None, Some(""), false), None);
    }
}
