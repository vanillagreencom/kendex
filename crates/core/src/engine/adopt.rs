use std::fs;
use std::path::{Path, PathBuf};

use super::adopt_shared::{SharedTarget, shared_capture_ops, shared_target};
use super::desired::native_dir;
use super::ops::manifest_for_mutation;
use crate::apply::{Op, Plan, PlannedOp, Pre};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{self, ItemDecl, LOCAL_SOURCE_NAME};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::source::local_source_root;

/// Record an observed, unmanaged item into the manifest: its content moves
/// into the scope's local source (nothing is ever lost), the item is
/// declared from source `local`, and the original artifact goes to the
/// trash. A follow-up apply renders the managed replacement.
///
/// State machine: target-has-files → merge into declaration;
/// live symlink → adopt the *target's* content when it passes the shared-
/// target boundary (a skill folder the user linked several tools at), and
/// take every sibling link with it so the follow-up apply can restore the
/// sharing with kendex's copy as canonical; anything else a link points at
/// stays a conflict, never a clobber target; broken symlink → nothing to
/// adopt, the follow-up apply recreates from declaration.
/// The kinds adoption can take. A declaration built around content already
/// on disk needs somewhere in the local source to put that content, and
/// only these two have one — the same two the local-source match below
/// takes. Read wherever a refusal offers adoption as a way out, so no
/// message ever names an action that would error.
pub fn supports(kind: ItemKind) -> bool {
    matches!(kind, ItemKind::Agent | ItemKind::Skill)
}

pub fn adopt(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
) -> Result<Plan> {
    let mut manifest = manifest_for_mutation(env, scope)?;
    let Some(dir) = native_dir(env, scope, harness, kind) else {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: format!("{} {}", harness.name(), kind.name()),
        });
    };
    let original = match kind {
        ItemKind::Agent => dir.join(crate::render::agent::file_name(harness, name)),
        _ => dir.join(name),
    };

    let local_root = local_source_root(env, scope);
    let local_item = match kind {
        ItemKind::Skill => local_root.join("skills").join(name),
        ItemKind::Agent => local_root.join("agents").join(format!("{name}.md")),
        other => {
            return Err(CoreError::ItemNotInSource {
                name: name.to_owned(),
                source_name: format!("adopt does not support {} yet", other.name()),
            });
        }
    };

    // Broken link: content is gone; declaring is all adoption can do. The
    // link itself is cleared by a planned op — planning never touches disk,
    // so a plan that is never applied (or fails) leaves the world as it was.
    let mut broken_link: Option<Pre> = None;
    let mut shared: Option<SharedTarget> = None;
    if original.is_symlink() {
        let points_to = fs::read_link(&original).map_err(|e| CoreError::io(&original, e))?;
        if original.exists() {
            shared = Some(shared_target(
                env,
                scope,
                kind,
                name,
                &original,
                points_to,
                &local_item,
            )?);
        } else {
            broken_link = Some(Pre::SymlinkTo { target: points_to });
        }
    }

    let mut ops = match &shared {
        Some(shared) => shared_capture_ops(name, shared, &local_item)?,
        None => capture_ops(kind, name, original, &local_item, broken_link)?,
    };

    // A shared folder is declared for every tool that was reading it, not
    // only the one the user clicked — dropping the others is exactly the
    // broken sharing this path exists to avoid.
    let wanted: Vec<HarnessId> = match &shared {
        Some(shared) => shared.harnesses.clone(),
        None => vec![harness],
    };
    // Adoption binds to the harnesses that were actually reading the item.
    // Only when the [install] defaults name exactly that set may the list be
    // left off: a wider default would install the item for tools the user
    // never gave it to.
    let defaults_match = {
        let defaults: std::collections::BTreeSet<&HarnessId> =
            manifest.install.harnesses.iter().collect();
        wanted
            .iter()
            .collect::<std::collections::BTreeSet<&HarnessId>>()
            == defaults
    };
    let decl = manifest
        .declared_mut(kind)
        .entry(name.to_owned())
        .or_insert_with(|| ItemDecl::from_source(LOCAL_SOURCE_NAME));
    decl.source = LOCAL_SOURCE_NAME.to_owned();
    if decl.harnesses.is_none() && !defaults_match {
        decl.harnesses = Some(wanted);
    }

    let manifest_path = manifest::manifest_path(env, scope);
    ops.push(PlannedOp {
        description: "declare the adopted item in kendex.toml".into(),
        op: Op::WriteManifest {
            pre: Pre::observed(&manifest_path)?,
            path: manifest_path,
            manifest: Box::new(manifest),
        },
    });
    Ok(Plan {
        scope: scope.clone(),
        ops,
    })
}

/// Move the observed artifact into the local source and clear what it left
/// behind. Nothing here runs at plan time: every byte read becomes an op.
fn capture_ops(
    kind: ItemKind,
    name: &str,
    original: PathBuf,
    local_item: &Path,
    broken_link: Option<Pre>,
) -> Result<Vec<PlannedOp>> {
    let mut ops = Vec::new();
    if let Some(pre) = broken_link {
        ops.push(PlannedOp {
            description: format!("clear the broken link at {}", original.display()),
            op: Op::Trash {
                path: original.clone(),
                pre,
            },
        });
    }
    if !original.exists() {
        if !local_item.exists() {
            return Err(CoreError::ItemNotInSource {
                name: name.to_owned(),
                source_name: format!("nothing at {} to adopt", original.display()),
            });
        }
        return Ok(ops);
    }
    // A copy the local source already holds is not overwritten in place:
    // it goes to the trash first, where it can be got back.
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
    let capture = match kind {
        ItemKind::Skill => Op::WriteTree {
            root: local_item.to_path_buf(),
            files: read_tree(&original)?,
            pre: Pre::Absent,
        },
        _ => Op::WriteFile {
            path: local_item.to_path_buf(),
            bytes: fs::read(&original).map_err(|e| CoreError::io(&original, e))?,
            pre: Pre::Absent,
        },
    };
    ops.push(PlannedOp {
        description: format!("move {name} into the local source"),
        op: capture,
    });
    ops.push(PlannedOp {
        description: format!("trash the unmanaged original at {}", original.display()),
        op: Op::Trash {
            path: original,
            pre: Pre::Any,
        },
    });
    Ok(ops)
}

/// Far beyond any real skill, but a hard stop before a link at a huge
/// folder turns a capture into a memory problem. Fail-loud: the error
/// names the file that broke the budget.
pub(super) const MAX_CAPTURE_FILES: usize = 2000;
pub(super) const MAX_CAPTURE_BYTES: u64 = 100 * 1024 * 1024;

pub(crate) fn read_tree(root: &Path) -> Result<Vec<(PathBuf, Vec<u8>)>> {
    fn walk(
        dir: &Path,
        rel: &Path,
        files: &mut Vec<(PathBuf, Vec<u8>)>,
        bytes: &mut u64,
    ) -> Result<()> {
        for entry in fs::read_dir(dir).map_err(|e| CoreError::io(dir, e))? {
            // A per-entry read error is not silently skipped: dropping it
            // would capture an incomplete tree and then trash the
            // original, losing content the caller asked to keep.
            let entry = entry.map_err(|e| CoreError::io(dir, e))?;
            let path = entry.path();
            let Some(name) = path.file_name() else {
                continue;
            };
            let rel = rel.join(name);
            // A link is not plain content: following it would read whatever
            // it points at into the capture under this tree's name. Rather
            // than silently drop it (and then trash the original), refuse —
            // nothing the user asked to keep is lost without a word.
            if path.is_symlink() {
                return Err(CoreError::ForeignSymlink {
                    points_to: fs::read_link(&path).unwrap_or_default(),
                    target: path,
                });
            }
            if path.is_dir() {
                walk(&path, &rel, files, bytes)?;
                continue;
            }
            // A FIFO would block the read forever and a device is not
            // content; capturing arbitrary user folders means saying so
            // instead of hanging.
            let meta = fs::symlink_metadata(&path).map_err(|e| CoreError::io(&path, e))?;
            if !meta.is_file() {
                return Err(CoreError::io(
                    &path,
                    std::io::Error::other("not a regular file — adopt captures plain files only"),
                ));
            }
            *bytes += meta.len();
            if files.len() >= MAX_CAPTURE_FILES || *bytes > MAX_CAPTURE_BYTES {
                return Err(CoreError::io(
                    &path,
                    std::io::Error::other(format!(
                        "this folder is bigger than adopt will capture (over {MAX_CAPTURE_FILES} files or {} MB)",
                        MAX_CAPTURE_BYTES / (1024 * 1024)
                    )),
                ));
            }
            files.push((rel, fs::read(&path).map_err(|e| CoreError::io(&path, e))?));
        }
        Ok(())
    }
    let mut files = Vec::new();
    let mut bytes = 0;
    walk(root, Path::new(""), &mut files, &mut bytes)?;
    Ok(files)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::audit;
    use crate::env::FakeOs;

    #[test]
    fn adopting_a_handmade_skill_moves_merges_and_round_trips() {
        let tmp = tempfile::tempdir().unwrap();
        let env = Env::fake(tmp.path(), FakeOs::Linux);
        let project = tmp.path().join("app");
        let scope = Scope::Project {
            root: project.clone(),
        };
        fs::create_dir_all(project.join(".claude/skills/handmade")).unwrap();
        fs::write(
            project.join(".claude/skills/handmade/SKILL.md"),
            "---\nname: handmade\ndescription: mine\n---\nMy content.\n",
        )
        .unwrap();

        let plan = adopt(&env, &scope, ItemKind::Skill, "handmade", HarnessId::Claude).unwrap();
        crate::apply::execute(&env, &plan, None).unwrap();

        // Content lives in the local source; the original is trashed.
        assert!(
            project
                .join(".kendex-local/skills/handmade/SKILL.md")
                .is_file()
        );
        assert!(!project.join(".claude/skills/handmade").exists());

        // Follow-up apply renders the managed replacement, drift-clean.
        let report = audit(&env, &scope).unwrap();
        crate::apply::execute(&env, &report.plan, None).unwrap();
        let link = project.join(".claude/skills/handmade");
        assert!(link.is_symlink());
        let rendered =
            fs::read_to_string(project.join(".agents/skills/handmade/SKILL.md")).unwrap();
        assert!(rendered.contains("My content."));
        let after = audit(&env, &scope).unwrap();
        assert_eq!(after.drift, vec![]);
    }

    /// The local source already had a copy: it is trashed, never overwritten
    /// in place, so nothing adoption replaces is gone for good.
    #[test]
    fn an_earlier_local_copy_goes_to_the_trash_not_under_the_new_one() {
        let tmp = tempfile::tempdir().unwrap();
        let env = Env::fake(tmp.path(), FakeOs::Linux);
        let project = tmp.path().join("app");
        let scope = Scope::Project {
            root: project.clone(),
        };
        let earlier = project.join(".kendex-local/skills/handmade");
        fs::create_dir_all(&earlier).unwrap();
        fs::write(earlier.join("SKILL.md"), "earlier").unwrap();
        fs::write(earlier.join("notes.md"), "kept only here").unwrap();
        fs::create_dir_all(project.join(".claude/skills/handmade")).unwrap();
        fs::write(project.join(".claude/skills/handmade/SKILL.md"), "observed").unwrap();

        let plan = adopt(&env, &scope, ItemKind::Skill, "handmade", HarnessId::Claude).unwrap();
        crate::apply::execute(&env, &plan, None).unwrap();

        assert_eq!(
            fs::read_to_string(earlier.join("SKILL.md")).unwrap(),
            "observed"
        );
        assert!(!earlier.join("notes.md").exists());
        let trashed: Vec<_> = fs::read_dir(env.trash_dir()).unwrap().flatten().collect();
        assert!(trashed.iter().any(|e| e.path().join("notes.md").is_file()));
    }

    /// The [install] defaults name more tools than the one the item was
    /// adopted from: the declaration pins to what was actually observed, so
    /// the follow-up apply never installs it somewhere the user never put it.
    #[test]
    fn adoption_binds_only_the_harnesses_that_had_the_item() {
        let tmp = tempfile::tempdir().unwrap();
        let env = Env::fake(tmp.path(), FakeOs::Linux);
        let project = tmp.path().join("app");
        let scope = Scope::Project {
            root: project.clone(),
        };
        fs::create_dir_all(&project).unwrap();
        fs::write(
            project.join("kendex.toml"),
            "schema = 5\n\n[install]\nharnesses = [\"claude\", \"opencode\"]\nmethod = \"symlink\"\n",
        )
        .unwrap();
        fs::create_dir_all(project.join(".claude/skills/handmade")).unwrap();
        fs::write(
            project.join(".claude/skills/handmade/SKILL.md"),
            "---\nname: handmade\ndescription: mine\n---\nMy content.\n",
        )
        .unwrap();

        let plan = adopt(&env, &scope, ItemKind::Skill, "handmade", HarnessId::Claude).unwrap();
        crate::apply::execute(&env, &plan, None).unwrap();

        let manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
        assert!(manifest.contains("[skills.handmade]"));
        assert!(
            manifest.contains("harnesses = [\"claude\"]"),
            "the declaration must pin to the adopted harness alone:\n{manifest}"
        );

        let report = audit(&env, &scope).unwrap();
        crate::apply::execute(&env, &report.plan, None).unwrap();
        assert!(project.join(".claude/skills/handmade").is_symlink());
        assert!(!project.join(".opencode/skills/handmade").exists());
    }

    #[test]
    fn foreign_symlinks_are_conflicts_never_clobbered() {
        let tmp = tempfile::tempdir().unwrap();
        let env = Env::fake(tmp.path(), FakeOs::Linux);
        let project = tmp.path().join("app");
        let scope = Scope::Project {
            root: project.clone(),
        };
        let elsewhere = tmp.path().join("elsewhere");
        fs::create_dir_all(&elsewhere).unwrap();
        fs::create_dir_all(project.join(".claude/skills")).unwrap();
        std::os::unix::fs::symlink(&elsewhere, project.join(".claude/skills/linked")).unwrap();

        let error = adopt(&env, &scope, ItemKind::Skill, "linked", HarnessId::Claude).unwrap_err();
        assert!(matches!(error, CoreError::ForeignSymlink { .. }));
        assert!(project.join(".claude/skills/linked").is_symlink());
    }
}
