//! This repository's committed renders, held to the bytes it renders.
//!
//! A pull request leaves `.kendex-lock.json` as `main` holds it (D007), so
//! nothing on a branch runs `kendex verify` over the renders it commits.
//! A render synced by hand that differs from what this tree renders by a
//! single byte passes every pull-request check, and after the merge
//! `tools/lock-record`'s refresh keeps it as an edit, so the verify that
//! follows fails on every push to `main` until a later change repairs it.
//!
//! This is the check that refuses that state before the merge. It plans
//! this checkout the way `refresh --discard-edits` does and writes nothing:
//! with edits discarded the planner writes every render whose bytes on disk
//! are not the ones it renders, so the judge of a render's bytes stays the
//! planner's own comparison, and this reads only what the plan would write.
//!
//! Not on Windows, for the reason `own_inventory.rs` gives: the tree a
//! Windows checkout holds is not the tree that was committed.

use std::collections::BTreeSet;
use std::path::Path;

use crate::apply::Op;
use crate::engine::{EngineReport, PlanOptions, plan_scope};
use crate::env::Env;
use crate::lock::{LockFile, lock_path};
use crate::manifest::{self, Manifest, ManifestFile};
use crate::model::Scope;

/// The first word of every line this check writes.
const NAME: &str = "render-bytes";

/// What the check found, one variant per keyed line it can open with.
#[derive(Debug, PartialEq, Eq)]
enum Finding {
    /// The checkout could not be planned, so what it renders is unknown.
    Unplanned { root: String, cause: String },
    /// Renders the plan would not write even with edits discarded, so their
    /// bytes went unjudged.
    Held { paths: Vec<String> },
    /// Tracked renders whose bytes on disk are not the bytes this checkout
    /// renders.
    Differs { paths: Vec<String> },
}

/// Whether every committed render is the bytes this checkout renders.
#[derive(Debug, PartialEq, Eq)]
enum Standing {
    Current,
    Refused(Finding),
}

/// The stable first line every message opens with, `<name>: <key>=<value>`.
fn line(key: &str, value: &str) -> String {
    format!("{NAME}: {key}={value}\n")
}

/// Every line this check writes, and the only place its text lives.
fn refusal(finding: &Finding) -> String {
    let mut text = String::new();
    match finding {
        Finding::Unplanned { root, cause } => {
            text.push_str(&line("unplanned", root));
            text.push_str(
                "this checkout could not be planned, so the bytes it renders are unknown\n",
            );
            text.push_str(cause);
            text.push('\n');
        }
        Finding::Held { paths } => {
            text.push_str(&line("held", &paths.len().to_string()));
            text.push_str(
                "the plan refuses to write these renders even with edits discarded, so \
                 their bytes are not judged:\n",
            );
            for path in paths {
                text.push_str(&format!("  {path}\n"));
            }
        }
        Finding::Differs { paths } => {
            text.push_str(&line("differs", &paths.len().to_string()));
            text.push_str(
                "this checkout renders these tracked paths to other bytes than the \
                 committed ones, so the refresh after the merge keeps each as an edit \
                 and `kendex verify` on main fails on it:\n",
            );
            for path in paths {
                text.push_str(&format!("  {path}\n"));
            }
            text.push_str(
                "change the source so it renders the committed bytes, or commit the bytes \
                 `kendex refresh --discard-edits` writes at a checkout that may run it\n",
            );
        }
    }
    text
}

/// The renders `report` writes whose bytes differ from the ones on disk,
/// and the renders it holds back, each spelled relative to `root`.
///
/// A write is judged only where it lands on a path the inventory lists: the
/// record is left to `main` (D007), and every other op is a neighbouring
/// check's. A tree is judged file by file, since its op rewrites the whole
/// tree for one file that moved.
fn judge(report: &EngineReport, root: &Path) -> Standing {
    let relative = |path: &Path| path.strip_prefix(root).ok().map(crate::paths::slashed);
    let held: Vec<String> = report
        .generated
        .held
        .iter()
        .filter_map(|path| relative(path))
        .collect();
    if !held.is_empty() {
        return Standing::Refused(Finding::Held { paths: held });
    }
    let declared = report.generated.relative(root);
    let mut differs = BTreeSet::new();
    let mut note = |path: &Path, same: bool| {
        if let Some(spelled) = relative(path)
            && declared.contains(&spelled)
            && !same
        {
            differs.insert(spelled);
        }
    };
    for planned in &report.plan.ops {
        match &planned.op {
            Op::WriteFile { path, bytes, .. } | Op::WriteExecutable { path, bytes, .. } => {
                note(path, std::fs::read(path).is_ok_and(|disk| disk == *bytes));
            }
            Op::WriteTree {
                root: tree, files, ..
            } => {
                for (file, bytes) in files {
                    let path = tree.join(file);
                    note(&path, std::fs::read(&path).is_ok_and(|disk| disk == *bytes));
                }
            }
            Op::Symlink { link, target, .. } => {
                note(
                    link,
                    std::fs::read_link(link).is_ok_and(|disk| disk == *target),
                );
            }
            _ => {}
        }
    }
    if differs.is_empty() {
        Standing::Current
    } else {
        Standing::Refused(Finding::Differs {
            paths: differs.into_iter().collect(),
        })
    }
}

/// Plan `root` from `declared` with edits discarded, and hold its committed
/// renders to what that pass would write. The plan is taken and never
/// executed, so the run writes nothing into the scope it judges.
fn check_against(env: &Env, root: &Path, declared: &Manifest) -> Standing {
    let unplanned = |cause: String| {
        Standing::Refused(Finding::Unplanned {
            root: crate::paths::slashed(root),
            cause,
        })
    };
    let scope = Scope::Project {
        root: root.to_path_buf(),
    };
    let lock = match crate::lock::load_file(&lock_path(env, &scope)) {
        Ok(LockFile::Current(lock)) => lock,
        Ok(LockFile::Absent) => return unplanned("the checkout holds no install record".into()),
        Err(error) => return unplanned(error.to_string()),
    };
    let options = PlanOptions {
        overwrite_edited: true,
        ..PlanOptions::default()
    };
    match plan_scope(env, &scope, declared, &lock, &options) {
        Ok(report) => judge(&report, root),
        Err(error) => unplanned(error.to_string()),
    }
}

/// This checkout's own declaration, as `plan_apply` reads it.
fn declaration(env: &Env, root: &Path) -> Result<Manifest, String> {
    let scope = Scope::Project {
        root: root.to_path_buf(),
    };
    match manifest::load(&manifest::manifest_path(env, &scope)) {
        Ok(ManifestFile::Current(manifest)) => Ok(*manifest),
        Ok(ManifestFile::Absent) => Err("the checkout holds no manifest".into()),
        Err(error) => Err(error.to_string()),
    }
}

/// A checkout held to its own declaration.
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
    match declaration(&env, root) {
        Ok(declared) => check_against(&env, root, &declared),
        Err(cause) => unplanned(cause),
    }
}

/// The check itself: every render this repository commits is the bytes
/// this repository renders. The passing direction, through the whole path.
#[test]
fn the_committed_renders_are_the_bytes_this_checkout_renders() {
    let root = crate::test_util::checkout_root();
    if let Standing::Refused(finding) = check(&root) {
        panic!("{}", refusal(&finding));
    }
}

/// The refusing direction, through the same path: this checkout's own
/// declaration with one skill's project instructions grown by a line,
/// planned against the committed renders untouched: an instruction source
/// whose render was synced by hand to other bytes.
///
/// The skill is read off the declaration rather than named here, so the
/// control follows whatever this repository configures; its render path is
/// spelled independently of the renderer.
#[test]
fn a_render_its_source_no_longer_renders_is_refused() {
    let root = crate::test_util::checkout_root();
    let env = Env::detect().expect("the host environment is readable");
    let mut declared = declaration(&env, &root).expect("the checkout's manifest reads");
    let (skill, instructions) = declared
        .skill_instructions
        .iter_mut()
        .find(|(skill, _)| !matches!(skill.as_str(), "all" | "*"))
        .expect("the manifest configures one skill's instructions");
    let skill = skill.clone();
    instructions.push_str("\nA line no committed render carries.\n");

    let standing = check_against(&env, &root, &declared);
    assert_eq!(
        standing,
        Standing::Refused(Finding::Differs {
            paths: vec![format!(".agents/skills/{skill}/SKILL.md")],
        })
    );
    let Standing::Refused(finding) = standing else {
        unreachable!("the assertion above pinned the variant")
    };
    assert_eq!(
        refusal(&finding).lines().next(),
        Some("render-bytes: differs=1")
    );
}
