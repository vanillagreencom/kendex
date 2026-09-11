//! This repository's committed inventory, held to the set it renders.
//!
//! `kendex refresh` at a checkout is the only writer of
//! `.kendex-generated.json`, and a worktree may not run it, so nothing moved
//! the committed copy when a pull request landed a new render. Its readers —
//! `hooks/doc-drift-check.sh`, commit-guards' `suppression-ban` and
//! harness-ci's `harness-only` — judge a path the inventory does not list as
//! hand-written, so a render it lost is named as uncovered code at every
//! stop.
//!
//! This is the check that refuses that state before the commit that would
//! cause it. It plans this checkout the way `refresh` does and writes
//! nothing, so the judge of what a render is stays [`super::collect`] — the
//! renderer's own — and no list of harness directories is spelled a second
//! time here.
//!
//! Not on Windows. The renders this repository commits include symlinks,
//! and a Windows checkout materialises each as a regular file holding its
//! target's path, so the tree a planner reads there is not the tree that was
//! committed and the set it derives is not this one. The Linux and macOS
//! legs judge every pull request, and `tools/guard --full` judges the commit.

use std::collections::BTreeSet;
use std::path::Path;

use crate::engine::{PlanOptions, plan_apply};
use crate::env::Env;
use crate::model::Scope;

use super::INVENTORY;

/// The first word of every line this check writes.
const NAME: &str = "render-inventory";

/// What the check found, one variant per keyed line it can open with.
#[derive(Debug, PartialEq, Eq)]
enum Finding {
    /// The checkout could not be planned, so what it renders is unknown.
    Unplanned { root: String, cause: String },
    /// The committed inventory is present and could not be read.
    Unreadable { cause: String },
    /// It is not one JSON array of path strings.
    Invalid { cause: String },
    /// It reads, and it is not the set this checkout renders.
    Drifted {
        /// Rendered here and not listed.
        missing: Vec<String>,
        /// Listed and rendered nowhere here.
        stale: Vec<String>,
    },
}

/// Whether the committed inventory is the set a pass renders.
#[derive(Debug, PartialEq, Eq)]
enum Standing {
    /// It lists every rendered path and nothing besides.
    Current,
    /// It does not, and this is what the reader is handed.
    Refused(Finding),
}

/// The stable first line every message opens with: a key naming the
/// condition and the value acted on, `<name>: <key>=<value>`.
fn line(key: &str, value: &str) -> String {
    format!("{NAME}: {key}={value}\n")
}

/// Every line this check writes, and the only place its text lives.
///
/// The keyed line stands first, at position 1, and the English follows it. A
/// drifted inventory writes one keyed line per direction that holds, in the
/// order `missing`, `stale`, then names the paths under each and the command
/// that rewrites the file. What a call this check made wrote of its own is
/// carried in as the cause and replayed under the key, never ahead of it.
fn refusal(finding: &Finding) -> String {
    let mut text = String::new();
    match finding {
        Finding::Unplanned { root, cause } => {
            text.push_str(&line("unplanned", root));
            text.push_str(
                "this checkout could not be planned, so the set it renders is unknown; \
                 refusing rather than reading the committed inventory as current\n",
            );
            text.push_str(cause);
            text.push('\n');
        }
        Finding::Unreadable { cause } => {
            text.push_str(&line("unreadable", INVENTORY));
            text.push_str("the committed inventory is present and could not be read\n");
            text.push_str(cause);
            text.push('\n');
        }
        Finding::Invalid { cause } => {
            text.push_str(&line("invalid", INVENTORY));
            text.push_str(
                "the committed inventory is not one JSON array of path strings; refusing \
                 rather than reading it as a checkout that renders nothing\n",
            );
            text.push_str(cause);
            text.push('\n');
        }
        Finding::Drifted { missing, stale } => {
            if !missing.is_empty() {
                text.push_str(&line("missing", &missing.len().to_string()));
            }
            if !stale.is_empty() {
                text.push_str(&line("stale", &stale.len().to_string()));
            }
            if !missing.is_empty() {
                text.push_str(
                    "this checkout renders these paths and the committed inventory lists \
                     none of them, so every reader of it judges each as hand-written code:\n",
                );
                for path in missing {
                    text.push_str(&format!("  {path}\n"));
                }
            }
            if !stale.is_empty() {
                text.push_str(
                    "the committed inventory lists these paths and this checkout renders \
                     none of them, so each excludes a hand-written file from the scans \
                     that read it:\n",
                );
                for path in stale {
                    text.push_str(&format!("  {path}\n"));
                }
            }
            text.push_str(&format!(
                "run `kendex refresh` at the checkout root, the one writer of {INVENTORY}, \
                 and commit that file with this change\n"
            ));
        }
    }
    text
}

/// The committed inventory against the set a pass renders.
///
/// Both directions are findings. A rendered path the inventory does not list
/// reads as hand-written to every reader of it, and a path it lists that
/// nothing renders excludes a hand-written file from their scans.
fn judge(listed: &BTreeSet<String>, rendered: &BTreeSet<String>) -> Standing {
    let missing: Vec<String> = rendered.difference(listed).cloned().collect();
    let stale: Vec<String> = listed.difference(rendered).cloned().collect();
    if missing.is_empty() && stale.is_empty() {
        return Standing::Current;
    }
    Standing::Refused(Finding::Drifted { missing, stale })
}

/// The paths the committed inventory lists.
///
/// An absent file is no read failure: a checkout that renders anything is
/// owed one, so every rendered path comes back missing and the same refusal
/// names them. Present and unreadable, or present and not the document the
/// writer lays down, refuses instead of reading as a checkout that renders
/// nothing — which would pass every drift silently.
fn committed(root: &Path) -> Result<BTreeSet<String>, Finding> {
    let text = match crate::fs::read_if_exists(&root.join(INVENTORY)) {
        Ok(Some(text)) => text,
        Ok(None) => return Ok(BTreeSet::new()),
        Err(error) => {
            return Err(Finding::Unreadable {
                cause: error.to_string(),
            });
        }
    };
    serde_json::from_str::<BTreeSet<String>>(&text).map_err(|error| Finding::Invalid {
        cause: error.to_string(),
    })
}

/// Plan this checkout as `refresh` does, and hold its committed inventory to
/// what that pass renders. The plan is taken and never executed, so the run
/// writes nothing into the scope it judges.
fn check(root: &Path) -> Standing {
    let unplanned = |cause: String| {
        Standing::Refused(Finding::Unplanned {
            root: crate::paths::slashed(root),
            cause,
        })
    };
    let env = match Env::detect() {
        Ok(env) => env,
        Err(error) => return unplanned(error.to_string()),
    };
    let scope = Scope::Project {
        root: root.to_path_buf(),
    };
    let report = match plan_apply(&env, &scope, &PlanOptions::default()) {
        Ok(report) => report,
        Err(error) => return unplanned(error.to_string()),
    };
    match committed(root) {
        Ok(listed) => judge(&listed, &report.generated.relative(root)),
        Err(finding) => Standing::Refused(finding),
    }
}

/// The check itself: this repository's `.kendex-generated.json` is the set
/// this repository renders.
#[test]
fn the_committed_inventory_is_the_set_this_checkout_renders() {
    let root = crate::test_util::checkout_root();
    match check(&root) {
        Standing::Current => {}
        Standing::Refused(finding) => panic!("{}", refusal(&finding)),
    }
}

fn set(paths: &[&str]) -> BTreeSet<String> {
    paths.iter().map(|path| (*path).to_owned()).collect()
}

/// A render the inventory does not list, and an entry nothing renders: one
/// keyed line each, in order, and the refusal that carries them.
#[test]
fn an_inventory_that_is_not_the_render_set_is_refused() {
    let rendered = set(&[".agents/skills/one/SKILL.md", INVENTORY]);
    let listed = set(&[".agents/skills/gone/SKILL.md", INVENTORY]);

    let standing = judge(&listed, &rendered);
    assert_eq!(
        standing,
        Standing::Refused(Finding::Drifted {
            missing: vec![".agents/skills/one/SKILL.md".to_owned()],
            stale: vec![".agents/skills/gone/SKILL.md".to_owned()],
        })
    );
    let Standing::Refused(finding) = standing else {
        unreachable!("the assertion above pinned the variant")
    };
    let text = refusal(&finding);
    let mut lines = text.lines();
    assert_eq!(lines.next(), Some("render-inventory: missing=1"));
    assert_eq!(lines.next(), Some("render-inventory: stale=1"));
}

/// An inventory equal to the render set passes, so the refusal above is the
/// difference and not the comparison always answering.
#[test]
fn an_inventory_equal_to_the_render_set_passes() {
    let rendered = set(&[".agents/skills/one/SKILL.md", INVENTORY]);

    assert_eq!(judge(&rendered.clone(), &rendered), Standing::Current);
}
