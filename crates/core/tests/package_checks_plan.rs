//! What the app shows before it offers to switch a project's package
//! checks on: every file the install writes, read from the planner rather
//! than described from memory, and what else the project already has
//! waiting.

#![cfg(unix)]

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::drift;
use kendex_core::drift::setup::{FileRole, SetupPlan};
use kendex_core::engine;
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::manifest;
use kendex_core::model::HarnessId;
use kendex_core::model::Scope;
use kendex_core::process::Hardened;

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

const REPO: &str = "owner/catalog";

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    root: PathBuf,
    scope: Scope,
}

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let output = Hardened::git(args, Some(dir)).run().unwrap();
    assert!(output.status.success(), "git {args:?}");
}

#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let upstream: PathBuf = home.join("git").join(REPO);
    fs::create_dir_all(&upstream).unwrap();
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    fs::create_dir_all(home.join(".claude")).unwrap();
    let root = home.join("app");
    fs::create_dir_all(root.join(".claude")).unwrap();
    let base = format!("file://{}", home.join("git").display());
    World {
        env: Env::fake(&home, FakeOs::Linux).with_var("KENDEX_GIT_BASE", &base),
        scope: Scope::Project { root: root.clone() },
        root,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn declare(w: &World, body: &str) {
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\", \"pi\"]\nmethod = \"symlink\"\n\n{body}"
        ),
    )
    .unwrap();
}

/// The preview's positions, as absolute paths again. The list is shown
/// relative to the project root, which is what the reader needs and what
/// makes a comparison against the plan's own paths worth making.
fn positions(plan: &SetupPlan, root: &Path) -> BTreeSet<PathBuf> {
    plan.files
        .iter()
        .map(|file| match Path::new(&file.path).is_absolute() {
            true => PathBuf::from(&file.path),
            false => root.join(&file.path),
        })
        .collect()
}

fn role_of(plan: &SetupPlan, role: FileRole) -> Vec<&str> {
    plan.files
        .iter()
        .filter(|file| file.role == role)
        .map(|file| file.path.as_str())
        .collect()
}

/// The disclosure is the install's own plan. The floor is derived from the
/// install rather than from a second list here: everything the declaration
/// and the render it triggers actually write must have been on the list
/// the person was shown, and nothing on that list may belong to a tool the
/// declaration does not name.
#[test]
#[allow(clippy::unwrap_used)]
fn the_preview_lists_every_position_the_install_writes_and_no_other_tool() {
    let w = world();
    declare(&w, "");

    let preview = drift::setup::setup_plan(&w.env, &w.scope).unwrap();
    assert_eq!(
        preview.harnesses,
        drift::hook::target_harnesses(&w.scope),
        "the preview names the tools the declaration does"
    );
    let shown = positions(&preview, &w.root);

    // Nothing was written by the read: a preview is a read.
    assert!(
        !manifest::manifest_path(&w.env, &w.scope)
            .parent()
            .unwrap()
            .join(".kendex-local")
            .exists()
    );

    // Now do it for real and collect what the writes touched.
    let install = drift::hook::install_plan(&w.env, &w.scope).unwrap();
    let mut written: BTreeSet<PathBuf> = install
        .ops
        .iter()
        .flat_map(|planned| planned.op.touched())
        .collect();
    apply::execute(&w.env, &install).unwrap();
    let render = engine::plan_apply(&w.env, &w.scope, &engine::PlanOptions::default()).unwrap();
    written.extend(
        render
            .plan
            .ops
            .iter()
            .flat_map(|planned| planned.op.touched()),
    );
    apply::execute(&w.env, &render.plan).unwrap();

    for position in &written {
        assert!(
            shown.contains(position),
            "the install wrote {} and the preview did not list it: {shown:?}",
            position.display()
        );
    }
    // A required member of the floor, so a preview that listed nothing
    // could not pass by writing nothing either.
    assert!(
        written.contains(&kendex_core::lock::lock_path(&w.env, &w.scope)),
        "the install records what it did: {written:?}"
    );

    // What the preview named, against what the install actually recorded.
    // Checking each row's harness against preview.harnesses instead would
    // be checking that list against itself: the rows are built from it, so
    // a preview reading a list the renderer does not obey would agree with
    // itself all the way through.
    let recorded: BTreeSet<HarnessId> = match kendex_core::lock::load_file(
        &kendex_core::lock::lock_path(&w.env, &w.scope),
    )
    .unwrap()
    {
        kendex_core::lock::LockFile::Current(lock) => lock
            .entries
            .values()
            .filter(|entry| {
                entry.kind == kendex_core::model::ItemKind::Hook
                    && entry.name == drift::hook::HOOK_NAME
            })
            .map(|entry| entry.harness)
            .collect(),
        kendex_core::lock::LockFile::Absent => BTreeSet::new(),
    };
    assert_eq!(
        preview.harnesses.iter().copied().collect::<BTreeSet<_>>(),
        recorded,
        "the preview named one set of tools and the install registered another"
    );

    // Each role is on the list, and every row says either what it will
    // hold or why it cannot be shown.
    assert_eq!(
        role_of(&preview, FileRole::Declaration),
        vec!["kendex.toml"]
    );
    assert_eq!(role_of(&preview, FileRole::CheckScript).len(), 1);
    assert_eq!(role_of(&preview, FileRole::InstallRecord).len(), 1);
    for harness in &preview.harnesses {
        assert!(
            preview
                .files
                .iter()
                .any(|file| file.role == FileRole::StartupRegistration
                    && file.harness == Some(*harness)),
            "{harness:?} has no startup registration on the list: {:?}",
            preview.files
        );
    }
    for file in &preview.files {
        assert!(
            file.preview.is_some() != file.no_preview.is_some(),
            "{} says neither what it holds nor why it cannot: {file:?}",
            file.path
        );
    }
    let script = preview
        .files
        .iter()
        .find(|file| file.role == FileRole::CheckScript)
        .unwrap();
    assert_eq!(script.preview.as_deref(), Some(drift::hook::HOOK_SCRIPT));
}

/// A yes to the checks is not a yes to whatever else is waiting. The count
/// the confirmation shows is the scope's own pending work with the check's
/// positions taken out, so a clean scope reads zero and an unrelated
/// declaration reads what it is.
#[test]
#[allow(clippy::unwrap_used)]
fn other_pending_counts_the_work_the_checks_did_not_ask_for() {
    let w = fresh_git_world();
    declare(&w, "");
    let clean = drift::setup::setup_plan(&w.env, &w.scope).unwrap();
    assert_eq!(clean.other_pending, 0, "{:?}", clean);

    declare(
        &w,
        "[[custom-hooks]]\nname = \"guard\"\nevent = \"PreToolUse\"\nmatcher = \"Bash\"\ncommand = \"./guard.sh\"\n",
    );
    let waiting = drift::setup::setup_plan(&w.env, &w.scope).unwrap();
    assert!(waiting.other_pending > 0, "{waiting:?}");
    assert_eq!(
        positions(&waiting, &w.root),
        positions(&clean, &w.root),
        "the unrelated hook is counted, never listed as a file the checks write"
    );
}

/// A registered project whose folder has moved: the read refuses in the
/// same words the install does, so a card left standing over the old path
/// cannot open a dialog offering to rebuild it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_preview_at_a_moved_project_refuses() {
    let w = world();
    declare(&w, "");
    fs::rename(&w.root, w.root.parent().unwrap().join("moved")).unwrap();

    let refused = drift::setup::setup_plan(&w.env, &w.scope).unwrap_err();
    assert!(
        matches!(&refused, CoreError::ProjectRootMissing { path } if path == &w.root),
        "{refused:?}"
    );
    assert!(!w.root.exists());
}

/// Install the checks for real at `w`, and answer the scope's plan after.
#[allow(clippy::unwrap_used)]
fn install(w: &World) -> engine::EngineReport {
    let plan = drift::hook::install_plan(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let render = engine::plan_apply(&w.env, &w.scope, &engine::PlanOptions::default()).unwrap();
    apply::execute(&w.env, &render.plan).unwrap();
    engine::plan_apply(&w.env, &w.scope, &engine::PlanOptions::default()).unwrap()
}

/// The position one tool's registration occupies, taken from the preview
/// rather than spelled here: the point of the answer under test is that no
/// surface keeps a second list of destinations, and a test that wrote one
/// would be that second list.
#[allow(clippy::unwrap_used)]
fn registration_of(w: &World, harness: HarnessId) -> PathBuf {
    let preview = drift::setup::setup_plan(&w.env, &w.scope).unwrap();
    let file = preview
        .files
        .iter()
        .find(|file| {
            file.role == FileRole::StartupRegistration
                && file.harness == Some(harness)
                && file.no_preview.is_some()
        })
        .unwrap_or_else(|| panic!("no registration listed for {harness:?}"));
    w.root.join(&file.path)
}

/// What the surface says after a write is read back from the scope, per
/// tool. An installer's return value says a plan ran; it cannot say every
/// promised target is live, and one tool losing its registration is the
/// difference between "On" and "Setup incomplete".
#[test]
#[allow(clippy::unwrap_used)]
fn every_target_registered_reads_each_tool_and_not_just_one() {
    let w = world();
    // A project with a package installed and the checks off — what a card
    // reading "Off" sits over. The install record exists and names none of
    // the check's targets, and nothing complains about a check nobody
    // declared. Silence is not coverage: the answer has to come from the
    // record of an install, not from the absence of a complaint.
    declare(
        &w,
        "[[custom-hooks]]\nname = \"guard\"\nevent = \"PreToolUse\"\nmatcher = \"Bash\"\ncommand = \"./guard.sh\"\n",
    );
    let other = engine::plan_apply(&w.env, &w.scope, &engine::PlanOptions::default()).unwrap();
    apply::execute(&w.env, &other.plan).unwrap();
    let quiet = engine::plan_apply(&w.env, &w.scope, &engine::PlanOptions::default()).unwrap();
    assert!(
        kendex_core::lock::lock_path(&w.env, &w.scope).exists(),
        "the fixture needs an install record that names no target of the check"
    );
    assert!(
        !drift::setup::every_target_registered(&w.env, &w.scope, &quiet).unwrap(),
        "the check is installed nowhere and no row says so, and the answer read as registered: {:?}",
        quiet.drift
    );

    let after = install(&w);
    assert!(
        drift::setup::every_target_registered(&w.env, &w.scope, &after).unwrap(),
        "a complete install reads as complete: {:?}",
        after.drift
    );

    // One tool's registration taken away, the other left exactly as it is.
    let gone = registration_of(&w, HarnessId::Pi);
    fs::remove_file(&gone).unwrap();
    let short = engine::plan_apply(&w.env, &w.scope, &engine::PlanOptions::default()).unwrap();
    assert!(
        !drift::setup::every_target_registered(&w.env, &w.scope, &short).unwrap(),
        "{} is gone and the answer still reads complete: {:?}",
        gone.display(),
        short.drift
    );
}

/// A project as the app registers one: a git checkout kendex has never
/// applied, with no kendex.toml of its own. The flow KEN-1279 built.
#[allow(clippy::unwrap_used)]
fn fresh_git_world() -> World {
    let w = world();
    git(&w.root, &["init", "--quiet", "-b", "main"]);
    w
}

/// The count the confirmation shows, and the decision the install makes
/// from it, are about the person's own waiting work. Seeding a kendex.toml
/// for a scope that has none — and the ledger line the planner then wants
/// in .gitignore — is what enabling the checks brings about, not work that
/// was already there. Counting it left every freshly registered project
/// with the script and the declaration on disk and no registration in any
/// tool.
#[test]
#[allow(clippy::unwrap_used)]
fn a_never_applied_git_project_has_nothing_of_its_own_waiting() {
    let w = fresh_git_world();
    assert!(!w.root.join("kendex.toml").exists());
    assert!(
        w.root.join(".git").is_dir(),
        "the fixture is a git checkout"
    );

    let waiting = drift::setup::pending_without_checks(&w.env, &w.scope).unwrap();
    assert!(
        waiting.plan.is_empty(),
        "kendex's own bookkeeping counted as the person's pending work: {:?}",
        waiting
            .plan
            .ops
            .iter()
            .map(|op| op.line())
            .collect::<Vec<_>>()
    );

    // And the install that reads it therefore finishes: the registration
    // reaches every tool, which is what the card then reads as On.
    let after = install(&w);
    assert!(
        drift::setup::every_target_registered(&w.env, &w.scope, &after).unwrap(),
        "the render never ran: {:?}",
        after.drift
    );
}

/// The second window. Installing runs two plans, and the render is the one
/// that puts the registration into each tool; both callers execute it
/// after a confirmation a person answers. Every op in it creates the
/// directories above itself, so an unguarded render rebuilds a root that
/// went away while the prompt was waiting.
#[test]
#[allow(clippy::unwrap_used)]
fn a_folder_that_goes_away_before_the_render_refuses_at_the_apply() {
    let w = fresh_git_world();
    let declaration = drift::hook::install_plan(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &declaration).unwrap();

    let render = engine::plan_apply(&w.env, &w.scope, &engine::PlanOptions::default()).unwrap();
    assert!(!render.plan.is_empty(), "nothing to render");

    // Strictly this interval: the plan is built, then the folder goes,
    // then the plan runs. Removing the root any earlier proves nothing —
    // the second plan reads no kendex.toml there and comes back empty.
    fs::remove_dir_all(&w.root).unwrap();
    let refused = apply::execute(&w.env, &render.plan).unwrap_err();
    let CoreError::RolledBack { cause, .. } = &refused else {
        panic!("{refused:?}");
    };
    assert!(
        matches!(cause.as_ref(), CoreError::ProjectRootMissing { path } if path == &w.root),
        "{cause:?}"
    );
    assert!(
        !w.root.exists(),
        "the old path was rebuilt: {}",
        w.root.display()
    );
}

/// A declaration already on the file, switched off and naming fewer tools
/// than the script runs in. The planner takes a declaration's own
/// harnesses list as it stands, so nothing narrows it back and nothing
/// widens it either: left alone, the confirmation lists a file per tool
/// while the render places half of them, and the answer afterwards reads
/// complete because the tool nobody asked for raises no row at all.
#[test]
#[allow(clippy::unwrap_used)]
fn a_narrowed_declaration_is_brought_up_to_the_tools_the_script_runs_in() {
    let w = fresh_git_world();
    let targets = drift::hook::target_harnesses(&w.scope);
    assert!(targets.len() > 1, "the fixture needs more than one target");
    declare(
        &w,
        &format!(
            "[hooks.{}]\nsource = \"local\"\nenabled = false\nharnesses = [\"{}\"]\n",
            drift::hook::HOOK_NAME,
            targets[0].name()
        ),
    );

    // Nothing is registered anywhere, and the answer must say so rather
    // than read the narrowed tool's silence as coverage.
    let before = engine::plan_apply(&w.env, &w.scope, &engine::PlanOptions::default()).unwrap();
    assert!(
        !drift::setup::every_target_registered(&w.env, &w.scope, &before).unwrap(),
        "an unasked-for target has no row, and no row read as registered: {:?}",
        before.drift
    );

    let after = install(&w);
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    assert_eq!(
        loaded.hooks.get(drift::hook::HOOK_NAME).unwrap().harnesses,
        Some(targets.clone()),
        "the declaration still names fewer tools than the confirmation listed files for"
    );
    assert!(
        drift::setup::every_target_registered(&w.env, &w.scope, &after).unwrap(),
        "{:?}",
        after.drift
    );
}

/// A position nothing can settle blocks its own item and nothing else.
///
/// Enabling the checks used to be held back by one of these, because the
/// only op such a scope carried was kendex's own ignore line and that
/// counted as the person's waiting work. With the housekeeping out, the
/// plan is empty and the render runs — so the confirmation must not tell
/// the person their registration waits on positions it never touches.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unrelated_conflict_is_named_and_does_not_hold_the_registration() {
    let w = fresh_git_world();
    let source = w.root.join(".kendex-local/skills/mine");
    fs::create_dir_all(&source).unwrap();
    fs::write(
        source.join("SKILL.md"),
        "---\nname: mine\ndescription: a skill of my own\n---\n\nBody.\n",
    )
    .unwrap();
    declare(
        &w,
        "[skills.mine]\nsource = \"local\"\nharnesses = [\"claude\"]\n",
    );
    // A link kendex will not follow, where that skill installs. Its own
    // position is unsettled; the check installs nowhere near it.
    let occupied = w.root.join(".claude/skills/mine");
    fs::create_dir_all(occupied.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink("/dev/null", &occupied).unwrap();

    let preview = drift::setup::setup_plan(&w.env, &w.scope).unwrap();
    assert!(
        !preview.conflicts.is_empty(),
        "the fixture produced no unsettled position"
    );
    assert_eq!(
        preview.other_pending, 0,
        "an unsettled position is not the person's pending work: {:?}",
        preview.conflicts
    );

    // And the install goes all the way through, which is what makes the
    // old sentence about the registration waiting untrue.
    let after = install(&w);
    assert!(
        drift::setup::every_target_registered(&w.env, &w.scope, &after).unwrap(),
        "the registration was held by a position it does not sit at: {:?}",
        after.drift
    );
    assert!(
        occupied.is_symlink(),
        "the unsettled position was written over"
    );
}
