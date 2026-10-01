use crate::test_util::{fixture_env, rooted, source_path};
use kendex_core::{
    env::Env,
    model::{FileState, HarnessId, ItemKind, Scope},
    scan, settings,
};
use serde_json::{Value, json};
use std::{
    fs,
    path::Path,
    process::{Command, Output},
};

#[allow(clippy::unwrap_used)]
fn kendex(home: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(home)
        .env_clear()
        .envs(fixture_env(home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .output()
        .unwrap()
}

#[test]
fn cli_builtin_disable_enable_verify_and_remove() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    fs::create_dir_all(home.join(".copilot")).unwrap();
    let path = home.join(".copilot/settings.json");
    fs::write(&path, "{\"theme\":\"dark\"}\n").unwrap();
    let listed = kendex(
        &home,
        &["list", "--scope", "global", "--harness", "copilot"],
    );
    assert!(listed.status.success());
    let env = Env::host_rooted(&home);
    let roots = settings::load(&env).unwrap().harness_roots;
    let scopes = [Scope::Global];
    for verb in ["disable", "enable", "disable"] {
        let out = kendex(
            &home,
            &[
                verb,
                "github-mcp-server",
                "--kind",
                "mcp-server",
                "--scope",
                "global",
                "--yes",
            ],
        );
        assert!(out.status.success(), "{:?}", out);
        let config: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(config["theme"], "dark");
        assert_eq!(
            config.get("disabledMcpServers").cloned(),
            if verb == "disable" {
                Some(json!(["github-mcp-server"]))
            } else {
                None
            }
        );
        let listed = kendex(
            &home,
            &["list", "--scope", "global", "--harness", "copilot"],
        );
        assert!(listed.status.success());
        let scanned = scan::scan_scopes(&env, &roots, &scopes);
        assert_eq!(
            scanned
                .items
                .iter()
                .filter(
                    |item| item.harness == HarnessId::Copilot && item.kind == ItemKind::McpServer
                )
                .map(|item| (item.name.as_str(), item.file_state.clone(), item.enabled))
                .collect::<Vec<_>>(),
            vec![
                (
                    "github-mcp-server",
                    FileState::Builtin,
                    Some(verb == "enable")
                ),
                ("githubiq", FileState::Builtin, Some(true)),
            ]
        );
        assert!(
            kendex(&home, &["verify", "github-mcp-server", "--scope", "global"])
                .status
                .success()
        );
    }
    // A lock cannot hide a hand edit of the native switch.
    fs::write(&path, "{\"theme\":\"dark\"}\n").unwrap();
    assert!(
        !kendex(&home, &["verify", "github-mcp-server", "--scope", "global"])
            .status
            .success()
    );
    let out = kendex(
        &home,
        &[
            "remove",
            "github-mcp-server",
            "--scope",
            "global",
            "--no-sweep",
        ],
    );
    assert!(out.status.success(), "{:?}", out);
    assert_eq!(
        serde_json::from_str::<Value>(&fs::read_to_string(path).unwrap()).unwrap(),
        json!({"theme":"dark"})
    );
    assert!(
        kendex(&home, &["verify", "--scope", "global"])
            .status
            .success()
    );
}

#[test]
fn cli_builtin_legacy_settings_refuse_verify_and_toggle() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    fs::create_dir_all(home.join(".copilot")).unwrap();
    let path = home.join(".copilot/settings.json");
    let out = kendex(
        &home,
        &["disable", "github-mcp-server", "--scope", "global", "--yes"],
    );
    assert!(out.status.success(), "{out:?}");
    let legacy = home.join(".copilot/config.json");
    fs::write(&legacy, "{\"theme\":\"dark\"}").unwrap();
    fs::remove_file(&path).unwrap();
    assert!(
        !kendex(&home, &["verify", "github-mcp-server", "--scope", "global"])
            .status
            .success()
    );
    for verb in ["enable", "disable"] {
        let out = kendex(
            &home,
            &[verb, "github-mcp-server", "--scope", "global", "--yes"],
        );
        assert!(!out.status.success(), "{out:?}");
        assert!(!path.exists());
        assert_eq!(fs::read_to_string(&legacy).unwrap(), "{\"theme\":\"dark\"}");
    }
}

#[test]
fn cli_pi_extension_toggles_native_filters_and_verify_reads_them_back() {
    use kendex_core::{lock, manifest, pi_ext};
    for scope_arg in ["global", "project"] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let scope = match scope_arg {
            "global" => Scope::Global,
            "project" => Scope::Project { root: home.clone() },
            _ => unreachable!(),
        };
        let env = Env::host_rooted(&home);
        let source = home.join("catalog/pi-extensions/pi-widgets");
        fs::create_dir_all(&source).unwrap();
        fs::write(
            home.join("catalog/kendex.toml"),
            "is_source_catalog = true\n",
        )
        .unwrap();
        fs::write(
            source.join("package.json"),
            r#"{"name":"pi-widgets","pi":{"extensions":["index.js"]}}"#,
        )
        .unwrap();
        fs::write(
            source.join("index.js"),
            "export default function widgets(pi) {}\n",
        )
        .unwrap();
        let path = manifest::manifest_path(&env, &scope);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, format!(
            "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"pi\"]\n[pi-extensions.pi-widgets]\nsource = \"cat\"\nenabled = false\n", source_path(&home.join("catalog"))
        )).unwrap();
        if matches!(&scope, Scope::Project { .. }) {
            // Discovery accepts home as a project only when it carries a lock.
            lock::save(&lock::lock_path(&env, &scope), &lock::Lock::default()).unwrap();
        }
        let installed = kendex(&home, &["update-pi", "--scope", scope_arg]);
        assert!(installed.status.success(), "{installed:?}");
        let root = pi_ext::scope_root(&env, &scope).unwrap();
        let settings_path = pi_ext::settings_path(&root);
        let mut native: Value = serde_json::from_slice(&fs::read(&settings_path).unwrap()).unwrap();
        assert_eq!(native["packages"][0]["extensions"], json!([]));
        native["theme"] = json!("dark");
        native["packages"][0]["skills"] = json!([]);
        fs::write(&settings_path, serde_json::to_string(&native).unwrap()).unwrap();
        let payload = fs::read(root.join("packages/pi-widgets/index.js")).unwrap();
        let key = lock::entry_key(ItemKind::PiExtension, "pi-widgets", HarnessId::Pi);
        for (explicit, verb) in [
            (true, "enable"),
            (false, "disable"),
            (false, "enable"),
            (true, "disable"),
        ] {
            let mut args = vec![verb, "pi-widgets", "--scope", scope_arg, "--yes"];
            if explicit {
                args.extend(["--kind", "pi-extension"]);
            }
            let result = kendex(&home, &args);
            assert!(result.status.success(), "{verb} {result:?}");
            let config: Value = serde_json::from_slice(&fs::read(&settings_path).unwrap()).unwrap();
            assert_eq!(config["theme"], "dark");
            assert_eq!(config["packages"][0]["skills"], json!([]));
            assert_eq!(
                config["packages"][0].get("extensions").cloned(),
                (verb == "disable").then(|| json!([]))
            );
            assert_eq!(
                fs::read(root.join("packages/pi-widgets/index.js")).unwrap(),
                payload
            );
            assert_eq!(
                lock::load(&lock::lock_path(&env, &scope)).unwrap().entries[&key].enabled,
                verb == "enable"
            );
            let verified = kendex(&home, &["verify", "pi-widgets", "--scope", scope_arg]);
            assert!(verified.status.success(), "{verified:?}");
        }
        // A source update replaces bytes but does not enable a disabled package.
        fs::write(
            source.join("index.js"),
            "export default function updated(pi) {}\n",
        )
        .unwrap();
        let updated = kendex(&home, &["update-pi", "--scope", scope_arg]);
        assert!(updated.status.success(), "{updated:?}");
        assert!(!lock::load(&lock::lock_path(&env, &scope)).unwrap().entries[&key].enabled);
        let verified = kendex(&home, &["verify", "pi-widgets", "--scope", scope_arg]);
        assert!(verified.status.success(), "{verified:?}");
        let check = kendex(&home, &["check", "--scope", scope_arg, "--report-only"]);
        assert_eq!(check.status.code(), Some(0), "{check:?}");
        // Removing the native filter must fail verification with a completed lock.
        let mut config: Value = serde_json::from_slice(&fs::read(&settings_path).unwrap()).unwrap();
        config["packages"][0]
            .as_object_mut()
            .unwrap()
            .remove("extensions");
        fs::write(&settings_path, serde_json::to_string(&config).unwrap()).unwrap();
        let verified = kendex(&home, &["verify", "pi-widgets", "--scope", scope_arg]);
        assert_eq!(verified.status.code(), Some(1), "{verified:?}");
        let check = kendex(&home, &["check", "--scope", scope_arg, "--report-only"]);
        assert_eq!(check.status.code(), Some(1), "{check:?}");
    }
}

#[test]
fn cli_toggle_installed_server_skill_and_hook() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let source = home.join("catalog");
    for dir in ["mcp", "skills/deploy", "hooks"] {
        fs::create_dir_all(source.join(dir)).unwrap();
    }
    fs::write(source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(source.join("mcp/docs.toml"), "command = \"docs\"\n").unwrap();
    fs::write(
        source.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: Ship\n---\nSteps.\n",
    )
    .unwrap();
    fs::write(
        source.join("hooks/audit.sh"),
        "#!/bin/sh\n# ---\n# name: audit\n# event: PreToolUse\n# matcher: Bash\n# ---\nexit 0\n",
    )
    .unwrap();
    fs::create_dir_all(home.join(".copilot")).unwrap();
    let env = kendex_core::env::Env::host_rooted(&home);
    let manifest_path =
        kendex_core::manifest::manifest_path(&env, &kendex_core::model::Scope::Global);
    fs::create_dir_all(manifest_path.parent().unwrap()).unwrap();
    fs::write(manifest_path, format!(
        "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"copilot\"]\nmethod = \"copy\"\n[mcp-servers.docs]\nsource = \"cat\"\n[skills.deploy]\nsource = \"cat\"\n[hooks.audit]\nsource = \"cat\"\n", source_path(&source))).unwrap();
    // Enabling uses the same plan as the app, so it also settles a declared install.
    for (kind, name) in [
        ("mcp-server", "docs"),
        ("skill", "deploy"),
        ("hook", "audit"),
    ] {
        for verb in ["enable", "disable", "enable"] {
            let out = kendex(
                &home,
                &[verb, name, "--kind", kind, "--scope", "global", "--yes"],
            );
            assert!(out.status.success(), "{kind} {verb}: {:?}", out);
            let read = kendex_core::engine::ops::manifest_for_reading(
                &env,
                &kendex_core::model::Scope::Global,
            )
            .unwrap();
            let kind = match kind {
                "mcp-server" => kendex_core::model::ItemKind::McpServer,
                "skill" => kendex_core::model::ItemKind::Skill,
                "hook" => kendex_core::model::ItemKind::Hook,
                _ => unreachable!(),
            };
            assert_eq!(read.declared(kind)[name].enabled, verb == "enable");
            let verified = kendex(&home, &["verify", name, "--scope", "global"]);
            assert!(verified.status.success(), "{kind:?} {verb}: {verified:?}");
        }
    }
}
