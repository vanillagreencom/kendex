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
        .env("KENDEX_REAL_HOME", home)
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
    use kendex_core::{lock, manifest};
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    fs::create_dir_all(home.join(".copilot")).unwrap();
    let settings_path = home.join(".copilot/settings.json");
    let out = kendex(
        &home,
        &["disable", "github-mcp-server", "--scope", "global", "--yes"],
    );
    assert!(out.status.success(), "{out:?}");
    let legacy = home.join(".copilot/config.json");
    fs::write(&legacy, "{\"theme\":\"dark\"}").unwrap();
    fs::remove_file(&settings_path).unwrap();
    let env = Env::host_rooted(&home);
    let watched = [
        manifest::manifest_path(&env, &Scope::Global),
        lock::lock_path(&env, &Scope::Global),
        legacy,
    ];
    let before: Vec<_> = watched
        .iter()
        .map(|path| (path, fs::read(path).unwrap()))
        .collect();
    for verb in ["verify", "enable", "disable"] {
        let mut args = vec![verb, "github-mcp-server", "--scope", "global"];
        if verb != "verify" {
            args.push("--yes");
        }
        let out = kendex(&home, &args);
        assert_eq!(out.status.code(), Some(1), "{verb}: {out:?}");
        for (path, bytes) in &before {
            assert_eq!(&fs::read(path).unwrap(), bytes, "{verb}: {path:?}");
        }
        assert!(!settings_path.exists());
    }
}

#[test]
fn cli_builtin_legacy_catalog_refuses_verify_toggle_and_remove() {
    use kendex_core::{apply, engine::ops, lock, manifest};
    for project in [false, true] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        fs::create_dir_all(home.join(".copilot")).unwrap();
        fs::create_dir_all(home.join(".github/copilot")).unwrap();
        let env = Env::host_rooted(&home);
        let scope = if project {
            Scope::Project { root: home.clone() }
        } else {
            Scope::Global
        };
        let scope_arg = if project { "project" } else { "global" };
        let path = manifest::manifest_path(&env, &scope);
        let lock_path = lock::lock_path(&env, &scope);
        let settings_path = kendex_core::harness::copilot::settings::settings_file(&env, &scope);
        let names = ["deploy", "githubiq", "github-mcp-server"];
        let source = home.join("builtin");
        for (relative, body) in [
            ("kendex.toml", "is_source_catalog = true\n"),
            (
                "skills/deploy/SKILL.md",
                "---\nname: deploy\ndescription: Ship\n---\nSteps.\n",
            ),
            ("mcp/githubiq.toml", "command = \"custom\"\n"),
            ("mcp/github-mcp-server.toml", "command = \"custom\"\n"),
        ] {
            let file = source.join(relative);
            fs::create_dir_all(file.parent().unwrap()).unwrap();
            fs::write(file, body).unwrap();
        }
        let report = ops::add(
            &env,
            &scope,
            &ops::AddRequest {
                source: Some(source.to_str().unwrap().into()),
                skills: vec!["deploy".into()],
                mcp_servers: names[1..].iter().map(|name| (*name).into()).collect(),
                harnesses: Some(vec![HarnessId::Copilot]),
                method: Some(manifest::Method::Copy),
                ..Default::default()
            },
        )
        .unwrap();
        apply::execute(&env, &report.plan).unwrap();
        fs::write(
            &settings_path,
            "{\"theme\":\"dark\",\"disabledMcpServers\":[\"githubiq\",\"github-mcp-server\"]}\n",
        )
        .unwrap();

        let verified = kendex(&home, &["verify", "--scope", scope_arg]);
        assert_eq!(verified.status.code(), Some(0), "{verified:?}");
        let record = lock::load(&lock_path).unwrap();
        let skill =
            &record.entries[&lock::entry_key(ItemKind::Skill, "deploy", HarnessId::Copilot)];
        fs::remove_file(skill.emitted.as_ref().unwrap().paths[0].join("SKILL.md")).unwrap();
        let missing = kendex(&home, &["verify", "deploy", "--scope", scope_arg]);
        assert_eq!(missing.status.code(), Some(1), "{missing:?}");
        // The shipped basename allocators saved the catalog alias in both files.
        // Only alias tokens change; recorded positions and catalog provenance stay intact.
        let aliases = 3 + usize::from(record.sources.contains_key("builtin-2"));
        for (file, count) in [(&path, 4), (&lock_path, aliases)] {
            let before = fs::read_to_string(file).unwrap();
            assert_eq!(before.matches("builtin-2").count(), count);
            let legacy = before.replace("builtin-2", "builtin");
            assert_ne!(legacy, before);
            fs::write(file, legacy).unwrap();
        }
        let watched = [
            path,
            lock_path,
            settings_path,
            if project {
                home.join(".github/mcp.json")
            } else {
                home.join(".copilot/mcp-config.json")
            },
        ];
        let before: Vec<_> = watched
            .iter()
            .map(|path| (path, fs::read(path).unwrap()))
            .collect();
        for name in names {
            for verb in ["verify", "enable", "disable", "remove"] {
                let mut args = vec![verb, name, "--scope", scope_arg];
                if verb == "enable" || verb == "disable" {
                    args.push("--yes");
                }
                if verb == "remove" {
                    args.push("--no-sweep");
                }
                let out = kendex(&home, &args);
                assert_eq!(out.status.code(), Some(1), "{name} {verb}: {out:?}");
                for (path, bytes) in &before {
                    assert_eq!(&fs::read(path).unwrap(), bytes, "{verb}: {path:?}");
                }
            }
        }
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
fn cli_saved_pi_config_selection_survives_enable_update_and_refused_disable() {
    use kendex_core::{lock, manifest, pi_ext};
    let name = "@vanillagreen/pi-hooks";
    for scope_arg in ["global", "project"] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let scope = if scope_arg == "global" {
            Scope::Global
        } else {
            Scope::Project { root: home.clone() }
        };
        let env = Env::host_rooted(&home);
        let catalog = home.join("catalog");
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
        let path = manifest::manifest_path(&env, &scope);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, format!(
            "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"pi\"]\n[pi-extensions.\"{name}\"]\nsource = \"cat\"\n", source_path(&catalog)
        )).unwrap();
        let lock_path = lock::lock_path(&env, &scope);
        if matches!(&scope, Scope::Project { .. }) {
            lock::save(&lock_path, &lock::Lock::default()).unwrap();
        }
        let installed = kendex(&home, &["update-pi", "--scope", scope_arg]);
        assert!(installed.status.success(), "{installed:?}");
        let settings_path = pi_ext::settings_path(&pi_ext::scope_root(&env, &scope).unwrap());
        // The shipped pi config selector writes this exact exclusion.
        let native = json!({"theme":"dark", "packages":["./unmanaged", {
            "source":"./packages/@vanillagreen/pi-hooks",
            "extensions":["-extensions/lane-mail-wake.ts"], "skills":[], "themes":[],
            "prompts":["+prompts/review.md"]
        }, {"source":"./other", "extensions":["-extensions/other.ts"]}]});
        fs::write(&settings_path, format!("{native}\r\n")).unwrap();
        for args in [
            vec!["enable", name, "--scope", scope_arg, "--yes"],
            vec!["update-pi", "--scope", scope_arg],
        ] {
            if args[0] == "update-pi" {
                fs::write(
                    source.join("extensions/hooks.ts"),
                    "export default function updated(pi) {}\n",
                )
                .unwrap();
            }
            let result = kendex(&home, &args);
            assert!(result.status.success(), "{result:?}");
            assert_eq!(
                serde_json::from_slice::<Value>(&fs::read(&settings_path).unwrap()).unwrap(),
                native
            );
        }
        let settings_before = fs::read(&settings_path).unwrap();
        let manifest_before = fs::read(&path).unwrap();
        let lock_before = fs::read(&lock_path).unwrap();
        let result = kendex(&home, &["disable", name, "--scope", scope_arg, "--yes"]);
        assert_eq!(result.status.code(), Some(1), "{result:?}");
        assert_eq!(fs::read(&settings_path).unwrap(), settings_before);
        assert_eq!(fs::read(&path).unwrap(), manifest_before);
        assert_eq!(fs::read(&lock_path).unwrap(), lock_before);
        let disabled = fs::read_to_string(&path)
            .unwrap()
            .replace("source = \"cat\"", "source = \"cat\"\nenabled = false");
        fs::write(&path, disabled).unwrap();
        fs::write(
            source.join("extensions/hooks.ts"),
            "export default function disabledUpdate(pi) {}\n",
        )
        .unwrap();
        let result = kendex(&home, &["update-pi", "--scope", scope_arg]);
        assert_eq!(result.status.code(), Some(1), "{result:?}");
        assert_eq!(fs::read(&settings_path).unwrap(), settings_before);
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
