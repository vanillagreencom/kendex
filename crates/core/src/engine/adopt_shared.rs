//! Adopting a shared folder through the link a tool reads it by: the
//! boundary that decides what a link may be adopted through, and the ops
//! that take the folder over without breaking the other tools reading it.

use std::fs;
use std::path::{Path, PathBuf};

use super::adopt::read_tree;
use super::desired::native_dir;
use crate::apply::{Op, PlannedOp, Pre};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::source::local_source_root;

/// A live symlink's resolved target, once it has passed the boundary: the
/// real folder whose content is being adopted, and every native link (with
/// the text it was written with) that resolves to it.
pub(super) struct SharedTarget {
    pub(super) target: PathBuf,
    /// Link path → the target exactly as the link spells it, so the
    /// removal's precondition catches a link repointed between plan and
    /// apply.
    pub(super) links: Vec<(PathBuf, PathBuf)>,
    /// Every tool whose native link reads this folder.
    pub(super) harnesses: Vec<HarnessId>,
}

/// What a live link may be adopted through. The target must be a real
/// skill folder — the `SKILL.md` marker is what keeps a link at `$HOME` or
/// `/etc` refused — and must sit outside kendex's own machinery: the
/// rendered canonical and variant trees, the trash, the source cache, the
/// journal, and the local source the capture would write into (a managed
/// tree is already ours, and capturing it under another name would steal
/// it; capturing the destination would recurse). Everything is compared
/// canonicalized, so a `..`-laden link cannot dress one side up as the
/// other. Anything that fails stays what it was: a foreign symlink,
/// reported as a conflict.
pub(super) fn shared_target(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    original: &Path,
    points_to: PathBuf,
    local_item: &Path,
) -> Result<SharedTarget> {
    let refuse = || CoreError::ForeignSymlink {
        target: original.to_path_buf(),
        points_to: points_to.clone(),
    };
    // Only a skill directory has the marker that makes the boundary
    // checkable; an agent's file link stays a conflict.
    if kind != ItemKind::Skill {
        return Err(refuse());
    }
    let target = fs::canonicalize(original).map_err(|e| CoreError::io(original, e))?;
    if !target.is_dir() || !target.join("SKILL.md").is_file() {
        return Err(refuse());
    }
    let canon = |path: PathBuf| path.canonicalize().unwrap_or(path);
    let mut ours = vec![
        env.rendered_skills_dir(),
        env.trash_dir(),
        env.source_cache_dir(),
        env.journal_dir(),
        local_source_root(env, scope),
    ];
    ours.extend(
        HarnessId::ALL
            .iter()
            .map(|h| env.rendered_skill_variants_dir(h.name())),
    );
    if ours.into_iter().any(|root| target.starts_with(canon(root))) {
        return Err(refuse());
    }
    if local_item.starts_with(&target) {
        return Err(refuse());
    }

    let mut links = Vec::new();
    let mut harnesses = Vec::new();
    for h in HarnessId::ALL {
        let Some(dir) = native_dir(env, scope, h, ItemKind::Skill) else {
            continue;
        };
        let candidate = dir.join(crate::harness::rendered_name(h, name));
        if !candidate.is_symlink() {
            continue;
        }
        let Ok(resolved) = fs::canonicalize(&candidate) else {
            continue;
        };
        if resolved != target {
            continue;
        }
        harnesses.push(h);
        if !links.iter().any(|(path, _)| path == &candidate) {
            let raw = fs::read_link(&candidate).map_err(|e| CoreError::io(&candidate, e))?;
            links.push((candidate, raw));
        }
    }
    Ok(SharedTarget {
        target,
        links,
        harnesses,
    })
}

/// The ops that take over a shared folder: capture its bytes into the
/// local source, move the folder itself to the trash — bound to the exact
/// bytes just captured, so a folder that changed under the plan aborts the
/// apply (invariant 7) — and clear every link that read it, each bound to
/// the text it was written with. The follow-up apply re-renders the
/// canonical tree and the links, which is what restores the sharing.
pub(super) fn shared_capture_ops(
    name: &str,
    shared: &SharedTarget,
    local_item: &Path,
) -> Result<Vec<PlannedOp>> {
    let mut ops = Vec::new();
    if local_item.exists() {
        ops.push(PlannedOp {
            description: format!("trash the local source's earlier copy of {name}"),
            op: Op::Trash {
                path: local_item.to_path_buf(),
                pre: Pre::HashIs {
                    hash: crate::hash::hash_tree(local_item)?,
                },
            },
        });
    }
    ops.push(PlannedOp {
        description: format!("move the shared folder's content of {name} into the local source"),
        op: Op::WriteTree {
            root: local_item.to_path_buf(),
            files: read_tree(&shared.target)?,
            pre: Pre::Absent,
        },
    });
    ops.push(PlannedOp {
        description: format!(
            "trash the shared folder at {} (recoverable)",
            shared.target.display()
        ),
        op: Op::Trash {
            path: shared.target.clone(),
            pre: Pre::HashIs {
                hash: crate::hash::hash_tree(&shared.target)?,
            },
        },
    });
    for (link, raw) in &shared.links {
        ops.push(PlannedOp {
            description: format!("clear the link at {}", link.display()),
            op: Op::Trash {
                path: link.clone(),
                pre: Pre::SymlinkTo {
                    target: raw.clone(),
                },
            },
        });
    }
    Ok(ops)
}

#[cfg(test)]
mod tests {
    use super::super::adopt::adopt;
    use super::*;
    use crate::env::FakeOs;

    /// The shared-folder case this path exists for: two tools read one
    /// folder through links. Adopting captures the folder's content, and
    /// after the follow-up apply every tool still resolves to real files —
    /// the sharing survives with kendex's copy as canonical.
    #[test]
    fn a_shared_skill_folder_adopts_the_target_and_keeps_every_tool_reading() {
        let tmp = tempfile::tempdir().unwrap();
        let env = Env::fake(tmp.path(), FakeOs::Linux);
        let project = tmp.path().join("app");
        let scope = Scope::Project {
            root: project.clone(),
        };
        let shared = tmp.path().join("shared/browser");
        fs::create_dir_all(&shared).unwrap();
        fs::write(
            shared.join("SKILL.md"),
            "---\nname: browser\ndescription: drive a browser\n---\nShared content.\n",
        )
        .unwrap();
        fs::create_dir_all(project.join(".claude/skills")).unwrap();
        fs::create_dir_all(project.join(".agents/skills")).unwrap();
        std::os::unix::fs::symlink(&shared, project.join(".claude/skills/browser")).unwrap();
        std::os::unix::fs::symlink(&shared, project.join(".agents/skills/browser")).unwrap();

        let plan = adopt(
            &env,
            &scope,
            ItemKind::Skill,
            "browser",
            &[HarnessId::Claude],
        )
        .unwrap();
        crate::apply::execute(&env, &plan, None).unwrap();

        // Content captured; the folder and every link that read it cleared.
        assert!(
            project
                .join(".kendex-local/skills/browser/SKILL.md")
                .is_file()
        );
        assert!(!shared.exists());
        assert!(!project.join(".claude/skills/browser").is_symlink());
        assert!(!project.join(".agents/skills/browser").is_symlink());

        // The follow-up apply restores the sharing from kendex's copy.
        let report = crate::engine::audit(&env, &scope).unwrap();
        crate::apply::execute(&env, &report.plan, None).unwrap();
        let through_claude =
            fs::read_to_string(project.join(".claude/skills/browser/SKILL.md")).unwrap();
        assert!(through_claude.contains("Shared content."));
        let through_agents =
            fs::read_to_string(project.join(".agents/skills/browser/SKILL.md")).unwrap();
        assert!(through_agents.contains("Shared content."));
        let after = crate::engine::audit(&env, &scope).unwrap();
        assert_eq!(after.drift, vec![]);
    }

    /// "Somewhere kendex has no business touching": a folder that is not a
    /// skill at all. The marker is the boundary — no SKILL.md, no adopt.
    #[test]
    fn a_link_at_a_folder_without_the_marker_still_refuses() {
        let tmp = tempfile::tempdir().unwrap();
        let env = Env::fake(tmp.path(), FakeOs::Linux);
        let project = tmp.path().join("app");
        let scope = Scope::Project {
            root: project.clone(),
        };
        let elsewhere = tmp.path().join("documents");
        fs::create_dir_all(&elsewhere).unwrap();
        fs::write(elsewhere.join("notes.txt"), "private").unwrap();
        fs::create_dir_all(project.join(".claude/skills")).unwrap();
        std::os::unix::fs::symlink(&elsewhere, project.join(".claude/skills/documents")).unwrap();

        let error = adopt(
            &env,
            &scope,
            ItemKind::Skill,
            "documents",
            &[HarnessId::Claude],
        )
        .unwrap_err();
        assert!(matches!(error, CoreError::ForeignSymlink { .. }));
        assert!(project.join(".claude/skills/documents").is_symlink());
        assert!(elsewhere.join("notes.txt").is_file());
    }

    /// A link the user repointed into kendex's own store is not theirs to
    /// adopt: capturing a managed tree under another name would steal it.
    #[test]
    fn a_link_into_kendexs_own_trees_refuses() {
        let tmp = tempfile::tempdir().unwrap();
        let env = Env::fake(tmp.path(), FakeOs::Linux);
        let project = tmp.path().join("app");
        let scope = Scope::Project {
            root: project.clone(),
        };
        let managed = env.rendered_skills_dir().join("other");
        fs::create_dir_all(&managed).unwrap();
        fs::write(
            managed.join("SKILL.md"),
            "---\nname: other\ndescription: managed elsewhere\n---\nManaged.\n",
        )
        .unwrap();
        fs::create_dir_all(project.join(".claude/skills")).unwrap();
        std::os::unix::fs::symlink(&managed, project.join(".claude/skills/stolen")).unwrap();

        let error = adopt(
            &env,
            &scope,
            ItemKind::Skill,
            "stolen",
            &[HarnessId::Claude],
        )
        .unwrap_err();
        assert!(matches!(error, CoreError::ForeignSymlink { .. }));
        assert!(managed.join("SKILL.md").is_file());
    }

    /// The folder changing between the plan and the apply aborts the whole
    /// transaction: the trash op is bound to the bytes that were captured,
    /// so a stale snapshot can never become "the backup".
    #[test]
    fn a_target_that_changed_after_planning_fails_the_apply() {
        let tmp = tempfile::tempdir().unwrap();
        let env = Env::fake(tmp.path(), FakeOs::Linux);
        let project = tmp.path().join("app");
        let scope = Scope::Project {
            root: project.clone(),
        };
        let shared = tmp.path().join("shared/browser");
        fs::create_dir_all(&shared).unwrap();
        fs::write(
            shared.join("SKILL.md"),
            "---\nname: browser\ndescription: drive a browser\n---\nShared content.\n",
        )
        .unwrap();
        fs::create_dir_all(project.join(".claude/skills")).unwrap();
        std::os::unix::fs::symlink(&shared, project.join(".claude/skills/browser")).unwrap();

        let plan = adopt(
            &env,
            &scope,
            ItemKind::Skill,
            "browser",
            &[HarnessId::Claude],
        )
        .unwrap();
        fs::write(shared.join("SKILL.md"), "changed under the plan").unwrap();

        assert!(crate::apply::execute(&env, &plan, None).is_err());
        assert!(
            shared.join("SKILL.md").is_file(),
            "the folder stays where it was"
        );
        assert!(project.join(".claude/skills/browser").is_symlink());
    }

    /// A folder bigger than any real skill is refused before anything is
    /// planned, naming the budget, instead of being captured wholesale.
    #[test]
    fn an_oversized_target_is_refused_out_loud() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("huge");
        fs::create_dir_all(&dir).unwrap();
        for i in 0..(super::super::adopt::MAX_CAPTURE_FILES + 1) {
            fs::write(dir.join(format!("f{i}")), "x").unwrap();
        }
        let error = read_tree(&dir).unwrap_err();
        assert!(error.to_string().contains("bigger than adopt"), "{error}");
    }
}
