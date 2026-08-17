//! The hook half of the `vstack check` contract: what counts as a hook
//! being installed per harness — native script and registration, the Codex
//! prose fallback, and a harness that will not run what is fully there.

use super::*;

/// A Codex hook whose event has no native equivalent installs as prose inside
/// agent TOMLs. In a scope with no Codex agents there is nothing to write —
/// and nothing to miss, so it must not read as permanent drift no `add` or
/// `refresh` could ever clear.
#[test]
fn a_codex_prose_fallback_hook_is_not_drift_before_an_agent_exists() {
    let sb = Sandbox::new("check-codex-prose");
    // TaskCompleted has no Codex equivalent, so this installs as prose only.
    sb.write_hook_for_event("guard", "TaskCompleted");
    sb.write_agent("rust");
    let add = |args: &[&str]| {
        let output = sb
            .vstack()
            .args(["add", sb.source.to_str().unwrap()])
            .args(args)
            .args(["--harness", "codex", "--no-auto-skills", "-y"])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "add failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stderr).into_owned()
    };

    // No Codex agent anywhere yet.
    let log = add(&["--hook", "guard"]);
    assert!(
        log.contains("no artifact yet"),
        "add must say it wrote nothing rather than claim a plain success: {log}"
    );
    let quiet = sb.check(&["--quiet"]);
    assert_eq!(
        quiet.status.code(),
        Some(0),
        "an unwritable-yet fallback is not drift: {}",
        text(&quiet.stderr)
    );
    assert!(quiet.stderr.is_empty(), "{}", text(&quiet.stderr));

    // Installing a Codex agent gives the fallback somewhere to live; the lock
    // entry is what drives that, so it must still record codex.
    add(&["--agent", "rust"]);
    let toml = sb.project.join(".codex/agents/rust.toml");
    let content = fs::read_to_string(&toml).unwrap();
    assert!(content.contains("## Safety: guard"), "{content}");
    let quiet = sb.check(&["--quiet"]);
    assert_eq!(quiet.status.code(), Some(0), "{}", text(&quiet.stderr));

    // Control: with an agent present, losing the prose IS drift.
    fs::write(
        &toml,
        content.replace("## Safety: guard", "## Safety: removed"),
    )
    .unwrap();
    let quiet = sb.check(&["--quiet"]);
    assert_eq!(quiet.status.code(), Some(1), "{}", text(&quiet.stderr));
    let err = text(&quiet.stderr);
    assert!(err.contains("guard (hook)"), "{err}");
}

/// A hook whose name is an ordinary word in the generated agent header ("check",
/// "add", "run") must still get its safety prose: the idempotency skip and the
/// presence check have to agree on the anchored marker, not on a bare substring.
#[test]
fn a_prose_hook_named_like_a_common_word_is_written_and_verified() {
    let sb = Sandbox::new("check-codex-word");
    sb.write_hook_for_event("check", "TaskCompleted");
    sb.write_agent("rust");
    let add = |args: &[&str]| {
        let output = sb
            .vstack()
            .args(["add", sb.source.to_str().unwrap()])
            .args(args)
            .args(["--harness", "codex", "--no-auto-skills", "-y"])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "add failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    };
    add(&["--agent", "rust"]);
    add(&["--hook", "check"]);

    let toml = sb.project.join(".codex/agents/rust.toml");
    let content = fs::read_to_string(&toml).unwrap();
    assert!(
        content.contains("## Safety: check"),
        "the word `check` in the header must not be mistaken for the block: {content}"
    );
    let quiet = sb.check(&["--quiet"]);
    assert_eq!(quiet.status.code(), Some(0), "{}", text(&quiet.stderr));

    // Control: losing the block IS drift.
    fs::write(
        &toml,
        content.replace("## Safety: check", "## Safety: something-else"),
    )
    .unwrap();
    let quiet = sb.check(&["--quiet"]);
    assert_eq!(quiet.status.code(), Some(1), "{}", text(&quiet.stderr));
    assert!(
        text(&quiet.stderr).contains("check (hook)"),
        "{}",
        text(&quiet.stderr)
    );
}

/// A natively supported Codex event installs a SCRIPT, whose absence is drift
/// whether or not the scope has agent TOMLs — the prose-fallback guard must
/// not silence it.
#[test]
fn a_deleted_native_codex_hook_script_is_drift_without_any_agents() {
    let sb = Sandbox::new("check-codex-native");
    sb.write_hook_for_event("guard", "PreToolUse");
    let output = sb
        .vstack()
        .args([
            "add",
            sb.source.to_str().unwrap(),
            "--hook",
            "guard",
            "--harness",
            "codex",
            "--no-auto-skills",
            "-y",
        ])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "add failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let script = sb.project.join(".codex/hooks/guard.sh");
    assert!(script.exists(), "a native event installs a script");
    assert!(
        !sb.project.join(".codex/agents").exists()
            || fs::read_dir(sb.project.join(".codex/agents"))
                .map(|entries| entries.count() == 0)
                .unwrap_or(true),
        "this scope deliberately has no Codex agents"
    );

    let clean = sb.check(&["--quiet"]);
    assert_eq!(clean.status.code(), Some(0), "{}", text(&clean.stderr));

    fs::remove_file(&script).unwrap();
    let quiet = sb.check(&["--quiet"]);
    assert_eq!(
        quiet.status.code(),
        Some(1),
        "a deleted native script is drift even with no agents: {}",
        text(&quiet.stderr)
    );
    assert!(
        text(&quiet.stderr).contains("guard (hook)"),
        "{}",
        text(&quiet.stderr)
    );

    // Deleting hooks.json too must not launder the hook into a prose
    // fallback: nativeness comes from the hook's EVENT in its source, which
    // no amount of deleted install artifacts can rewrite.
    fs::remove_file(sb.project.join(".codex/hooks.json")).unwrap();
    let quiet = sb.check(&["--quiet"]);
    assert_eq!(
        quiet.status.code(),
        Some(1),
        "a fully-deleted native install is still drift: {}",
        text(&quiet.stderr)
    );
}

/// `pre-check.sh` in hooks.json must never answer for a hook named `check`:
/// nativeness is derived from each hook's EVENT in its source, so a
/// prose-fallback hook whose name nests inside a native sibling's stays a
/// prose fallback — not a phantom native install with an impossible remedy.
#[test]
fn a_prose_hook_nested_inside_a_native_hooks_name_is_not_phantom_drift() {
    let sb = Sandbox::new("check-codex-nested");
    sb.write_hook_for_event("pre-check", "PreToolUse"); // native script
    sb.write_hook_for_event("check", "TaskCompleted"); // prose-only event
    let add = |name: &str| {
        let output = sb
            .vstack()
            .args(["add", sb.source.to_str().unwrap(), "--hook", name])
            .args(["--harness", "codex", "--no-auto-skills", "-y"])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "add failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    };
    add("pre-check");
    add("check");

    // The trap is real: the registration file contains `pre-check.sh`, whose
    // name CONTAINS `check.sh`, and this scope has no agent for prose.
    let hooks_json = fs::read_to_string(sb.project.join(".codex/hooks.json")).unwrap();
    assert!(hooks_json.contains("pre-check.sh"), "{hooks_json}");

    let quiet = sb.check(&["--quiet"]);
    assert_eq!(
        quiet.status.code(),
        Some(0),
        "an agent-less prose fallback beside a nested native name is clean: {}",
        text(&quiet.stderr)
    );

    // Control: the native sibling is still protected.
    fs::remove_file(sb.project.join(".codex/hooks/pre-check.sh")).unwrap();
    let quiet = sb.check(&["--quiet"]);
    assert_eq!(quiet.status.code(), Some(1), "{}", text(&quiet.stderr));
    assert!(
        text(&quiet.stderr).contains("pre-check (hook)"),
        "{}",
        text(&quiet.stderr)
    );
}

/// A cache whose `.git` cannot be written can never record anything, so the
/// stamp-based report would never mention it and every session would fork
/// another doomed refresh. The read path has to see it.
#[cfg(unix)]
#[test]
fn a_cache_that_cannot_be_written_is_named_in_the_report() {
    use std::os::unix::fs::PermissionsExt;
    if unsafe { libc::geteuid() } == 0 {
        return; // root ignores the permission bits this test relies on
    }
    let sb = Sandbox::new("check-unwritable-cache");
    let source = sb.remote_source_repo();
    let output = sb
        .vstack()
        .args([
            "add",
            &source,
            "--skill",
            "alpha",
            "--harness",
            "claude",
            "-y",
        ])
        .output()
        .unwrap();
    assert!(output.status.success(), "add: {}", text(&output.stderr));

    let cache = sb.cache_entry();
    let git = cache.join(".git");
    let _ = fs::remove_file(git.join("vstack-fetch-stamp"));
    fs::set_permissions(&git, fs::Permissions::from_mode(0o500)).unwrap();
    let json = sb.check(&["--json"]);
    let quiet = sb.check(&["--quiet"]);
    fs::set_permissions(&git, fs::Permissions::from_mode(0o700)).unwrap();

    let parsed: serde_json::Value = serde_json::from_slice(&json.stdout).unwrap();
    let failures = parsed["cache_refresh_failures"].as_array().unwrap();
    assert_eq!(failures.len(), 1, "{parsed}");
    assert_eq!(failures[0]["source"], source);
    assert_eq!(
        failures[0]["persistent"], true,
        "a cache that can never refresh cannot resolve itself: {parsed}"
    );
    assert!(
        failures[0]["reason"]
            .as_str()
            .unwrap_or_default()
            .contains("cannot be written"),
        "{parsed}"
    );
    assert_eq!(quiet.status.code(), Some(1), "{}", text(&quiet.stderr));
    // The quiet report is length-bounded, so a long `file://` source is
    // elided at the tail — it still has to be named.
    assert!(
        text(&quiet.stderr).contains(&source[..60.min(source.len())]),
        "the quiet path must name it: {}",
        text(&quiet.stderr)
    );
}

/// A harness switched off is its own report at the process boundary: neither
/// the phantom list, whose printed remedy is a reinstall of files that are
/// already correct, nor the unverifiable list, whose remedy is repairing a
/// file that parsed fine. Both session adapters relay this text verbatim, so
/// the wording that names the setting is part of the contract.
#[test]
fn a_hook_the_harness_will_not_run_is_its_own_json_and_quiet_report() {
    let sb = Sandbox::new("check-disabled-json");
    sb.write_hook("guard");
    sb.install_kind("--hook", "guard");

    let clean = sb.check(&["--quiet"]);
    assert_eq!(clean.status.code(), Some(0), "{}", text(&clean.stderr));

    // Claude's own documented switch, beside the registration `add` wrote.
    let settings = sb.project.join(".claude/settings.json");
    let registered = fs::read_to_string(&settings).unwrap();
    let body = registered.trim_end().trim_end_matches('}').trim_end();
    fs::write(
        &settings,
        format!("{body},\n  \"disableAllHooks\": true\n}}\n"),
    )
    .unwrap();

    let json = sb.check(&["--json"]);
    assert_eq!(json.status.code(), Some(1), "{}", text(&json.stderr));
    let parsed: serde_json::Value = serde_json::from_slice(&json.stdout).unwrap();
    let scope = &parsed["scopes"][0];
    let disabled = scope["disabled"].as_array().unwrap();
    assert_eq!(disabled.len(), 1, "{parsed}");
    assert_eq!(disabled[0]["name"], "guard", "{parsed}");
    let detail = disabled[0]["detail"].as_str().unwrap_or_default();
    assert!(detail.contains("disableAllHooks"), "{parsed}");
    assert!(detail.contains(".claude/settings.json"), "{parsed}");
    assert!(scope["phantom"].as_array().unwrap().is_empty(), "{parsed}");
    assert!(
        scope["unverifiable"].as_array().unwrap().is_empty(),
        "{parsed}"
    );

    let quiet = sb.check(&["--quiet"]);
    assert_eq!(quiet.status.code(), Some(1), "{}", text(&quiet.stderr));
    let err = text(&quiet.stderr);
    assert!(err.contains("the harness will not run it"), "{err}");
    assert!(err.contains("guard (hook)"), "{err}");
    assert!(err.contains("disableAllHooks"), "{err}");
    assert!(
        !err.contains("missing from disk"),
        "the reinstall remedy must not appear: {err}"
    );

    // Control: the same file with the switch off is clean again.
    fs::write(&settings, &registered).unwrap();
    let clean = sb.check(&["--quiet"]);
    assert_eq!(clean.status.code(), Some(0), "{}", text(&clean.stderr));
    assert!(clean.stderr.is_empty(), "{}", text(&clean.stderr));
}
