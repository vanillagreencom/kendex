use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::configedit::ConfigEdit;
use crate::error::{CoreError, Result};
use crate::lock::{Lock, OutputStyleRecord, entry_key};
use crate::model::{HarnessId, ItemKind};

/// Every structured edit the plan wants, grouped by config file. The plan
/// composes each file's edits into one mutation with one precondition —
/// per-edit preconditions against the same original bytes can never all
/// hold once the first edit lands.
#[derive(Debug, Default)]
pub(super) struct ConfigEditPlan {
    pub(super) by_file: BTreeMap<PathBuf, (Vec<String>, Vec<ConfigEdit>)>,
}

impl ConfigEditPlan {
    pub(super) fn push(&mut self, path: PathBuf, label: String, edit: ConfigEdit) {
        let entry = self.by_file.entry(path).or_default();
        entry.0.push(label);
        entry.1.push(edit);
    }

    /// Compose a shared-file mutation and record its selection ownership.
    pub(super) fn compose(
        path: &Path,
        current: &str,
        edits: &mut [ConfigEdit],
        new_lock: &mut Lock,
    ) -> Result<String> {
        let error = |message| CoreError::ConfigEdit {
            path: path.to_path_buf(),
            message,
        };
        // The old style's owned selection leaves before the new one can
        // acquire it. Other edits retain their collection order.
        edits.sort_by_key(|edit| matches!(edit, ConfigEdit::ClaudeOutputStyle { .. }));
        let mut written = current.to_owned();
        for edit in edits {
            let after = edit.apply(&written).map_err(error)?;
            if let ConfigEdit::ClaudeOutputStyle { name } = edit {
                let mut selected_by_other = false;
                if after == written {
                    for entry in new_lock
                        .entries
                        .values()
                        .filter(|entry| entry.name != *name && entry.enabled)
                    {
                        if let Some(OutputStyleRecord::Claude {
                            path: owned_path,
                            selection: Some(owned_name),
                        }) = &entry.output_style
                            && owned_path == path
                        {
                            selected_by_other |= !ConfigEdit::RemoveClaudeOutputStyle {
                                name: owned_name.clone(),
                            }
                            .in_sync(&written)
                            .map_err(error)?;
                        }
                    }
                }
                let key = entry_key(ItemKind::OutputStyle, name, HarnessId::Claude);
                let entry = new_lock.entries.get_mut(&key).ok_or_else(|| {
                    error("a planned style selection has no installation record".into())
                })?;
                if after != written {
                    entry.output_style = Some(OutputStyleRecord::Claude {
                        path: path.to_path_buf(),
                        selection: Some(name.clone()),
                    });
                } else if selected_by_other {
                    // A refresh keeps the old installation. Its selection
                    // is not a user choice; a later apply may release it.
                    entry.output_style = None;
                }
            }
            if after != written
                && let ConfigEdit::RemoveClaudeOutputStyle { name } = edit
                && let Some(entry) = new_lock.entries.get_mut(&entry_key(
                    ItemKind::OutputStyle,
                    name,
                    HarnessId::Claude,
                ))
                && !entry.enabled
            {
                entry.output_style = None;
            }
            written = after;
        }
        Ok(written)
    }
}
