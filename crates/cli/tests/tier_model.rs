//! Both runtime transports use the real CLI and fixture-home process isolation.
use crate::test_util::{fixture_env, rooted};
use serde_json::{Value, json};
use std::io::Write;
use std::path::Path;
use std::process::{Command, Output, Stdio};

#[allow(clippy::unwrap_used)]
fn invoke(home: &Path, args: &[&str], context: Option<&Value>) -> Output {
    invoke_at(home, home, args, context, None)
}

#[allow(clippy::unwrap_used)]
fn invoke_at(
    home: &Path,
    cwd: &Path,
    args: &[&str],
    context: Option<&Value>,
    path: Option<&Path>,
) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_kendex"));
    command
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(fixture_env(home))
        // Windows known folders ignore HOME, and the personal install lives
        // under the fixture home's own config dir.
        .env("KENDEX_REAL_HOME", home)
        .env("KENDEX_UI", "plain")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(path) = path {
        command.env("PATH", path);
    }
    let mut child = command.spawn().unwrap();
    if let Some(context) = context {
        child
            .stdin
            .take()
            .unwrap()
            .write_all(context.to_string().as_bytes())
            .unwrap();
    }
    child.wait_with_output().unwrap()
}
fn context() -> Value {
    json!({"protocol":"model-resolution-v1","harness":"pi","account":"fixture","host":"host","providers":["openai"],"currentProvider":"openai",
        "models":{"tag":"complete","source":"fixture:list","account":"fixture","host":"host","models":[{"provider":"openai","id":"gpt-6.1-terra","nativeSelector":null,"allowed":true,"chat":true,"isDefault":true}]},
        "default":{"tag":"native-default"},"capacity":[{"tag":"known","selector":"openai/gpt-6.1-terra","account":"fixture","host":"host","source":"fixture:capacity","context_window":1000}],"rejected":[]})
}

#[cfg(unix)]
#[test]
fn codex_collector_process_failure_stays_failed_after_complete_protocol() {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    // Native app-server can complete RPC and still exit unsuccessfully.
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let bin = home.join("bin");
    fs::create_dir(&bin).unwrap();
    let codex = bin.join("codex");
    fs::write(
        &codex,
        concat!(
            "#!/bin/sh\n",
            "test \"$1\" = app-server || exit 8\n",
            "IFS= read -r request || exit 8\n",
            "printf '%s\\n' '{\"id\":0,\"result\":{}}'\n",
            "IFS= read -r request || exit 8\n",
            "IFS= read -r request || exit 8\n",
            "printf '%s\\n' '{\"id\":1,\"result\":{\"data\":[],\"nextCursor\":null}}'\n",
            "while IFS= read -r request; do :; done\n",
            "exit 7\n",
        ),
    )
    .unwrap();
    fs::set_permissions(&codex, fs::Permissions::from_mode(0o700)).unwrap();
    let mut evidence = context();
    evidence["harness"] = json!("codex");
    let output = invoke_at(
        &home,
        &home,
        &[
            "tier-model",
            "codex",
            "--model",
            "standard",
            "--runtime-context-stdin",
            "--discover-codex-models",
            "--json",
        ],
        Some(&evidence),
        Some(&bin),
    );
    assert!(output.status.success(), "{output:?}");
    let response: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(response["resolution"]["tag"], "harness-default");
    assert!(
        response["resolution"]["diagnostics"]
            .as_array()
            .unwrap()
            .iter()
            .any(|cause| cause["code"] == "model-list-failed"
                && cause["source"] == "codex:model/list"
                && !cause["cause"].as_str().unwrap().is_empty())
    );
}
#[test]
fn runtime_transports_return_confirmed_selection_and_clean_stdout() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let evidence = context();
    let payload = evidence.to_string();
    for (args, stdin, class) in [
        (
            vec![
                "tier-model",
                "pi",
                "--model",
                "fast",
                "--runtime-context-stdin",
                "--json",
            ],
            Some(&evidence),
            "fast",
        ),
        (
            vec![
                "tier-model",
                "pi",
                "--model",
                "fast",
                "--runtime-context-json",
                &payload,
                "--json",
            ],
            None,
            "fast",
        ),
        (
            vec![
                "tier-model",
                "pi",
                "--model",
                "standard",
                "--runtime-context-stdin",
                "--json",
            ],
            Some(&evidence),
            "standard",
        ),
        (
            vec![
                "tier-model",
                "pi",
                "--model",
                "top",
                "--runtime-context-json",
                &payload,
                "--json",
            ],
            None,
            "top",
        ),
    ] {
        let output = invoke(&home, &args, stdin);
        assert!(output.status.success(), "{output:?}");
        let response: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(response["protocol"], "model-resolution-v1");
        assert!(response.get("selectorChange").is_none());
        assert_eq!(response["request"]["tag"], "class");
        assert_eq!(response["request"]["class"], class);
        assert_eq!(response["resolution"]["tag"], "selected");
        assert_eq!(
            response["resolution"]["selection"]["nativeSelector"],
            "openai/gpt-6.1-terra"
        );
        assert!(
            output.stderr.is_empty(),
            "JSON consumers own warnings: {output:?}"
        );
    }
}
#[test]
fn native_root_observation_returns_core_comparison_and_list_failure() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    for (prior, current, tag) in [
        (None, "claude-opus-5-5", "unknown"),
        (Some("opus"), "claude-opus-5-5", "equivalent"),
        (Some("claude-opus-5-5"), "claude-opus-5-5", "equivalent"),
        (Some("opus"), "claude-sonnet-5", "changed"),
    ] {
        let evidence = json!({"protocol":"model-resolution-v1","harness":"claude","account":"fixture","host":"host","providers":["anthropic"],"currentProvider":null,
            "models":{"tag":"failed","source":"fixture:reader","cause":"read failed"},"default":{"tag":"native-default"},"capacity":[],"rejected":[],
            "selectorObservation":{"priorSelector":prior,"currentSelector":current}});
        let output = invoke(
            &home,
            &[
                "tier-model",
                "claude",
                "--model",
                "standard",
                "--runtime-context-stdin",
                "--json",
            ],
            Some(&evidence),
        );
        assert!(output.status.success(), "{output:?}");
        let response: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(response["selectorChange"], json!({"tag":tag}));
        assert_eq!(response["resolution"]["tag"], "harness-default");
        assert_eq!(
            response["resolution"]["path"],
            json!({"tag":"native-default"})
        );
        assert!(
            response["resolution"]["diagnostics"]
                .as_array()
                .unwrap()
                .iter()
                .any(|d| d["code"] == "model-list-failed"
                    && d["source"] == "fixture:reader"
                    && d["cause"] == "read failed")
        );
    }
}
#[test]
fn malformed_native_root_observations_refuse_before_output() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    for observation in [
        json!({"priorSelector":"opus","currentSelector":""}),
        json!({"priorSelector":"a b","currentSelector":"claude-opus-5-5"}),
        json!({"priorSelector":"opus"}),
        json!({"priorSelector":false,"currentSelector":"claude-opus-5-5"}),
    ] {
        let mut evidence = context();
        evidence["selectorObservation"] = observation;
        let output = invoke(
            &home,
            &[
                "tier-model",
                "pi",
                "--model",
                "standard",
                "--runtime-context-stdin",
                "--json",
            ],
            Some(&evidence),
        );
        assert!(!output.status.success(), "{output:?}");
        assert!(output.stdout.is_empty());
    }
}
#[test]
fn failed_list_unknown_capacity_and_empty_list_preserve_default() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let mut evidence = context();
    for list in [
        json!({"tag":"unsupported","source":"fixture:interface"}),
        json!({"tag":"failed","source":"fixture:reader","cause":"read failed"}),
        json!({"tag":"complete","source":"fixture:empty","account":"fixture","host":"host","models":[]}),
    ] {
        evidence["models"] = list;
        let output = invoke(
            &home,
            &[
                "tier-model",
                "pi",
                "--model",
                "fast",
                "--runtime-context-stdin",
                "--json",
            ],
            Some(&evidence),
        );
        assert!(output.status.success(), "{output:?}");
        let response: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(response["resolution"]["tag"], "harness-default");
        assert_eq!(response["resolution"]["path"]["tag"], "native-default");
        assert_eq!(response["resolution"]["capacity"]["tag"], "unknown");
        assert!(response["resolution"].get("selection").is_none());
    }
    evidence = context();
    evidence["capacity"] = json!([]);
    let output = invoke(
        &home,
        &[
            "tier-model",
            "pi",
            "--model",
            "fast",
            "--runtime-context-stdin",
            "--json",
        ],
        Some(&evidence),
    );
    assert!(output.status.success());
    let response: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(
        response["resolution"]["diagnostics"][0]["code"],
        "model-capacity-unknown"
    );
}
#[test]
fn unknown_pin_warns_once_with_original_request_and_failed_source() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let mut evidence = context();
    evidence["models"] = json!({"tag":"failed","source":"fixture:reader","cause":"read failed"});
    let output = invoke(
        &home,
        &[
            "tier-model",
            "pi",
            "--model",
            "openai/user-pin",
            "--runtime-context-stdin",
        ],
        Some(&evidence),
    );
    assert!(output.status.success());
    assert_eq!(String::from_utf8(output.stdout).unwrap(), "inherit\n");
    let warning = String::from_utf8(output.stderr).unwrap();
    assert_eq!(
        warning
            .lines()
            .filter(|l| l.starts_with("model-resolution:"))
            .count(),
        1
    );
    for key in [
        "requested=openai/user-pin",
        "old-id",
        "model-availability-unknown",
        "model-list-failed",
        "source=fixture:reader",
        "detail=read failed",
    ] {
        assert!(warning.contains(key), "{warning}");
    }
}
/// The Claude plugin logs `warning` verbatim, so it must be the plain path's line.
#[test]
fn json_warning_is_the_line_the_plain_path_prints() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let mut fallback = context();
    fallback["models"] = json!({"tag":"failed","source":"fixture:reader","cause":"read failed"});
    for (evidence, warns) in [(fallback, true), (context(), false)] {
        let args = [
            "tier-model",
            "pi",
            "--model",
            "fast",
            "--runtime-context-stdin",
        ];
        let plain = invoke(&home, &args, Some(&evidence));
        assert!(plain.status.success(), "{plain:?}");
        let stderr = String::from_utf8(plain.stderr).unwrap();
        let printed = stderr
            .lines()
            .find(|l| l.starts_with("model-resolution:"))
            .map(str::to_owned);
        let json = invoke(&home, &[&args[..], &["--json"]].concat(), Some(&evidence));
        assert!(json.status.success(), "{json:?}");
        let response: Value = serde_json::from_slice(&json.stdout).unwrap();
        assert_eq!(printed.is_some(), warns, "{stderr}");
        assert_eq!(
            response.get("warning").and_then(Value::as_str),
            printed.as_deref(),
            "{response}"
        );
        assert!(json.stderr.is_empty(), "{json:?}");
    }
}
#[test]
fn no_model_and_confirmed_unavailable_pin_refuse_with_tags() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    for (model, mut evidence, code) in [
        ("top", context(), "no-model"),
        ("openai/missing", context(), "model-unavailable"),
    ] {
        if code == "no-model" {
            evidence["models"] = json!({"tag":"unsupported","source":"fixture:none"});
            evidence["default"] = json!({"tag":"no-usable-model","source":"fixture:default","cause":"affirmative no usable path"});
        }
        let output = invoke(
            &home,
            &[
                "tier-model",
                "pi",
                "--model",
                model,
                "--runtime-context-stdin",
                "--json",
            ],
            Some(&evidence),
        );
        assert!(!output.status.success(), "{output:?}");
        let response: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(response["resolution"]["tag"], "refused");
        assert_eq!(response["resolution"]["code"], code);
    }
}
#[test]
fn malformed_and_cross_account_inputs_never_select() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    for (field, value) in [
        ("protocol", "wrong"),
        ("host", "other-host"),
        ("harness", "codex"),
    ] {
        let mut evidence = context();
        evidence[field] = json!(value);
        let output = invoke(
            &home,
            &[
                "tier-model",
                "pi",
                "--model",
                "fast",
                "--runtime-context-stdin",
                "--json",
            ],
            Some(&evidence),
        );
        assert!(!output.status.success(), "{field}: {output:?}");
        assert!(output.stdout.is_empty());
    }
    for args in [
        vec!["tier-model", "pi", "1", "--model", "fast"],
        vec!["tier-model", "pi", "--model", "a b"],
        vec!["tier-model", "codex", "0"],
    ] {
        assert!(!invoke(&home, &args, None).status.success());
    }
    for (tier, risk) in [("micro", "normal"), ("small", "complex")] {
        let output = invoke(
            &home,
            &[
                "tier-model",
                "pi",
                "--item-tier",
                tier,
                "--risk",
                risk,
                "--runtime-context-stdin",
                "--json",
            ],
            Some(&context()),
        );
        assert!(!output.status.success(), "{output:?}");
        assert!(output.stdout.is_empty(), "{output:?}");
    }
}

fn installed_native_agent_fixture(
    home: &Path,
    project: &Path,
    catalog: &Path,
) -> Result<kendex_core::env::Env, Box<dyn std::error::Error>> {
    use kendex_core::{env::Env, model::Scope};
    use std::fs;
    fs::create_dir_all(project.join(".claude"))?;
    fs::create_dir_all(catalog.join("agents"))?;
    fs::write(
        catalog.join("agents/worker.md"),
        "---\nname: worker\ndescription: Work\nmodel: light\n---\nBody.\n",
    )?;
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 7\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\"]\n[agents.worker]\nsource = \"cat\"\n[agent-frontmatter.claude.worker]\nmodel = \"fast\"\n",
            crate::test_util::source_path(catalog)
        ),
    )?;
    let env = Env::host_rooted(home.to_path_buf());
    let report = kendex_core::engine::audit(
        &env,
        &Scope::Project {
            root: project.to_path_buf(),
        },
    )?;
    kendex_core::apply::execute(&env, &report.plan)?;
    Ok(env)
}

fn globally_installed_class_agent_fixture(
    home: &Path,
    catalog: &Path,
    env: &kendex_core::env::Env,
) -> Result<(std::path::PathBuf, Value), Box<dyn std::error::Error>> {
    use kendex_core::model::Scope;
    use std::fs;
    fs::write(
        catalog.join("agents/worker.md"),
        "---\nname: worker\ndescription: Work\nmodel: standard\n---\nBody.\n",
    )?;
    let personal_path = kendex_core::manifest::manifest_path(env, &Scope::Global);
    fs::create_dir_all(
        personal_path
            .parent()
            .ok_or("personal manifest path has no parent")?,
    )?;
    fs::write(
        &personal_path,
        format!(
            "schema = 7\nmodel-classes.standard = \"anthropic/claude-opus-5\"\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\"]\n[agents.worker]\nsource = \"cat\"\n",
            crate::test_util::source_path(catalog)
        ),
    )?;
    let report = kendex_core::engine::audit(env, &Scope::Global)?;
    kendex_core::apply::execute(env, &report.plan)?;
    let class_project = home.join("class-project");
    fs::create_dir_all(&class_project)?;
    fs::write(
        class_project.join("kendex.toml"),
        "schema = 7\nmodel-classes.standard = \"anthropic/claude-sonnet-5\"\n",
    )?;
    let evidence = json!({"protocol":"model-resolution-v1","harness":"claude","account":"fixture","host":"host","providers":["anthropic"],"currentProvider":"anthropic",
        "models":{"tag":"complete","source":"fixture:list","account":"fixture","host":"host","models":[
            {"provider":"anthropic","id":"claude-opus-5","nativeSelector":null,"allowed":true,"chat":true,"isDefault":true},
            {"provider":"anthropic","id":"claude-sonnet-5","nativeSelector":null,"allowed":true,"chat":true,"isDefault":false}]},
        "default":{"tag":"native-default"},"capacity":[
            {"tag":"known","selector":"claude-opus-5","account":"fixture","host":"host","source":"fixture:capacity","context_window":1000},
            {"tag":"known","selector":"claude-sonnet-5","account":"fixture","host":"host","source":"fixture:capacity","context_window":1000}],"rejected":[]});
    Ok((class_project, evidence))
}

#[test]
fn native_agent_lookup_retains_intent_and_refuses_edited_managed_bytes() {
    use std::fs;
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("project");
    let catalog = home.join("catalog");
    let env = installed_native_agent_fixture(&home, &project, &catalog).unwrap();
    let evidence = json!({"protocol":"model-resolution-v1","harness":"claude","account":"fixture","host":"host","providers":["anthropic"],"currentProvider":null,"models":{"tag":"failed","source":"fixture:reader","cause":"read failed"},"default":{"tag":"native-default"},"capacity":[],"rejected":[]});
    for (agent, tag, class) in [
        ("worker", "harness-default", Some("fast")),
        ("other", "unmanaged", None),
    ] {
        let output = invoke_at(
            &home,
            &project,
            &[
                "tier-model",
                "claude",
                "--agent",
                agent,
                "--runtime-context-stdin",
                "--json",
            ],
            Some(&evidence),
            None,
        );
        assert!(output.status.success(), "{output:?}");
        let response: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(response["resolution"]["tag"], tag);
        assert_eq!(response["request"]["class"].as_str(), class);
        assert!(output.stderr.is_empty());
    }
    fs::write(
        project.join(".claude/agents/worker.md"),
        "edited installation",
    )
    .unwrap();
    let output = invoke_at(
        &home,
        &project,
        &[
            "tier-model",
            "claude",
            "--agent",
            "worker",
            "--runtime-context-stdin",
            "--json",
        ],
        Some(&evidence),
        None,
    );
    assert!(!output.status.success());
    let response: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(response["resolution"]["tag"], "refused");
    assert_eq!(response["resolution"]["code"], "agent-request-unreadable");

    // A globally installed agent can run under a project's class replacement.
    let (class_project, evidence) =
        globally_installed_class_agent_fixture(&home, &catalog, &env).unwrap();
    for (cwd, expected) in [
        (&class_project, "claude-sonnet-5"),
        (&home, "claude-opus-5"),
    ] {
        for (flag, value) in [("--agent", "worker"), ("--model", "standard")] {
            let output = invoke_at(
                &home,
                cwd,
                &[
                    "tier-model",
                    "claude",
                    flag,
                    value,
                    "--runtime-context-stdin",
                    "--json",
                ],
                Some(&evidence),
                None,
            );
            assert!(output.status.success(), "{output:?}");
            let response: Value = serde_json::from_slice(&output.stdout).unwrap();
            assert_eq!(response["request"]["class"], "standard");
            assert_eq!(response["resolution"]["tag"], "selected");
            assert_eq!(
                response["resolution"]["selection"]["concreteId"],
                expected,
                "{flag} at {}",
                cwd.display()
            );
            assert!(output.stderr.is_empty());
        }
    }
}
