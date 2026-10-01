use crate::test_util::{fixture_env, rooted, source_path};
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
    let table = String::from_utf8_lossy(&listed.stderr);
    for name in ["github-mcp-server", "githubiq"] {
        assert!(
            table
                .lines()
                .any(|line| line.contains(name) && line.contains("built-in, on"))
        );
    }
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
        let table = String::from_utf8_lossy(&listed.stderr);
        let state = if verb == "disable" {
            "built-in, off"
        } else {
            "built-in, on"
        };
        assert!(
            table
                .lines()
                .any(|line| line.contains("github-mcp-server") && line.contains(state))
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
