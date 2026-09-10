//! The session-start drift hook as an installed item: declared like any
//! other hook, idempotent to reinstall, a declaration from before the
//! product rename repairing its own script in place under its old name,
//! and a registered project whose folder has gone refusing the install
//! rather than rebuilding the folder out of the write's own parents.

#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::drift;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::manifest;
use kendex_core::model::Scope;
use kendex_core::process::Hardened;

const REPO: &str = "owner/catalog";

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
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
    let home = tmp.path().to_path_buf();
    let upstream: PathBuf = home.join("git").join(REPO);
    fs::create_dir_all(&upstream).unwrap();
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    fs::create_dir_all(home.join(".claude")).unwrap();
    fs::create_dir_all(home.join("app/.claude")).unwrap();
    let base = format!("file://{}", home.join("git").display());
    World {
        env: Env::fake(&home, FakeOs::Linux).with_var("KENDEX_GIT_BASE", &base),
        scope: Scope::Project {
            root: home.join("app"),
        },
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn declare(w: &World, source_extra: &str, body: &str) {
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n{source_extra}\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n{body}"
        ),
    )
    .unwrap();
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_drift_hook_installs_as_a_declared_item_and_is_idempotent() {
    let w = world();
    declare(&w, "", "");

    let plan = drift::hook::install_plan(&w.env, &w.scope).unwrap();
    assert!(!plan.is_empty());
    apply::execute(&w.env, &plan).unwrap();

    // Declared like any other hook, from the local source.
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    let decl = loaded.hooks.get(drift::hook::HOOK_NAME).unwrap();
    assert_eq!(decl.source, "local");
    // The report rides Pi's carrier too: same script, declared for both.
    assert_eq!(
        decl.harnesses.as_deref(),
        Some(
            &[
                kendex_core::model::HarnessId::Claude,
                kendex_core::model::HarnessId::Pi
            ][..]
        )
    );
    assert_eq!(
        kendex_core::hook::parse_hook(drift::hook::HOOK_SCRIPT)
            .unwrap()
            .harnesses,
        Some(vec!["claude-code".to_owned(), "pi".to_owned()]),
    );

    // The ordinary refresh renders it.
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    assert!(
        report.drift.is_empty(),
        "the rendered hook audits clean: {:?}",
        report.drift
    );

    // Installing again plans nothing.
    let plan = drift::hook::install_plan(&w.env, &w.scope).unwrap();
    assert!(plan.is_empty(), "{plan:?}");
}

// A yes to the note is a yes to it running. Switched off from the
// Library, the declaration stays and nothing renders; installing again
// must flip the switch rather than plan nothing and report success.
#[test]
#[allow(clippy::unwrap_used)]
fn installing_over_a_switched_off_declaration_switches_it_back_on() {
    let w = world();
    declare(
        &w,
        "",
        &format!(
            "[hooks.{}]\nsource = \"local\"\nenabled = false\n",
            drift::hook::HOOK_NAME
        ),
    );

    let plan = drift::hook::install_plan(&w.env, &w.scope).unwrap();
    assert!(
        plan.ops
            .iter()
            .any(|op| matches!(op.op, apply::Op::WriteManifest { .. })),
        "the switched-off declaration is rewritten: {plan:?}"
    );
    apply::execute(&w.env, &plan).unwrap();

    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    assert!(loaded.hooks.get(drift::hook::HOOK_NAME).unwrap().enabled);

    // And once on, installing again plans nothing.
    let plan = drift::hook::install_plan(&w.env, &w.scope).unwrap();
    assert!(plan.is_empty(), "{plan:?}");
}

/// Every position the install could put something at, for a scope whose
/// root is `root`. Read through the same derivations the plan uses, so a
/// derivation that moves cannot leave this assertion checking nowhere.
#[allow(clippy::unwrap_used)]
fn positions(w: &World) -> Vec<PathBuf> {
    vec![
        manifest::manifest_path(&w.env, &w.scope),
        kendex_core::lock::lock_path(&w.env, &w.scope),
        kendex_core::source::local_source_root(&w.env, &w.scope),
    ]
}

#[allow(clippy::unwrap_used)]
fn root_of(scope: &Scope) -> PathBuf {
    match scope {
        Scope::Project { root } => root.clone(),
        Scope::Global => unreachable!("the fixture scope is a project"),
    }
}

/// The reported bug: a registered project renamed on disk, and the card
/// left standing over its old path offering to install there. Every write
/// kendex plans makes the directories above it, so the install would put
/// the folder back — a new project-shaped one, over a project the person
/// moved rather than deleted.
#[test]
#[allow(clippy::unwrap_used)]
fn an_install_at_a_moved_project_refuses_and_leaves_the_old_path_empty() {
    let w = world();
    declare(&w, "", "");
    let root = root_of(&w.scope);
    let places = positions(&w);
    fs::rename(&root, root.parent().unwrap().join("moved")).unwrap();

    let refused = drift::hook::install_plan(&w.env, &w.scope).unwrap_err();
    assert!(
        matches!(&refused, CoreError::ProjectRootMissing { path } if path == &root),
        "{refused:?}"
    );
    assert!(
        !root.exists(),
        "the old path was rebuilt: {}",
        root.display()
    );
    for place in places {
        assert!(!place.exists(), "{} was written", place.display());
    }
}

/// The same folder, gone between the plan and the apply that runs it. The
/// CLI puts a confirmation prompt in that gap and the app a dialog, so the
/// check rides in the plan as well: a plan made a minute ago must not
/// rebuild a folder that went away since.
#[test]
#[allow(clippy::unwrap_used)]
fn a_folder_that_goes_away_after_the_plan_refuses_at_the_apply() {
    let w = world();
    declare(&w, "", "");
    let root = root_of(&w.scope);
    let places = positions(&w);
    let plan = drift::hook::install_plan(&w.env, &w.scope).unwrap();
    assert!(!plan.is_empty(), "{plan:?}");

    fs::remove_dir_all(&root).unwrap();
    let refused = apply::execute(&w.env, &plan).unwrap_err();
    let CoreError::RolledBack { cause, .. } = &refused else {
        panic!("{refused:?}");
    };
    assert!(
        matches!(cause.as_ref(), CoreError::ProjectRootMissing { path } if path == &root),
        "{cause:?}"
    );
    assert!(
        !root.exists(),
        "the old path was rebuilt: {}",
        root.display()
    );
    for place in places {
        assert!(!place.exists(), "{} was written", place.display());
    }
}
