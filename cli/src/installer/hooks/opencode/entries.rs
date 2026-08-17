//! Which `instructions` entry is vstack's OWN.
//!
//! One set of predicates for the presence check and the remover, because
//! they answer the same question in opposite directions: an entry the check
//! would not accept as a registration is an entry the remover must not
//! delete.

use jsonc_parser::cst::CstNode;
use std::path::{Path, PathBuf};

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
pub(super) struct InstructionTarget {
    /// The config file's own directory: a relative entry resolves against it.
    base: PathBuf,
    /// The instruction file, lexically normalized.
    lexical: PathBuf,
    /// The same file after following links, when it exists.
    resolved: Option<PathBuf>,
}

impl InstructionTarget {
    pub(super) fn for_path(config_path: &Path, instruction_path: &Path) -> Self {
        Self {
            base: config_path.parent().unwrap_or(Path::new(".")).to_path_buf(),
            lexical: crate::config::normalize_path_lexical(instruction_path),
            resolved: std::fs::canonicalize(instruction_path).ok(),
        }
    }

    /// Does this `instructions` entry point OpenCode at the target file? A
    /// hand-spelled but still-correct path counts; a path naming some other
    /// file does not, whatever words it contains.
    pub(super) fn matches(&self, entry: &str) -> bool {
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

/// Every vstack hook instruction file installed in `instruction_dir`, as the
/// targets an `instructions` entry has to RESOLVE to.
///
/// The names come from the directory the INSTALLER writes into — files vstack
/// itself created as `vstack-hook-<name>.md` — so the entry is still judged by
/// the file it names, through the one predicate above, and never by how it is
/// spelled. Reading the entry's own basename was a second answer to
/// [`InstructionTarget::matches`]'s question, and the two disagreed: a hook
/// registered through an equivalent spelling read as nothing at all, so
/// removing a sibling deleted the `permission.bash` rule they share and left
/// the survivor half-installed with no command reporting it.
///
/// `None` when the directory cannot be listed, which is not the same as
/// empty: a removal that cannot see what is installed must not conclude
/// nothing is. A directory that does not exist holds no instruction files and
/// answers so.
pub(super) fn vstack_hook_instruction_targets(
    config_path: &Path,
    instruction_dir: &Path,
) -> Option<Vec<InstructionTarget>> {
    let listing = match std::fs::read_dir(instruction_dir) {
        Ok(listing) => listing,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Some(Vec::new()),
        Err(_) => return None,
    };
    let mut targets = Vec::new();
    for entry in listing {
        let path = entry.ok()?.path();
        let is_ours = path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with("vstack-hook-") && name.ends_with(".md"));
        if is_ours {
            targets.push(InstructionTarget::for_path(config_path, &path));
        }
    }
    Some(targets)
}

/// Does this entry hold the inline prose an older vstack wrote instead of a
/// file reference?
///
/// Matched on the heading vstack itself emits — `# Safety: <name>` on its own
/// line — which is a delimiter this code owns, not a word the user might have
/// written. The heading is what [`opencode_hook_instruction_contents`] renders,
/// so an entry carrying it came from vstack and from this hook.
pub(super) fn is_legacy_inline_prose(entry: &str, name: &str) -> bool {
    let heading = format!("# Safety: {name}");
    entry.lines().any(|line| line.trim_end() == heading)
}

/// The string an `instructions` element holds, or `None` for an element that
/// is not a string at all — somebody else's entry, which no writer here
/// matches or removes.
pub(super) fn instruction_entry(entry: &CstNode) -> Option<String> {
    entry.as_string_lit()?.decoded_value().ok()
}
