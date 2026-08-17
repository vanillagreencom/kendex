use crate::agent::Agent;
use crate::harness::Harness;
use crate::hook::Hook;
use crate::json_config::REFUSE_UNPARSEABLE_CONFIG;
use crate::path_safety::validate_item_name;
use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

pub(crate) mod contract;
pub(crate) mod enforcement;

mod command;

use command::{command_targets_hook_script, shell_quote};
use contract::Mechanism;

mod cursor;

pub(crate) use cursor::{cursor_hook_rule_contents, cursor_hook_rule_path};
use cursor::{cursor_hook_switch, install_hook_cursor};

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
pub(crate) use codex::install_codex_fallback_hooks_for_agents;
pub use codex::migrate_codex_config;
pub(crate) use codex::{
    CodexProse, codex_event_for, codex_hook_prose, codex_native_hook_gaps, codex_root,
};
use codex::{
    install_hook_codex_native, install_hook_codex_prose, remove_hook_from_codex_json,
    strip_hook_prose_from_codex_agents,
};

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
///
/// `schema` is the harness's own: claude's adds `disableAllHooks` to the
/// shared shape. Every reader and writer of one harness's file passes the same
/// one, so what a writer refuses to rewrite a presence check cannot call
/// missing.
fn read_hooks_config(
    path: &Path,
    schema: &crate::json_config::Schema,
) -> Result<Option<serde_json::Value>> {
    crate::json_config::read(path, schema)
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

/// Which registration answers for a hook: the event key it has to sit under
/// and the matcher it has to carry.
///
/// Both, because both decide WHEN the harness runs the script: a handler under
/// another event fires at the wrong time, and one with another matcher fires
/// for the wrong tools. Neither is this hook's registration.
#[derive(Debug, Clone, Copy)]
pub(crate) struct RegistrationSlot<'a> {
    pub event: &'a str,
    pub matcher: Option<&'a str>,
}

/// Decides whether a registered command is one of this hook's — the single
/// question a reinstall (replace my own entry), a removal (take it away) and a
/// presence check (does the harness still run it) all ask, so no two of them
/// can disagree about which entry is ours.
type OwnsCommand<'a> = &'a dyn Fn(&str) -> bool;

/// The entries `slot` selects, over a document [`read_hooks_config`] already
/// validated. `None` accepts every entry: the hook's own definition could not
/// be read, so demanding a key would invent drift no reinstall can clear.
fn hooks_config_entries<'a>(
    doc: &'a serde_json::Value,
    slot: Option<RegistrationSlot<'a>>,
) -> impl Iterator<Item = &'a serde_json::Value> {
    doc.get("hooks")
        .and_then(|hooks| hooks.as_object())
        .into_iter()
        .flatten()
        .filter(move |(key, _)| slot.is_none_or(|slot| key.as_str() == slot.event))
        .flat_map(|(_, entries)| validated_array(Some(entries)))
        .filter(move |entry| {
            slot.is_none_or(|slot| {
                entry.get("matcher").and_then(|value| value.as_str()) == slot.matcher
            })
        })
}

/// Does the harness config at `path` register one of this hook's commands in
/// `slot`?
///
/// The file is PARSED, never substring-searched: a config naming `pre-check.sh`
/// must not answer for `check.sh`. Which command counts is `owns`, the same
/// predicate the installer replaces entries with and the remover deletes them
/// by.
///
/// Claude's `settings.json` and codex's `hooks.json` share this
/// `hooks → event → [{matcher, hooks: [{command}]}]` shape, so both harnesses
/// answer presence from one traversal — and from the same reader their
/// installers write through, so what one refuses to rewrite the other cannot
/// call missing.
fn hooks_config_registration(
    path: &Path,
    schema: &crate::json_config::Schema,
    slot: Option<RegistrationSlot<'_>>,
    owns: OwnsCommand<'_>,
) -> HookRegistration {
    let doc = match read_hooks_config(path, schema) {
        Ok(Some(doc)) => doc,
        Ok(None) => return HookRegistration::Absent,
        Err(err) => return HookRegistration::Unreadable(format!("{err:#}")),
    };
    let registered =
        hooks_config_entries(&doc, slot).any(|entry| entry_has_owned_command(entry, owns));
    if registered {
        HookRegistration::Registered
    } else {
        HookRegistration::Absent
    }
}

fn entry_has_owned_command(entry: &serde_json::Value, owns: OwnsCommand<'_>) -> bool {
    validated_array(entry.get("hooks"))
        .iter()
        .filter_map(|handler| handler.get("command"))
        .any(|command| {
            owns(
                command
                    .as_str()
                    .expect("validated by json_config: a command is a string"),
            )
        })
}

/// Drop vstack's own entries from a VALIDATED `hooks` object, leaving every
/// other entry exactly as it was.
fn remove_hook_entries_from_hooks_object(
    hooks_obj: &mut serde_json::Map<String, serde_json::Value>,
    owns: OwnsCommand<'_>,
) -> bool {
    let mut changed = false;
    let event_keys: Vec<String> = hooks_obj.keys().cloned().collect();
    for event in event_keys {
        let arr = hooks_obj
            .get_mut(&event)
            .and_then(|v| v.as_array_mut())
            .expect("validated by json_config: an event value is an array");
        let before = arr.len();
        arr.retain(|entry| !entry_has_owned_command(entry, owns));
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

/// Build the command Claude Code runs. Project scope anchors on
/// `$CLAUDE_PROJECT_DIR`, which the harness sets in every project including
/// one that is not a git repository; global scope has no project layer to
/// resolve against and takes the install-time absolute path.
fn claude_hook_command(global: bool, hook_name: &str, script_path: &Path) -> String {
    if global {
        format!("bash {}", shell_quote(&script_path.to_string_lossy()))
    } else {
        format!("bash \"{CLAUDE_PROJECT_DIR}/.claude/hooks/{hook_name}.sh\"")
    }
}

/// The command an installed Claude hook script is invoked through, for callers
/// that render the registration rather than write it — agent frontmatter and
/// `settings.json` cannot then drift apart.
pub(crate) fn claude_installed_hook_command(global: bool, hook_name: &str) -> String {
    let script_path = claude_hook_script_path(global, hook_name).unwrap_or_default();
    claude_hook_command(global, hook_name, &script_path)
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

/// Is this registered command one of THIS Claude hook's?
///
/// One predicate for the installer, the remover and the presence check, so a
/// command one of them owns another cannot leave behind. A command vstack
/// itself renders matches outright; beyond that the command has to RUN our
/// script — [`command_targets_hook_script`] proves it, so a hand-wrapped
/// `env FOO=1 bash <script> --strict` still counts while a command that merely
/// names the path in some other program's arguments does not.
fn claude_owns_command(global: bool, hook_name: &str, script_path: &Path) -> impl Fn(&str) -> bool {
    let owned = claude_owned_hook_commands(global, hook_name, script_path);
    let script_path = script_path.to_path_buf();
    // Only the project-scope command defers the project root to run time.
    let deferred_root = (!global).then(crate::config::project_root);
    move |command: &str| {
        owned.iter().any(|own| own == command)
            || command_targets_hook_script(
                command,
                &script_path,
                deferred_root
                    .as_deref()
                    .map(|root| (CLAUDE_PROJECT_DIR, root)),
            )
    }
}

/// Refuse a hook script path that is not valid UTF-8.
///
/// The registration is written into a JSON config, which cannot carry the
/// bytes at all; a lossy conversion would register a command naming a file
/// that does not exist and fail on every tool call instead of installing.
fn require_utf8_script_path(script_path: &Path) -> Result<()> {
    if script_path.to_str().is_some() {
        return Ok(());
    }
    anyhow::bail!(
        "hook script path is not valid UTF-8, so no harness config can carry it: {}",
        script_path.display()
    )
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

/// Every settings file claude merges hooks from for this scope, LOWEST
/// precedence first.
///
/// vstack writes only `settings.json`, but claude runs what the project's
/// `settings.local.json` registers just the same — reporting a hook a user
/// keeps there as missing would prescribe a second registration that fires the
/// hook twice.
///
/// The local tier is PROJECT-ONLY, and the asymmetry is the point: claude's
/// user tier is `~/.claude/settings.json` and nothing else — there is no
/// `~/.claude/settings.local.json` in its load order. Offering one in the
/// global scope let a stale or hand-made file answer for a global registration
/// claude never loads, so a deleted one read as installed.
fn claude_settings_candidates(global: bool) -> Vec<PathBuf> {
    let dir = claude_settings_dir(global);
    if global {
        return vec![dir.join("settings.json")];
    }
    vec![dir.join("settings.json"), dir.join("settings.local.json")]
}

/// Every settings file whose `disableAllHooks` claude weighs for a session
/// here, LOWEST precedence first.
///
/// One chain, not one per scope, because `disableAllHooks` is ONE effective
/// value: claude resolves it after settings precedence, so a project's `false`
/// overrides a user-level `true` — and a project-level `true` stops the
/// globally installed hooks exactly as dead as the project's own. A per-scope
/// reading would call the global hooks clean in a project that runs none of
/// them, which is the fail-open this check exists to close.
fn claude_disable_switch_chain() -> Vec<PathBuf> {
    let mut chain = vec![claude_settings_dir(true).join("settings.json")];
    chain.extend(claude_settings_candidates(false));
    chain
}

/// Whether a harness will act on an artifact that is fully installed —
/// the third question beside "is it there" and "could that be read", and the
/// one every harness with a switch answers in the same words, so the report
/// reads alike whichever one is off.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum HookSwitch {
    /// Nothing the harness reads turns it off.
    On,
    /// It is off. The note names the setting AND the file holding it, because
    /// that setting is the whole remedy: no reinstall changes it, and vstack
    /// must not write it either way.
    Off(String),
    /// A file that could have decided it exists and could not be read.
    Unreadable(String),
}

/// Will `harness` act on this hook's artifacts, once they are all there?
///
/// One entry point, so a harness that grows a switch is answered by adding an
/// arm here rather than by a caller learning a new function. Codex's
/// `[features] hooks` is deliberately not here: it is inseparable from the
/// registration read that shares its `hooks.json` scope, so it arrives
/// classified with the other native gaps in [`codex_native_hook_gaps`].
pub(crate) fn hook_switch(harness: Harness, global: bool, name: &str) -> HookSwitch {
    match harness {
        Harness::ClaudeCode => claude_hooks_switch(),
        Harness::Cursor => cursor_hook_switch(global, name),
        // OpenCode loads every instruction its config names and offers no way
        // to suppress one; Pi's toggles are vstack's own UI, not the harness's
        // configuration. Neither has a switch to read.
        Harness::OpenCode | Harness::Codex | Harness::Pi => HookSwitch::On,
    }
}

/// The effective `disableAllHooks`, walked from HIGHEST precedence down: the
/// first file that states the key settles it, and a file that could not be
/// read settles nothing but stops the walk — it may hold the very value that
/// would have overridden everything below it.
///
/// Managed policy sits above every file here and can disable hooks on its own
/// (`disableAllHooks`, or `allowManagedHooksOnly` leaving only admin-installed
/// hooks running). It reaches a machine as a system file, an MDM profile, a
/// registry key, or settings delivered at sign-in — channels no local read can
/// answer for — so this reads the tiers the user owns and claims nothing about
/// the rest.
fn claude_hooks_switch() -> HookSwitch {
    for path in claude_disable_switch_chain().iter().rev() {
        let doc = match read_hooks_config(path, &crate::json_config::CLAUDE_SETTINGS) {
            Ok(Some(doc)) => doc,
            Ok(None) => continue,
            Err(err) => return HookSwitch::Unreadable(format!("{err:#}")),
        };
        let Some(value) = doc.get("disableAllHooks") else {
            continue;
        };
        let disabled = value
            .as_bool()
            .expect("validated by json_config: `disableAllHooks` is a boolean");
        return if disabled {
            HookSwitch::Off(format!("disableAllHooks is true in {}", path.display()))
        } else {
            HookSwitch::On
        };
    }
    HookSwitch::On
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
/// `slot` is the hook's own event and matcher. `None` — its source could not
/// be read to name either — accepts a registration under any of them rather
/// than inventing drift that naming the wrong key would make unclearable.
///
/// Claude merges several settings files, so one that registers the hook answers
/// for all of them; only when NONE does, and one of them could not be read, is
/// the answer unknowable.
pub(crate) fn claude_hook_registration(
    global: bool,
    hook_name: &str,
    slot: Option<RegistrationSlot<'_>>,
) -> HookRegistration {
    let Some(script_path) = claude_hook_script_path(global, hook_name) else {
        return HookRegistration::Absent;
    };
    let owns = claude_owns_command(global, hook_name, &script_path);
    let mut unreadable = None;
    for settings in claude_settings_candidates(global) {
        match hooks_config_registration(
            &settings,
            &crate::json_config::CLAUDE_SETTINGS,
            slot,
            &owns,
        ) {
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
    let Some(cell) = contract::cell(&hook.event, harness) else {
        anyhow::bail!(contract::unknown_event_error(&hook.name, &hook.event));
    };
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
    let installed = match cell.mechanism() {
        Some(Mechanism::ClaudeSettingsHook) => {
            install_hook_claude(hook, global)?;
            true
        }
        Some(Mechanism::OpenCodeInstruction) => {
            install_hook_opencode(hook, global)?;
            true
        }
        Some(Mechanism::CodexHooksJson) => {
            install_hook_codex_native(hook, global)?;
            true
        }
        Some(Mechanism::CodexInstructions) => install_hook_codex_prose(hook, global, agents)?,
        Some(Mechanism::CursorRule) => {
            install_hook_cursor(hook, global)?;
            true
        }
        // Pi carries hook behavior in the `pi-hooks` package rather than a
        // per-hook artifact, and an unsupported cell writes nothing. Neither
        // leaves anything for `check` to demand; the level below says which.
        Some(Mechanism::PiHooksExtension) | None => true,
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
        detail: format!(
            "[hook] {} → {} ({}, {})",
            hook.name,
            harness.name(),
            hook.event,
            cell.level()
        ),
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
    // Only the global command carries the path itself; project scope registers
    // `$CLAUDE_PROJECT_DIR` and the hook name, which are UTF-8 by construction.
    if global {
        require_utf8_script_path(&dest)?;
    }
    std::fs::write(&dest, &hook.script)?;

    // Make executable
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&dest, std::fs::Permissions::from_mode(0o755))?;
    }

    // Merge into settings.json
    let settings_path = claude_settings_path(global);
    let mut settings = read_hooks_config(&settings_path, &crate::json_config::CLAUDE_SETTINGS)
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
    remove_hook_entries_from_hooks_object(
        hooks_obj,
        &claude_owns_command(global, &hook.name, &dest),
    );

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
        read_hooks_config(&settings_path, &crate::json_config::CLAUDE_SETTINGS)
            .context(REFUSE_UNPARSEABLE_CONFIG)?
    else {
        return Ok(());
    };

    let mut changed = false;
    if let Some(hooks) = settings.get_mut("hooks") {
        let hooks = hooks
            .as_object_mut()
            .expect("validated by json_config: `hooks` is an object");
        changed |= remove_hook_entries_from_hooks_object(
            hooks,
            &claude_owns_command(global, name, script_path),
        );
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
