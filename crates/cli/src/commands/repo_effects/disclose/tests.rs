use super::*;
use crate::ui::testing::{plain, rich, tagged};
use kendex_core::repo_effects::{Companion, RepoEffects, Written};

#[test]
fn the_disclosure_keeps_every_write_shared_mark_and_unread_key_in_both_renderings() {
    let disclosure = Disclosure {
        declared: DeclaredEffects {
            name: "guards".into(),
            root: "/pkg/guards".into(),
            effects: RepoEffects {
                summary: "arms hooks".into(),
                writes: vec![],
                installer: None,
                uninstaller: None,
                checker: None,
                staged_checker: None,
                removal: None,
                notes: vec![],
                companions: vec![],
                unknown_keys: vec![],
            },
        },
        name: "guards".into(),
        summary: "arms hooks".into(),
        writes: vec![
            Written {
                path: "/repo/.git/hooks/pre-commit".into(),
                shared: true,
            },
            Written {
                path: "/repo/.github/rules.md".into(),
                shared: false,
            },
        ],
        companions: vec![Companion {
            name: "preflight".into(),
            installed: true,
        }],
        notes: vec!["Checks each commit.".into()],
        unknown_keys: vec!["writse".into()],
        undo: None,
    };
    assert_eq!(
        disclosure_lines(&plain(), &disclosure),
        [
            "",
            "guards changes how this repository works, beyond the files above:",
            "  arms hooks",
            "",
            "  writes",
            "    /repo/.git/hooks/pre-commit  (shared)",
            "    /repo/.github/rules.md",
            "",
            "  the paths marked shared are the repository's, not this",
            "  checkout's: every work tree of it sees those files",
            "",
            "  companion packages",
            "    preflight (installed)",
            "",
            "  Checks each commit.",
            "",
            "  keys this kendex does not read",
            "    writse",
            "    a newer kendex may read them; a key spelled wrong is read by none",
            "",
            "  to undo: the package declares no way to undo it",
        ]
    );
    assert_eq!(
        tagged(&disclosure_lines(&rich(80), &disclosure)),
        [
            "",
            "<33>!</> <1>guards changes how this repository works, beyond the files above:</>",
            "  arms hooks",
            "",
            "  <36>•</> writes",
            "    <90>/repo/.git/hooks/pre-commit (shared)</>",
            "    <90>/repo/.github/rules.md</>",
            "",
            "    <90>the paths marked shared are the repository's, not this</>",
            "    <90>checkout's: every work tree of it sees those files</>",
            "",
            "  <36>•</> companion packages",
            "    <90>preflight (installed)</>",
            "",
            "    <90>Checks each commit.</>",
            "",
            "  <36>•</> keys this kendex does not read",
            "    <90>writse</>",
            "    <90>a newer kendex may read them; a key spelled wrong is read by none</>",
            "",
            "    <90>to undo: the package declares no way to undo it</>",
        ]
    );
}
