//! Pi hooks, enforced through the carrier: events map onto the listeners
//! Pi actually fires (unmappable ones stay honestly unsupported), labels
//! read carrier reality at both scopes — a project-installed hook with a
//! global carrier is enforced — and everything renders through the ordinary
//! plan.
#![cfg(unix)]

use crate::test_util;
use test_util::source_path;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::harness::{Enforcement, pi_listener};
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::pi_ext::carrier;
use serde_json::Value;

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    home: PathBuf,
    project: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let project = home.join("app");
    fs::create_dir_all(project.join(".pi")).unwrap();
    World {
        env: Env::fake(&home, FakeOs::Linux),
        home,
        project,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn register_carrier(settings_dir: &Path) {
    fs::create_dir_all(settings_dir).unwrap();
    fs::write(
        settings_dir.join("settings.json"),
        r#"{ "packages": ["./packages/@vanillagreen/pi-hooks"] }"#,
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn declare_hook(world: &World, event: &str) {
    let catalog = world.home.join("cat");
    fs::create_dir_all(catalog.join("hooks")).unwrap();
    // Hooks install only from a catalog that declares kendex's layout.
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        catalog.join("hooks/guard.sh"),
        format!(
            "#!/bin/sh\n# ---\n# name: guard\n# event: {event}\n# description: a guard\n# harnesses: [pi]\n# ---\nexit 0\n"
        ),
    )
    .unwrap();
    fs::write(
        world.project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"pi\"]\nmethod = \"symlink\"\n\n[hooks.guard]\nsource = \"cat\"\n",
            source_path(&catalog)
        ),
    )
    .unwrap();
}

fn scope(world: &World) -> Scope {
    Scope::Project {
        root: world.project.clone(),
    }
}

/// Every listener kendex renders a registration under, so the case below can
/// assert the whole set rather than the one key it drives.
const DISPATCHED: [&str; 6] = [
    "tool_call",
    "tool_result",
    "turn_end",
    "agent_before_settle",
    "session_start",
    "session_shutdown",
];

#[test]
fn events_map_onto_the_listeners_pi_actually_fires() {
    for (event, listener) in [
        ("PreToolUse", Some("tool_call")),
        ("PostToolUse", Some("tool_result")),
        ("Stop", Some("turn_end")),
        ("TaskCompleted", Some("turn_end")),
        ("StopFailure", Some("agent_before_settle")),
        ("SessionStart", Some("session_start")),
        ("SessionEnd", Some("session_shutdown")),
        ("PostCompact", None),
        ("UserPromptSubmit", None),
    ] {
        assert_eq!(pi_listener(event), listener, "{event}");
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn carrier_presence_is_read_per_settings_layer_and_either_scope_enforces() {
    let w = world();
    let project_scope = scope(&w);
    assert!(!carrier::presence(&w.env, &project_scope).anywhere());
    assert_eq!(
        carrier::enforcement(&w.env, &project_scope),
        Enforcement::Advisory,
        "no carrier anywhere: a rendered registry is prose"
    );

    // The hook installs in the project while the carrier is registered only
    // globally. Pi loads both settings layers, so the hook is enforced.
    register_carrier(&w.home.join(".pi/agent"));
    let presence = carrier::presence(&w.env, &project_scope);
    assert!(presence.global && !presence.project);
    assert_eq!(
        carrier::enforcement(&w.env, &project_scope),
        Enforcement::Enforced
    );

    // And the mirror case: a project carrier alone also enforces.
    fs::remove_file(w.home.join(".pi/agent/settings.json")).unwrap();
    register_carrier(&w.project.join(".pi"));
    let presence = carrier::presence(&w.env, &project_scope);
    assert!(!presence.global && presence.project);
    assert_eq!(
        carrier::enforcement(&w.env, &project_scope),
        Enforcement::Enforced
    );

    // A registered carrier with Pi's native off filter enforces nothing.
    fs::write(
        w.project.join(".pi/settings.json"),
        r#"{"packages":[{"source":"./packages/@vanillagreen/pi-hooks","extensions":[]}]}"#,
    )
    .unwrap();
    assert!(!carrier::presence(&w.env, &project_scope).anywhere());
    assert_eq!(
        carrier::enforcement(&w.env, &project_scope),
        Enforcement::Advisory
    );

    // The global scope reads only the layers Pi loads globally.
    assert_eq!(
        carrier::enforcement(&w.env, &Scope::Global),
        Enforcement::Advisory
    );
}

#[test]
#[allow(
    clippy::unwrap_used,
    clippy::too_many_lines,
    reason = "one scope and mode table keeps package retention and PiRemove ownership assertions together"
)]
fn retiring_pi_inventory_keeps_declared_packages_until_pi_remove() {
    use kendex_core::apply::{self, Op};
    use kendex_core::engine::{PlanOptions, plan_apply};
    use kendex_core::lock::{self, EmittedArtifact, entry_key};
    use kendex_core::{manifest, pi_ext};

    let w = world();
    let name = "@vanillagreen/pi-hooks";
    let catalog = w.home.join("cat");
    let source = catalog.join("pi-extensions/pi-hooks");
    fs::create_dir_all(&source).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    // pi_ext::install produces a copied package with no runtime dependencies.
    // Its package hash therefore also matches generic stale-file cleanup.
    fs::write(
        source.join("package.json"),
        r#"{"name":"@vanillagreen/pi-hooks","version":"1.0.0","pi":{"extensions":["index.js"]}}"#,
    )
    .unwrap();
    let payload = b"export default function hooks(pi) {}\n";
    fs::write(source.join("index.js"), payload).unwrap();
    let declaration = format!(
        "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"pi\"]\n\n[pi-extensions.\"{name}\"]\nsource = \"cat\"\n",
        source_path(&catalog)
    );
    let key = entry_key(ItemKind::PiExtension, name, HarnessId::Pi);

    for scope in [Scope::Global, scope(&w)] {
        let manifest_path = manifest::manifest_path(&w.env, &scope);
        fs::create_dir_all(manifest_path.parent().unwrap()).unwrap();
        fs::write(&manifest_path, &declaration).unwrap();
        let pi_root = pi_ext::scope_root(&w.env, &scope).unwrap();
        let installed = pi_ext::install(&w.env, &pi_root, &source, true)
            .unwrap()
            .dest;
        let settings = fs::read(pi_ext::settings_path(&pi_root)).unwrap();
        let before = fs::read(&manifest_path).unwrap();
        assert!(
            kendex_core::engine::ops::toggle(&w.env, &scope, &[name.to_owned()], None, false, None)
                .is_err()
        );
        assert_eq!(fs::read(&manifest_path).unwrap(), before);
        assert_eq!(fs::read(pi_ext::settings_path(&pi_root)).unwrap(), settings);

        let lock_path = lock::lock_path(&w.env, &scope);
        let mut previous = lock::load(&lock_path).unwrap();
        let declared = manifest::load_for_mutation(&manifest_path)
            .unwrap()
            .unwrap();
        let drift = pi_ext::record_matching_manifest(
            &w.env,
            &scope,
            &declared,
            &mut previous,
            pi_ext::RecordBasis::MatchedBytes,
            None,
        )
        .unwrap();
        assert!(drift.is_empty(), "{scope:?}: {drift:?}");
        assert!(previous.entries[&key].emitted.is_none());
        // The Pi record writer shipped an inventory of the package directory.
        previous.entries.get_mut(&key).unwrap().emitted = Some(EmittedArtifact {
            kind: ItemKind::PiExtension,
            name: name.into(),
            paths: vec![installed.clone()],
        });

        for (mode, options) in [
            ("refresh", PlanOptions::current()),
            (
                "apply",
                PlanOptions {
                    remove_orphans: true,
                    ..PlanOptions::current()
                },
            ),
        ] {
            lock::save(&lock_path, &previous).unwrap();
            let report = plan_apply(&w.env, &scope, &options).unwrap();
            assert!(
                report.drift.is_empty(),
                "{scope:?} {mode}: {:?}",
                report.drift
            );
            assert!(
                !report.plan.ops.iter().any(|op| matches!(&op.op,
                    Op::Trash { path, .. } if path.starts_with(&installed)
                ) || matches!(&op.op, Op::PiRemove { .. })),
                "{scope:?} {mode}: a declared package must stay installed: {:?}",
                report.plan.ops
            );
            apply::execute(&w.env, &report.plan).unwrap();
            assert_eq!(fs::read(installed.join("index.js")).unwrap(), payload);
            assert_eq!(fs::read(pi_ext::settings_path(&pi_root)).unwrap(), settings);
            let settled = plan_apply(&w.env, &scope, &options).unwrap();
            assert!(
                settled.plan.ops.is_empty(),
                "{scope:?} {mode}: {:?}",
                settled.plan.ops
            );
        }

        // Removing the declaration still retires payload and registration
        // through their existing owner, not generic rendered-file cleanup.
        fs::write(
            &manifest_path,
            "schema = 6\n\n[install]\nharnesses = [\"pi\"]\n",
        )
        .unwrap();
        let removal = plan_apply(
            &w.env,
            &scope,
            &PlanOptions {
                remove_orphans: true,
                ..PlanOptions::current()
            },
        )
        .unwrap();
        assert!(
            removal.plan.ops.iter().any(|op| matches!(&op.op,
                Op::PiRemove { package, .. } if package == &installed
            )),
            "{scope:?}: {:?}",
            removal.plan.ops
        );
        apply::execute(&w.env, &removal.plan).unwrap();
        assert!(!installed.exists());
        assert!(!pi_ext::registered(&pi_root, name).unwrap());
        assert!(!lock::load(&lock_path).unwrap().entries.contains_key(&key));
    }
}

const WIDGETS_INDEX: &[u8] = b"export default function widgets(pi) {}\n";

/// A catalog shipping `pi-widgets`, a package whose `appendSystem` file
/// tells the model to use its tool: the catalog and the package source.
#[allow(clippy::unwrap_used)]
fn widgets_catalog(w: &World) -> (PathBuf, PathBuf) {
    let catalog = w.home.join("cat");
    let source = catalog.join("pi-extensions/pi-widgets");
    fs::create_dir_all(&source).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        source.join("package.json"),
        r#"{"name":"pi-widgets","pi":{"extensions":["index.js"],"appendSystem":"system.md"}}"#,
    )
    .unwrap();
    fs::write(source.join("index.js"), WIDGETS_INDEX).unwrap();
    fs::write(source.join("system.md"), "Use the widget tool.\n").unwrap();
    (catalog, source)
}

/// Record the scope's installed Pi packages as they match their bytes, the
/// record `update-pi` leaves behind, over whatever the record already holds.
#[allow(clippy::unwrap_used)]
fn record_installed_packages(w: &World, scope: &Scope) {
    use kendex_core::{engine, lock, pi_ext};
    let path = lock::lock_path(&w.env, scope);
    let mut record = lock::load(&path).unwrap();
    let declared = engine::ops::manifest_for_reading(&w.env, scope).unwrap();
    pi_ext::record_matching_manifest(
        &w.env,
        scope,
        &declared,
        &mut record,
        pi_ext::RecordBasis::MatchedBytes,
        None,
    )
    .unwrap();
    lock::save(&path, &record).unwrap();
}

#[test]
#[allow(clippy::unwrap_used)]
#[allow(
    clippy::too_many_lines,
    reason = "one walk: three toggles at two scopes, each read back from settings, instructions, record, audit and scan"
)]
fn native_package_toggles_keep_files_settings_and_records_at_both_scopes() {
    use kendex_core::{apply, engine, lock, manifest, pi_ext, scan, settings};
    use serde_json::json;
    // The shared world's project walk starts where its global walk ended:
    // the global registration enabled and inherited into the project file,
    // which a project disable must leave to the global file again.
    let shared = world();
    for (global, carried) in [(true, false), (false, false), (true, true), (false, true)] {
        let fresh;
        let w = match carried {
            true => &shared,
            false => {
                fresh = world();
                &fresh
            }
        };
        let name = "pi-widgets";
        let (catalog, source) = widgets_catalog(w);
        let scope = if global { Scope::Global } else { scope(w) };
        let path = manifest::manifest_path(&w.env, &scope);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, format!(
            "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"pi\"]\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n", source_path(&catalog)
        )).unwrap();
        let root = pi_ext::scope_root(&w.env, &scope).unwrap();
        let dest = pi_ext::install(&w.env, &root, &source, true).unwrap().dest;
        let settings_path = pi_ext::settings_path(&root);
        let entry = json!({"source":dest, "skills":["keep"], "themes":[], "prompts":["keep.md"]});
        let original = json!({"theme":"dark", "packages":["npm:first", entry, "npm:last"]});
        let text = serde_json::to_string_pretty(&original)
            .unwrap()
            .replace('\n', "\r\n");
        fs::write(&settings_path, format!("{text}\r\n")).unwrap();
        let declared = engine::ops::manifest_for_reading(&w.env, &scope).unwrap();
        let mut record = lock::Lock::default();
        let seeded = pi_ext::record_matching_manifest(
            &w.env,
            &scope,
            &declared,
            &mut record,
            pi_ext::RecordBasis::MatchedBytes,
            None,
        )
        .unwrap();
        assert!(seeded.is_empty());
        lock::save(&lock::lock_path(&w.env, &scope), &record).unwrap();
        let key = lock::entry_key(ItemKind::PiExtension, name, HarnessId::Pi);
        for (kind, enabled) in [
            (Some(ItemKind::PiExtension), false),
            (None, true),
            (None, false),
        ] {
            let before = fs::read(&settings_path).unwrap();
            let report =
                engine::ops::toggle(&w.env, &scope, &[name.to_owned()], kind, enabled, None)
                    .unwrap();
            assert_eq!(
                fs::read(&settings_path).unwrap(),
                before,
                "preview writes nothing"
            );
            apply::execute(&w.env, &report.plan).unwrap();
            let text = fs::read_to_string(&settings_path).unwrap();
            assert!(text.contains("\r\n"));
            let observed: Value = serde_json::from_str(&text).unwrap();
            let mut expected = original.clone();
            if !enabled {
                expected["packages"][1]["extensions"] = json!([]);
            }
            assert_eq!(observed, expected);
            // A switch carries the package's instructions with it.
            let append = fs::read_to_string(pi_ext::append_system_path(&root)).unwrap_or_default();
            assert_eq!(
                append.contains("Use the widget tool."),
                enabled,
                "global {global}, carried {carried}"
            );
            assert_eq!(fs::read(dest.join("index.js")).unwrap(), WIDGETS_INDEX);
            let record = lock::load(&lock::lock_path(&w.env, &scope)).unwrap();
            let declared = engine::ops::manifest_for_reading(&w.env, &scope).unwrap();
            assert_eq!(
                (
                    record.entries[&key].enabled,
                    declared.pi_extensions[name].enabled
                ),
                (enabled, enabled)
            );
            assert!(engine::audit(&w.env, &scope).unwrap().drift.is_empty());
            let scanned = scan::scan_scopes(
                &w.env,
                &settings::load(&w.env).unwrap().harness_roots,
                std::slice::from_ref(&scope),
            );
            let item = scanned
                .items
                .iter()
                .find(|item| item.kind == ItemKind::PiExtension && item.name == name)
                .unwrap();
            assert_eq!(item.enabled, Some(enabled));
        }
        // The native read, not the completed record, judges a hand edit.
        fs::write(&settings_path, serde_json::to_string(&original).unwrap()).unwrap();
        assert!(
            engine::audit(&w.env, &scope)
                .unwrap()
                .drift
                .iter()
                .any(|row| row.kind == ItemKind::PiExtension && row.name == name)
        );
    }
}

/// A package's `APPEND_SYSTEM.md` block follows its declaration whatever
/// Pi's native filter already says: a declaration switched to agree with
/// the filter needs no native switch, and still takes the block away or
/// puts it back. Each row: the declaration installed, whether Pi's filter
/// loads the package, and the declaration the toggle sets.
#[test]
#[allow(clippy::unwrap_used)]
fn a_declaration_switch_pi_already_made_moves_only_its_block() {
    use kendex_core::{apply, engine, manifest, pi_ext};
    use serde_json::json;
    for (declared, native_on, toggled) in [(true, false, false), (false, true, true)] {
        let row = format!("declared {declared}, toggled {toggled}");
        let w = world();
        let (catalog, source) = widgets_catalog(&w);
        let scope = scope(&w);
        fs::write(manifest::manifest_path(&w.env, &scope), format!(
            "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"pi\"]\n[pi-extensions.pi-widgets]\nsource = \"cat\"\nenabled = {declared}\n", source_path(&catalog)
        )).unwrap();
        let root = pi_ext::scope_root(&w.env, &scope).unwrap();
        let dest = pi_ext::install(&w.env, &root, &source, declared)
            .unwrap()
            .dest;
        let settings_path = pi_ext::settings_path(&root);
        let mut entry = json!({"source": dest});
        if !native_on {
            entry["extensions"] = json!([]);
        }
        fs::write(&settings_path, json!({"packages": [entry]}).to_string()).unwrap();
        record_installed_packages(&w, &scope);
        let append_path = pi_ext::append_system_path(&root);
        let settings = fs::read(&settings_path).unwrap();
        let instructions = fs::read(&append_path).ok();
        assert_eq!(
            instructions
                .as_deref()
                .is_some_and(|text| String::from_utf8_lossy(text).contains("Use the widget tool.")),
            declared,
            "{row}"
        );

        let report = engine::ops::toggle(
            &w.env,
            &scope,
            &["pi-widgets".to_owned()],
            Some(ItemKind::PiExtension),
            toggled,
            None,
        )
        .unwrap();
        apply::execute(&w.env, &report.plan).unwrap();

        let append = fs::read_to_string(&append_path).unwrap_or_default();
        assert_eq!(
            append.contains("Use the widget tool."),
            toggled,
            "{row}: {append}"
        );
        assert_eq!(
            fs::read(&settings_path).unwrap(),
            settings,
            "{row}: no native switch"
        );
        let drift = engine::audit(&w.env, &scope).unwrap().drift;
        assert!(drift.is_empty(), "{row}: {} rows", drift.len());
        // The block as it stood before the toggle is drift the plan writes.
        match &instructions {
            Some(bytes) => fs::write(&append_path, bytes).unwrap(),
            None => fs::remove_file(&append_path).unwrap(),
        }
        let drift = engine::audit(&w.env, &scope).unwrap().drift;
        assert!(
            drift.iter().any(|row| row.kind == ItemKind::PiExtension
                && row.name == "pi-widgets"
                && row.state == engine::DriftState::Stale
                && row.cause == Some(engine::DriftCause::UpstreamChanged)),
            "{row}: {} rows",
            drift.len()
        );
    }
}

/// A toggle plans before it saves the manifest, so an `APPEND_SYSTEM.md`
/// that will not read fails it there: no declaration claims a switch whose
/// block was never compared.
#[test]
#[allow(clippy::unwrap_used)]
fn a_toggle_over_an_unreadable_append_system_refuses_and_writes_nothing() {
    use kendex_core::{engine, lock, manifest, pi_ext};
    let w = world();
    let (catalog, source) = widgets_catalog(&w);
    let scope = scope(&w);
    let manifest_path = manifest::manifest_path(&w.env, &scope);
    fs::write(&manifest_path, format!(
        "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"pi\"]\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n", source_path(&catalog)
    )).unwrap();
    let root = pi_ext::scope_root(&w.env, &scope).unwrap();
    pi_ext::install(&w.env, &root, &source, true).unwrap();
    record_installed_packages(&w, &scope);
    // Bytes that are not UTF-8, as an editor saving another encoding leaves.
    fs::write(pi_ext::append_system_path(&root), b"Notes \xff\n").unwrap();
    let lock_path = lock::lock_path(&w.env, &scope);
    let settings_path = pi_ext::settings_path(&root);
    let before = [&manifest_path, &settings_path, &lock_path].map(|path| fs::read(path).unwrap());

    let toggled = engine::ops::toggle(
        &w.env,
        &scope,
        &["pi-widgets".to_owned()],
        Some(ItemKind::PiExtension),
        false,
        None,
    );

    assert!(toggled.is_err(), "the toggle planned over an unread block");
    let after = [&manifest_path, &settings_path, &lock_path].map(|path| fs::read(path).unwrap());
    assert_eq!(after, before);
}

/// A package's block leaves through the plan's edit to the project's
/// `APPEND_SYSTEM.md`, so a removal whose append file is a link or not a
/// file plans none of the removal: the package, its registration and the
/// file the link reaches stay as they were. WORKTREE_SYMLINKS links the
/// prompt file this way.
#[test]
#[allow(clippy::unwrap_used)]
fn a_removal_over_a_linked_or_nonregular_append_file_keeps_the_package() {
    use kendex_core::apply::{self, Op};
    use kendex_core::engine::{DriftState, PlanOptions, plan_apply};
    use kendex_core::{manifest, pi_ext};
    for target in ["directory", "file-link", "worktree-file-link"] {
        let w = world();
        let (catalog, source) = widgets_catalog(&w);
        let scope = scope(&w);
        let manifest_path = manifest::manifest_path(&w.env, &scope);
        fs::write(&manifest_path, format!(
            "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"pi\"]\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n", source_path(&catalog)
        )).unwrap();
        let root = pi_ext::scope_root(&w.env, &scope).unwrap();
        let dest = pi_ext::install(&w.env, &root, &source, true).unwrap().dest;
        record_installed_packages(&w, &scope);
        let global = pi_ext::append_system_path(&w.home.join(".pi/agent"));
        fs::create_dir_all(global.parent().unwrap()).unwrap();
        fs::write(&global, "Personal global instructions.\n").unwrap();
        let append = pi_ext::append_system_path(&root);
        let personal = w.project.join("personal.md");
        fs::rename(&append, &personal).unwrap();
        match target {
            "directory" => fs::create_dir(&append).unwrap(),
            "file-link" => std::os::unix::fs::symlink(&personal, &append).unwrap(),
            "worktree-file-link" => std::os::unix::fs::symlink(&global, &append).unwrap(),
            _ => unreachable!(),
        }
        fs::write(
            &manifest_path,
            format!(
                "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"pi\"]\n",
                source_path(&catalog)
            ),
        )
        .unwrap();
        let settings = fs::read(pi_ext::settings_path(&root)).unwrap();
        let reached = [&personal, &global].map(|path| fs::read(path).unwrap());

        let removal = plan_apply(
            &w.env,
            &scope,
            &PlanOptions {
                remove_orphans: true,
                ..PlanOptions::current()
            },
        )
        .unwrap();
        assert!(
            !removal
                .plan
                .ops
                .iter()
                .any(|op| matches!(&op.op, Op::PiRemove { .. })),
            "{target}"
        );
        assert!(
            removal
                .drift
                .iter()
                .any(|row| row.name == "pi-widgets" && row.state == DriftState::Conflict),
            "{target}"
        );
        apply::execute(&w.env, &removal.plan).unwrap();
        assert_eq!(fs::read(dest.join("index.js")).unwrap(), WIDGETS_INDEX);
        assert_eq!(fs::read(pi_ext::settings_path(&root)).unwrap(), settings);
        assert_eq!(
            [&personal, &global].map(|path| fs::read(path).unwrap()),
            reached,
            "{target}"
        );
        assert_eq!(append.is_dir(), target == "directory", "{target}");
    }
}

/// A package installed after the scope's Pi output style puts its block
/// after the style's. Keeping either block where it stands is no change,
/// so every audit reads both in line and no apply rewrites the file.
#[test]
#[allow(clippy::unwrap_used)]
fn a_style_and_a_package_block_audit_clean_across_repeated_applies() {
    use kendex_core::{apply, engine, manifest, pi_ext};
    let w = world();
    let (catalog, source) = widgets_catalog(&w);
    fs::create_dir_all(catalog.join("output-styles")).unwrap();
    fs::write(
        catalog.join("output-styles/STE.md"),
        "---\nname: STE\ndescription: Short sentences\nkeep-coding-instructions: true\n---\nWrite short sentences.\n",
    )
    .unwrap();
    let scope = scope(&w);
    fs::write(manifest::manifest_path(&w.env, &scope), format!(
        "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"pi\"]\n[output-styles.STE]\nsource = \"cat\"\n[pi-extensions.pi-widgets]\nsource = \"cat\"\n", source_path(&catalog)
    )).unwrap();
    let style = engine::audit(&w.env, &scope).unwrap();
    apply::execute(&w.env, &style.plan).unwrap();
    let root = pi_ext::scope_root(&w.env, &scope).unwrap();
    pi_ext::install(&w.env, &root, &source, true).unwrap();
    record_installed_packages(&w, &scope);
    let append_path = pi_ext::append_system_path(&root);
    let installed = fs::read_to_string(&append_path).unwrap();
    let style_at = installed.find("output-style-STE begin").unwrap();
    let package_at = installed.find("pi-widgets begin").unwrap();
    assert!(style_at < package_at, "{installed}");

    for pass in 0..3 {
        let report = engine::audit(&w.env, &scope).unwrap();
        let drift: Vec<_> = report
            .drift
            .iter()
            .map(|row| (row.name.clone(), row.detail.clone()))
            .collect();
        assert!(drift.is_empty(), "pass {pass}: {drift:?}");
        apply::execute(&w.env, &report.plan).unwrap();
        assert_eq!(
            fs::read_to_string(&append_path).unwrap(),
            installed,
            "pass {pass}"
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn saved_pi_config_selection_refuses_native_disable_and_disabled_update() {
    use kendex_core::{apply, engine, error::CoreError, lock, manifest, pi_ext};
    use serde_json::json;
    let w = world();
    let name = "@vanillagreen/pi-hooks";
    let catalog = w.home.join("cat");
    let source = catalog.join("pi-extensions/pi-hooks");
    fs::create_dir_all(source.join("extensions")).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(source.join("package.json"), json!({
        "name":name, "pi":{"extensions":["./extensions/hooks.ts", "./extensions/lane-mail-wake.ts"]}
    }).to_string()).unwrap();
    for file in ["hooks.ts", "lane-mail-wake.ts"] {
        fs::write(
            source.join("extensions").join(file),
            "export default function hooks(pi) {}\n",
        )
        .unwrap();
    }
    for scope in [Scope::Global, scope(&w)] {
        let path = manifest::manifest_path(&w.env, &scope);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, format!(
            "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"pi\"]\n[pi-extensions.\"{name}\"]\nsource = \"cat\"\n", source_path(&catalog)
        )).unwrap();
        let root = pi_ext::scope_root(&w.env, &scope).unwrap();
        pi_ext::install(&w.env, &root, &source, true).unwrap();
        // Pi config's togglePackageResource excludes exactly one shipped file.
        let native = json!({"theme":"dark", "packages":["npm:first", {
            "source":"./packages/@vanillagreen/pi-hooks",
            "extensions":["-extensions/lane-mail-wake.ts"], "skills":[],
            "prompts":["+prompts/review.md"], "themes":[]
        }, "npm:last"]});
        let settings_path = pi_ext::settings_path(&root);
        fs::write(&settings_path, format!("{native}\r\n")).unwrap();
        let declared = engine::ops::manifest_for_reading(&w.env, &scope).unwrap();
        let mut record = lock::Lock::default();
        assert!(
            pi_ext::record_matching_manifest(
                &w.env,
                &scope,
                &declared,
                &mut record,
                pi_ext::RecordBasis::MatchedBytes,
                None
            )
            .unwrap()
            .is_empty()
        );
        let lock_path = lock::lock_path(&w.env, &scope);
        lock::save(&lock_path, &record).unwrap();
        let report =
            engine::ops::toggle(&w.env, &scope, &[name.to_owned()], None, true, None).unwrap();
        apply::execute(&w.env, &report.plan).unwrap();
        pi_ext::install(&w.env, &root, &source, true).unwrap();
        assert_eq!(
            serde_json::from_slice::<Value>(&fs::read(&settings_path).unwrap()).unwrap(),
            native
        );
        let settings_before = fs::read(&settings_path).unwrap();
        let manifest_before = fs::read(&path).unwrap();
        let lock_before = fs::read(&lock_path).unwrap();
        assert!(matches!(engine::ops::toggle(
            &w.env, &scope, &[name.to_owned()], None, false, None
        ), Err(CoreError::PiPackage { name: refused, .. }) if refused == name));
        assert_eq!(fs::read(&settings_path).unwrap(), settings_before);
        assert_eq!(fs::read(&path).unwrap(), manifest_before);
        assert_eq!(fs::read(&lock_path).unwrap(), lock_before);
        assert!(matches!(pi_ext::install(&w.env, &root, &source, false),
            Err(CoreError::PiPackage { name: refused, .. }) if refused == name));
        assert_eq!(fs::read(&settings_path).unwrap(), settings_before);
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_mappable_event_renders_the_registry_in_pi_listener_names() {
    let w = world();
    register_carrier(&w.project.join(".pi"));
    declare_hook(&w, "PreToolUse");

    let report = audit(&w.env, &scope(&w)).unwrap();
    kendex_core::apply::execute(&w.env, &report.plan).unwrap();

    let script = w.project.join(".pi/kendex/hooks/guard.sh");
    assert!(
        script.is_file(),
        "the hook script lands beside the registry"
    );
    let registry: Value =
        serde_json::from_str(&fs::read_to_string(w.project.join(".pi/kendex/hooks.json")).unwrap())
            .unwrap();
    assert_eq!(
        registry["hooks"]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        ["tool_call"],
    );

    // No downgrade warning while the carrier is registered.
    let report = audit(&w.env, &scope(&w)).unwrap();
    assert!(
        !report
            .warnings
            .iter()
            .any(|warning| warning.kind == ItemKind::Hook
                && warning.name == "guard"
                && warning.harness == Some(HarnessId::Pi)),
        "{:?}",
        report.warnings
    );
    assert!(report.drift.is_empty(), "{:?}", report.drift);
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_unmappable_event_installs_nothing_on_pi() {
    let w = world();
    register_carrier(&w.project.join(".pi"));
    declare_hook(&w, "PostCompact");

    let report = audit(&w.env, &scope(&w)).unwrap();
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.state == kendex_core::engine::DriftState::Conflict
                && row.detail.lines().next()
                    == Some("kendex-hook-unsupported: harness=pi event=PostCompact hook=guard")),
        "{:?}",
        report.drift
    );
    assert_eq!(
        report.declaration_status,
        kendex_core::engine::DeclarationStatus::Incomplete
    );
    kendex_core::apply::execute(&w.env, &report.plan).unwrap();
    assert!(
        !w.project.join(".pi/kendex/hooks/guard.sh").exists(),
        "no stale advisory artifact for an event pi cannot fire"
    );
    assert!(!w.project.join(".pi/kendex/hooks.json").exists());
}

#[test]
#[allow(clippy::unwrap_used)]
fn labels_downgrade_per_item_when_the_carrier_is_missing() {
    let w = world();
    declare_hook(&w, "PreToolUse");

    let report = audit(&w.env, &scope(&w)).unwrap();
    let warning = report
        .warnings
        .iter()
        .find(|warning| {
            warning.kind == ItemKind::Hook
                && warning.name == "guard"
                && warning.harness == Some(HarnessId::Pi)
        })
        .unwrap_or_else(|| panic!("no carrier warning: {:?}", report.warnings));
    assert!(
        warning
            .remediation
            .as_deref()
            .is_some_and(|fix| fix.contains("pi-hooks")),
        "{warning:?}"
    );
}

/// Pi warns about a `hooks/` beside a root it loads on the name alone —
/// so the name is one kendex never writes.
#[test]
#[allow(clippy::unwrap_used)]
fn nothing_lands_in_the_directory_names_pi_reserved() {
    let w = world();
    register_carrier(&w.project.join(".pi"));
    declare_hook(&w, "PreToolUse");

    let report = audit(&w.env, &scope(&w)).unwrap();
    kendex_core::apply::execute(&w.env, &report.plan).unwrap();

    assert!(
        !w.project.join(".pi/hooks").exists(),
        "the reserved directory name makes pi warn at every start"
    );
}

/// A scope carrying the layout an older kendex wrote: script and registry
/// beside the root, nothing under `kendex/`. Everything here reads or
/// writes one level down, so the files beside the root are outside every
/// path this build takes — including removal's. They stay exactly as they
/// are, the refresh renders the hook under `kendex/` on its own, and the
/// pass after it changes nothing.
///
/// Said plainly because `docs/adapters/pi.md` says it: what is beside the
/// root is the person's to deal with by hand. `kendex remove` does not
/// touch it, and nothing in this build does.
#[test]
#[allow(clippy::unwrap_used)]
fn the_older_layout_beside_the_root_is_left_exactly_where_it_is() {
    let w = world();
    register_carrier(&w.project.join(".pi"));
    declare_hook(&w, "PreToolUse");
    let report = audit(&w.env, &scope(&w)).unwrap();
    kendex_core::apply::execute(&w.env, &report.plan).unwrap();

    // Put the installation back where an older kendex kept it: script and
    // registry beside the root, with kendex's own segment gone.
    let home = w.project.join(".pi/kendex");
    let beside_script = w.project.join(".pi/hooks/guard.sh");
    let beside_registry = w.project.join(".pi/hooks.json");
    fs::create_dir_all(beside_script.parent().unwrap()).unwrap();
    fs::rename(home.join("hooks/guard.sh"), &beside_script).unwrap();
    fs::rename(home.join("hooks.json"), &beside_registry).unwrap();
    fs::remove_dir_all(&home).unwrap();
    let left_script = fs::read_to_string(&beside_script).unwrap();
    let left_registry = fs::read_to_string(&beside_registry).unwrap();

    // The refresh renders the hook under `kendex/` and stops there.
    let report = audit(&w.env, &scope(&w)).unwrap();
    kendex_core::apply::execute(&w.env, &report.plan).unwrap();
    assert!(home.join("hooks/guard.sh").is_file());
    let restored: Value =
        serde_json::from_str(&fs::read_to_string(home.join("hooks.json")).unwrap()).unwrap();
    assert_eq!(
        kendex_core::hook::command_stem(
            restored["hooks"]["tool_call"][0]["hooks"][0]["command"]
                .as_str()
                .unwrap()
        ),
        "guard"
    );

    // And the pass after it settles.
    let settled = audit(&w.env, &scope(&w)).unwrap();
    assert!(settled.plan.ops.is_empty(), "{:?}", settled.plan.ops);

    // Nothing touched what is beside the root — not the refresh, and not
    // a removal, which derives its paths the same way.
    let removal = kendex_core::engine::ops::remove(
        &w.env,
        &scope(&w),
        std::slice::from_ref(&"guard".to_owned()),
        None,
        false,
    )
    .unwrap();
    kendex_core::apply::execute(&w.env, &removal.plan).unwrap();
    assert!(
        !home.join("hooks/guard.sh").exists(),
        "removal takes what this build wrote"
    );
    assert_eq!(fs::read_to_string(&beside_script).unwrap(), left_script);
    assert_eq!(fs::read_to_string(&beside_registry).unwrap(), left_registry);
}

/// Is `bun` on PATH? The carrier is TypeScript, so the case below runs the
/// real extension the way its own suite does.
fn bun_on_path() -> Option<std::path::PathBuf> {
    std::env::var_os("PATH").and_then(|path| {
        std::env::split_paths(&path)
            .map(|dir| dir.join("bun"))
            .find(|candidate| candidate.is_file())
    })
}

/// The lanes that have to prove the case below rather than skip it: CI on
/// Linux and macOS, where the kendex-core leg of `.github/workflows/
/// skill-tests.yml`'s cargo shards installs bun. Without bun, the end-to-end
/// case skips and cargo swallows the `eprintln!` of a passing test. Windows
/// installs no bun and skips.
fn bun_is_required() -> bool {
    cfg!(any(target_os = "linux", target_os = "macos"))
        && (std::env::var_os("GITHUB_ACTIONS").is_some() || std::env::var_os("CI").is_some())
}

/// The `bun` an end-to-end case drives the carrier with, or `None` where
/// the case is allowed to skip: a lane `bun_is_required` names fails here
/// instead, since a skipped end-to-end case proves nothing.
// The skip line a `#[test]` body may print without the lint noticing.
#[allow(clippy::print_stderr)]
fn carrier_runner() -> Option<std::path::PathBuf> {
    let bun = bun_on_path();
    assert!(
        bun.is_some() || !bun_is_required(),
        "bun is not on PATH: restore the oven-sh/setup-bun step on the kendex-core leg of the cargo-linux and cargo-macos jobs in .github/workflows/skill-tests.yml, or this case proves nothing"
    );
    if bun.is_none() {
        eprintln!("skipped: bun is not on PATH, so the carrier cannot be run");
    }
    bun
}

/// A hook declared in `kendex.toml` fires under Pi.
///
/// A `[[custom-hooks]]` entry is the case that proves it, because a custom
/// hook has no file of its own — kendex registers the person's command
/// verbatim, so it exists nowhere but the rendered registry. The engine
/// renders it here and the `pi-hooks` carrier's own `tool_call` handler runs
/// it, which is the whole chain the `enforced` label claims.
#[test]
#[allow(clippy::unwrap_used)]
fn a_declared_custom_hook_fires_through_the_carrier() {
    let Some(bun) = carrier_runner() else { return };
    let w = world();
    register_carrier(&w.project.join(".pi"));
    fs::write(
        w.project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"pi\"]\n\n[[custom-hooks]]\nname = \"e2e-guard\"\nevent = \"PreToolUse\"\nmatcher = \"Bash\"\ncommand = \"echo ken-941-fired >&2; exit 2\"\nagents = \"all\"\n",
    )
    .unwrap();

    let report = audit(&w.env, &scope(&w)).unwrap();
    kendex_core::apply::execute(&w.env, &report.plan).unwrap();
    let registry: Value =
        serde_json::from_str(&fs::read_to_string(w.project.join(".pi/kendex/hooks.json")).unwrap())
            .unwrap();
    assert_eq!(
        registry["hooks"]["tool_call"][0]["hooks"][0]["command"],
        "echo ken-941-fired >&2; exit 2",
    );

    // The real carrier, driven the way Pi drives it: one bash tool call.
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let carrier = repo.join("pi-extensions/pi-hooks/extensions/hooks.ts");
    let driver = w.home.join("drive.ts");
    fs::write(
        &driver,
        format!(
            "import piHooks from {carrier};\nlet handler;\npiHooks({{ on(event, callback) {{ if (event === \"tool_call\") handler = callback; }} }});\nconst verdict = await handler(\n\t{{ toolName: \"bash\", input: {{ command: \"git push\" }} }},\n\t{{ cwd: {project}, isProjectTrusted: () => true, sessionManager: {{ getSessionId: () => \"carrier-session\", getSessionFile: () => undefined }} }},\n);\nprocess.stdout.write(JSON.stringify(verdict ?? null));\n",
            carrier = serde_json::to_string(&carrier.to_string_lossy()).unwrap(),
            project = serde_json::to_string(&w.project.to_string_lossy()).unwrap(),
        ),
    )
    .unwrap();

    let run = std::process::Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .current_dir(&w.project)
        // The fixture's global root, so the run reads no Pi install of the
        // developer's; the project root is the walk's own answer from the
        // working directory, which is the project below.
        .env("PI_CODING_AGENT_DIR", w.home.join(".pi/agent"))
        .output()
        .unwrap();
    assert!(
        run.status.success(),
        "carrier run failed: {}",
        String::from_utf8_lossy(&run.stderr)
    );
    let verdict: Value = serde_json::from_slice(&run.stdout).unwrap();
    assert_eq!(verdict["block"], true);
    assert!(
        verdict["reason"]
            .as_str()
            .unwrap()
            .contains("ken-941-fired"),
        "{verdict}"
    );
}

/// End to end, KEN-1189: the listeners `pi_listener` maps events onto
/// besides `tool_call`. kendex rendered a registration under each and labelled
/// it enforced while the carrier read one key, so a `PostToolUse`, `Stop`,
/// `TaskCompleted` or `SessionStart` hook ran nothing — KEN-941's defect, one
/// event narrower.
///
/// `[[custom-hooks]]` entries again, because a custom hook has no file of its
/// own and exists nowhere but the registry. The render is asserted for every
/// listener; the carrier is driven over `tool_result`, whose handler
/// returns its answer rather than delivering it out of band, and whose patched
/// tool result is what the model reads.
#[test]
#[allow(clippy::unwrap_used)]
fn a_declared_hook_on_the_other_listeners_fires_through_the_carrier() {
    let Some(bun) = carrier_runner() else { return };
    let w = world();
    register_carrier(&w.project.join(".pi"));
    fs::write(
        w.project.join("kendex.toml"),
        concat!(
            "schema = 6\n\n[install]\nharnesses = [\"pi\"]\n\n",
            "[[custom-hooks]]\nname = \"e2e-post\"\nevent = \"PostToolUse\"\nmatcher = \"Bash\"\ncommand = \"echo ken-1189-post >&2; exit 2\"\nagents = \"all\"\n\n",
            "[[custom-hooks]]\nname = \"e2e-stop\"\nevent = \"Stop\"\ncommand = \"echo ken-1189-stop >&2; exit 2\"\nagents = \"all\"\n\n",
            "[[custom-hooks]]\nname = \"e2e-session\"\nevent = \"SessionStart\"\ncommand = \"echo ken-1189-session; exit 0\"\nagents = \"all\"\n\n",
            "[[custom-hooks]]\nname = \"e2e-failure\"\nevent = \"StopFailure\"\ncommand = \"exit 0\"\nagents = \"all\"\n\n",
            "[[custom-hooks]]\nname = \"e2e-end\"\nevent = \"SessionEnd\"\ncommand = \"exit 0\"\nagents = \"all\"\n\n",
            "[[custom-hooks]]\nname = \"e2e-pre\"\nevent = \"PreToolUse\"\nmatcher = \"Bash\"\ncommand = \"exit 0\"\nagents = \"all\"\n",
        ),
    )
    .unwrap();

    let report = audit(&w.env, &scope(&w)).unwrap();
    kendex_core::apply::execute(&w.env, &report.plan).unwrap();
    let registry: Value =
        serde_json::from_str(&fs::read_to_string(w.project.join(".pi/kendex/hooks.json")).unwrap())
            .unwrap();
    assert_eq!(
        registry["hooks"]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect::<std::collections::BTreeSet<_>>(),
        DISPATCHED.into_iter().collect(),
    );

    // The real carrier, driven the way Pi drives a tool result.
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let carrier = repo.join("pi-extensions/pi-hooks/extensions/hooks.ts");
    let driver = w.home.join("drive-tool-result.ts");
    fs::write(
        &driver,
        format!(
            "import piHooks from {carrier};\nlet handler;\npiHooks({{ on(event, callback) {{ if (event === \"tool_result\") handler = callback; }} }});\nconst patch = await handler(\n\t{{ toolName: \"bash\", input: {{ command: \"git push\" }}, content: [{{ type: \"text\", text: \"Everything up-to-date\" }}], isError: false }},\n\t{{ cwd: {project}, isProjectTrusted: () => true, sessionManager: {{ getSessionId: () => \"carrier-session\", getSessionFile: () => undefined }} }},\n);\nprocess.stdout.write(JSON.stringify(patch ?? null));\n",
            carrier = serde_json::to_string(&carrier.to_string_lossy()).unwrap(),
            project = serde_json::to_string(&w.project.to_string_lossy()).unwrap(),
        ),
    )
    .unwrap();

    let run = std::process::Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .current_dir(&w.project)
        .env("PI_CODING_AGENT_DIR", w.home.join(".pi/agent"))
        .output()
        .unwrap();
    assert!(
        run.status.success(),
        "carrier run failed: {}",
        String::from_utf8_lossy(&run.stderr)
    );
    let patch: Value = serde_json::from_slice(&run.stdout).unwrap();
    let text: Vec<_> = patch["content"]
        .as_array()
        .unwrap()
        .iter()
        .map(|block| block["text"].as_str().unwrap())
        .collect();
    assert!(
        text.iter().any(|text| text.contains("ken-1189-post")),
        "the declared PostToolUse hook did not reach the tool result: {patch}"
    );
    assert!(
        text.contains(&"Everything up-to-date"),
        "the tool's own result was dropped rather than added to: {patch}"
    );
}
