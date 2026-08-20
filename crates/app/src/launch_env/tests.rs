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
    let explained = |session| overriding_the_bundle(session, &plan(session));
    assert!(explained(appimage()));
    // Their own choice was heard, so there is nothing to apologise for.
    assert!(!explained(Session {
        ours: Some("wayland"),
        ..appimage()
    }));
    assert!(!explained(wayland()));
}

#[test]
fn the_appimage_runtime_says_so_by_itself() {
    let exe = Path::new("/usr/bin/kendex-app");
    assert!(in_appimage(
        Some(OsStr::new("/home/me/kendex.AppImage")),
        None,
        Some(exe)
    ));
    assert!(!in_appimage(None, None, Some(exe)));
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
    assert!(!in_appimage(None, Some(extracted), None));
}

/// The whole point of the narrower signal: a deb that inherited APPDIR
/// must still treat GDK_BACKEND as the person's word.
#[test]
fn a_deb_that_inherited_appdir_keeps_the_backend_the_person_set() {
    let session = Session {
        in_appimage: in_appimage(
            None,
            Some(OsStr::new("/home/me/kendex.AppDir")),
            Some(Path::new("/usr/bin/kendex-app")),
        ),
        gdk: Some("x11"),
        ..wayland()
    };
    assert_eq!(backend(session), None);
}
