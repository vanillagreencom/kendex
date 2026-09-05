use super::*;
use crate::env::FakeOs;

#[test]
fn claude_hooks_use_the_project_dir_variable_and_absolute_global_paths() {
    let env = Env::fake("/h", FakeOs::Linux);
    let scope = Scope::Project {
        root: PathBuf::from("/p"),
    };
    let Some(HookTarget::Script {
        path,
        command,
        registry,
        feature,
        ..
    }) = hook_target(&env, &scope, HarnessId::Claude, "guard")
    else {
        panic!("claude hooks are script targets");
    };
    assert_eq!(path, PathBuf::from("/p/.claude/hooks/guard.sh"));
    assert_eq!(
        command,
        "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh\""
    );
    assert_eq!(registry, PathBuf::from("/p/.claude/settings.json"));
    assert_eq!(feature, None);

    let Some(HookTarget::Script { command, .. }) =
        hook_target(&env, &Scope::Global, HarnessId::Claude, "guard")
    else {
        panic!("claude hooks are script targets");
    };
    assert_eq!(command, "bash \"/h/.claude/hooks/guard.sh\"");
}

#[test]
fn codex_registers_in_hooks_json_and_enables_the_feature() {
    let env = Env::fake("/h", FakeOs::Linux);
    let scope = Scope::Project {
        root: PathBuf::from("/p"),
    };
    let Some(HookTarget::Script {
        command,
        registry,
        feature,
        ..
    }) = hook_target(&env, &scope, HarnessId::Codex, "guard")
    else {
        panic!("codex hooks are script targets");
    };
    assert_eq!(
        command,
        "bash \"$(git rev-parse --show-toplevel)/.codex/hooks/guard.sh\""
    );
    assert_eq!(registry, PathBuf::from("/p/.codex/hooks.json"));
    assert_eq!(feature, Some(PathBuf::from("/p/.codex/config.toml")));
}

#[test]
fn instruction_references_are_scope_relative_and_cursor_is_project_only() {
    let env = Env::fake("/h", FakeOs::Linux);
    let scope = Scope::Project {
        root: PathBuf::from("/p"),
    };
    let Some(HookTarget::Instruction {
        path, reference, ..
    }) = hook_target(&env, &scope, HarnessId::Opencode, "guard")
    else {
        panic!("opencode hooks are instruction targets");
    };
    assert_eq!(
        path,
        PathBuf::from("/p/.opencode/instructions/kendex-hook-guard.md")
    );
    assert_eq!(reference, ".opencode/instructions/kendex-hook-guard.md");

    let Some(HookTarget::Instruction { reference, .. }) =
        hook_target(&env, &Scope::Global, HarnessId::Opencode, "guard")
    else {
        panic!("opencode hooks are instruction targets");
    };
    assert_eq!(reference, "instructions/kendex-hook-guard.md");

    assert_eq!(
        hook_target(&env, &scope, HarnessId::Cursor, "guard"),
        Some(HookTarget::Rule {
            path: PathBuf::from("/p/.cursor/rules/safety-guard.mdc"),
        })
    );
    assert_eq!(
        hook_target(&env, &Scope::Global, HarnessId::Cursor, "guard"),
        None
    );
    // Pi's target is the carrier registry, keyed by listener name at
    // render time; the script rides beside it.
    assert_eq!(
        hook_target(&env, &scope, HarnessId::Pi, "guard"),
        Some(HookTarget::Script {
            path: PathBuf::from("/p/.pi/kendex/hooks/guard.sh"),
            command: "bash \"$(git rev-parse --show-toplevel)/.pi/kendex/hooks/guard.sh\"".into(),
            registry: PathBuf::from("/p/.pi/kendex/hooks.json"),
            format: HookFormat::Nested,
            feature: None,
        })
    );
}

/// Copilot's hook file and the script it runs sit side by side, and the
/// file is the one its loader globs for.
#[test]
fn a_copilot_hook_gets_a_document_of_its_own_beside_its_script() {
    let env = Env::fake("/h", FakeOs::Linux);
    let scope = Scope::Project {
        root: PathBuf::from("/p"),
    };
    let Some(HookTarget::Script {
        path,
        command,
        registry,
        format,
        feature,
    }) = hook_target(&env, &scope, HarnessId::Copilot, "audit")
    else {
        panic!("copilot hooks are script targets");
    };
    assert_eq!(path, PathBuf::from("/p/.github/hooks/audit.sh"));
    assert_eq!(
        command,
        "bash \"$(git rev-parse --show-toplevel)/.github/hooks/audit.sh\""
    );
    assert_eq!(registry, PathBuf::from("/p/.github/hooks/audit.json"));
    assert_eq!(format, HookFormat::Copilot);
    assert_eq!(feature, None);

    let Some(HookTarget::Script {
        command, registry, ..
    }) = hook_target(&env, &Scope::Global, HarnessId::Copilot, "audit")
    else {
        panic!("copilot hooks are script targets");
    };
    assert_eq!(command, "bash \"/h/.copilot/hooks/audit.sh\"");
    assert_eq!(registry, PathBuf::from("/h/.copilot/hooks/audit.json"));
}

/// Antigravity keys its one registry by hook name, so the script sits in
/// a directory its loader never scans and the entry under the name.
#[test]
fn an_antigravity_hook_registers_by_name_in_the_roots_hooks_json() {
    let env = Env::fake("/h", FakeOs::Linux);
    let scope = Scope::Project {
        root: PathBuf::from("/p"),
    };
    assert_eq!(
        hook_target(&env, &scope, HarnessId::Antigravity, "audit"),
        Some(HookTarget::Script {
            path: PathBuf::from("/p/.agents/hooks/audit.sh"),
            command: "bash \"$(git rev-parse --show-toplevel)/.agents/hooks/audit.sh\"".into(),
            registry: PathBuf::from("/p/.agents/hooks.json"),
            format: HookFormat::Antigravity,
            feature: None,
        })
    );
    let Some(HookTarget::Script {
        command, registry, ..
    }) = hook_target(&env, &Scope::Global, HarnessId::Antigravity, "audit")
    else {
        panic!("antigravity hooks are script targets");
    };
    assert_eq!(command, "bash \"/h/.gemini/config/hooks/audit.sh\"");
    assert_eq!(registry, PathBuf::from("/h/.gemini/config/hooks.json"));
}

/// The reserved name is one kendex never writes at either scope: pi warns
/// about a `hooks/` beside a root it loads whatever the directory holds.
#[test]
fn pi_hooks_live_under_the_kendex_segment_at_both_scopes() {
    let env = Env::fake("/h", FakeOs::Linux);
    let Some(HookTarget::Script {
        path,
        command,
        registry,
        ..
    }) = hook_target(&env, &Scope::Global, HarnessId::Pi, "guard")
    else {
        panic!("pi hooks are script targets");
    };
    assert_eq!(path, PathBuf::from("/h/.pi/agent/kendex/hooks/guard.sh"));
    assert_eq!(command, "bash \"/h/.pi/agent/kendex/hooks/guard.sh\"");
    assert_eq!(registry, PathBuf::from("/h/.pi/agent/kendex/hooks.json"));
}
