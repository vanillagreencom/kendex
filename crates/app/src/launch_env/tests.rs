//! What each launch decision has to come out as.

use std::ffi::OsStr;
use std::path::Path;

use super::*;

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
/// later launch to trust.
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
