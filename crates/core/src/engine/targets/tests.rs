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
    }) = hook_target(&env, &scope, HarnessId::Claude, "guard", None)
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
        hook_target(&env, &Scope::Global, HarnessId::Claude, "guard", None)
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
    }) = hook_target(&env, &scope, HarnessId::Codex, "guard", None)
    else {
        panic!("codex hooks are script targets");
    };
    assert_eq!(command, project_command(".codex/hooks/guard.sh", None));
    // The whole text names no directory outside the project, so every clone
    // of a repository that commits this registry reads the same bytes.
    assert!(!command.contains("/p"), "{command}");
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
    }) = hook_target(&env, &scope, HarnessId::Opencode, "guard", None)
    else {
        panic!("opencode hooks are instruction targets");
    };
    assert_eq!(
        path,
        PathBuf::from("/p/.opencode/instructions/kendex-hook-guard.md")
    );
    assert_eq!(reference, ".opencode/instructions/kendex-hook-guard.md");

    let Some(HookTarget::Instruction { reference, .. }) =
        hook_target(&env, &Scope::Global, HarnessId::Opencode, "guard", None)
    else {
        panic!("opencode hooks are instruction targets");
    };
    assert_eq!(reference, "instructions/kendex-hook-guard.md");

    assert_eq!(
        hook_target(&env, &scope, HarnessId::Cursor, "guard", None),
        Some(HookTarget::Rule {
            path: PathBuf::from("/p/.cursor/rules/safety-guard.mdc"),
        })
    );
    assert_eq!(
        hook_target(&env, &Scope::Global, HarnessId::Cursor, "guard", None),
        None
    );
    // Pi's target is the carrier registry, keyed by listener name at
    // render time; the script rides beside it.
    assert_eq!(
        hook_target(&env, &scope, HarnessId::Pi, "guard", None),
        Some(HookTarget::Script {
            path: PathBuf::from("/p/.pi/kendex/hooks/guard.sh"),
            command: project_command(".pi/kendex/hooks/guard.sh", None),
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
    }) = hook_target(&env, &scope, HarnessId::Copilot, "audit", None)
    else {
        panic!("copilot hooks are script targets");
    };
    assert_eq!(path, PathBuf::from("/p/.github/hooks/audit.sh"));
    assert_eq!(command, project_command(".github/hooks/audit.sh", None));
    assert_eq!(registry, PathBuf::from("/p/.github/hooks/audit.json"));
    assert_eq!(format, HookFormat::Copilot);
    assert_eq!(feature, None);

    let Some(HookTarget::Script {
        command, registry, ..
    }) = hook_target(&env, &Scope::Global, HarnessId::Copilot, "audit", None)
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
        hook_target(&env, &scope, HarnessId::Antigravity, "audit", None),
        Some(HookTarget::Script {
            path: PathBuf::from("/p/.agents/hooks/audit.sh"),
            command: project_command(".agents/hooks/audit.sh", None),
            registry: PathBuf::from("/p/.agents/hooks.json"),
            format: HookFormat::Antigravity,
            feature: None,
        })
    );
    let Some(HookTarget::Script {
        command, registry, ..
    }) = hook_target(&env, &Scope::Global, HarnessId::Antigravity, "audit", None)
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
    }) = hook_target(&env, &Scope::Global, HarnessId::Pi, "guard", None)
    else {
        panic!("pi hooks are script targets");
    };
    assert_eq!(path, PathBuf::from("/h/.pi/agent/kendex/hooks/guard.sh"));
    assert_eq!(command, "bash \"/h/.pi/agent/kendex/hooks/guard.sh\"");
    assert_eq!(registry, PathBuf::from("/h/.pi/agent/kendex/hooks.json"));
}

/// A declared environment rides in the registered command as assignments
/// ahead of the script, on every harness that runs a script at either scope,
/// and the script stays the command's first path-shaped word: a value holding
/// a `/`, a glob, a space and a quote still leaves the hook named by its own
/// script wherever a registration is read back.
#[test]
fn a_declared_environment_is_assigned_ahead_of_the_script_that_names_the_hook() {
    let env = Env::fake("/h", FakeOs::Linux);
    let project = Scope::Project {
        root: PathBuf::from("/p"),
    };
    let vars = BTreeMap::from([(
        "KENDEX_SKILL_LOAD_RULES".to_owned(),
        "crates/ui/**/*.rs=iced-rs; it's".to_owned(),
    )]);
    let assignment = "KENDEX_SKILL_LOAD_RULES='crates/ui/**/*.rs=iced-rs; it'\\''s' bash ";
    for harness in [
        HarnessId::Claude,
        HarnessId::Codex,
        HarnessId::Gemini,
        HarnessId::Copilot,
        HarnessId::Pi,
        HarnessId::Antigravity,
    ] {
        for scope in [&project, &Scope::Global] {
            let Some(HookTarget::Script { command, .. }) =
                hook_target(&env, scope, harness, "guard", Some(&vars))
            else {
                panic!("{harness:?} hooks are script targets");
            };
            assert!(
                command.contains(assignment),
                "{harness:?} {scope:?}: {command}"
            );
            assert_eq!(
                crate::hook::command_stem(&command),
                "guard",
                "{harness:?} {scope:?}: {command}"
            );
        }
    }
    let Some(HookTarget::Script { command, .. }) =
        hook_target(&env, &project, HarnessId::Claude, "guard", Some(&vars))
    else {
        panic!("claude hooks are script targets");
    };
    assert_eq!(
        command,
        format!("h=\"$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh\"; {assignment}\"$h\"")
    );
}
