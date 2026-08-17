use crate::agent::Agent;
use crate::harness::Harness;
use crate::hook::Hook;
use crate::json_config::REFUSE_UNPARSEABLE_CONFIG;
use crate::path_safety::validate_item_name;
use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

mod opencode;

use opencode::{install_hook_opencode, remove_hook_from_opencode_json};
pub(crate) use opencode::{
    opencode_hook_instruction_contents, opencode_hook_instruction_path, opencode_hook_registration,
};

mod codex;

#[cfg(test)]
pub(crate) use codex::codex_agent_prose_section;
/// The block itself is written here and read back only by tests.
#[cfg(test)]
pub(crate) use codex::codex_hook_safety_block;
pub(crate) use codex::{
    CodexProse, codex_event_for, codex_hook_prose, codex_native_hook_gaps, codex_root,
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

/// What a harness config says about our script.
///
/// A file that EXISTS but cannot be read is deliberately its own answer rather
/// than `Absent`: collapsing the two reports the hook missing and prescribes
/// `vstack add`, which is a remedy for a different fault — and, before the
/// installers refused it, one that rewrote the unreadable file from a default
/// and took the user's other settings with it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum HookRegistration {
    /// The config registers this script under the requested event.
    Registered,
    /// The config is readable and holds no such registration.
    Absent,
    /// The file exists and nothing could parse it. The note names the file and
    /// the failure; repairing that file is the only remedy.
    Unreadable(String),
}

/// The `hooks → event → [{hooks: [{command}]}]` document claude's
/// `settings.json` and codex's `hooks.json` share, read against the WHOLE
/// shape both the presence check and the writers here depend on — see
/// [`crate::json_config`] for the rule and the schema.
fn read_hooks_config(path: &Path) -> Result<Option<serde_json::Value>> {
    crate::json_config::read(path, &crate::json_config::HOOKS_CONFIG)
}

/// An array on a VALIDATED document. Every array this module reaches for was
/// checked when the document was read, so an absent key is the only other
/// case and it means an empty list — no shape probe here can quietly answer
/// "no registration" for a value nothing understood.
fn validated_array(value: Option<&serde_json::Value>) -> &[serde_json::Value] {
    match value {
        None => &[],
        Some(value) => value
            .as_array()
            .expect("validated by json_config: this value is an array"),
    }
}

/// Every command handler registered under the events `event` selects — the
/// one traversal presence reading and removal both ask, over a document
/// [`read_hooks_config`] already validated.
fn hooks_config_commands<'a>(
    doc: &'a serde_json::Value,
    event: Option<&'a str>,
) -> impl Iterator<Item = &'a str> {
    doc.get("hooks")
        .and_then(|hooks| hooks.as_object())
        .into_iter()
        .flatten()
        .filter(move |(key, _)| event.is_none_or(|want| key.as_str() == want))
        .flat_map(|(_, entries)| validated_array(Some(entries)))
        .flat_map(|entry| validated_array(entry.get("hooks")))
        .filter_map(|handler| {
            handler.get("command").map(|command| {
                command
                    .as_str()
                    .expect("validated by json_config: a command is a string")
            })
        })
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
/// presence from one matcher — and from the same reader their installers write
/// through, so what one refuses to rewrite the other cannot call missing.
fn hooks_config_registration(
    path: &Path,
    event: Option<&str>,
    script_path: &Path,
    deferred_root: Option<(&str, &Path)>,
    owned_commands: &[String],
) -> HookRegistration {
    let doc = match read_hooks_config(path) {
        Ok(Some(doc)) => doc,
        Ok(None) => return HookRegistration::Absent,
        Err(err) => return HookRegistration::Unreadable(format!("{err:#}")),
    };
    let registered = hooks_config_commands(&doc, event).any(|command| {
        command_matches_owned_hook_command(command, owned_commands)
            || command_targets_hook_script(command, script_path, deferred_root)
    });
    if registered {
        HookRegistration::Registered
    } else {
        HookRegistration::Absent
    }
}

fn hook_entry_mentions_owned_command(entry: &serde_json::Value, owned_commands: &[String]) -> bool {
    validated_array(entry.get("hooks"))
        .iter()
        .filter_map(|handler| handler.get("command"))
        .any(|command| {
            command_matches_owned_hook_command(
                command
                    .as_str()
                    .expect("validated by json_config: a command is a string"),
                owned_commands,
            )
        })
}

/// Drop vstack's own entries from a VALIDATED `hooks` object, leaving every
/// other entry exactly as it was.
fn remove_hook_entries_from_hooks_object(
    hooks_obj: &mut serde_json::Map<String, serde_json::Value>,
    owned_commands: &[String],
) -> bool {
    let mut changed = false;
    let event_keys: Vec<String> = hooks_obj.keys().cloned().collect();
    for event in event_keys {
        let arr = hooks_obj
            .get_mut(&event)
            .and_then(|v| v.as_array_mut())
            .expect("validated by json_config: an event value is an array");
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
///
/// Claude merges several settings files, so one that registers the hook answers
/// for all of them; only when NONE does, and one of them could not be read, is
/// the answer unknowable.
pub(crate) fn claude_hook_registration(
    global: bool,
    hook_name: &str,
    event: Option<&str>,
) -> HookRegistration {
    let Some(script_path) = claude_hook_script_path(global, hook_name) else {
        return HookRegistration::Absent;
    };
    let owned = claude_owned_hook_commands(global, hook_name, &script_path);
    // Only the project-scope command defers the project root to run time.
    let project_root = (!global).then(crate::config::project_root);
    let deferred_root = project_root
        .as_deref()
        .map(|root| (CLAUDE_PROJECT_DIR, root));
    let mut unreadable = None;
    for settings in claude_settings_candidates(global) {
        match hooks_config_registration(&settings, event, &script_path, deferred_root, &owned) {
            HookRegistration::Registered => return HookRegistration::Registered,
            HookRegistration::Absent => {}
            HookRegistration::Unreadable(reason) => {
                unreadable.get_or_insert(reason);
            }
        }
    }
    match unreadable {
        Some(reason) => HookRegistration::Unreadable(reason),
        None => HookRegistration::Absent,
    }
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
#[derive(Debug)]
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
    let mut settings = read_hooks_config(&settings_path)
        .context(REFUSE_UNPARSEABLE_CONFIG)?
        .unwrap_or_else(|| serde_json::json!({}));

    let map = settings
        .as_object_mut()
        .expect("validated by json_config: the document is an object");
    let hooks_obj = map
        .entry("hooks")
        .or_insert_with(|| serde_json::json!({}))
        .as_object_mut()
        .expect("validated by json_config: `hooks` is an object");
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

    // Append to the event's own array, CREATING it only when the document
    // does not have that key at all. The probe that used to stand here
    // replaced any non-array value with an empty array — everything the user
    // had registered under that event, discarded by the very command the
    // drift report told them to run. A value that is not an array now makes
    // the whole read unreadable, so nothing reaches this point to replace.
    let event_arr = hooks_obj
        .entry(hook.event.clone())
        .or_insert_with(|| serde_json::json!([]))
        .as_array_mut()
        .expect("validated by json_config: an event value is an array");

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

/// Remove a hook entry from Claude Code settings.json. A file that cannot be
/// parsed is refused here too: removal rewrites the same document install does.
fn remove_hook_from_claude_settings(global: bool, name: &str, script_path: &Path) -> Result<()> {
    validate_item_name(name)?;
    let settings_path = claude_settings_path(global);
    let Some(mut settings) =
        read_hooks_config(&settings_path).context(REFUSE_UNPARSEABLE_CONFIG)?
    else {
        return Ok(());
    };

    let mut changed = false;
    if let Some(hooks) = settings.get_mut("hooks") {
        let hooks = hooks
            .as_object_mut()
            .expect("validated by json_config: `hooks` is an object");
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
mod codex_config_tests;
#[cfg(test)]
mod prose_tests;
#[cfg(test)]
mod registration_tests;
#[cfg(test)]
mod tests;
