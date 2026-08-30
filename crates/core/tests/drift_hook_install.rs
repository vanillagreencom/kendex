//! The session-start drift hook as an installed item: declared like any
//! other hook, idempotent to reinstall, and a declaration from before the
//! product rename repairs its own script in place under its old name.

#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::drift;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
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
    assert!(
        drift::hook::HOOK_SCRIPT.contains("harnesses: [claude-code, pi]"),
        "the script itself must apply to pi"
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
