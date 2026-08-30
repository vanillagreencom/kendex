//! The Library preview pane's one query: the primary file behind an
//! installed item, capped so a hostile or merely enormous file cannot turn
//! a preview into a read of the whole thing.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::{HarnessId, ItemKind, ObservedItem, Scope};

/// Bytes read before truncating — enough to preview a real file, not the
/// whole of an enormous one.
const MAX_SOURCE_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ItemSource {
    pub path: String,
    pub content: String,
    pub truncated: bool,
}

/// The primary file behind one installed item: `SKILL.md` for a skill, the
/// document itself for an agent, command, or pi-extension. A hook or MCP
/// server lives as one entry inside a config file the harness shares across
/// every item of that kind — until that entry has its own reader, the
/// preview is honest about showing the whole file rather than pretending to
/// isolate one entry from it.
pub fn item_source(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
) -> Result<ItemSource> {
    let scope = scope.canonical();
    let settings = crate::settings::load(env)?;
    let scan = crate::scan::scan_scopes(env, &settings.harness_roots, std::slice::from_ref(&scope));
    let item = scan
        .items
        .iter()
        .find(|item| item.kind == kind && item.name == name && item.harness == harness)
        .ok_or_else(|| CoreError::ItemNotFound {
            kind,
            name: name.to_owned(),
            harness,
        })?;
    read_capped(&primary_file(item))
}

fn primary_file(item: &ObservedItem) -> PathBuf {
    match item.kind {
        ItemKind::Skill => item.path.join("SKILL.md"),
        _ => item.path.clone(),
    }
}

pub(crate) fn read_capped(path: &Path) -> Result<ItemSource> {
    let bytes = std::fs::read(path).map_err(|e| CoreError::io(path, e))?;
    let taken = char_boundary(&bytes, bytes.len().min(MAX_SOURCE_BYTES));
    Ok(ItemSource {
        path: crate::paths::slashed(path),
        content: String::from_utf8_lossy(&bytes[..taken]).into_owned(),
        truncated: bytes.len() > taken,
    })
}

/// `at`, moved back to the nearest character boundary — a budget the reader
/// chose must not manufacture bytes that will not decode.
fn char_boundary(bytes: &[u8], at: usize) -> usize {
    let mut at = at;
    while at > 0 && at < bytes.len() && bytes[at] & 0xC0 == 0x80 {
        at -= 1;
    }
    at
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;
    use std::fs;

    fn env_in(dir: &Path) -> Env {
        Env::fake(dir, FakeOs::Linux)
    }

    #[test]
    fn reads_a_skills_marker_file_by_its_directory() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        let skill_dir = home.join(".claude/skills/gh");
        fs::create_dir_all(&skill_dir).unwrap();
        fs::write(
            skill_dir.join("SKILL.md"),
            "---\nname: gh\ndescription: Work with GitHub.\n---\nBody.\n",
        )
        .unwrap();

        let env = env_in(home);
        let source = item_source(
            &env,
            &Scope::Global,
            ItemKind::Skill,
            "gh",
            HarnessId::Claude,
        )
        .unwrap();
        assert_eq!(
            source.content,
            "---\nname: gh\ndescription: Work with GitHub.\n---\nBody.\n"
        );
        assert!(source.path.ends_with("SKILL.md"), "{}", source.path);
        assert!(!source.truncated);
    }

    #[test]
    fn caps_at_64kb_and_reports_truncation() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        let dir = home.join(".claude/agents");
        fs::create_dir_all(&dir).unwrap();
        let big = "a".repeat(MAX_SOURCE_BYTES + 500);
        fs::write(dir.join("orch.md"), &big).unwrap();

        let env = env_in(home);
        let source = item_source(
            &env,
            &Scope::Global,
            ItemKind::Agent,
            "orch",
            HarnessId::Claude,
        )
        .unwrap();
        assert_eq!(source.content.len(), MAX_SOURCE_BYTES);
        assert!(source.truncated);
    }

    #[test]
    fn an_undeclared_name_is_a_plain_word_error() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let error = item_source(
            &env,
            &Scope::Global,
            ItemKind::Skill,
            "ghost",
            HarnessId::Claude,
        )
        .unwrap_err();
        assert!(error.to_string().contains("ghost"), "{error}");
        assert!(error.to_string().contains("skill"), "{error}");
    }
}
