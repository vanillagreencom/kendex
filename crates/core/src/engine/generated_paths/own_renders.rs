//! This repository's committed renders, held to the bytes it renders.
//!
//! A pull request leaves `.kendex-lock.json` as `main` holds it (D007), so
//! no pull-request check fails on what `kendex verify` reports about the
//! renders it commits: D007 removed the record row, and the change-class
//! render proof only picks a lane class. A render synced by hand that
//! differs from what this tree renders by a single byte passes every
//! pull-request check, and after the merge `tools/lock-record`'s refresh
//! keeps it as an edit, so the verify that follows fails on every push to
//! `main` until a later change repairs it.
//!
//! This is the check that refuses that state before the merge. It plans
//! a copy of what a commit of this checkout carries the way
//! `refresh --discard-edits` does, and writes nothing into the checkout.
//! The planner decides which inventory paths it would write, and the check
//! reports them: it reads no render and compares no bytes of its own.
//!
//! Not on Windows, for the reason `own_inventory.rs` gives: the tree a
//! Windows checkout holds is not the tree that was committed.

use std::path::{Path, PathBuf};

use crate::engine::{EngineReport, PlanOptions, plan_scope};
use crate::env::Env;
use crate::lock::{LOCK_FILE, Lock, LockFile, lock_path};
use crate::manifest::{self, Manifest, ManifestFile};
use crate::model::Scope;

/// The first word of every line this check writes.
const NAME: &str = "render-bytes";

/// What the check found, one variant per keyed line it can open with.
#[derive(Debug, PartialEq, Eq)]
enum Finding {
    /// The checkout could not be planned, so what it renders is unknown.
    Unplanned { root: String, cause: String },
    /// Inventory paths the plan would not leave as they are committed:
    /// those it writes, and those it holds back as a conflict or a file
    /// kendex did not write, which a refresh with edits discarded leaves as
    /// they are.
    Differs {
        written: Vec<String>,
        held: Vec<String>,
    },
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
        Finding::Differs { written, held } => {
            let count = written.len() + held.len();
            text.push_str(&line("differs", &count.to_string()));
            if !written.is_empty() {
                text.push_str(
                    "a refresh of this checkout with edits discarded writes these tracked \
                     paths, so the committed bytes are not the ones it renders; the \
                     refresh after the merge keeps each as an edit and `kendex verify` \
                     on main fails on it:\n",
                );
                for path in written {
                    text.push_str(&format!("  {path}\n"));
                }
                text.push_str(
                    "change the source so it renders the committed bytes, or commit the \
                     bytes `kendex refresh --discard-edits` writes at a checkout that may \
                     run it\n",
                );
            }
            if !held.is_empty() {
                text.push_str(
                    "a refresh refuses to write these paths, with edits discarded or \
                     not: a file kendex did not write sits there with other bytes than \
                     it renders, or the refresh reports a conflict there:\n",
                );
                for path in held {
                    text.push_str(&format!("  {path}\n"));
                }
                text.push_str(
                    "run `kendex refresh` at a checkout that may run it and settle the row \
                     it reports for each, then commit the bytes it writes there\n",
                );
            }
        }
    }
    text
}

/// The inventory paths `report` would not leave as they are, spelled
/// relative to `root`: each one a planned op lands on or on a tree holding
/// it, and each a render the plan holds back.
///
/// The planner is the only judge. With edits discarded it plans an op on a
/// render exactly where the bytes on disk are not the ones it renders, so
/// an op is a finding by its presence, and [`crate::apply::Op::touched`]
/// is the only account of where one lands. A tree is one op, so a render
/// tree holding a file the render does not write is named by every file
/// the inventory lists in it, and a shared configuration file's owned
/// keys are an edit like any write.
///
/// A render the plan holds back is one the refresh refuses to write: a
/// file kendex never wrote sitting where a render goes with other bytes,
/// or a conflict. Discarding edits does not lift that refusal, so it is
/// named too, apart from the writes because settling the refresh's row for
/// it is the way out.
///
/// The record is taken out of the set judged: the plan writes it whenever a
/// branch's sources move, and a pull request leaves it as `main` holds it
/// (D007).
fn judge(report: &EngineReport, root: &Path) -> Standing {
    let mut inventory = report.generated.relative(root);
    inventory.remove(LOCK_FILE);
    let relative = |path: &PathBuf| path.strip_prefix(root).ok().map(crate::paths::slashed);
    let reached: Vec<String> = report
        .plan
        .ops
        .iter()
        .flat_map(|planned| planned.op.touched())
        .filter_map(|path| relative(&path))
        .collect();
    let holds: Vec<String> = report.generated.held.iter().filter_map(relative).collect();
    let under = |listed: &String, paths: &[String]| {
        paths
            .iter()
            .any(|path| path == listed || within(listed, path))
    };
    let (held, rest): (Vec<String>, Vec<String>) = inventory
        .into_iter()
        .partition(|listed| under(listed, &holds));
    let written: Vec<String> = rest
        .into_iter()
        .filter(|listed| under(listed, &reached))
        .collect();
    if written.is_empty() && held.is_empty() {
        Standing::Current
    } else {
        Standing::Refused(Finding::Differs { written, held })
    }
}

/// Whether slashed `path` sits beneath the directory `tree`.
fn within(path: &str, tree: &str) -> bool {
    path.strip_prefix(tree)
        .is_some_and(|rest| rest.starts_with('/'))
}

/// A checkout whose plan could not be taken.
fn unplanned(root: &Path, cause: String) -> Standing {
    Standing::Refused(Finding::Unplanned {
        root: crate::paths::slashed(root),
        cause,
    })
}

/// Plan `root` from `declared` and `lock` with edits discarded, and hold
/// its committed renders to what that pass would write. The plan is taken
/// and never executed, so the run writes nothing into the scope it judges.
fn check_against(env: &Env, root: &Path, declared: &Manifest, lock: &Lock) -> Standing {
    let scope = Scope::Project {
        root: root.to_path_buf(),
    };
    let options = PlanOptions {
        overwrite_edited: true,
        ..PlanOptions::current()
    };
    match plan_scope(env, &scope, declared, lock, &options) {
        Ok(report) => judge(&report, root),
        Err(error) => unplanned(root, error.to_string()),
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

/// This checkout's own install record, as `plan_apply` reads it.
fn record(env: &Env, root: &Path) -> Result<Lock, String> {
    let scope = Scope::Project {
        root: root.to_path_buf(),
    };
    match crate::lock::load_file(&lock_path(env, &scope)) {
        Ok(LockFile::Current(lock)) => Ok(lock),
        Ok(LockFile::Absent) => Err("the checkout holds no install record".into()),
        Err(error) => Err(error.to_string()),
    }
}

/// A copy of the files a commit of `root` carries: every tracked file and
/// every untracked one Git does not ignore, as the working tree holds them.
/// The path returned is the copy's root.
///
/// The planner reads every file in a render tree but the tool caches a
/// skill's source leaves out (`source_read::TOOL_CACHES`), so any other
/// ignored file there, such as an editor's swap file, makes it plan the
/// tree over again. No commit carries that file, and no clone
/// `tools/lock-record` refreshes holds it, so the check judges this copy
/// and leaves the checkout's leftovers out.
///
/// The scratch directory is a Git repository with every copied file staged,
/// and the copy sits one directory below it, as a project in a subdirectory
/// of a repository does. Git lists the copy's nested instruction files to
/// the planner as it lists the checkout's. The copy's root holds no `.git`,
/// so its plan writes no inventory, which `own_inventory.rs` judges, and
/// keeps every position it holds back: where the root holds `.git`, the
/// plan keeps only those the inventory at `HEAD` lists, and that drops the
/// render of a package the branch adds.
fn committed_copy(root: &Path) -> Result<(tempfile::TempDir, PathBuf), String> {
    let tmp = tempfile::tempdir().map_err(|error| format!("scratch directory: {error}"))?;
    let repository = crate::test_util::rooted(&tmp);
    let copy = repository.join("checkout");
    let listed = crate::test_util::git(
        root,
        &[
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ],
    );
    // Git lists an untracked nested repository, such as a linked worktree,
    // as its directory with a trailing slash: none of its files is this
    // checkout's.
    let carried = listed
        .split('\0')
        .filter(|carried| !carried.is_empty() && !carried.ends_with('/'));
    for carried in carried {
        let from = root.join(carried);
        let meta = match std::fs::symlink_metadata(&from) {
            Ok(meta) => meta,
            // A tracked file deleted in the working tree is not carried.
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(format!("read {carried}: {error}")),
        };
        let to = copy.join(carried);
        let copied = to
            .parent()
            .map_or(Ok(()), std::fs::create_dir_all)
            .and_then(|()| match meta.file_type().is_symlink() {
                true => std::fs::read_link(&from)
                    .and_then(|target| std::os::unix::fs::symlink(target, &to)),
                false => std::fs::copy(&from, &to).map(|_| ()),
            });
        copied.map_err(|error| format!("copy {carried}: {error}"))?;
    }
    crate::test_util::git(&repository, &["init", "-q"]);
    crate::test_util::git(&repository, &["add", "-A", "-f"]);
    Ok((tmp, copy))
}

/// A checkout held to its own declaration and record, read off a copy of
/// what a commit of it carries.
fn check(root: &Path) -> Standing {
    let env = match Env::detect() {
        Ok(env) => env,
        Err(error) => return unplanned(root, error.to_string()),
    };
    let (_tmp, copy) = match committed_copy(root) {
        Ok(copied) => copied,
        Err(cause) => return unplanned(root, cause),
    };
    match (declaration(&env, &copy), record(&env, &copy)) {
        (Ok(declared), Ok(lock)) => check_against(&env, &copy, &declared, &lock),
        (Err(cause), _) | (_, Err(cause)) => unplanned(root, cause),
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

/// One skill this checkout's declaration configures instructions for,
/// read off the declaration rather than named here so each control follows
/// whatever this repository configures.
#[allow(clippy::expect_used)]
fn instructed_skill(declared: &Manifest) -> String {
    declared
        .skill_instructions
        .keys()
        .find(|skill| !matches!(skill.as_str(), "all" | "*"))
        .expect("the manifest configures one skill's instructions")
        .clone()
}

/// What a control plants its defect into: the host environment, a copy of
/// this checkout as [`check`] plans it, and that copy's declaration and
/// record, to change in memory before the plan.
struct Planted {
    env: Env,
    _tmp: tempfile::TempDir,
    copy: PathBuf,
    declared: Manifest,
    lock: Lock,
}

impl Planted {
    #[allow(clippy::expect_used)]
    fn new() -> Self {
        let env = Env::detect().expect("the host environment is readable");
        let (tmp, copy) =
            committed_copy(&crate::test_util::checkout_root()).expect("the checkout copies");
        let declared = declaration(&env, &copy).expect("the copy's manifest reads");
        let lock = record(&env, &copy).expect("the copy's install record reads");
        Planted {
            env,
            _tmp: tmp,
            copy,
            declared,
            lock,
        }
    }

    /// Grow `skill`'s project instructions by a line no committed render
    /// carries.
    #[allow(clippy::expect_used)]
    fn grow(&mut self, skill: &str) {
        self.declared
            .skill_instructions
            .get_mut(skill)
            .expect("the skill was read off this map")
            .push_str("\nA line no committed render carries.\n");
    }

    /// The paths the check names over the planted copy, written and held;
    /// any standing but a differs refusal fails the test.
    fn named(&self) -> (Vec<String>, Vec<String>) {
        match check_against(&self.env, &self.copy, &self.declared, &self.lock) {
            Standing::Refused(Finding::Differs { written, held }) => (written, held),
            other => panic!("expected a differs refusal, got {other:?}"),
        }
    }
}

/// The refusing direction, through the same path: this checkout's own
/// declaration with one skill's project instructions grown by a line,
/// planned against the committed renders untouched: an instruction source
/// whose render was synced by hand to other bytes. The render path is
/// spelled independently of the renderer.
#[test]
fn a_render_its_source_no_longer_renders_is_refused() {
    let mut planted = Planted::new();
    let skill = instructed_skill(&planted.declared);
    planted.grow(&skill);

    let (written, _) = planted.named();
    let render = format!(".agents/skills/{skill}/SKILL.md");
    assert!(written.contains(&render), "{render} not in {written:?}");
}

/// A package a branch adds, its render synced by hand to other bytes and
/// left out of the record and the inventory, which D007 leaves as `main`
/// holds them: the planner reads the render as a file kendex never wrote
/// and holds it back rather than writing it, and no inventory at `HEAD`
/// lists it. The package is planted in the copy.
#[test]
#[allow(clippy::expect_used)]
fn a_render_of_a_package_the_record_does_not_hold_is_refused() {
    let mut planted = Planted::new();
    let skill = "planted-package";
    let render = format!(".agents/skills/{skill}/SKILL.md");
    let committed = crate::commit_offer::committed_inventory(&crate::test_util::checkout_root())
        .expect("the inventory at HEAD reads");
    assert!(
        !committed.contains(&render),
        "HEAD's inventory lists {render}"
    );
    let frontmatter = format!("---\nname: {skill}\ndescription: \"A planted package.\"\n---\n");
    for (path, body) in [
        (format!("skills/{skill}/SKILL.md"), "Rendered.\n"),
        (render.clone(), "Synced by hand.\n"),
    ] {
        let path = planted.copy.join(path);
        std::fs::create_dir_all(path.parent().expect("a planted file has a parent"))
            .expect("the planted directory is writable");
        std::fs::write(&path, format!("{frontmatter}\n{body}")).expect("the planted file writes");
    }
    let manifest = planted.copy.join("kendex-local.toml");
    let mut text = std::fs::read_to_string(&manifest).expect("the copy's manifest reads");
    text.push_str(&format!(
        "\n[skills.{skill}]\nsource = \".\"\nharnesses = [\"codex\"]\nenabled = true\n"
    ));
    std::fs::write(&manifest, text).expect("the copy's manifest writes");
    planted.declared =
        declaration(&planted.env, &planted.copy).expect("the planted manifest reads");

    let (_, held) = planted.named();
    assert!(held.contains(&render), "{render} not in {held:?}");
}

/// A render tree holding a file the render does not write, as a hand sync
/// with `cp -r` leaves one: every file the render writes there is the
/// bytes it renders.
#[test]
fn a_render_tree_holding_a_file_it_does_not_render_is_refused() {
    let planted = Planted::new();
    let skill = instructed_skill(&planted.declared);
    let tree = format!(".agents/skills/{skill}");
    let extra = planted.copy.join(&tree).join("not-rendered.md");
    assert!(!extra.exists(), "the render already holds {extra:?}");
    std::fs::write(&extra, "copied by hand\n").expect("the planted file is writable");

    let (written, _) = planted.named();
    let render = format!("{tree}/SKILL.md");
    assert!(written.contains(&render), "{render} not in {written:?}");
}

/// A nested instruction shim deleted while its `AGENTS.md` stays: the
/// planner finds nested instruction files through Git, so this holds the
/// copy to the discovery the checkout gets. The shim is read off the
/// checkout's tracked files rather than named here.
#[test]
#[allow(clippy::expect_used)]
fn a_nested_instruction_shim_deleted_is_refused() {
    let planted = Planted::new();
    let listed = crate::test_util::git(
        &crate::test_util::checkout_root(),
        &["ls-files", "-z", "--", "*/CLAUDE.md"],
    );
    let shim = listed
        .split('\0')
        .find(|path| {
            !path.is_empty()
                && !path.starts_with('.')
                && planted
                    .copy
                    .join(path)
                    .with_file_name("AGENTS.md")
                    .is_file()
        })
        .expect("the checkout tracks a nested CLAUDE.md beside an AGENTS.md")
        .to_owned();
    std::fs::remove_file(planted.copy.join(&shim)).expect("the planted shim is removable");

    let (written, _) = planted.named();
    assert!(written.contains(&shim), "{shim} not in {written:?}");
}
