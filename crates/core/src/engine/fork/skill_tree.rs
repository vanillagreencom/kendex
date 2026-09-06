//! Where a skill's content actually lives for one harness. Every tool
//! reads the same skill through a different path — the shared canonical
//! tree it reads directly, a link into that tree, or its own copied tree —
//! and an operation that captures or compares bytes has to land on the
//! tree that tool really reads, never on whichever one shares the name.

use std::path::PathBuf;

use crate::engine::desired::{read_dirs, skill_canonical};
use crate::env::Env;
use crate::model::{HarnessId, ItemKind, Scope};

/// The tree that holds a skill's content for one harness: its own tree
/// when it was copied there (each tool a real directory), or the shared
/// canonical tree when the tool reads that instead — directly, where the
/// tool reads the shared tree itself, or through a link.
///
/// The tool's own directory is asked first and the shared tree last, which
/// is the reverse of the order an install writes in. A copy lands in the
/// tool's own directory precisely so no other tool reads it, and the
/// shared tree may hold another tool's skill of the same name; taking the
/// shared one first would hand back bytes belonging to whichever tool
/// happens to share the name, not the one asked for.
pub(crate) fn skill_content_path(
    env: &Env,
    scope: &Scope,
    name: &str,
    harness: HarnessId,
) -> Option<PathBuf> {
    let installed = crate::harness::rendered_name(harness, name);
    for dir in read_dirs(env, scope, harness, ItemKind::Skill)
        .into_iter()
        .rev()
    {
        let native = dir.join(&installed);
        // A real directory here is this tool's own tree: its copy, or the
        // shared tree where this tool reads that itself. A symlink is
        // followed to the shared canonical tree it reads instead.
        // Resolving it gives a real directory either way, never the wrong
        // tool's bytes.
        if native.is_symlink() {
            if let Ok(target) = std::fs::read_link(&native) {
                let resolved = if target.is_absolute() {
                    target
                } else {
                    dir.join(target)
                };
                // Only a link into a location kendex itself manages is
                // followed — this scope's shared canonical tree. A foreign
                // link the user pointed elsewhere is not this skill's
                // content, and reading (then trashing) it would expose and
                // move whatever it happens to point at.
                if resolved.is_dir() && managed_skill_tree(env, scope, name, &resolved) {
                    return Some(resolved);
                }
            }
        } else if native.is_dir() {
            return Some(native);
        }
    }
    let canonical = skill_canonical(env, scope, name);
    canonical.is_dir().then_some(canonical)
}

/// Whether `path` is a skill tree kendex manages for `name`: the scope's
/// shared canonical tree. Compared canonically so a `..`-laden link cannot
/// dress a foreign directory up as a managed one.
fn managed_skill_tree(env: &Env, scope: &Scope, name: &str, path: &std::path::Path) -> bool {
    let real = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let canonical = skill_canonical(env, scope, name);
    real == canonical.canonicalize().unwrap_or(canonical)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;
    use crate::test_util::rooted;
    use std::fs;

    fn tree(path: &std::path::Path, body: &str) {
        fs::create_dir_all(path).expect("fixture dir");
        fs::write(path.join("SKILL.md"), body).expect("fixture SKILL.md");
    }

    /// A global copy lands in the tool's own directory, which is the whole
    /// point of a copy — no other tool reads it. The shared tree may hold
    /// another tool's skill of the same name, so asking the shared tree
    /// first would hand back that tool's bytes; the copy is what Codex has.
    #[test]
    fn a_global_copy_is_found_in_the_tools_own_directory() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let home = rooted(&tmp);
        let env = Env::fake(&home, FakeOs::Linux);
        let mine = home.join(".codex/skills/gh");
        tree(
            &mine,
            "---\nname: gh\ndescription: codex's copy\n---\nMine.\n",
        );
        tree(
            &env.global_skills_dir().join("gh"),
            "---\nname: gh\ndescription: somebody else's\n---\nTheirs.\n",
        );

        assert_eq!(
            skill_content_path(&env, &Scope::Global, "gh", HarnessId::Codex),
            Some(mine)
        );
    }

    /// With no copy of its own, the tool reads the shared tree it shares.
    #[test]
    fn without_a_copy_the_shared_tree_is_what_the_tool_reads() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let home = rooted(&tmp);
        let env = Env::fake(&home, FakeOs::Linux);
        let shared = env.global_skills_dir().join("gh");
        tree(&shared, "---\nname: gh\ndescription: shared\n---\nOurs.\n");

        assert_eq!(
            skill_content_path(&env, &Scope::Global, "gh", HarnessId::Codex),
            Some(shared)
        );
    }
}
