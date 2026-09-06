//! What each launch decision has to come out as.

use std::ffi::OsStr;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use super::*;
use crate::test_util::rooted;

/// A Wayland session with nothing set — the shape every case varies.
fn wayland() -> Session<'static> {
    Session {
        session_type: Some("wayland"),
        ..Session::default()
    }
}

/// The environment the shipped AppImage really has: the bundled GTK
/// hook's own value, written here rather than read from the constant so
/// the constant is pinned in a second place.
fn appimage() -> Session<'static> {
    Session {
        in_appimage: true,
        gdk: Some("x11"),
        ..wayland()
    }
}

/// What launchd hands a GUI application, spelled out rather than joined
/// from the constant so the constant is pinned in a second place. Read off
/// a bundle opened with `open` from an emptied environment on macOS 26.
const LAUNCHD_GIVES: &str = "/usr/bin:/bin:/usr/sbin:/sbin";

/// What a login shell says, shaped like the one on that same Mac: the
/// Homebrew directory holding the git that clears the floor comes first,
/// and launchd's four are still at the end.
const LOGIN_SHELL_SAYS: &str =
    "/opt/homebrew/bin:/Users/me/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin";

/// A Finder launch: launchd's `PATH`, and a login shell that answers.
fn finder() -> Session<'static> {
    Session {
        path: Some(LAUNCHD_GIVES),
        login_path: Some(LOGIN_SHELL_SAYS),
        ..Session::default()
    }
}

fn named<'a>(session: Session<'a>, name: &str) -> Option<String> {
    plan(session)
        .into_iter()
        .find(|(entry, _)| *entry == name)
        .map(|(_, value)| value)
}

fn backend(session: Session<'_>) -> Option<String> {
    named(session, "GDK_BACKEND")
}

fn path(session: Session<'_>) -> Option<String> {
    named(session, "PATH")
}

/// The whole point: the plan is settled before anything is spawned, so the
/// git version probe and the checkout it guards both run on this `PATH`.
#[test]
fn a_finder_launch_starts_over_with_the_login_shells_path() {
    assert_eq!(path(finder()), Some(LOGIN_SHELL_SAYS.to_owned()));
    // launchd's list is nobody's choice in any order, and a shorter one is
    // no more of a choice than the full one.
    for given in ["/bin:/usr/bin", "/sbin:/usr/sbin:/bin:/usr/bin", ""] {
        assert_eq!(
            path(Session {
                path: Some(given),
                ..finder()
            }),
            Some(LOGIN_SHELL_SAYS.to_owned()),
            "{given:?}"
        );
    }
}

/// A login shell prints its startup files' output before the answer, so
/// the whole of stdout is not the answer: a greeting welded onto the first
/// directory would put a `PATH` naming a directory that does not exist in
/// place, and nothing would ask again.
#[test]
fn the_answer_is_the_last_line_the_login_shell_printed() {
    for (what, printed) in [
        ("nothing before it", "/opt/homebrew/bin:/usr/bin\n"),
        ("no closing newline", "/opt/homebrew/bin:/usr/bin"),
        (
            "a greeting before it",
            "Welcome back!\n/opt/homebrew/bin:/usr/bin\n",
        ),
        (
            "several lines before it",
            "Welcome back!\nnvm: using v24\n/opt/homebrew/bin:/usr/bin\n",
        ),
    ] {
        assert_eq!(
            answered_path(printed),
            Some("/opt/homebrew/bin:/usr/bin"),
            "{what}"
        );
    }
    // Nothing said is no answer, and `shell_path` then leaves `PATH` alone.
    for printed in ["", "\n", "   \n"] {
        assert_eq!(answered_path(printed), None, "{printed:?}");
    }
}

/// The must-fail control. A `PATH` naming anything launchd does not hand
/// over came through a shell and is the person's, and a login shell that
/// answers with nothing leaves the environment as it was.
#[test]
fn a_path_that_came_through_a_shell_is_left_alone() {
    let kept = [
        (
            "started from a terminal",
            Some(LOGIN_SHELL_SAYS),
            Some(LOGIN_SHELL_SAYS),
        ),
        (
            "one directory of their own on it",
            Some("/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"),
            Some(LOGIN_SHELL_SAYS),
        ),
        ("the login shell said nothing", Some(LAUNCHD_GIVES), None),
        (
            "the login shell said only blanks",
            Some(LAUNCHD_GIVES),
            Some("  "),
        ),
        // Nothing to take, and taking it is what a relaunch would do
        // again on the next start, and the one after that.
        (
            "the login shell said launchd's own list back",
            Some(LAUNCHD_GIVES),
            Some("/bin:/usr/bin"),
        ),
    ];
    for (what, given, said) in kept {
        assert_eq!(
            path(Session {
                path: given,
                login_path: said,
                ..Session::default()
            }),
            None,
            "{what}"
        );
    }
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
            // Spelled out, not taken from the constant: the order is
            // the fix. Reversed, GDK opens X11 first and the window is
            // back on XWayland at half size.
            ("GDK_BACKEND", "wayland,x11".to_owned()),
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
            ours: Some("x11"),
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

/// What stops a relaunch looping: applying the plan leaves nothing to do.
/// There is no marker in the environment for a child to inherit and a
/// later launch to trust. `login_path` is carried forward rather than
/// re-derived because the second run does not read it back from what the
/// first set — it asks the login shell again — and `shell_path` refuses a
/// launchd-shaped answer whatever the shell says, so no answer it could
/// give a second time reopens the plan.
#[test]
fn applying_the_plan_leaves_nothing_to_do() {
    let sessions = [
        ("the AppImage on Wayland", appimage()),
        ("a deb on Wayland", wayland()),
        (
            "a backend the person named",
            Session {
                ours: Some("broadway"),
                ..appimage()
            },
        ),
        (
            "a named backend on an X11 session",
            Session {
                session_type: Some("x11"),
                ours: Some("broadway"),
                ..Session::default()
            },
        ),
        ("a Finder launch", finder()),
    ];
    for (what, session) in sessions {
        let first = plan(session);
        assert!(!first.is_empty(), "{what}: nothing to apply");
        let applied = |name| {
            first
                .iter()
                .find(|(entry, _)| *entry == name)
                .map(|(_, value)| value.as_str())
        };
        let relaunched = Session {
            webkit: applied("WEBKIT_DISABLE_DMABUF_RENDERER").or(session.webkit),
            gdk: applied("GDK_BACKEND").or(session.gdk),
            path: applied("PATH").or(session.path),
            ..session
        };
        assert!(plan(relaunched).is_empty(), "{what}: would relaunch again");
    }
}

#[test]
fn only_an_ignored_bundle_pin_is_explained() {
    let explained = |session| overriding_the_bundle(session, &plan(session));
    assert!(explained(appimage()));
    // Their own choice was heard, so there is nothing to apologise for —
    // including when they named the very value the default would have used,
    // which is the one the plan cannot tell apart on its own.
    for chosen in ["wayland", "wayland,x11"] {
        assert!(
            !explained(Session {
                ours: Some(chosen),
                ..appimage()
            }),
            "{chosen}"
        );
    }
    assert!(!explained(wayland()));
}

/// The whole point of the narrower signal: a deb launched from a terminal
/// that came out of an AppImage inherits both variables, and must still
/// treat GDK_BACKEND as the person's word.
#[test]
fn a_deb_that_inherited_the_variables_keeps_the_backend_the_person_set() {
    for (appimage, appdir) in [
        (Some(OsStr::new("/home/me/other.AppImage")), None),
        (None, Some(OsStr::new("/tmp/.mount_otherXyz"))),
        (
            Some(OsStr::new("/home/me/other.AppImage")),
            Some(OsStr::new("/tmp/.mount_otherXyz")),
        ),
    ] {
        let session = Session {
            in_appimage: in_appimage(appimage, appdir, Some(Path::new("/usr/bin/kendex-app"))),
            gdk: Some("x11"),
            ..wayland()
        };
        assert_eq!(backend(session), None, "{appimage:?} {appdir:?}");
    }
}

/// A stand-in for a login shell: a script that ignores `-l -c` and does
/// what the case needs. The real one runs other people's startup files,
/// which is the whole reason the call is bounded.
fn a_shell_that(body: &str, tmp: &tempfile::TempDir) -> PathBuf {
    let shell = rooted(tmp).join("shell");
    let mut file = std::fs::File::create(&shell).expect("fixture shell is writable");
    write!(file, "#!/bin/sh\n{body}\n").expect("fixture shell is writable");
    drop(file);
    std::fs::set_permissions(&shell, std::fs::Permissions::from_mode(0o755))
        .expect("fixture shell is runnable");
    shell
}

/// The control. A startup file that waits on something — a network call, a
/// version manager, a lock — must not hold the window shut: the wait ends
/// at the limit and `PATH` stays the one launchd gave.
#[test]
fn a_login_shell_that_never_answers_is_stopped_at_the_limit() {
    let tmp = tempfile::tempdir().expect("fixture root");
    let shell = a_shell_that("sleep 120", &tmp);
    let limit = Duration::from_millis(400);

    let started = Instant::now();
    let asked = ask_login_shell(&shell, limit);
    let waited = started.elapsed();

    assert_eq!(asked, Asked::TimedOut);
    // Bounded by the limit, not by the sleep. Generous against a loaded
    // machine; the point is that it is not two minutes.
    assert!(waited < Duration::from_secs(30), "waited {waited:?}");
    // And a shell that did not answer leaves the plan empty, so the
    // relaunch never happens and launchd's PATH stands.
    assert!(
        plan(Session {
            path: Some(LAUNCHD_GIVES),
            login_path: None,
            ..Session::default()
        })
        .is_empty()
    );
}

/// Its must-fail control: the same bound, a shell that does answer. Without
/// it the case above would pass on a call that refuses everything.
#[test]
fn a_login_shell_that_answers_within_the_limit_is_heard() {
    let tmp = tempfile::tempdir().expect("fixture root");
    let shell = a_shell_that("printf '%s\\n' \"/opt/homebrew/bin:/usr/bin\"", &tmp);

    assert_eq!(
        ask_login_shell(&shell, Duration::from_secs(30)),
        Asked::Printed("/opt/homebrew/bin:/usr/bin\n".to_owned())
    );
}
