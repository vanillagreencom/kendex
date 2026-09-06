//! What the environment must say before GTK and WebKit start, and before
//! kendex looks up the first program it runs.
//!
//! Two of the fixes here are for how the Linux app is packaged and how
//! WebKitGTK behaves on Wayland. The third settles what a kendex opened
//! from Finder is expected to find, and the answer is: the programs the
//! person's terminal finds. launchd hands a GUI application four system
//! directories and nothing else, so without this the app runs Apple's
//! `/usr/bin/git` and never the newer one Homebrew installed to clear the
//! 2.41 floor. Taking the login shell's `PATH` in its place belongs here
//! rather than beside any one spawn: `PATH` is corrected once, before
//! anything reads it, and every subprocess inherits the correction, so the
//! version probe and the checkout it guards are covered by one mechanism
//! instead of two.
//!
//! Every decision is a pure function of strings, so it can be tested
//! without a display, a bundle, or a Finder launch.

use kendex_core::install_channel::in_appimage;

/// Choose a backend for the AppImage, where `GDK_BACKEND` cannot be heard.
/// Nothing in the bundle writes this one.
const OUR_BACKEND: &str = "KENDEX_GDK_BACKEND";

/// The value the AppImage's bundled GTK hook writes, always and exactly.
const BUNDLED_BACKEND: &str = "x11";

/// GDK's own ordered list: open Wayland where the compositor is, and fall
/// back to X11 rather than failing to start, so a compositor the Wayland
/// backend cannot talk to still gets a window.
const WAYLAND_THEN_X11: &str = "wayland,x11";

/// The directories launchd hands a GUI application, and the whole of what
/// it hands one, whatever the person's shell would have said. Read as a
/// set: `from_launchd` asks whether a `PATH` names anything outside it.
const LAUNCHD_PATH: [&str; 4] = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"];

/// The login shell to ask when `SHELL` names none. It is what macOS makes
/// new accounts with.
#[cfg(target_os = "macos")]
const FALLBACK_SHELL: &str = "/bin/zsh";

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
    /// `PATH`.
    path: Option<&'a str>,
    /// What a login shell says `PATH` is, asked for only where the answer
    /// can differ from what this process was handed.
    login_path: Option<&'a str>,
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
/// starts. What it dodges is not the DMABUF crash `webview_env` handles,
/// but a GLib-GIO settings-schema lookup that aborts the process when an
/// AppImage built on an old distro runs on a newer one. The cost of the pin
/// is paid by everyone: the shipped app
/// always lands on XWayland, where a Wayland compositor reports a scale of
/// 1 while driving the display at 2, so the whole window comes out at half
/// size.
///
/// `wayland,x11` is a display-open fallback, not a net under that abort: a
/// `g_error` kills the process after GDK has already chosen Wayland, and
/// the second entry is never reached. Overriding the pin is judged worth it
/// because upstream reports the abort does not occur for bundles built on
/// current Ubuntu, which is what `release.yml` builds on.
/// `KENDEX_GDK_BACKEND=x11` is the way back for anyone whose host proves
/// that judgement wrong.
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

/// Whether `PATH` is launchd's rather than a shell's.
///
/// A `PATH` made of nothing but the system directories is one nobody
/// chose: it is what launchd hands every GUI application, so it carries no
/// information about what the person wanted — the same reasoning
/// `chosen_backend` applies to the backend the AppImage pins. A `PATH`
/// naming anything else came through a shell and is theirs. Order and a
/// missing entry are not read into: launchd's list is what it is, and a
/// shorter one is no more a choice than the full one.
fn from_launchd(path: Option<&str>) -> bool {
    match said(path) {
        None => true,
        Some(path) => path.split(':').all(|dir| LAUNCHD_PATH.contains(&dir)),
    }
}

/// The `PATH` to start with, or `None` when the one in hand is already
/// somebody's answer or the login shell had none to give.
///
/// A login answer that is itself launchd's list names nothing the process
/// does not already have, so taking it could not help, and refusing it is
/// what makes the relaunch terminate: unlike the other entries, `PATH` is
/// not read back from the variable this plan sets — `apply` asks the login
/// shell again — so a second run must be stopped by what it is told, not
/// by what it set.
fn shell_path(path: Option<&str>, login_path: Option<&str>) -> Option<String> {
    let login = said(login_path)?;
    if !from_launchd(path) || from_launchd(Some(login)) {
        return None;
    }
    Some(login.to_owned())
}

/// Everything that has to change before GTK and WebKit start; empty when
/// nothing does, which is the common case and means no relaunch.
///
/// A relaunch cannot loop because this is a fixed point: applying what it
/// asks for makes the next call return nothing. For the display entries
/// that is because each is emitted only when the variable does not
/// already hold the wanted value; for `PATH`, which is decided against a
/// fresh answer rather than the variable just set, it is because a `PATH`
/// carrying anything of the person's is never replaced again. That is
/// checked rather than asserted — see the test. A sentinel variable
/// would not do: children inherit it, so a kendex launched from a process
/// kendex started would read a stale marker and skip a plan its own
/// environment needs.
fn plan(session: Session<'_>) -> Vec<(&'static str, String)> {
    let wayland = wayland_session(session.session_type, session.wayland_display);
    let mut vars = Vec::new();
    if let Some(value) = webview_env(wayland, session.webkit) {
        vars.push(("WEBKIT_DISABLE_DMABUF_RENDERER", value.to_owned()));
    }
    if let Some(backend) = gdk_backend(wayland, session) {
        vars.push(("GDK_BACKEND", backend));
    }
    if let Some(path) = shell_path(session.path, session.login_path) {
        vars.push(("PATH", path));
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

/// The answer inside what the login shell printed.
///
/// `-l` sources the startup files before running the command, so a file
/// that greets or reports prints ahead of the answer. `printenv PATH` is
/// the last thing `-c` runs, so the last line is the answer, and a
/// greeting is never welded onto its first directory — which would put a
/// `PATH` naming something outside launchd's list in place, so nothing
/// would ask the shell again.
#[cfg(any(target_os = "macos", test))]
fn answered_path(printed: &str) -> Option<&str> {
    said(printed.lines().next_back().map(str::trim))
}

/// Ask the login shell what `PATH` is.
///
/// `-l -c` runs the startup files a terminal run would run and nothing
/// interactive, and `printenv` is the spelling every login shell answers
/// the same way: in fish `$PATH` is a list, so `echo` would hand back a
/// space-separated line rather than a `PATH`. Standard input is closed so
/// a startup file that reads it is answered with end-of-file instead of
/// holding the window shut, and a shell that fails or says nothing leaves
/// the environment as it was. What it printed is read by `answered_path`.
#[cfg(target_os = "macos")]
fn login_shell_path() -> Option<String> {
    use std::process::{Command, Stdio};

    let shell = std::env::var("SHELL")
        .ok()
        .filter(|shell| !shell.trim().is_empty())
        .unwrap_or_else(|| FALLBACK_SHELL.to_owned());
    let asked = Command::new(shell)
        .args(["-l", "-c", "printenv PATH"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !asked.status.success() {
        return None;
    }
    let printed = String::from_utf8(asked.stdout).ok()?;
    answered_path(&printed).map(str::to_owned)
}

/// Relaunch with the selected environment values. Setting them in this
/// process instead would need `unsafe` — the workspace forbids it, and
/// changing the environment in place is not thread-safe — and every other
/// setting rides the same relaunch.
#[cfg(any(target_os = "linux", target_os = "macos"))]
fn relaunch_with(vars: &[(&'static str, String)]) {
    use std::io::Write;
    use std::os::unix::process::CommandExt;

    let exe = match std::env::current_exe() {
        Ok(exe) => exe,
        Err(error) => {
            let _ = writeln!(std::io::stderr(), "launch environment kept: {error}");
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
    let _ = writeln!(std::io::stderr(), "launch environment kept: {error}");
}

/// Read the session, decide, say what changed, and relaunch if anything did.
///
/// Each platform reads only the variables it has, so the plan comes out
/// holding only that platform's entries: nothing on macOS names a Wayland
/// session or a GDK backend, and nothing on Linux is asked what a login
/// shell would say.
#[cfg(any(target_os = "linux", target_os = "macos"))]
pub(crate) fn apply() {
    use std::io::Write;

    let session_type = std::env::var("XDG_SESSION_TYPE").ok();
    let wayland_display = std::env::var("WAYLAND_DISPLAY").ok();
    let webkit = std::env::var("WEBKIT_DISABLE_DMABUF_RENDERER").ok();
    let ours = std::env::var(OUR_BACKEND).ok();
    let gdk = std::env::var("GDK_BACKEND").ok();
    let path = std::env::var("PATH").ok();
    // A login shell is a process to start and startup files to run, so it
    // is asked only where its answer can differ from what is in hand. A
    // terminal-started kendex already has the answer and pays nothing.
    #[cfg(target_os = "macos")]
    let login_path = from_launchd(path.as_deref())
        .then(login_shell_path)
        .flatten();
    #[cfg(not(target_os = "macos"))]
    let login_path: Option<String> = None;
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
        path: path.as_deref(),
        login_path: login_path.as_deref(),
    };

    let vars = plan(session);
    if vars.is_empty() {
        return;
    }
    // Said out loud for whoever is at a terminal to read; a
    // launcher-started app has no stderr and pays nothing either way.
    let mut stderr = std::io::stderr();
    let setting = vars
        .iter()
        .map(|(name, value)| format!("{name}={value}"))
        .collect::<Vec<_>>()
        .join(" ");
    let _ = writeln!(stderr, "launch environment: starting with {setting}");
    if overriding_the_bundle(session, &vars) {
        let _ = writeln!(
            stderr,
            "launch environment: the AppImage pins GDK_BACKEND={BUNDLED_BACKEND}, which puts the window \
             on XWayland at half size; set {OUR_BACKEND} to choose a backend yourself"
        );
    }
    relaunch_with(&vars);
}

#[cfg(test)]
mod tests;
