//! What the environment must say before GTK and WebKit start.
//!
//! Both fixes here are for how the Linux app is packaged and how WebKitGTK
//! behaves on Wayland. The whole decision is a pure function of strings, so
//! it can be tested without a display or a bundle.

use std::ffi::OsStr;
use std::path::Path;

/// Choose a backend for the AppImage, where `GDK_BACKEND` cannot be heard.
/// Nothing in the bundle writes this one.
const OUR_BACKEND: &str = "KENDEX_GDK_BACKEND";

/// The value the AppImage's bundled GTK hook writes, always and exactly.
const BUNDLED_BACKEND: &str = "x11";

/// GDK's own ordered list: open Wayland where the compositor is, and fall
/// back to X11 rather than failing to start, so a compositor the Wayland
/// backend cannot talk to still gets a window.
const WAYLAND_THEN_X11: &str = "wayland,x11";

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
}

/// A value only counts as said if there is something in it.
fn said(value: Option<&str>) -> Option<&str> {
    value.filter(|said| !said.trim().is_empty())
}

/// The same for a directory-valued variable, whose bytes need not be UTF-8.
/// An exported-but-empty one matters here: `Path::new("")` has no components,
/// so every path starts with it.
fn said_dir(value: Option<&OsStr>) -> Option<&Path> {
    let dir = value?;
    if dir.is_empty() || dir.to_str().is_some_and(|dir| dir.trim().is_empty()) {
        return None;
    }
    Some(Path::new(dir))
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
/// starts. What it dodges is not the DMABUF crash `webview_env` handles —
/// it is tauri-apps/tauri#8541, a GLib-GIO settings-schema lookup that
/// aborts the process, hit by AppImages built on an old distro and run on a
/// newer one. The cost of the pin is paid by everyone: the shipped app
/// always lands on XWayland, where a Wayland compositor reports a scale of
/// 1 while driving the display at 2, so the whole window comes out at half
/// size.
///
/// `wayland,x11` is a display-open fallback, not a net under that abort: a
/// `g_error` kills the process after GDK has already chosen Wayland, and
/// the second entry is never reached. Overriding the pin is judged worth it
/// because upstream reports the abort does not occur for bundles built on
/// current Ubuntu, which is what `release.yml` builds on, and because the
/// released AppImage patched to this value was run on a Wayland session and
/// came up native with an empty log. `KENDEX_GDK_BACKEND=x11` is the way
/// back for anyone whose host proves that judgement wrong.
///
/// No other packaging needs the push: with the variable unset, GDK already
/// tries Wayland before X11.
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
///
/// A relaunch cannot loop because this is a fixed point: applying what it
/// asks for makes the next call return nothing, since every entry is only
/// emitted when the variable does not already hold the wanted value. That
/// is checked rather than asserted — see the test. A sentinel variable
/// would be the obvious alternative and was the wrong one: children inherit
/// it, so a kendex launched from a process kendex started would read a
/// stale marker and skip a plan its own environment needs.
fn plan(session: Session<'_>) -> Vec<(&'static str, String)> {
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

/// Whether this plan is overriding the bundle's pinned backend.
///
/// What is being set comes off the plan rather than being worked out a
/// second time, but the plan alone cannot say why: a person who names
/// `wayland,x11` themselves produces the same entry the default does, and
/// telling them the bundle's pin was overridden would be telling them their
/// own choice was ignored. So the question of whether anybody named one is
/// asked here, and the message names the AppImage, so the AppImage is asked
/// about rather than inferred.
fn overriding_the_bundle(session: Session<'_>, vars: &[(&'static str, String)]) -> bool {
    session.in_appimage
        && chosen_backend(session).is_none()
        && vars
            .iter()
            .any(|(name, value)| *name == "GDK_BACKEND" && value == WAYLAND_THEN_X11)
}

/// Whether the bundled GTK hook has already been through this environment,
/// so `GDK_BACKEND` is the bundle's word rather than the person's.
///
/// Neither variable answers this on its own. An AppImage's AppRun exports
/// both `APPIMAGE` and `APPDIR`, and every process it starts inherits both,
/// so a terminal opened from one hands a stranger's pair to every `.deb`
/// and source build launched from it. What separates those cases is where
/// this executable lives: `APPDIR` is the directory a bundle unpacks to —
/// the mount point of a running AppImage, or the tree a hand-extracted one
/// sits in — and a process inside it really is inside that bundle.
///
/// Only when there is no executable to place does a bare variable get the
/// last word, so a genuine bundle that cannot read its own path is not
/// quietly demoted to a half-size window.
fn in_appimage(appimage: Option<&OsStr>, appdir: Option<&OsStr>, exe: Option<&Path>) -> bool {
    let appdir = said_dir(appdir);
    let Some(exe) = exe else {
        return appimage.is_some() || appdir.is_some();
    };
    appdir.is_some_and(|dir| exe.starts_with(dir))
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
    command.args(std::env::args_os().skip(1));
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
        in_appimage: in_appimage(
            std::env::var_os("APPIMAGE").as_deref(),
            std::env::var_os("APPDIR").as_deref(),
            std::env::current_exe().ok().as_deref(),
        ),
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
    if overriding_the_bundle(session, &vars) {
        let _ = writeln!(
            stderr,
            "display: the AppImage pins GDK_BACKEND={BUNDLED_BACKEND}, which puts the window \
             on XWayland at half size; set {OUR_BACKEND} to choose a backend yourself"
        );
    }
    relaunch_with(&vars);
}

#[cfg(test)]
mod tests;
