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
use kendex_core::drift::setup::{FileChange, FileRole, PlannedFile, SetupPlan};
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

/// The rows of one role that belong to the project itself rather than to
/// a tool's rendering: its own copy of the check script, its manifest and
/// its install record all carry no harness.
fn own_rows(plan: &SetupPlan, role: FileRole) -> Vec<&str> {
    plan.files
        .iter()
        .filter(|file| file.role == role && file.harness.is_none())
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
        own_rows(&preview, FileRole::Declaration),
        vec!["kendex.toml"]
    );
    assert_eq!(own_rows(&preview, FileRole::CheckScript).len(), 1);
    assert_eq!(own_rows(&preview, FileRole::InstallRecord).len(), 1);
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

/// A conflict at the check's OWN destination, on a RE-ENABLE. It stops the
/// registration, unlike one anywhere else in the project, so the
/// confirmation names it before the ask and the answer afterwards says it
/// is what went wrong. Reading a plan with the check's declaration
/// stripped — the one that counts the person's unrelated work — cannot see
/// this at all.
///
/// Re-enable only, and the `install` below is what makes it one. The
/// preview can name this position because the check's script is already in
/// the local source, so the planner derives the artifact and raises a row
/// about it. A first enable has no such script yet and names nothing:
/// [`a_first_enable_names_no_conflict_but_still_says_why_after`] is that
/// world, and the two together are the whole of what this surface does.
#[test]
#[allow(clippy::unwrap_used)]
fn a_conflict_at_the_checks_own_target_is_named_on_a_re_enable() {
    let w = fresh_git_world();
    declare(&w, "");
    // The checks already set up here, which is what puts the check's
    // script in the local source and so lets the planner see the item at
    // all. A first install learns the same thing from the result instead.
    install(&w);
    let preview = drift::setup::setup_plan(&w.env, &w.scope).unwrap();
    let target = preview
        .files
        .iter()
        .find(|file| file.role == FileRole::CheckScript && file.harness.is_some())
        .map(|file| w.root.join(&file.path))
        .unwrap();

    // A link kendex will not follow, exactly where the check registers.
    fs::remove_file(&target).unwrap();
    std::os::unix::fs::symlink("/dev/null", &target).unwrap();

    let blocked = drift::setup::setup_plan(&w.env, &w.scope).unwrap();
    assert!(
        blocked
            .blocked
            .iter()
            .any(|said| said.contains(target.file_name().unwrap().to_str().unwrap())),
        "the confirmation never named the position that stops the check: {:?}",
        blocked
            .files
            .iter()
            .map(|f| f.path.as_str())
            .collect::<Vec<_>>()
    );
    // And it is not filed as somebody else's unsettled position, which
    // carries a sentence that says the check is unaffected.
    assert!(blocked.conflicts.is_empty(), "{:?}", blocked.conflicts);

    // And the scope read back is incomplete and able to say why, rather
    // than reporting a state with no reason at all.
    let after = engine::plan_apply(&w.env, &w.scope, &engine::PlanOptions::default()).unwrap();
    let waiting = drift::setup::targets_waiting(&w.env, &w.scope, &after).unwrap();
    assert!(!waiting.is_empty(), "{:?}", after.drift);
    assert!(
        !drift::setup::check_conflicts(&after).is_empty(),
        "an incomplete setup with no reason to give: {:?}",
        after.drift
    );
}

/// Re-enabling on a project whose script already matches writes no
/// script: `install_plan` omits that op. The row must not call it a
/// change this press makes.
#[test]
#[allow(clippy::unwrap_used)]
fn a_script_already_in_place_is_not_a_change_this_action_makes() {
    let w = fresh_git_world();
    declare(&w, "");
    install(&w);

    let again = drift::setup::setup_plan(&w.env, &w.scope).unwrap();
    let script = again
        .files
        .iter()
        .find(|file| file.role == FileRole::CheckScript)
        .unwrap();
    assert_eq!(
        script.change,
        FileChange::Unchanged,
        "the confirmation named a file this press does not touch: {script:?}"
    );
    // The destination is still on the list. The defect was the status,
    // never the disclosure.
    assert!(script.path.ends_with("kendex-drift.sh"), "{script:?}");
}

/// A held setup writes the declaration and stops. Every destination stays
/// on the list, because that is the disclosure the ask owes; none of them
/// is presented as a file this press writes.
#[test]
#[allow(clippy::unwrap_used)]
fn a_held_setup_does_not_present_the_render_as_this_actions_writes() {
    let w = fresh_git_world();
    let source = w.root.join(".kendex-local/skills/mine");
    fs::create_dir_all(&source).unwrap();
    fs::write(
        source.join("SKILL.md"),
        "---\nname: mine\ndescription: a skill of my own\n---\n\nBody.\n",
    )
    .unwrap();
    declare(&w, "[skills.mine]\nsource = \"local\"\n");

    let held = drift::setup::setup_plan(&w.env, &w.scope).unwrap();
    assert!(held.other_pending > 0, "the fixture holds nothing back");
    for file in &held.files {
        // The declaration step runs whatever else waits, so the project's
        // own source and its manifest land now. Everything the render
        // places — a tool's own copy of the script included — waits with
        // the changes this project already had.
        let now = matches!(file.role, FileRole::CheckScript | FileRole::Declaration)
            && file.harness.is_none();
        match now {
            true => assert!(
                matches!(file.change, FileChange::Add | FileChange::Change),
                "{file:?}"
            ),
            false => assert_eq!(
                file.change,
                FileChange::Later,
                "a held press claimed to write {}",
                file.path
            ),
        }
    }
    // Every destination is still disclosed.
    for harness in &held.harnesses {
        assert!(
            held.files.iter().any(|file| file.harness == Some(*harness)),
            "{harness:?} dropped off the list"
        );
    }
}

/// A tool's registration occupies two positions of different kinds: the
/// script kendex renders for that tool, and the entry in the tool's own
/// files that makes it run at session start. Flattening both into one role
/// tells the reader that the script they are about to install is what
/// makes the tool run the script.
#[test]
#[allow(clippy::unwrap_used)]
fn a_rendered_script_is_disclosed_as_a_script_not_as_the_registration() {
    let w = world();
    declare(&w, "");

    let preview = drift::setup::setup_plan(&w.env, &w.scope).unwrap();
    let mut with_both = 0;
    for harness in &preview.harnesses {
        let rows: Vec<_> = preview
            .files
            .iter()
            .filter(|file| file.harness == Some(*harness))
            .collect();
        for file in &rows {
            if file.preview.is_some() {
                assert_eq!(
                    file.role,
                    FileRole::CheckScript,
                    "a rendered script described as the thing that runs it: {file:?}"
                );
            }
        }
        let script = rows.iter().any(|file| file.role == FileRole::CheckScript);
        let entry = rows
            .iter()
            .any(|file| file.role == FileRole::StartupRegistration);
        if script && entry {
            with_both += 1;
        }
    }
    // Without a tool that has both, nothing here separates the two roles.
    assert!(
        with_both > 0,
        "no tool disclosed a script and a registration: {:?}",
        preview.files
    );
}

/// A declaration under the check's own name, from a marketplace source.
///
/// Nothing downstream tells it from ours: the declaration is found by
/// name, widened and enabled, and the engine then renders that source's
/// hook — while the confirmation showed this binary's script. Both the
/// preview and the plan refuse instead, and neither touches the manifest.
#[test]
#[allow(clippy::unwrap_used)]
fn a_check_declared_from_a_marketplace_is_refused_rather_than_taken_over() {
    let w = fresh_git_world();
    declare(
        &w,
        "[hooks.kendex-drift]\nsource = \"cat\"\nenabled = false\nharnesses = [\"claude\"]\n",
    );
    let before = fs::read_to_string(manifest::manifest_path(&w.env, &w.scope)).unwrap();

    // The preview discloses nothing for a declaration it will not render.
    let refused = drift::setup::setup_plan(&w.env, &w.scope).unwrap_err();
    assert!(
        matches!(&refused, CoreError::SourceCollision { name, .. } if name == drift::hook::HOOK_NAME),
        "{refused:?}"
    );
    // And the write refuses at its own moment.
    let refused = drift::hook::install_plan(&w.env, &w.scope).unwrap_err();
    assert!(
        matches!(&refused, CoreError::SourceCollision { name, .. } if name == drift::hook::HOOK_NAME),
        "{refused:?}"
    );

    // Nothing was widened, switched on, or otherwise touched.
    assert_eq!(
        fs::read_to_string(manifest::manifest_path(&w.env, &w.scope)).unwrap(),
        before,
        "the foreign declaration was edited"
    );
    assert!(
        !w.root.join(".kendex-local/hooks").exists(),
        "the refusal still wrote the script"
    );
}

/// The same name from the local source is ours, and is not refused. The
/// control above must fail because the source is foreign, not because the
/// name is declared at all.
#[test]
#[allow(clippy::unwrap_used)]
fn a_check_declared_locally_is_ours_and_previews() {
    let w = fresh_git_world();
    declare(
        &w,
        "[hooks.kendex-drift]\nsource = \"local\"\nenabled = false\n",
    );

    let preview = drift::setup::setup_plan(&w.env, &w.scope).unwrap();
    assert!(!preview.files.is_empty(), "{preview:?}");
}

/// The repository's own file, in a project that is a git checkout.
///
/// The ignore rule that keeps the install record out of the person's
/// commits is not their pending work — kendex owes it for managing the
/// project at all, and the count says so — and it IS a file this press
/// writes. Both have to be true at once, and an earlier fix here made the
/// first true by making the second false.
#[test]
#[allow(clippy::unwrap_used)]
fn the_repositorys_own_file_is_listed_and_is_still_not_pending_work() {
    let w = fresh_git_world();
    declare(&w, "");

    let preview = drift::setup::setup_plan(&w.env, &w.scope).unwrap();
    let shown: Vec<&PlannedFile> = preview
        .files
        .iter()
        .filter(|file| file.role == FileRole::RepositoryFile)
        .collect();
    // A required member: a floor with nothing in it passes over a preview
    // that lists nothing at all.
    let ignore = shown
        .iter()
        .find(|file| file.path.ends_with(".gitignore"))
        .unwrap_or_else(|| panic!("the disclosure omits the ignore rule: {:?}", preview.files));
    assert!(
        matches!(ignore.change, FileChange::Add | FileChange::Change),
        "{ignore:?}"
    );
    assert!(ignore.no_preview.is_some(), "{ignore:?}");
    // And the count is still about the person's own work alone.
    assert_eq!(preview.other_pending, 0, "{preview:?}");
}

/// The same conflict on a FIRST enable, where the preview cannot see it.
///
/// Nothing of the check is on disk yet, so the planner derives no artifact
/// for it and no drift row about its positions can exist — the preview
/// names no conflict and the person is asked without being told. That is a
/// gap this branch does not close: the preview would need a plan whose
/// desired state carries an artifact restated from bytes rather than read
/// from disk, which is the engine's to give and not drift's to invent.
///
/// What is closed, and what this case exists to hold: after the write the
/// scope is read back, so the row still reports the setup incomplete AND
/// names the position that stopped it. A person is never left with a state
/// and no reason, whichever enable they are on.
#[test]
#[allow(clippy::unwrap_used)]
fn a_first_enable_names_no_conflict_but_still_says_why_after() {
    let w = fresh_git_world();
    declare(&w, "");
    // A link kendex will not follow, exactly where the check's script
    // renders — put there before anything of the check exists.
    let target = w.root.join(".claude/hooks/kendex-drift.sh");
    fs::create_dir_all(target.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink("/dev/null", &target).unwrap();

    // The ask says nothing about it. Recorded, not endorsed.
    let preview = drift::setup::setup_plan(&w.env, &w.scope).unwrap();
    assert!(
        preview.blocked.is_empty(),
        "a first enable cannot yet see its own positions: {:?}",
        preview.blocked
    );

    // The write, as the command runs it.
    let plan = drift::hook::install_plan(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let render = engine::plan_apply(&w.env, &w.scope, &engine::PlanOptions::default()).unwrap();
    let _ = apply::execute(&w.env, &render.plan);

    // Read back: incomplete, and able to say why.
    let after = engine::plan_apply(&w.env, &w.scope, &engine::PlanOptions::default()).unwrap();
    let waiting = drift::setup::targets_waiting(&w.env, &w.scope, &after).unwrap();
    assert!(
        waiting.contains(&HarnessId::Claude),
        "the tool whose position is occupied is registered: {:?}",
        after.drift
    );
    let said = drift::setup::check_conflicts(&after);
    assert!(
        said.iter().any(|one| one.contains("kendex-drift.sh")),
        "an incomplete first enable with no reason to give: {:?}",
        after.drift
    );
    assert!(target.is_symlink(), "the position was written over");
}
