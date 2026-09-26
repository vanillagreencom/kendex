//! Which changed paths count as touching a package.

use std::path::PathBuf;

use super::*;
use crate::commit_offer::{Branch, Owned};
use crate::repo_effects::RepoEffects;

/// A changed path touches a package where it sits under the package's own
/// tree or under a path the package declares it writes, compared as path
/// components: a declared directory spelled with a trailing `/` covers
/// what is under it, and `docs` does not cover `docsite`.
#[test]
fn a_changed_path_touches_the_package_that_owns_or_writes_it() {
    let root = PathBuf::from("/work/site");
    let declared = DeclaredEffects {
        name: "bot-instructions".to_owned(),
        root: root.join(".agents/skills/bot-instructions"),
        effects: RepoEffects {
            summary: "renders".to_owned(),
            writes: vec![".github/instructions/".to_owned(), "docs".to_owned()],
            installer: Some("render".to_owned()),
            uninstaller: None,
            checker: None,
            removal: None,
            notes: Vec::new(),
            companions: Vec::new(),
        },
    };
    for (path, want) in [
        (".github/instructions/code-review.md", true),
        (".agents/skills/bot-instructions/SKILL.md", true),
        ("docs/guide.md", true),
        ("docsite/x", false),
        (".github/copilot-instructions.md", false),
        (".agents/skills/bot-instructions-extra/SKILL.md", false),
    ] {
        let scan = Scan {
            root: root.clone(),
            owned: vec![Owned {
                path: path.to_owned(),
                untracked: false,
                added: false,
            }],
            shared: Vec::new(),
            manifest: None,
            others: 0,
            branch: Branch::On("main".to_owned()),
        };
        assert_eq!(touched(&scan, &declared), want, "{path}");
    }
}
