use crate::hook::Hook;
use crate::path_safety::validate_item_name;
use anyhow::{Context, Result};
use jsonc_parser::cst::{CstInputValue, CstNode, CstRootNode};
use std::path::{Path, PathBuf};

use super::checked_child_path;

/// OpenCode: add permission rules based on hook intent
pub(super) fn install_hook_opencode(hook: &Hook, global: bool) -> Result<()> {
    validate_item_name(&hook.name)?;
    let config_path = if global {
        crate::config::opencode_global_config_path()
    } else {
        crate::config::opencode_project_config_path()
    };
    let instruction_dir = opencode_hook_instruction_dir(global);
    if instruction_dir.exists() {
        checked_child_path(&instruction_dir, &format!("vstack-hook-{}.md", hook.name))?;
    }
    let instruction_path = opencode_hook_instruction_path(global, &hook.name);
    let instruction_ref = opencode_hook_instruction_ref(global, &hook.name);
    install_hook_opencode_at_path(hook, &config_path, &instruction_path, &instruction_ref)
}

fn opencode_hook_instruction_dir(global: bool) -> PathBuf {
    if global {
        crate::config::opencode_global_dir().join("instructions")
    } else {
        crate::config::project_root()
            .join(".opencode")
            .join("instructions")
    }
}

pub(crate) fn opencode_hook_instruction_path(global: bool, name: &str) -> PathBuf {
    let file_name = format!("vstack-hook-{name}.md");
    opencode_hook_instruction_dir(global).join(file_name)
}

fn opencode_hook_instruction_ref(global: bool, name: &str) -> String {
    let file_name = format!("vstack-hook-{name}.md");
    if global {
        format!("instructions/{file_name}")
    } else {
        format!(".opencode/instructions/{file_name}")
    }
}

pub(crate) fn opencode_hook_instruction_contents(hook: &Hook) -> String {
    format!(
        "{}\n\n# Safety: {}\n\n{}",
        super::contract::ADVISORY_BANNER,
        hook.name,
        hook.safety_prose()
    )
}

/// OpenCode's config read against the shape both writers here depend on — see
/// [`crate::json_config`]. The refusal is attached once, so an unreadable
/// config reads the same whether it was hit by an install or a removal.
fn read_opencode_config(path: &Path) -> Result<Option<serde_json::Value>> {
    crate::json_config::read(path, &crate::json_config::OPENCODE_CONFIG)
        .context(crate::json_config::REFUSE_UNPARSEABLE_CONFIG)
}

/// The same config as an editable syntax tree.
///
/// OpenCode parses its config as JSONC, so a comment in it is a line OpenCode
/// reads past and the user meant to keep. Both writers here edit through this
/// tree and re-render it, which leaves every comment, blank line, indent and
/// key order exactly where it was — the promise the codex writer already
/// makes with `toml_edit`. Serializing a `serde_json::Value` back over the
/// file would have deleted all of it on the first `vstack add`.
fn read_opencode_document(path: &Path) -> Result<Option<CstRootNode>> {
    crate::json_config::read_editable(path, &crate::json_config::OPENCODE_CONFIG)
        .context(crate::json_config::REFUSE_UNPARSEABLE_CONFIG)
}

/// What vstack writes when there is no config at all yet.
const OPENCODE_NEW_CONFIG: &str = "{\n  \"$schema\": \"https://opencode.ai/config.json\"\n}\n";

/// Does `opencode.json` still point OpenCode at this hook's instruction file?
///
/// The file on disk is half the install. OpenCode loads what the
/// `instructions` array names, so an entry a user (or an older vstack) removed
/// leaves the file sitting there and the hook inert — the same "artifact
/// present, harness never runs it" state the Claude and Codex registration
/// checks exist to catch, and the one this harness answered `Registered` for.
///
/// Read from the array the installer writes, through the reader both writers
/// go through, and compared by the file each entry RESOLVES to — so a
/// hand-spelled but still-correct path counts, and a path naming some other
/// file does not.
pub(crate) fn opencode_hook_registration(global: bool, name: &str) -> super::HookRegistration {
    let config_path = if global {
        crate::config::opencode_global_config_path()
    } else {
        crate::config::opencode_project_config_path()
    };
    let config = match read_opencode_config(&config_path) {
        Ok(Some(config)) => config,
        Ok(None) => return super::HookRegistration::Absent,
        Err(err) => return super::HookRegistration::Unreadable(format!("{err:#}")),
    };
    let instruction_path = opencode_hook_instruction_path(global, name);
    let target = InstructionTarget::for_path(&config_path, &instruction_path);
    let registered = config
        .get("instructions")
        .and_then(|instructions| instructions.as_array())
        .into_iter()
        .flatten()
        .filter_map(|entry| entry.as_str())
        .any(|entry| target.matches(entry));
    if registered {
        super::HookRegistration::Registered
    } else {
        super::HookRegistration::Absent
    }
}

/// The instruction file an entry has to NAME to count as this hook's
/// registration, and the resolution that decides whether it does.
///
/// One predicate for the reader and the remover, because they answer the same
/// question in opposite directions: an entry the reader would not accept as a
/// registration is an entry the remover must not delete. Removal used to split
/// the hook's name on `-` and drop any entry whose text contained every
/// fragment, so removing `block-bare-cd` also deleted the user's own
/// instructions whose names merely spelled the same words — a raw-text match
/// standing in for a path.
struct InstructionTarget {
    /// The config file's own directory: a relative entry resolves against it.
    base: PathBuf,
    /// The instruction file, lexically normalized.
    lexical: PathBuf,
    /// The same file after following links, when it exists.
    resolved: Option<PathBuf>,
}

impl InstructionTarget {
    fn for_path(config_path: &Path, instruction_path: &Path) -> Self {
        Self {
            base: config_path.parent().unwrap_or(Path::new(".")).to_path_buf(),
            lexical: crate::config::normalize_path_lexical(instruction_path),
            resolved: std::fs::canonicalize(instruction_path).ok(),
        }
    }

    /// Does this `instructions` entry point OpenCode at the target file? A
    /// hand-spelled but still-correct path counts; a path naming some other
    /// file does not, whatever words it contains.
    fn matches(&self, entry: &str) -> bool {
        let path = Path::new(entry);
        let absolute = if path.is_absolute() {
            path.to_path_buf()
        } else {
            self.base.join(path)
        };
        if crate::config::normalize_path_lexical(&absolute) == self.lexical {
            return true;
        }
        match (&self.resolved, std::fs::canonicalize(&absolute).ok()) {
            (Some(target), Some(entry)) => &entry == target,
            _ => false,
        }
    }
}

/// Does this entry name one of vstack's own hook instruction files?
///
/// Decided on the entry's FILE NAME, which is what the installer writes
/// (`vstack-hook-<name>.md`), rather than on the substring appearing anywhere
/// in the string: `./notes/why-i-dropped-vstack-hook-support.md` is the user's
/// file, and reading it as vstack's kept a bash restriction nothing needed.
fn names_a_vstack_hook_instruction(entry: &str) -> bool {
    Path::new(entry)
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.starts_with("vstack-hook-") && name.ends_with(".md"))
}

/// Does this entry hold the inline prose an older vstack wrote instead of a
/// file reference?
///
/// Matched on the heading vstack itself emits — `# Safety: <name>` on its own
/// line — which is a delimiter this code owns, not a word the user might have
/// written. The heading is what [`opencode_hook_instruction_contents`] renders,
/// so an entry carrying it came from vstack and from this hook.
fn is_legacy_inline_prose(entry: &str, name: &str) -> bool {
    let heading = format!("# Safety: {name}");
    entry.lines().any(|line| line.trim_end() == heading)
}

pub(super) fn install_hook_opencode_at_path(
    hook: &Hook,
    config_path: &Path,
    instruction_path: &Path,
    instruction_ref: &str,
) -> Result<()> {
    if let Some(parent) = config_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if let Some(parent) = instruction_path.parent() {
        std::fs::create_dir_all(parent)?;
        let file_name = instruction_path
            .file_name()
            .and_then(|name| name.to_str())
            .context("OpenCode hook instruction path missing file name")?;
        checked_child_path(parent, file_name)?;
    }

    std::fs::write(instruction_path, opencode_hook_instruction_contents(hook))?;

    let config = match read_opencode_document(config_path)? {
        Some(config) => config,
        None => CstRootNode::parse(OPENCODE_NEW_CONFIG, &crate::json_config::JSONC)
            .expect("vstack's own starting config parses"),
    };
    let root = config
        .object_value_or_create()
        .context("validated by json_config: the document is an object")?;

    // OpenCode doesn't have hooks — convert to permission rules and instructions.
    // Both containers are CREATED only when their key is absent: a value of
    // the wrong shape made the read unreadable above, so nothing here
    // replaces a value the user put there.
    if hook.event == "PreToolUse" && hook.matcher.as_deref() == Some("Bash") {
        // For bash hooks: set bash permission to "ask" (require confirmation)
        let perms = root
            .object_value_or_create("permission")
            .context("validated by json_config: `permission` is an object")?;
        if perms.get("bash").is_none() {
            perms.append(
                "bash",
                CstInputValue::Object(vec![("*".into(), CstInputValue::String("ask".into()))]),
            );
        }
    }

    // OpenCode instructions are file paths, so write a dedicated file and reference it.
    let instructions = root
        .array_value_or_create("instructions")
        .context("validated by json_config: `instructions` is an array")?;

    let already_has = instructions
        .elements()
        .iter()
        .any(|entry| instruction_entry(entry).as_deref() == Some(instruction_ref));

    if !already_has {
        instructions.append(CstInputValue::String(instruction_ref.to_string()));
    }

    std::fs::write(config_path, render_opencode_config(&config))?;

    Ok(())
}

/// The string an `instructions` element holds, or `None` for an element that
/// is not a string at all — somebody else's entry, which no writer here
/// matches or removes.
fn instruction_entry(entry: &CstNode) -> Option<String> {
    entry.as_string_lit()?.decoded_value().ok()
}

/// Remove hook instructions and permission entries from OpenCode opencode.json
pub(super) fn remove_hook_from_opencode_json(global: bool, name: &str) -> Result<()> {
    validate_item_name(name)?;
    let config_path = if global {
        crate::config::opencode_global_config_path()
    } else {
        crate::config::opencode_project_config_path()
    };
    let instruction_path = opencode_hook_instruction_path(global, name);
    let instruction_ref = opencode_hook_instruction_ref(global, name);
    remove_hook_from_opencode_json_at_path(&config_path, &instruction_path, &instruction_ref, name)
}

pub(super) fn remove_hook_from_opencode_json_at_path(
    config_path: &Path,
    instruction_path: &Path,
    instruction_ref: &str,
    name: &str,
) -> Result<()> {
    validate_item_name(name)?;
    if let Some(parent) = instruction_path.parent()
        && parent.exists()
    {
        let file_name = instruction_path
            .file_name()
            .and_then(|name| name.to_str())
            .context("OpenCode hook instruction path missing file name")?;
        checked_child_path(parent, file_name)?;
    }
    let document = read_opencode_document(config_path)?;
    // No file, or a document holding no object at all — nothing but comments.
    // Either way nothing in it registers this hook, so there is nothing here
    // to remove from.
    let (Some(config), Some(root)) = (
        document.as_ref(),
        document.as_ref().and_then(CstRootNode::object_value),
    ) else {
        let _ = std::fs::remove_file(instruction_path);
        return Ok(());
    };

    let mut changed = false;

    // Remove the current file-path based format plus the legacy inline prose
    // format. A non-string entry is somebody else's and is retained: it can
    // never be the reference vstack wrote. So is any entry that resolves to
    // another file — this removes vstack's own registration, never whatever
    // else the user pointed OpenCode at.
    let target = InstructionTarget::for_path(config_path, instruction_path);
    let instructions = root.array_value("instructions");
    if let Some(instructions) = &instructions {
        for entry in instructions.elements() {
            let Some(text) = instruction_entry(&entry) else {
                continue;
            };
            if text == instruction_ref
                || target.matches(&text)
                || is_legacy_inline_prose(&text, name)
            {
                entry.remove();
                changed = true;
            }
        }
    }

    let remove_instruction = instruction_path.exists();

    // If no vstack hook instructions remain, remove the temporary bash restriction we added.
    let no_vstack_hook_instructions = instructions.as_ref().is_none_or(|instructions| {
        !instructions
            .elements()
            .iter()
            .filter_map(instruction_entry)
            .any(|entry| names_a_vstack_hook_instruction(&entry))
    });

    if let Some(instructions) = &instructions
        && instructions.elements().is_empty()
        && let Some(prop) = root.get("instructions")
    {
        prop.remove();
        changed = true;
    }

    if no_vstack_hook_instructions && let Some(permission) = root.object_value("permission") {
        if let Some(bash) = permission.get("bash")
            && bash
                .value()
                .and_then(|value| value.to_serde_value())
                .is_some_and(|value| is_the_bash_rule_vstack_wrote(&value))
        {
            bash.remove();
            changed = true;
        }
        if permission.properties().is_empty()
            && let Some(prop) = root.get("permission")
        {
            prop.remove();
            changed = true;
        }
    }

    if changed {
        std::fs::write(config_path, render_opencode_config(config))?;
    }
    if remove_instruction {
        let _ = std::fs::remove_file(instruction_path);
    }
    Ok(())
}

/// Is `permission.bash` exactly the rule the installer above writes, and
/// nothing the user added to it?
fn is_the_bash_rule_vstack_wrote(value: &serde_json::Value) -> bool {
    value.as_object().is_some_and(|bash| {
        bash.len() == 1
            && bash
                .get("*")
                .and_then(|value| value.as_str())
                .is_some_and(|value| value == "ask")
    })
}

/// The edited tree back to text, with the file's own line ending and exactly
/// one of it at the end. Everything else — comments, blank lines, indent
/// width, key order — comes back byte-for-byte as the user wrote it, because
/// the tree only ever changed the nodes above.
fn render_opencode_config(config: &CstRootNode) -> String {
    let text = config.to_string();
    let newline = match text.contains("\r\n") {
        true => "\r\n",
        false => "\n",
    };
    let body = text.trim_end_matches(['\n', '\r']);
    format!("{body}{newline}")
}
