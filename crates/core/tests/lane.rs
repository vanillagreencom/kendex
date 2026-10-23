//! The CLI's marker reader takes only git identity and orch's launch record.

use std::fs;

use kendex_core::lane::marked_worktree;

use crate::test_util::lane::{Fixture, snapshot};

enum Case {
    Marked,
    NestedMarked,
    NestedUnmarked,
    BareMarked,
    BareUnmarked,
    AdministrationMarked,
    AdministrationUnmarked,
    IndependentBare,
    IndependentAdministration,
    TaggedBranch,
    Unmarked,
    NoMarkers,
    Main,
    Outside,
    OtherRoot,
    OtherBranch,
    Detached,
    NonItemBranch,
    BrokenMarker,
    MarkerDirectory,
}

#[test]
#[allow(clippy::expect_used, reason = "a fixture operation must succeed")]
#[allow(
    clippy::too_many_lines,
    reason = "one marker identity table shares its fixture and assertions"
)]
fn only_the_checked_out_item_marker_bound_to_a_linked_root_names_a_lane() {
    for case in [
        Case::Marked,
        Case::NestedMarked,
        Case::NestedUnmarked,
        Case::BareMarked,
        Case::BareUnmarked,
        Case::AdministrationMarked,
        Case::AdministrationUnmarked,
        Case::IndependentBare,
        Case::IndependentAdministration,
        Case::TaggedBranch,
        Case::Unmarked,
        Case::NoMarkers,
        Case::Main,
        Case::Outside,
        Case::OtherRoot,
        Case::OtherBranch,
        Case::Detached,
        Case::NonItemBranch,
        Case::BrokenMarker,
        Case::MarkerDirectory,
    ] {
        let fixture = Fixture::new("KEN-2299");
        fixture.mark();
        let nested = fixture.linked.join("vendor");
        let independent = fixture.root.join("vendor");
        let administration = nested.join(".git/objects");
        let independent_administration = independent.join(".git/objects");
        let mut checked = &fixture.linked;
        match case {
            Case::NestedMarked
            | Case::NestedUnmarked
            | Case::BareMarked
            | Case::BareUnmarked
            | Case::AdministrationMarked
            | Case::AdministrationUnmarked
            | Case::IndependentBare
            | Case::IndependentAdministration => {
                // Git clone and clone --bare create real inner repositories.
                // Their working-tree status does not change physical enclosure.
                let outside = matches!(
                    case,
                    Case::IndependentBare | Case::IndependentAdministration
                );
                let destination = if outside { &independent } else { &nested };
                let mut args = vec!["clone", "-q"];
                if matches!(
                    case,
                    Case::BareMarked | Case::BareUnmarked | Case::IndependentBare
                ) {
                    args.push("--bare");
                }
                args.extend([
                    fixture.main.to_str().expect("fixture path"),
                    destination.to_str().expect("fixture path"),
                ]);
                fixture.git(&fixture.root, &args);
                checked = if matches!(
                    case,
                    Case::AdministrationMarked | Case::AdministrationUnmarked
                ) {
                    &administration
                } else if matches!(case, Case::IndependentAdministration) {
                    &independent_administration
                } else {
                    destination
                };
                if !matches!(case, Case::NestedMarked | Case::NestedUnmarked) {
                    assert!(
                        kendex_core::guard::Repo::probe(checked)
                            .expect("working-tree probe")
                            .is_none()
                    );
                }
                let enclosing = kendex_core::guard::Repo::enclosing_linked(checked)
                    .expect("enclosing repository");
                if outside {
                    assert!(enclosing.is_none());
                } else {
                    assert_eq!(
                        enclosing.expect("linked checkout").worktree,
                        fixture.linked.canonicalize().expect("linked root")
                    );
                }
                assert_eq!(
                    kendex_core::guard::Repo::enclosed_by_linked(checked).expect("enclosure"),
                    !outside
                );
                if matches!(
                    case,
                    Case::NestedUnmarked | Case::BareUnmarked | Case::AdministrationUnmarked
                ) {
                    fs::remove_file(&fixture.marker).expect("remove enclosing marker");
                }
            }
            Case::Marked => {
                // Repo keeps std's resolved spelling. On Windows this row
                // must compare it with the marker's reduced root spelling.
                let resolved = fixture.linked.canonicalize().expect("resolved worktree");
                assert_eq!(kendex_core::paths::reduced(&resolved), fixture.linked);
                #[cfg(windows)]
                assert!(
                    resolved
                        .to_str()
                        .expect("Windows fixture path")
                        .starts_with(r"\\?\")
                );
            }
            Case::TaggedBranch => fixture.git(&fixture.main, &["tag", "KEN-2299"]),
            Case::Unmarked => fs::remove_file(&fixture.marker).expect("remove marker"),
            Case::NoMarkers => fs::remove_dir_all(fixture.marker.parent().expect("marker parent"))
                .expect("remove marker directory"),
            Case::Main => checked = &fixture.main,
            Case::Outside => checked = &fixture.root,
            Case::OtherRoot => fs::write(&fixture.marker, format!("{}\n", fixture.main.display()))
                .expect("bind other root"),
            Case::OtherBranch => fixture.git(&fixture.linked, &["checkout", "-qb", "KEN-2300"]),
            Case::Detached => fixture.git(&fixture.linked, &["checkout", "-q", "--detach"]),
            Case::NonItemBranch => {
                fixture.git(&fixture.linked, &["checkout", "-qb", "feature/package"])
            }
            Case::BrokenMarker => {
                fs::write(&fixture.marker, "relative-root\n").expect("malformed marker")
            }
            Case::MarkerDirectory => {
                fs::remove_file(&fixture.marker).expect("remove marker");
                fs::create_dir(&fixture.marker).expect("directory at marker");
            }
        }
        let before = snapshot(&fixture.root);
        let result = marked_worktree(checked);
        assert_eq!(snapshot(&fixture.root), before, "marker inspection wrote");
        match case {
            Case::Marked
            | Case::NestedMarked
            | Case::BareMarked
            | Case::AdministrationMarked
            | Case::TaggedBranch => {
                assert_eq!(result.expect("marker read"), Some("KEN-2299".into()))
            }
            Case::Unmarked
            | Case::NestedUnmarked
            | Case::BareUnmarked
            | Case::AdministrationUnmarked
            | Case::IndependentBare
            | Case::IndependentAdministration
            | Case::NoMarkers
            | Case::Main
            | Case::Outside
            | Case::OtherRoot
            | Case::OtherBranch
            | Case::Detached
            | Case::NonItemBranch => {
                assert_eq!(result.expect("unmarked read"), None);
            }
            Case::BrokenMarker | Case::MarkerDirectory => assert!(result.is_err()),
        }
    }
}

#[cfg(unix)]
#[test]
#[allow(clippy::expect_used, reason = "a fixture operation must succeed")]
fn a_linked_marker_component_is_not_an_absent_marker() {
    use std::os::unix::fs::symlink;
    for component in ["file", "directory"] {
        let fixture = Fixture::new("KEN-2299");
        fixture.mark();
        let original = if component == "file" {
            fixture.marker.clone()
        } else {
            fixture
                .marker
                .parent()
                .expect("marker parent")
                .to_path_buf()
        };
        let moved = fixture.root.join("moved");
        fs::rename(&original, &moved).expect("move component");
        symlink(&moved, &original).expect("link component");
        assert!(marked_worktree(&fixture.linked).is_err());
    }
}
