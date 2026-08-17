use crate::agent::Agent;
use crate::harness::Harness;
use crate::hook::Hook;
use crate::path_safety::validate_item_name;
use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

mod opencode;

use opencode::{install_hook_opencode, remove_hook_from_opencode_json};
pub(crate) use opencode::{opencode_hook_instruction_contents, opencode_hook_instruction_path};

mod codex;

pub(crate) use codex::{
    codex_event_for, codex_hook_safety_block, codex_native_hook_gaps, codex_root,
};
pub use codex::{install_codex_fallback_hooks_for_agents, migrate_codex_config};
use codex::{install_hook_codex, remove_hook_from_codex_json, strip_hook_prose_from_codex_agents};

fn validate_file_name(file_name: &str) -> Result<()> {
    if file_name.is_empty()
        || file_name == "."
        || file_name == ".."
        || file_name.contains('/')
        || file_name.contains('\\')
        || Path::new(file_name).is_absolute()
    {
        anyhow::bail!("unsafe file name {file_name:?}");
    }
    Ok(())
}

fn checked_child_path(parent: &Path, file_name: &str) -> Result<PathBuf> {
    validate_file_name(file_name)?;
    let path = parent.join(file_name);
    if !path.starts_with(parent) {
        anyhow::bail!(
            "refusing path outside expected directory: {}",
            path.display()
        );
    }
    if parent.exists() {
        let parent_canon = parent
            .canonicalize()
            .with_context(|| format!("canonicalizing {}", parent.display()))?;
        if path.exists() {
            let target_canon = path
                .canonicalize()
                .with_context(|| format!("canonicalizing {}", path.display()))?;
            if !target_canon.starts_with(&parent_canon) {
                anyhow::bail!(
                    "refusing target outside expected directory: {}",
                    path.display()
                );
            }
        } else if let Some(path_parent) = path.parent() {
            let path_parent_canon = path_parent
                .canonicalize()
                .with_context(|| format!("canonicalizing {}", path_parent.display()))?;
            if path_parent_canon != parent_canon {
                anyhow::bail!(
                    "refusing path outside expected directory: {}",
                    path.display()
                );
            }
        }
    }
    Ok(path)
}

fn command_matches_owned_hook_command(command: &str, owned_commands: &[String]) -> bool {
    owned_commands.iter().any(|owned| command == owned)
}

/// Path identity for comparison: the canonical path when it exists, so a
/// symlinked or `..`-spelled command still names the same script, and the
/// path exactly as written when it does not.
fn resolved_path(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

/// Shells that RUN their first operand. `bash <script>` executes the script;
/// the same path in some other program's argument list is data.
const SCRIPT_INTERPRETERS: &[&str] = &["sh", "bash", "dash", "ksh", "zsh", "ash"];

/// Programs that exec the command following their own arguments, with the
/// count of their own non-flag operands first (`timeout 30 bash …`). `env` is
/// not here: it also takes `NAME=VALUE` assignments, so it is walked
/// separately.
const EXEC_PREFIXES: &[(&str, usize)] = &[("nohup", 0), ("setsid", 0), ("timeout", 1)];

/// The program a token names, ignoring the directory it lives in, so
/// `/bin/bash` and `bash` read alike.
fn program_name(token: &str) -> Option<&str> {
    Path::new(token).file_name()?.to_str()
}

/// A `NAME=VALUE` token — what the shell and `env` both read as an
/// environment assignment rather than as the program to run.
fn is_env_assignment(token: &str) -> bool {
    token.split_once('=').is_some_and(|(name, _)| {
        !name.is_empty()
            && !name.starts_with(|c: char| c.is_ascii_digit())
            && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
    })
}

/// A shell flag that leaves the first operand as the script the shell runs.
/// `-c` makes that operand a command STRING, `-s` reads the script from
/// stdin, and `-o`/`-O` swallow the next token — after any of those we cannot
/// say what runs, so they are not here. Unknown long flags are refused for
/// the same reason.
fn shell_flag_keeps_operand(flag: &str) -> bool {
    match flag.strip_prefix("--") {
        Some(long) => matches!(
            long,
            "norc" | "noprofile" | "posix" | "login" | "restricted"
        ),
        None => flag.strip_prefix('-').is_some_and(|short| {
            !short.is_empty()
                && short
                    .chars()
                    .all(|c| c.is_ascii_lowercase() && !matches!(c, 'c' | 'o' | 's'))
        }),
    }
}

/// The token the shell would EXECUTE, walking past the prefixes that exec
/// what follows them. `None` when nothing in the command can be proven to run.
///
/// Only an executable position counts. `echo <script>` names our path in an
/// argument list, and reading that as a registration is exactly the fail-open
/// the registration check exists to close.
fn executed_token<'a>(tokens: &[&'a str]) -> Option<&'a str> {
    let mut index = 0;
    // A leading `VAR=value` run is the shell's own environment prefix.
    while tokens
        .get(index)
        .is_some_and(|token| is_env_assignment(token))
    {
        index += 1;
    }
    loop {
        let word = *tokens.get(index)?;
        let name = program_name(word)?;
        if name == "env" {
            index += 1;
            // `env` execs the first operand that is neither an assignment nor
            // one of the flags that take no argument of their own.
            while let Some(token) = tokens.get(index) {
                if *token == "--" {
                    index += 1;
                    break;
                }
                if is_env_assignment(token) || matches!(*token, "-i" | "--ignore-environment") {
                    index += 1;
                    continue;
                }
                if token.starts_with('-') {
                    return None;
                }
                break;
            }
            continue;
        }
        if let Some((_, operands)) = EXEC_PREFIXES.iter().find(|(prefix, _)| *prefix == name) {
            index += 1;
            while let Some(token) = tokens.get(index) {
                if *token == "--" {
                    index += 1;
                    break;
                }
                if matches!(*token, "--foreground" | "--preserve-status") {
                    index += 1;
                    continue;
                }
                if token.starts_with('-') {
                    return None;
                }
                break;
            }
            // Past its own operands — a `timeout` duration — sits the command.
            index += operands;
            continue;
        }
        if SCRIPT_INTERPRETERS.contains(&name) {
            index += 1;
            while let Some(token) = tokens.get(index) {
                if *token == "--" {
                    index += 1;
                    break;
                }
                if !token.starts_with('-') {
                    break;
                }
                if !shell_flag_keeps_operand(token) {
                    return None;
                }
                index += 1;
            }
            return tokens.get(index).copied();
        }
        // Some other program: our path can only be its data.
        return Some(word);
    }
}

/// Does this command RUN the managed script? The script has to sit where the
/// shell would execute it — the command word, or the operand of an
/// interpreter or exec prefix — and the path there has to be ours, so neither
/// `notfoo.sh` nor an unrelated `foo.sh` elsewhere on disk answers for
/// `<root>/hooks/foo.sh`. A command whose target cannot be proven reads as
/// unregistered: a spurious drift line is inspectable, a false clean is not.
///
/// `deferred_root` is the placeholder a project-scope command leaves for run
/// time and what the harness expands it to — `$(git rev-parse
/// --show-toplevel)` for codex, `$CLAUDE_PROJECT_DIR` for claude — so a
/// command a user reshaped by hand is read the way the shell running it will.
fn command_targets_hook_script(
    command: &str,
    script_path: &Path,
    deferred_root: Option<(&str, &Path)>,
) -> bool {
    let expanded = match deferred_root {
        Some((placeholder, root)) => command.replace(placeholder, &root.to_string_lossy()),
        None => command.to_string(),
    };
    let quotes = |c: char| c == '"' || c == '\'';
    let tokens: Vec<&str> = expanded
        .split_whitespace()
        .map(|token| token.trim_matches(quotes))
        .collect();
    executed_token(&tokens)
        .is_some_and(|token| resolved_path(Path::new(token)) == resolved_path(script_path))
}

/// Does the harness config at `path` register `script_path` as a command
/// handler? `event` pins the key it must sit under; `None` accepts any event.
///
/// The file is PARSED, never substring-searched: a config naming `pre-check.sh`
/// must not answer for `check.sh`. A handler counts when its command is one
/// vstack itself renders, or — for a command a user reshaped by hand around OUR
/// script — when [`command_targets_hook_script`] proves it EXECUTES
/// `script_path`. A same-named script elsewhere on disk is somebody else's
/// handler, and a command that merely mentions ours passes it as data; letting
/// either answer would mask a deleted managed entry.
///
/// Claude's `settings.json` and codex's `hooks.json` share this
/// `hooks → event → [{hooks: [{command}]}]` shape, so both harnesses answer
/// presence from one matcher.
fn hooks_config_registers_script(
    path: &Path,
    event: Option<&str>,
    script_path: &Path,
    deferred_root: Option<(&str, &Path)>,
    owned_commands: &[String],
) -> bool {
    let Ok(content) = std::fs::read_to_string(path) else {
        return false;
    };
    let Ok(doc) = serde_json::from_str::<serde_json::Value>(&content) else {
        return false;
    };
    let Some(hooks) = doc.get("hooks").and_then(|hooks| hooks.as_object()) else {
        return false;
    };
    hooks
        .iter()
        .filter(|(key, _)| event.is_none_or(|want| key.as_str() == want))
        .any(|(_, entries)| {
            entries.as_array().is_some_and(|entries| {
                entries.iter().any(|entry| {
                    entry
                        .get("hooks")
                        .and_then(|handlers| handlers.as_array())
                        .is_some_and(|handlers| {
                            handlers.iter().any(|handler| {
                                handler
                                    .get("command")
                                    .and_then(|command| command.as_str())
                                    .is_some_and(|command| {
                                        command_matches_owned_hook_command(command, owned_commands)
                                            || command_targets_hook_script(
                                                command,
                                                script_path,
                                                deferred_root,
                                            )
                                    })
                            })
                        })
                })
            })
        })
}

fn hook_entry_mentions_owned_command(entry: &serde_json::Value, owned_commands: &[String]) -> bool {
    entry
        .get("hooks")
        .and_then(|h| h.as_array())
        .is_some_and(|handlers| {
            handlers.iter().any(|handler| {
                handler
                    .get("command")
                    .and_then(|c| c.as_str())
                    .is_some_and(|command| {
                        command_matches_owned_hook_command(command, owned_commands)
                    })
            })
        })
}

fn remove_hook_entries_from_hooks_object(
    hooks_obj: &mut serde_json::Map<String, serde_json::Value>,
    owned_commands: &[String],
) -> bool {
    let mut changed = false;
    let event_keys: Vec<String> = hooks_obj.keys().cloned().collect();
    for event in event_keys {
        if let Some(arr) = hooks_obj.get_mut(&event).and_then(|v| v.as_array_mut()) {
            let before = arr.len();
            arr.retain(|entry| !hook_entry_mentions_owned_command(entry, owned_commands));
            if arr.len() != before {
                changed = true;
            }
            if arr.is_empty() {
                hooks_obj.remove(&event);
                changed = true;
            }
        }
    }
    changed
}

/// The project-root substitution the project-scope command defers to run
/// time; claude expands it from the session's project dir.
const CLAUDE_PROJECT_DIR: &str = "$CLAUDE_PROJECT_DIR";

fn claude_hook_command(global: bool, hook_name: &str, script_path: &Path) -> String {
    if global {
        format!("bash {}", shell_quote(&script_path.to_string_lossy()))
    } else {
        format!("bash \"{CLAUDE_PROJECT_DIR}/.claude/hooks/{hook_name}.sh\"")
    }
}

fn claude_owned_hook_commands(global: bool, hook_name: &str, script_path: &Path) -> Vec<String> {
    let mut commands = vec![claude_hook_command(global, hook_name, script_path)];
    if global {
        commands.push(script_path.to_string_lossy().into_owned());
    } else {
        commands.push(format!("{CLAUDE_PROJECT_DIR}/.claude/hooks/{hook_name}.sh"));
    }
    commands
}

/// The `settings.json` [`install_hook_claude`] registers into.
fn claude_settings_path(global: bool) -> PathBuf {
    claude_settings_dir(global).join("settings.json")
}

fn claude_settings_dir(global: bool) -> PathBuf {
    if global {
        crate::config::claude_global_dir()
    } else {
        crate::config::project_root().join(".claude")
    }
}

/// Every settings file claude merges hooks from for this scope. vstack writes
/// only `settings.json`, but claude runs what `settings.local.json` registers
/// just the same — reporting a hook a user keeps there as missing would
/// prescribe a second registration that fires the hook twice.
fn claude_settings_candidates(global: bool) -> Vec<PathBuf> {
    let dir = claude_settings_dir(global);
    vec![dir.join("settings.json"), dir.join("settings.local.json")]
}

/// The script path claude's hooks dir holds for this hook.
fn claude_hook_script_path(global: bool, hook_name: &str) -> Option<PathBuf> {
    Harness::ClaudeCode
        .hooks_dir(global)
        .map(|dir| dir.join(format!("{hook_name}.sh")))
}

/// Will claude RUN this hook? The script alone proves nothing: claude executes
/// what its settings register under the hook's event, so a registration deleted
/// beside a live script is a hook that silently never fires — including
/// `session-drift-check`, which then cannot report its own absence.
///
/// `event` is the hook's own event. `None` — its source could not be read to
/// name one — accepts a registration under any event rather than inventing
/// drift that naming the wrong key would make unclearable.
pub(crate) fn claude_hook_is_registered(
    global: bool,
    hook_name: &str,
    event: Option<&str>,
) -> bool {
    let Some(script_path) = claude_hook_script_path(global, hook_name) else {
        return false;
    };
    let owned = claude_owned_hook_commands(global, hook_name, &script_path);
    // Only the project-scope command defers the project root to run time.
    let project_root = (!global).then(crate::config::project_root);
    let deferred_root = project_root
        .as_deref()
        .map(|root| (CLAUDE_PROJECT_DIR, root));
    claude_settings_candidates(global).iter().any(|settings| {
        hooks_config_registers_script(settings, event, &script_path, deferred_root, &owned)
    })
}

fn shell_quote(s: &str) -> String {
    if s.chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '.' | '_' | '-'))
    {
        s.to_string()
    } else {
        let escaped = s.replace('\'', "'\\''");
        format!("'{escaped}'")
    }
}

fn is_toml_table_header(trimmed_line: &str) -> bool {
    trimmed_line.starts_with('[') && trimmed_line.ends_with(']')
}

/// Install a hook to a specific harness.
///
/// - Claude Code: copy script + add to settings.json hooks
/// - OpenCode: add permission rules to opencode.json
/// - Codex: native hooks.json entry + script when codex supports the event;
///   safety prose appended to agent TOML developer_instructions otherwise
/// - Cursor: write a dedicated `.cursor/rules/safety-<name>.mdc` rule file
/// - Pi: no per-hook install artifact; the native `pi-hooks` extension owns behavior
///
/// Honors the optional `harnesses:` allowlist in the hook frontmatter.
pub fn install_hook(
    hook: &Hook,
    harness: Harness,
    global: bool,
    agents: &[Agent],
) -> Result<HookInstall> {
    crate::path_safety::validate_new_item_name(&hook.name)?;
    if !hook.applies_to(harness.id()) {
        return Ok(HookInstall {
            detail: format!(
                "[hook] {} → {} (skipped: harness not in `harnesses:`)",
                hook.name,
                harness.name()
            ),
            installed: false,
        });
    }
    let installed = match harness {
        Harness::ClaudeCode => {
            install_hook_claude(hook, global)?;
            true
        }
        Harness::OpenCode => {
            install_hook_opencode(hook, global)?;
            true
        }
        Harness::Codex => install_hook_codex(hook, global, agents)?,
        Harness::Cursor => {
            install_hook_cursor(hook, global)?;
            true
        }
        // Pi has no per-hook artifact by design: the native `pi-hooks`
        // extension owns the behavior, so there is nothing to write and
        // nothing for `check` to demand.
        Harness::Pi => true,
    };

    if !installed {
        return Ok(HookInstall {
            detail: format!(
                "[hook] {} → {} (no artifact yet: this event has no native {} equivalent and the scope has no {} agents to carry the safety prose)",
                hook.name,
                harness.name(),
                harness.name(),
                harness.name()
            ),
            installed,
        });
    }
    Ok(HookInstall {
        detail: format!("[hook] {} → {} ({})", hook.name, harness.name(), hook.event),
        installed,
    })
}

/// What one hook install actually did. `installed` is false when the harness
/// produced NO artifact — the Codex prose fallback in a scope with no Codex
/// agents to write into — so `add` can say so instead of printing plain
/// success.
pub struct HookInstall {
    pub detail: String,
    pub installed: bool,
}

/// Claude Code: copy hook script + merge into settings.json
fn install_hook_claude(hook: &Hook, global: bool) -> Result<()> {
    validate_item_name(&hook.name)?;
    // Copy the script
    let hooks_dir = Harness::ClaudeCode
        .hooks_dir(global)
        .expect("Claude hooks dir");
    std::fs::create_dir_all(&hooks_dir)?;
    let dest = checked_child_path(&hooks_dir, &format!("{}.sh", hook.name))?;
    std::fs::write(&dest, &hook.script)?;

    // Make executable
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&dest, std::fs::Permissions::from_mode(0o755))?;
    }

    // Merge into settings.json
    let settings_path = claude_settings_path(global);
    let mut settings: serde_json::Value = if settings_path.exists() {
        let content = std::fs::read_to_string(&settings_path)?;
        serde_json::from_str(&content).unwrap_or(serde_json::json!({}))
    } else {
        serde_json::json!({})
    };

    let map = settings.as_object_mut().unwrap();
    if !map.contains_key("hooks") {
        map.insert("hooks".into(), serde_json::json!({}));
    }
    let hooks_obj = map.get_mut("hooks").unwrap().as_object_mut().unwrap();
    let owned_commands = claude_owned_hook_commands(global, &hook.name, &dest);
    remove_hook_entries_from_hooks_object(hooks_obj, &owned_commands);

    // Build the hook entry.
    // Project installs: use $CLAUDE_PROJECT_DIR so hooks resolve regardless of CWD.
    // Global installs: use the absolute path under the global config dir.
    let command = claude_hook_command(global, &hook.name, &dest);
    let hook_entry = {
        // Claude Code reads `timeout` from the command handler object, not the
        // matcher group, so it must live beside `command`.
        let mut handler = serde_json::json!({
            "type": "command",
            "command": command,
        });
        if let Some(timeout) = hook.timeout {
            handler
                .as_object_mut()
                .unwrap()
                .insert("timeout".into(), serde_json::Value::Number(timeout.into()));
        }
        let mut entry = serde_json::json!({ "hooks": [handler] });
        if let Some(ref matcher) = hook.matcher {
            entry
                .as_object_mut()
                .unwrap()
                .insert("matcher".into(), serde_json::Value::String(matcher.clone()));
        }
        entry
    };

    // Add to the appropriate event array
    if !hooks_obj.get(&hook.event).is_some_and(|v| v.is_array()) {
        hooks_obj.insert(hook.event.clone(), serde_json::json!([]));
    }
    let event_arr = hooks_obj
        .get_mut(&hook.event)
        .unwrap()
        .as_array_mut()
        .unwrap();

    event_arr.push(hook_entry);

    let output = crate::config::to_json_pretty(&settings)?;
    std::fs::write(&settings_path, output)?;

    Ok(())
}

pub(crate) fn cursor_hook_rule_contents(hook: &Hook) -> String {
    let mut output = String::new();
    output.push_str("---\n");
    output.push_str(&format!(
        "description: \"Safety: {} — {}\"\n",
        hook.name, hook.description
    ));
    output.push_str("alwaysApply: true\n");
    output.push_str("---\n\n");
    output.push_str(&format!("# Safety: {}\n\n", hook.name));
    output.push_str(&hook.safety_prose());
    output
}

pub(crate) fn cursor_hook_rule_path(global: bool, name: &str) -> PathBuf {
    Harness::Cursor
        .agents_dir(global)
        .join(format!("safety-{name}.mdc"))
}

/// Cursor: add safety advisory to a dedicated .mdc file
fn install_hook_cursor(hook: &Hook, global: bool) -> Result<()> {
    validate_item_name(&hook.name)?;
    let rules_dir = Harness::Cursor.agents_dir(global);
    std::fs::create_dir_all(&rules_dir)?;

    let path = checked_child_path(&rules_dir, &format!("safety-{}.mdc", hook.name))?;
    std::fs::write(&path, cursor_hook_rule_contents(hook))?;
    Ok(())
}

/// Remove a hook's harness-specific artifacts/config. Codex cleanup also
/// strips legacy `## Safety: <name>` prose from generated Codex agent TOMLs,
/// because older installs stored unmapped hook guidance there.
pub fn remove_hook_install(name: &str, harness: Harness, global: bool) -> Result<Vec<PathBuf>> {
    validate_item_name(name)?;
    let mut removed = Vec::new();

    match harness {
        Harness::ClaudeCode => {
            let hooks_dir = harness.hooks_dir(global).expect("Claude hooks dir");
            let hook_path = checked_child_path(&hooks_dir, &format!("{name}.sh"))?;
            remove_hook_from_claude_settings(global, name, &hook_path)?;
            if hook_path.exists() {
                std::fs::remove_file(&hook_path)?;
                removed.push(hook_path);
            }
        }
        Harness::OpenCode => {
            remove_hook_from_opencode_json(global, name)?;
        }
        Harness::Codex => {
            let root = codex_root(global);
            let hooks_dir = root.join("hooks");
            let script_path = checked_child_path(&hooks_dir, &format!("{name}.sh"))?;
            remove_hook_from_codex_json(global, name, &script_path)?;
            strip_hook_prose_from_codex_agents(global, name)?;
            if script_path.exists() {
                std::fs::remove_file(&script_path)?;
                removed.push(script_path.clone());
            }
        }
        Harness::Cursor => {
            let rules_dir = Harness::Cursor.agents_dir(global);
            let rule_path = checked_child_path(&rules_dir, &format!("safety-{name}.mdc"))?;
            if rule_path.exists() {
                std::fs::remove_file(&rule_path)?;
                removed.push(rule_path);
            }
        }
        Harness::Pi => {}
    }

    Ok(removed)
}

/// Remove a hook entry from Claude Code settings.json
fn remove_hook_from_claude_settings(global: bool, name: &str, script_path: &Path) -> Result<()> {
    validate_item_name(name)?;
    let settings_path = claude_settings_path(global);
    if !settings_path.exists() {
        return Ok(());
    }
    let content = std::fs::read_to_string(&settings_path)?;
    let mut settings: serde_json::Value = serde_json::from_str(&content)?;

    let mut changed = false;
    if let Some(hooks) = settings.get_mut("hooks").and_then(|h| h.as_object_mut()) {
        let owned_commands = claude_owned_hook_commands(global, name, script_path);
        changed |= remove_hook_entries_from_hooks_object(hooks, &owned_commands);
    }

    if changed {
        let output = crate::config::to_json_pretty(&settings)?;
        std::fs::write(&settings_path, output)?;
    }
    Ok(())
}

#[cfg(test)]
mod registration_tests;
#[cfg(test)]
mod tests;
