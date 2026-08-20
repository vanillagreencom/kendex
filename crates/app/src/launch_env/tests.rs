//! What each launch decision has to come out as.

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

/// A running AppImage: the runtime mounts it and both variables point at
/// that mount, which is where the executable is.
#[test]
fn a_mounted_appimage_is_recognised_by_where_it_runs_from() {
    assert!(in_appimage(
        Some(OsStr::new("/home/me/kendex.AppImage")),
        Some(OsStr::new("/tmp/.mount_kendexAbc")),
        Some(Path::new("/tmp/.mount_kendexAbc/usr/bin/kendex-app"))
    ));
    assert!(!in_appimage(
        None,
        None,
        Some(Path::new("/usr/bin/kendex-app"))
    ));
}

/// The other half of the inherited-variable problem: the runtime exports
/// APPIMAGE into the same environment every child gets, so it says no more
/// about this process than APPDIR does.
#[test]
fn a_stray_appimage_does_not_make_this_an_appimage() {
    let installed = Path::new("/usr/bin/kendex-app");
    assert!(!in_appimage(
        Some(OsStr::new("/home/me/other.AppImage")),
        None,
        Some(installed)
    ));
    assert!(!in_appimage(
        Some(OsStr::new("/home/me/other.AppImage")),
        Some(OsStr::new("/tmp/.mount_otherXyz")),
        Some(installed)
    ));
}

/// Neither variable can be measured against a path we do not have, and a
/// genuine bundle is not worth demoting to half size over it.
#[test]
fn a_bundle_that_cannot_read_its_own_path_is_still_a_bundle() {
    assert!(in_appimage(
        Some(OsStr::new("/home/me/kendex.AppImage")),
        None,
        None
    ));
    assert!(in_appimage(
        None,
        Some(OsStr::new("/home/me/kendex.AppDir")),
        None
    ));
    assert!(!in_appimage(None, None, None));
}

/// An exported-but-empty APPDIR is every path's prefix, so it has to be
/// read as unset rather than as a directory containing everything.
#[test]
fn an_empty_appdir_is_not_a_directory_this_lives_in() {
    for empty in ["", "   "] {
        assert!(
            !in_appimage(
                None,
                Some(OsStr::new(empty)),
                Some(Path::new("/usr/bin/kendex-app"))
            ),
            "{empty:?}"
        );
    }
}

/// Every AppImage's AppRun exports APPDIR and everything it starts
/// inherits it, so a deb launched from a terminal that came out of one
/// carries a stranger's APPDIR. It only speaks for this process when
/// this process lives inside it.
#[test]
fn a_stray_appdir_does_not_make_this_an_appimage() {
    let extracted = OsStr::new("/home/me/kendex.AppDir");
    assert!(in_appimage(
        None,
        Some(extracted),
        Some(Path::new("/home/me/kendex.AppDir/usr/bin/kendex-app"))
    ));
    assert!(!in_appimage(
        None,
        Some(extracted),
        Some(Path::new("/usr/bin/kendex-app"))
    ));
    // A prefix that only matches as a string, not as a path.
    assert!(!in_appimage(
        None,
        Some(extracted),
        Some(Path::new("/home/me/kendex.AppDirectory/usr/bin/kendex-app"))
    ));
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
