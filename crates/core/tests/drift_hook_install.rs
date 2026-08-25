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
    apply::execute(&w.env, &plan, None).unwrap();

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
    apply::execute(&w.env, &report.plan, None).unwrap();
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

/// A scope that declared the hook before the product rename keeps its
/// declaration and script path: repair refreshes the content in place, and
/// no second declaration appears under the new name.
#[test]
#[allow(clippy::unwrap_used)]
fn a_legacy_drift_hook_declaration_still_resolves_to_first_party_content() {
    let w = world();
    declare(
        &w,
        "",
        "[hooks.vstack-drift]\nsource = \"local\"\nharnesses = [\"claude\", \"pi\"]\n",
    );
    let script = kendex_core::source::local_source_root(&w.env, &w.scope)
        .join("hooks")
        .join("vstack-drift.sh");
    fs::create_dir_all(script.parent().unwrap()).unwrap();
    fs::write(&script, "#!/bin/sh\n# an older release's script\n").unwrap();

    let manifest = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    assert_eq!(
        drift::hook::script_current(&w.env, &w.scope, &manifest),
        Some(false),
        "an outdated legacy install must read as repairable, not undeclared"
    );

    let plan = drift::hook::install_plan(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &plan, None).unwrap();

    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    assert!(loaded.hooks.contains_key("vstack-drift"));
    assert!(
        !loaded.hooks.contains_key(drift::hook::HOOK_NAME),
        "repair must never stack a second declaration: {:?}",
        loaded.hooks.keys().collect::<Vec<_>>()
    );
    // The artifact agrees with itself: a script at vstack-drift.sh,
    // declared as vstack-drift, says so in its own frontmatter.
    let written = fs::read_to_string(&script).unwrap();
    assert!(written.contains("# name: vstack-drift"), "{written}");
    assert!(!written.contains("# name: kendex-drift"), "{written}");
    assert_eq!(written, drift::hook::script_for("vstack-drift"));
    assert_eq!(
        drift::hook::script_current(&w.env, &w.scope, &loaded),
        Some(true)
    );
}

/// A manifest carrying the drift hook under both its names holds one hook,
/// not two: the new declaration installs, and the legacy one is reported as
/// superseded instead of registering a second copy of the same report.
#[test]
#[allow(clippy::unwrap_used)]
fn both_drift_hook_declarations_install_one_hook_and_say_so() {
    let w = world();
    declare(
        &w,
        "",
        "[hooks.kendex-drift]\nsource = \"local\"\nharnesses = [\"claude\"]\n\n[hooks.vstack-drift]\nsource = \"local\"\nharnesses = [\"claude\"]\n",
    );
    let hooks_dir = kendex_core::source::local_source_root(&w.env, &w.scope).join("hooks");
    fs::create_dir_all(&hooks_dir).unwrap();
    fs::write(hooks_dir.join("kendex-drift.sh"), drift::hook::HOOK_SCRIPT).unwrap();
    fs::write(
        hooks_dir.join("vstack-drift.sh"),
        drift::hook::script_for("vstack-drift"),
    )
    .unwrap();

    let report = audit(&w.env, &w.scope).unwrap();
    let warning = report
        .warnings
        .iter()
        .find(|warning| warning.name == "vstack-drift")
        .unwrap_or_else(|| {
            panic!(
                "the superseded declaration is reported: {:?}",
                report.warnings
            )
        });
    assert!(
        warning.message.contains("kendex-drift") && warning.message.contains("vstack-drift"),
        "the warning names both declarations: {}",
        warning.message
    );

    apply::execute(&w.env, &report.plan, None).unwrap();
    let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(&w.env, &w.scope)).unwrap();
    assert!(
        lock.entries.keys().any(|key| key.contains("kendex-drift")),
        "{:?}",
        lock.entries.keys().collect::<Vec<_>>()
    );
    assert!(
        !lock.entries.keys().any(|key| key.contains("vstack-drift")),
        "one hook, never two: {:?}",
        lock.entries.keys().collect::<Vec<_>>()
    );
}
