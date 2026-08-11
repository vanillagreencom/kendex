use crate::agent::Agent;
use crate::config::{InstallMethod, ItemKind, LockEntry, LockFile};
use crate::harness::Harness;
use crate::hook::Hook;
use crate::skill::Skill;
use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

mod hooks;

pub(crate) use crate::path_safety::{validate_item_name, validate_new_item_name};
pub(crate) use hooks::{
    codex_event_for, codex_root, cursor_hook_rule_contents, cursor_hook_rule_path,
    install_codex_fallback_hooks_for_agents, install_hook, migrate_codex_config,
    opencode_hook_instruction_contents, opencode_hook_instruction_path, remove_hook_install,
};

pub(crate) fn codex_hook_safety_block(hook: &Hook) -> String {
    hooks::codex_hook_safety_block(hook)
}

/// Result of a single installation
pub struct InstallResult {
    pub name: String,
    pub kind: ItemKind,
    pub harness: Harness,
    pub path: PathBuf,
    pub detail: String,
}

/// Install an agent to a specific harness
pub fn install_agent(
    agent: &Agent,
    harness: Harness,
    global: bool,
    skills: &[(String, String)],
    hooks: &[crate::hook::Hook],
    extras: &crate::agent::AgentExtras,
) -> Result<InstallResult> {
    validate_new_item_name(&agent.name)?;
    let output_path = harness.generate_agent(agent, global, skills, hooks, extras)?;

    let detail = format!(
        "{} → {} ({})",
        agent.name,
        output_path.display(),
        harness.name()
    );

    Ok(InstallResult {
        name: agent.name.clone(),
        kind: ItemKind::Agent,
        harness,
        detail,
        path: output_path,
    })
}

/// Install a skill directory to a specific harness.
///
/// Symlink mode: copy to a canonical dir (`.agents/skills/<name>/`) in the
/// checkout where the harness link physically lands — the project root, or
/// the same-repository checkout a worktree setup shares its harness dirs
/// with — then symlink from each harness-specific dir to the canonical copy.
///
/// Copy mode: copy directly to each harness dir.
pub fn install_skill(
    skill: &Skill,
    harness: Harness,
    global: bool,
    method: InstallMethod,
    instructions: Option<&str>,
) -> Result<InstallResult> {
    validate_new_item_name(&skill.name)?;
    // The containment preflight must cover every install that writes
    // through `.agents`: all project-scope symlink installs (their
    // canonical lives there), and ANY install whose harness dest itself
    // sits under `.agents` (Codex/Pi copy mode included — the TUI
    // global→project move calls install_skill with no other preflight).
    // Copy installs into non-.agents harness dirs skip it: they must keep
    // working beside an unrelated linked agents root.
    let dest_under_agents = harness
        .skills_dir(global)
        .starts_with(crate::config::project_root().join(".agents"));
    if !global && (method == InstallMethod::Symlink || dest_under_agents) {
        crate::path_safety::ensure_agents_dir_within_project(&crate::config::project_root())?;
    }
    let dest = harness.install_skill(skill, global)?;
    if !global && method == InstallMethod::Symlink {
        // A dest that physically lives in a same-repository checkout whose
        // .agents FAILS validation must refuse outright: falling back to
        // ordinary relative linking writes a worktree-absolute target into
        // the other checkout — the dangling-link hazard once this worktree
        // is removed.
        let lexical = normalize_absolute_path(&dest);
        if let Some(physical) = canonicalize_allowing_missing(&dest) {
            if physical != lexical {
                let mut probe = physical.parent();
                while let Some(dir) = probe {
                    if dir.is_dir() {
                        break;
                    }
                    probe = dir.parent();
                }
                if let Some(probe_dir) = probe
                    && let (Some(project_common), Some((probe_common, checkout_toplevel))) = (
                        crate::path_safety::git_common_dir(&crate::config::project_root()),
                        crate::path_safety::git_repo_identity(probe_dir),
                    )
                    && probe_common == project_common
                {
                    let project_canon = std::fs::canonicalize(crate::config::project_root())
                        .unwrap_or_else(|_| {
                            normalize_absolute_path(&crate::config::project_root())
                        });
                    // Validate the CORRESPONDING nested project root, not the
                    // toplevel: for a project below the git toplevel, the
                    // shared surface lives at the other checkout's copy of
                    // that directory, and its toplevel `.agents` (unrelated
                    // or absent) says nothing about it.
                    let corresponding = corresponding_project_root_in(&checkout_toplevel);
                    match corresponding {
                        Some(root) => {
                            if root != project_canon
                                && crate::path_safety::ensure_agents_dir_within_project(&root)
                                    .is_err()
                            {
                                anyhow::bail!(
                                    "refusing to install {} through {}: that same-repository checkout's .agents fails validation, and falling back to an ordinary link would write a worktree-absolute target into it",
                                    skill.name,
                                    root.display()
                                );
                            }
                            // Symlink indirection whose landing parent is NOT
                            // a recognized skills surface is an alias (e.g.
                            // `.claude/skills -> cli/src`, same checkout or
                            // another): installing would remove_existing/
                            // replace children of an arbitrary repository
                            // directory. Current-checkout indirection gets
                            // the same gate — the fallback path would delete
                            // through the alias just as readily.
                            if let Some(parent) = physical.parent()
                                && !is_recognized_skills_surface(&root, parent)
                            {
                                anyhow::bail!(
                                    "refusing to install {} through {}: it resolves into {}, which is not a recognized skills directory of {}",
                                    skill.name,
                                    dest.display(),
                                    parent.display(),
                                    root.display()
                                );
                            }
                        }
                        None => anyhow::bail!(
                            "refusing to install {} through {}: cannot derive the corresponding project root in that same-repository checkout",
                            skill.name,
                            checkout_toplevel.display()
                        ),
                    }
                }
            }
        }
    }

    let detail = match method {
        InstallMethod::Symlink => {
            // Where the link physically lands. Worktree setups symlink
            // harness dirs into the main checkout (vstack#886), so this can
            // be a different checkout of the same repository than the
            // project root the command ran from.
            let link_home = if global { None } else { skill_link_home(&dest) };

            // Canonical location: .agents/skills/<name>/ (universal, like
            // Vercel npx skills). For project scope the copy must live in
            // the checkout where the link physically lands: the link's
            // relative spelling resolves from there, and a copy left in the
            // worktree would leave the main checkout's link pointing at
            // state that dies with the worktree (VST-195).
            let canonical = if global && matches!(harness, Harness::Codex) {
                crate::config::codex_home_dir()
                    .join("skills")
                    .join(&skill.name)
            } else if global {
                crate::config::global_state_dir()
                    .join("skills")
                    .join(&skill.name)
            } else {
                // No link evidence for THIS skill (fresh install). In a
                // per-child sharing layout — a real skills dir whose
                // EXISTING children symlink into another checkout — a new
                // skill follows its siblings' anchor so one layout does not
                // split canonicals across two checkouts.
                let home_root = link_home
                    .as_ref()
                    .map(|home| home.checkout_root.clone())
                    .unwrap_or_else(|| {
                        // Probe the SELECTED harness's skills dir first: a
                        // partially shared layout (real `.claude/skills`,
                        // each child linked out) with a LOCAL `.agents`
                        // leaves no evidence under `.agents/skills`, and a
                        // new skill must still follow its harness siblings
                        // into the owning checkout.
                        let own_skills =
                            crate::config::project_root().join(".agents").join("skills");
                        let mut anchored: Vec<(PathBuf, AnchorEvidence)> = dest
                            .parent()
                            .map(child_level_anchored_roots)
                            .unwrap_or_default();
                        anchored.extend(child_level_anchored_roots(&own_skills));
                        // Deterministic selection when children point at
                        // multiple checkouts: strongest evidence (most
                        // children) wins, path order breaks ties —
                        // read_dir order must never pick the anchor.
                        anchored.sort_by(|(a_root, a_ev), (b_root, b_ev)| {
                            let count = |ev: &AnchorEvidence| match ev {
                                AnchorEvidence::Children(names) => names.len(),
                                AnchorEvidence::SharedDir => usize::MAX,
                            };
                            count(b_ev).cmp(&count(a_ev)).then(a_root.cmp(b_root))
                        });
                        anchored
                            .into_iter()
                            .next()
                            .and_then(|(root, _)| {
                                // root is <checkout>/.agents/skills
                                root.parent()
                                    .and_then(Path::parent)
                                    .map(Path::to_path_buf)
                            })
                            .unwrap_or_else(crate::config::project_root)
                    });
                home_root
                    .join(".agents")
                    .join("skills")
                    .join(&skill.name)
            };

            // Step 1: Copy to canonical location (refresh from source).
            // Use a marker file to avoid re-copying if another harness
            // already refreshed the canonical in this process.
            //
            // Foreign canonicals are write-shy: an existing canonical in
            // another checkout is linked to AS-IS — its content and marker
            // belong to that checkout's installs, and refreshing it is the
            // owning checkout's job. A LinkHome alone does not make the
            // canonical foreign: an ordinary existing child link
            // (`.claude/skills/<name>` → `../../.agents/skills/<name>`)
            // resolves to a LinkHome whose checkout IS this project, and
            // treating that as foreign would skip every refresh after the
            // first install.
            let project_checkout = std::fs::canonicalize(crate::config::project_root())
                .unwrap_or_else(|_| normalize_absolute_path(&crate::config::project_root()));
            // Foreignness is a property of where the canonical PHYSICALLY
            // resolves, not of the harness link: with a shared `.agents` but
            // a local harness dir, link_home is None while the canonical
            // still lives in the main checkout — treating it as own would
            // remove_existing another checkout's copy.
            let canonical_physical = canonicalize_allowing_missing(&canonical)
                .unwrap_or_else(|| normalize_absolute_path(&canonical));
            // ... but a canonical THIS project already references is OURS to
            // refresh wherever it physically lives: the worktree that
            // installed through a shared layout must keep receiving source
            // updates (write-shy is for canonicals we find, not ones we
            // made). The dest artifact resolving to the canonical is that
            // ownership evidence.
            // Ownership evidence follows the anchor TYPE: SharedDir — the
            // dest's PARENT directory itself resolves into the other
            // checkout, so this project operates inside the shared surface
            // and the canonical it references there is its own install to
            // refresh. Children — a local parent whose final component
            // links out — stays write-shy: that linked copy is the owning
            // checkout's.
            let dest_parent_shared = dest
                .parent()
                .and_then(|parent| parent.canonicalize().ok())
                .is_some_and(|parent| !parent.starts_with(&project_checkout));
            // A symlink AT the canonical location is project-skills-dir
            // wiring wherever it is referenced from — never refresh-owned.
            let canonical_is_symlink = std::fs::symlink_metadata(&canonical)
                .is_ok_and(|meta| meta.file_type().is_symlink());
            let dest_references_canonical = dest_parent_shared
                && !canonical_is_symlink
                && dest
                    .canonicalize()
                    .is_ok_and(|resolved| resolved == canonical_physical)
                && std::fs::symlink_metadata(&dest).is_ok_and(|meta| {
                    // A symlink artifact in the shared surface, OR the
                    // direct-canonical shape (Codex/Pi: dest IS the real
                    // canonical dir reached through the shared `.agents`) —
                    // both are this project's install to refresh.
                    meta.file_type().is_symlink() || meta.file_type().is_dir()
                });
            // Global installs live under user homes by definition — the
            // anchoring/write-shy machinery is project-scope only, and a
            // global Codex canonical (canonical == dest, outside any
            // project) must keep refreshing.
            let mut foreign_existing = !global
                && !canonical_physical.starts_with(&project_checkout)
                && !dest_references_canonical
                && canonical.exists();
            if foreign_existing
                && std::fs::symlink_metadata(&canonical)
                    .is_ok_and(|meta| meta.file_type().is_symlink())
            {
                // A symlink canonical is legitimate when it stays inside its
                // OWN checkout — the supported project-skills-dir layout
                // spells `.agents/skills/<name>` as a link to the tracked
                // project-owned skill. Only a link escaping its checkout is
                // the smuggle case (exists()/is_file() would follow it past
                // containment): that one is repaired from source
                // (remove_existing unlinks the symlink itself, never its
                // target).
                // The owning root comes from the PARENT's physical home —
                // the spelled path may run through this worktree's shared
                // `.agents`, and spelled-parent canonicalization would name
                // the worktree, misreading main's project-skills-dir
                // symlink as escaping.
                let owning_checkout = canonical
                    .parent()
                    .and_then(|parent| parent.canonicalize().ok())
                    .and_then(|skills| skills.parent().map(Path::to_path_buf))
                    .and_then(|agents| agents.parent().map(Path::to_path_buf));
                let escapes_checkout = match owning_checkout {
                    Some(root) => !canonical_physical.starts_with(&root),
                    None => true,
                };
                if escapes_checkout {
                    eprintln!(
                        "  Warning: existing canonical {} is a symlink escaping its checkout; repairing it from source (VST-195)",
                        canonical.display()
                    );
                    foreign_existing = false;
                }
            }
            if foreign_existing && !canonical.join("SKILL.md").is_file() {
                if canonical.join(".vstack-refreshed").exists() {
                    // Write-shy protects the owning checkout's valid
                    // installs; a MARKED canonical without SKILL.md was a
                    // vstack install that lost its payload — repair it from
                    // source rather than linking to it AS-IS.
                    eprintln!(
                        "  Warning: existing canonical {} has no SKILL.md; repairing it from source (VST-195)",
                        canonical.display()
                    );
                    foreign_existing = false;
                } else {
                    // No SKILL.md AND no managed marker: this directory in
                    // another checkout is not provably a vstack install —
                    // deleting it could destroy manually maintained data
                    // that merely shares the skill's name. Refuse loudly.
                    anyhow::bail!(
                        "existing directory {} in another checkout has neither SKILL.md nor a vstack marker — refusing to replace what may not be a vstack install; remove or rename it there first",
                        canonical.display()
                    );
                }
            }
            let marker = canonical.join(".vstack-refreshed");
            let current_pid = std::process::id().to_string();
            let already_refreshed = marker.exists()
                && std::fs::read_to_string(&marker).is_ok_and(|s| s.trim() == current_pid);
            if !foreign_existing && !already_refreshed {
                remove_existing(&canonical)?;
                copy_dir(&skill.source_dir, &canonical)?;

                // Inject skill instructions from project config
                let skill_md = canonical.join("SKILL.md");
                if let Some(text) = instructions {
                    crate::skill::inject_skill_instructions(&skill_md, text);
                }
                crate::skill::inject_vstack_notice(&skill_md);

                // Mark as done for this process
                let _ = std::fs::write(&marker, std::process::id().to_string());
            }

            // Step 2: If this harness IS the canonical path — by spelling,
            // or physically because a shared `.agents` already places dest
            // at the canonical copy — we're done. Linking a physically
            // canonical dest would replace the copy with a self-referential
            // symlink.
            let physically_canonical = link_home.as_ref().is_some_and(|_| {
                // Compare where DEST itself physically resolves, not a
                // reconstructed `<physical parent>/<name>`: a stale child
                // link `foo -> .../bar` shares the canonical's parent, and
                // the reconstruction would call it canonical while it points
                // at the wrong skill. A symlink at dest is never physically
                // canonical — it is an artifact to (re)point in Step 3.
                !std::fs::symlink_metadata(&dest)
                    .is_ok_and(|meta| meta.file_type().is_symlink())
                    && canonicalize_allowing_missing(&dest)
                        .is_some_and(|resolved| resolved == canonical_physical)
            });
            if dest == canonical || physically_canonical {
                format!(
                    "{} → {} (canonical, {})",
                    skill.name,
                    canonical.display(),
                    harness.name()
                )
            } else {
                // Step 3: Symlink from harness dir to canonical
                if let Some(parent) = dest.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                remove_existing(&dest)?;

                #[cfg(unix)]
                {
                    // Where the new link ACTUALLY lands. Parent-level sharing:
                    // dest's parent resolves into the other checkout, so the
                    // link is physically created at home.physical_parent.
                    // Child-level sharing: the parent is LOCAL (the old child
                    // symlink was just removed above), so the link lands in
                    // this checkout — a spelling computed at the foreign
                    // parent (`github`) would be self-referential here.
                    let creation_parent = dest
                        .parent()
                        .and_then(|parent| parent.canonicalize().ok());
                    let rel = match (&link_home, creation_parent) {
                        // The repo layout is identical in every checkout, so
                        // the relative spelling computed at the link's
                        // physical home resolves there — worktree-independent.
                        (Some(home), Some(created_in)) if created_in == home.physical_parent => {
                            let rel = lexical_relative(&home.physical_parent, &canonical);
                            if home.physical_parent.join(&rel).is_dir() {
                                rel
                            } else {
                                // Never emit a relative spelling whose target
                                // does not exist from the link's physical
                                // landing point.
                                let abs = std::fs::canonicalize(&canonical)
                                    .unwrap_or_else(|_| canonical.clone());
                                eprintln!(
                                    "  Warning: skill link {} cannot anchor inside its own checkout (VST-195); using absolute target {}",
                                    dest.display(),
                                    abs.display()
                                );
                                abs
                            }
                        }
                        // Child-level sharing: recreate the layout's shape —
                        // a local child link pointing at the other checkout's
                        // canonical. The target is absolute: it lives in the
                        // OWNING checkout (stable), while this link dies with
                        // the worktree; a cross-checkout ../ chain would
                        // depend on where the worktree happens to sit.
                        (Some(_), _) => std::fs::canonicalize(&canonical)
                            .unwrap_or_else(|_| canonical.clone()),
                        (None, _) => relative_path(dest.parent().unwrap(), &canonical)?,
                    };
                    std::os::unix::fs::symlink(&rel, &dest).with_context(|| {
                        format!("symlinking {} → {}", dest.display(), rel.display())
                    })?;
                }

                #[cfg(not(unix))]
                copy_dir(&canonical, &dest)?;

                format!(
                    "{} → {} (symlink, {})",
                    skill.name,
                    dest.display(),
                    harness.name()
                )
            }
        }
        InstallMethod::Copy => {
            remove_existing(&dest)?;
            copy_dir(&skill.source_dir, &dest)?;

            // Inject skill instructions from project config
            let skill_md = dest.join("SKILL.md");
            if let Some(text) = instructions {
                crate::skill::inject_skill_instructions(&skill_md, text);
            }
            crate::skill::inject_vstack_notice(&skill_md);

            // Write marker so reconciliation can detect vstack-managed skills
            let _ = std::fs::write(
                dest.join(".vstack-refreshed"),
                std::process::id().to_string(),
            );

            format!(
                "{} → {} (copy, {})",
                skill.name,
                dest.display(),
                harness.name()
            )
        }
    };

    Ok(InstallResult {
        name: skill.name.clone(),
        kind: ItemKind::Skill,
        harness,
        path: dest,
        detail,
    })
}

/// What [`remove_item`] did and deliberately did not do.
#[derive(Debug)]
pub struct RemoveOutcome {
    /// Paths deleted from disk.
    pub removed: Vec<PathBuf>,
    /// Anchored canonical copies left in place (noted on stderr) for their
    /// own checkout's removal to collect.
    pub anchored_left: Vec<PathBuf>,
}

/// Remove an installed item.
///
/// Agent/skill deletion and hook cleanup are attempted for every requested
/// harness. Any deletion failure includes path/harness/scope context so callers
/// can keep the lock entry until a later retry succeeds.
pub fn remove_item(
    name: &str,
    kind: Option<ItemKind>,
    harnesses: &[Harness],
    global: bool,
) -> Result<RemoveOutcome> {
    validate_item_name(name)?;
    let mut removed = Vec::new();
    let mut anchored_left = Vec::new();
    let mut cleanup_errors = Vec::new();
    let remove_agents = kind.is_none_or(|kind| kind == ItemKind::Agent);
    let remove_skills = kind.is_none_or(|kind| kind == ItemKind::Skill);
    let remove_hooks = kind.is_none_or(|kind| kind == ItemKind::Hook);

    // Resolve anchored canonical homes for every requested dest BEFORE any
    // unlinking: removal destroys the evidence it needs (deleting a
    // child-level link makes the parent look purely local), so anchored-side
    // bookkeeping must act on a snapshot.
    let anchored_canonicals: Vec<PathBuf> = if global || !remove_skills {
        Vec::new()
    } else {
        let mut canonicals: Vec<PathBuf> = Vec::new();
        let mut probed: Vec<PathBuf> = Vec::new();
        // Anchored preservation is for OTHER checkouts' canonicals only: an
        // ordinary project-scope child link also yields a LinkHome, but its
        // checkout IS this project — admitting it would make every normal
        // `vstack remove` skip deleting its own canonical (and clear its
        // marker) while reporting success.
        let project_checkout = std::fs::canonicalize(crate::config::project_root())
            .unwrap_or_else(|_| normalize_absolute_path(&crate::config::project_root()));
        for harness in harnesses {
            let dest = harness.skills_dir(false).join(name);
            if probed.contains(&dest) {
                continue;
            }
            probed.push(dest.clone());
            if let Some(home) = skill_link_home(&dest).filter(|home| home.checkout_root != project_checkout) {
                let canonical = home
                    .checkout_root
                    .join(".agents")
                    .join("skills")
                    .join(name);
                // Only an artifact OF THIS SKILL resolving to that canonical
                // makes this removal an owner there. A parent-level share
                // alone proves where a NEW link would land, not that one
                // exists — a same-named install belonging to the other
                // checkout must keep its marker (its disk-recovery
                // evidence) untouched.
                let owned = dest.canonicalize().is_ok_and(|resolved| {
                    canonicalize_allowing_missing(&canonical)
                        .unwrap_or_else(|| normalize_absolute_path(&canonical))
                        == resolved
                });
                if owned && !canonicals.contains(&canonical) {
                    canonicals.push(canonical);
                }
            }
        }
        canonicals
    };

    // A skill path whose final component is not itself a symlink can still
    // RESOLVE to a snapshotted anchored canonical through a symlinked
    // ancestor (a fully shared `.agents`): remove_expected_path would follow
    // that ancestor and recursively delete the other checkout's copy before
    // the preservation pass below could report it. Unlinking a symlink final
    // component only removes the link itself and stays allowed.
    let anchored_resolved: Vec<PathBuf> = anchored_canonicals
        .iter()
        .filter_map(|path| canonicalize_allowing_missing(path))
        .collect();
    let resolves_to_anchored = |path: &Path| -> bool {
        !anchored_resolved.is_empty()
            && !std::fs::symlink_metadata(path).is_ok_and(|meta| meta.file_type().is_symlink())
            && canonicalize_allowing_missing(path)
                .is_some_and(|resolved| anchored_resolved.contains(&resolved))
    };

    // Clear the anchored canonicals' managed markers BEFORE any unlinking.
    // A marker that survives past this removal lets the owning checkout's
    // disk recovery adopt (resurrect) a copy that may have existed solely
    // for this worktree's install — and once the child links below are
    // unlinked, the anchor evidence needed to rediscover these canonicals is
    // gone, so a post-unlink failure would be unrepairable by retry. Failing
    // here aborts with every link intact: fix the marker, run remove again.
    //
    // EXCEPT when the OWNING checkout itself still references the canonical
    // (its own harness artifact resolves there): that install survives this
    // removal, and clearing its marker would drop it from the owner's next
    // disk recovery. This worktree's own links live under this project root,
    // never the owning root, so they cannot count as survivors.
    // Artifact dirs THIS removal will unlink (by physical parent): a shared
    // dir means the owning root's spelling and our dest name the same file,
    // which must not read as a surviving owner reference.
    let removing_parent_canons: Vec<PathBuf> = harnesses
        .iter()
        .filter_map(|harness| harness.skills_dir(false).canonicalize().ok())
        .collect();
    // EVERY harness's relative dir, not only the ones being removed: the
    // owner may reference the canonical through a harness absent from this
    // removal (or from this worktree's lock entirely).
    let project_rel_skills: Vec<PathBuf> = Harness::ALL
        .iter()
        .filter_map(|harness| {
            harness
                .skills_dir(false)
                .strip_prefix(crate::config::project_root())
                .ok()
                .map(Path::to_path_buf)
        })
        .collect();
    for anchored in &anchored_canonicals {
        let (Some(name), Some(owning_root)) = (
            anchored.file_name(),
            anchored.parent().and_then(Path::parent).and_then(Path::parent),
        ) else {
            continue;
        };
        let anchored_resolved = canonicalize_allowing_missing(anchored)
            .unwrap_or_else(|| normalize_absolute_path(anchored));
        let owner_still_references = project_rel_skills.iter().any(|rel| {
            let candidate = owning_root.join(rel).join(name);
            let candidate_parent_canon = owning_root.join(rel).canonicalize().ok();
            let survives_this_removal = candidate_parent_canon
                .as_ref()
                .is_some_and(|parent| !removing_parent_canons.contains(parent));
            // A SYMLINK is affirmative owner evidence. For harnesses whose
            // project artifact IS the canonical directory (Codex/Pi), the
            // path would count as referencing itself, so DIRECT ownership
            // is evidenced by the owner's LOCK instead (checked below).
            survives_this_removal
                && std::fs::symlink_metadata(&candidate)
                    .is_ok_and(|meta| meta.file_type().is_symlink())
                && candidate
                    .canonicalize()
                    .is_ok_and(|resolved| resolved == anchored_resolved)
        }) || {
            // Direct-canonical owner evidence: the owning checkout's lock
            // names this skill — its Codex/Pi install IS the canonical dir
            // and must keep its recovery marker through our removal.
            let owner_lock = owning_root.join(".vstack-lock.json");
            std::fs::read_to_string(&owner_lock)
                .ok()
                .and_then(|raw| serde_json::from_str::<crate::config::LockFile>(&raw).ok())
                .is_some_and(|lock| {
                    lock.entries
                        .get(name.to_str().unwrap_or_default())
                        .is_some_and(|entry| {
                            // Only a symlink-mode install for a
                            // direct-canonical harness (Codex/Pi: the
                            // project artifact IS the canonical dir) makes
                            // the lock entry ownership evidence for THIS
                            // path. A copy-mode entry (or one for
                            // link-artifact harnesses only, whose evidence
                            // is the symlink checked above) never
                            // references the canonical, and preserving the
                            // marker on its word would let reconciliation
                            // later adopt a stale foreign copy.
                            entry.kind == crate::config::ItemKind::Skill
                                && entry.method == crate::config::InstallMethod::Symlink
                                && entry.harnesses.iter().any(|id| {
                                    matches!(
                                        Harness::from_id(id),
                                        Some(Harness::Codex | Harness::Pi)
                                    )
                                })
                        })
                })
        };
        if owner_still_references {
            continue;
        }
        let marker = anchored.join(".vstack-refreshed");
        if let Err(err) = std::fs::remove_file(&marker)
            && err.kind() != std::io::ErrorKind::NotFound
        {
            anyhow::bail!(
                "could not clear managed marker {} — aborting removal before any unlinking so it stays retryable: {err}",
                marker.display()
            );
        }
    }

    for harness in harnesses {
        // Agent files
        if remove_agents {
            let agent_paths = match harness {
                Harness::ClaudeCode => vec![harness.agents_dir(global).join(format!("{name}.md"))],
                Harness::Cursor => vec![harness.agents_dir(global).join(format!("{name}.mdc"))],
                Harness::OpenCode => vec![harness.agents_dir(global).join(format!("{name}.md"))],
                Harness::Codex => vec![harness.agents_dir(global).join(format!("{name}.toml"))],
                Harness::Pi => vec![harness.agents_dir(global).join(format!("{name}.md"))],
            };

            for path in agent_paths {
                match remove_expected_path(&path, ExpectedArtifact::File) {
                    Ok(true) => removed.push(path),
                    Ok(false) => {}
                    Err(err) => cleanup_errors.push(format!(
                        "agent {name} removal failed for {} {} scope at {}: {err:#}",
                        harness.name(),
                        if global { "global" } else { "project" },
                        path.display()
                    )),
                }
            }
        }

        // Skill directories
        if remove_skills {
            let skill_path = harness.skills_dir(global).join(name);
            // An anchored path is the preservation pass's to report and
            // keep. A shared-dir LINK is deliberately removable from the
            // worktree: the owner's lock entry and canonical both survive,
            // and its next refresh recreates the link — preserving it here
            // would turn worktree removal into a silent no-op.
            if !resolves_to_anchored(&skill_path) {
                match remove_expected_path(&skill_path, ExpectedArtifact::Any) {
                    Ok(true) => removed.push(skill_path),
                    Ok(false) => {}
                    Err(err) => cleanup_errors.push(format!(
                        "skill {name} removal failed for {} {} scope at {}: {err:#}",
                        harness.name(),
                        if global { "global" } else { "project" },
                        skill_path.display()
                    )),
                }
            }
        }

        if remove_hooks {
            match remove_hook_install(name, *harness, global) {
                Ok(hook_removed) => removed.extend(hook_removed),
                Err(err) => cleanup_errors.push(format!(
                    "hook {name} cleanup failed for {} {} scope: {err:#}",
                    harness.name(),
                    if global { "global" } else { "project" }
                )),
            }
        }
    }

    if remove_skills {
        let canonical_skill_paths = if global {
            vec![
                crate::config::global_state_dir().join("skills").join(name),
                crate::config::codex_home_dir().join("skills").join(name),
            ]
        } else {
            vec![
                crate::config::project_root()
                    .join(".agents")
                    .join("skills")
                    .join(name),
            ]
        };

        for path in canonical_skill_paths {
            // The project-spelled canonical resolves to a FOREIGN anchored
            // canonical when `.agents` itself is symlinked into the shared
            // checkout; deleting through that ancestor would destroy the copy
            // the preservation pass below promises to leave in place. The
            // same shield covers a final-component SYMLINK whose parent
            // physically lives in the other checkout: that entry is the
            // owner's project-skills-dir canonical wiring, not ours to
            // unlink (unlike harness links, no owner refresh recreates a
            // hand-authored canonical spelling).
            if resolves_to_anchored(&path) {
                continue;
            }
            let parent_foreign = path
                .parent()
                .and_then(|parent| parent.canonicalize().ok())
                .is_some_and(|parent| {
                    let project_checkout = std::fs::canonicalize(crate::config::project_root())
                        .unwrap_or_else(|_| normalize_absolute_path(&crate::config::project_root()));
                    !parent.starts_with(&project_checkout)
                });
            if parent_foreign && std::fs::symlink_metadata(&path).is_ok() {
                eprintln!(
                    "  Note: leaving {} in place — it lives in another checkout's .agents; remove it from that checkout to delete it (VST-195)",
                    path.display()
                );
                continue;
            }
            match remove_expected_path(&path, ExpectedArtifact::Any) {
                Ok(true) => removed.push(path),
                Ok(false) => {}
                Err(err) => cleanup_errors.push(format!(
                    "canonical skill {name} removal failed for {} scope at {}: {err:#}",
                    if global { "global" } else { "project" },
                    path.display()
                )),
            }
        }

        // A canonical copy anchored in another checkout is shared per-skill
        // across ALL of that checkout's harnesses — a Codex/Pi install there
        // IS the canonical dir itself, indistinguishable on disk from a
        // leftover. Never delete it from a foreign worktree; that checkout's
        // own remove collects it.
        for anchored in &anchored_canonicals {
            if anchored.exists() {
                // Marker already cleared before the unlink phase (a checkout
                // that still references the skill re-marks it on its next
                // refresh; lock entries survive regardless, since the stale
                // gate checks existence, not the marker). No printing here:
                // callers (CLI remove, TUI report) render anchored_left
                // themselves — a direct eprintln would duplicate the notice
                // and, from the TUI's worker thread, write into a raw-mode
                // terminal.
                anchored_left.push(anchored.clone());
            }
        }
    }

    if !cleanup_errors.is_empty() {
        anyhow::bail!(cleanup_errors.join("; "));
    }

    Ok(RemoveOutcome {
        removed,
        anchored_left,
    })
}

#[derive(Clone, Copy)]
enum ExpectedArtifact {
    File,
    Any,
}

fn remove_expected_path(path: &Path, expected: ExpectedArtifact) -> Result<bool> {
    let meta = match std::fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(err) => return Err(err).with_context(|| format!("checking {}", path.display())),
    };
    if meta.file_type().is_symlink() || meta.is_file() {
        std::fs::remove_file(path).with_context(|| format!("removing file {}", path.display()))?;
        return Ok(true);
    }
    if meta.is_dir() {
        if matches!(expected, ExpectedArtifact::File) {
            anyhow::bail!("expected file but found directory");
        }
        std::fs::remove_dir_all(path)
            .with_context(|| format!("removing directory {}", path.display()))?;
        return Ok(true);
    }
    anyhow::bail!("unsupported file type")
}

/// Record installation in lock file
pub fn record_install(
    lock: &mut LockFile,
    results: &[InstallResult],
    source: &str,
    source_repo: Option<&str>,
    method: InstallMethod,
) {
    let now = crate::config::now_iso();
    for result in results {
        let harness_id = result.harness.id().to_string();
        if let Some(existing) = lock.entries.get_mut(&result.name) {
            if !existing.harnesses.contains(&harness_id) {
                existing.harnesses.push(harness_id);
            }
            existing.source = source.into();
            existing.source_repo = source_repo.map(str::to_string);
            existing.method = method;
            existing.installed_at = now.clone();
            existing.source_hash = crate::config::compute_source_hash(existing);
        } else {
            let mut entry = LockEntry {
                name: result.name.clone(),
                kind: result.kind,
                source: source.into(),
                source_repo: source_repo.map(str::to_string),
                harnesses: vec![harness_id],
                method,
                installed_at: now.clone(),
                source_hash: String::new(),
            };
            entry.source_hash = crate::config::compute_source_hash(&entry);
            lock.add(entry);
        }
    }
}

fn remove_existing(path: &Path) -> Result<()> {
    if path.is_symlink() {
        std::fs::remove_file(path)?;
    } else if path.is_dir() {
        std::fs::remove_dir_all(path)?;
    } else if path.exists() {
        std::fs::remove_file(path)?;
    }
    Ok(())
}

fn normalize_absolute_path(path: &Path) -> PathBuf {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    };

    let mut normalized = PathBuf::new();
    for component in absolute.components() {
        match component {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized
}

/// Anchored `.agents/skills` roots for `harnesses`' project skill dirs: each
/// same-repository checkout root one of those dirs physically lands in
/// (VST-195), paired with the harnesses that land there. The project's own
/// root is not included. A copy in another checkout is part of this
/// project's view only through a harness that shares into that checkout, so
/// removal and reconciliation must scope root derivation to the harness set
/// actually in play — an unscoped derivation would let a worktree operation
/// reach a main-checkout install that exists only for other harnesses.
/// How a harness's project skill dir evidences an anchored root. Child-link
/// evidence is per-skill: one linked child proves nothing about OTHER names
/// in the foreign root.
#[derive(Clone, Debug)]
pub(crate) enum AnchorEvidence {
    /// The whole harness dir is shared; every skill name is in scope.
    SharedDir,
    /// Only these individually linked children are shared.
    Children(Vec<String>),
}

impl AnchorEvidence {
    pub(crate) fn covers(&self, name: &str) -> bool {
        match self {
            AnchorEvidence::SharedDir => true,
            AnchorEvidence::Children(names) => names.iter().any(|child| child == name),
        }
    }
}

/// Harnesses evidencing an anchored root, with how each one evidences it.
pub(crate) type AnchorSharing = Vec<(Harness, AnchorEvidence)>;

pub(crate) fn anchored_canonical_skill_roots(
    harnesses: &[Harness],
) -> Vec<(PathBuf, AnchorSharing)> {
    // Contract: OTHER checkouts' roots only. An ordinary child link
    // (`.claude/skills/foo -> ../../.agents/skills/foo`) resolves to the
    // CURRENT checkout and must not report the project's own canonical
    // root as anchored.
    let own_root = std::fs::canonicalize(crate::config::project_root())
        .unwrap_or_else(|_| normalize_absolute_path(&crate::config::project_root()));
    let mut anchored: Vec<(PathBuf, AnchorSharing)> = Vec::new();
    let mut probed: Vec<(PathBuf, Vec<(PathBuf, AnchorEvidence)>)> = Vec::new();
    for harness in harnesses {
        let dir = harness.skills_dir(false);
        let roots = match probed.iter().find(|(probed_dir, _)| *probed_dir == dir) {
            Some((_, cached)) => cached.clone(),
            None => {
                let roots = match same_repo_link_home(&dir) {
                    Some(home) => vec![(
                        home.checkout_root.join(".agents").join("skills"),
                        AnchorEvidence::SharedDir,
                    )],
                    // Partial sharing keeps the dir real and links each
                    // skill CHILD into the shared checkout; the children
                    // are then the only evidence of the anchor.
                    None => child_level_anchored_roots(&dir),
                };
                probed.push((dir, roots.clone()));
                roots
            }
        };
        for (root, evidence) in roots {
            let root_physical = canonicalize_allowing_missing(&root)
                .unwrap_or_else(|| normalize_absolute_path(&root));
            if root_physical.starts_with(&own_root) {
                continue;
            }
            match anchored
                .iter_mut()
                .find(|(anchored_root, _)| *anchored_root == root)
            {
                Some((_, sharing)) => {
                    if !sharing.iter().any(|(shared, _)| shared == harness) {
                        sharing.push((*harness, evidence));
                    }
                }
                None => anchored.push((root, vec![(*harness, evidence)])),
            }
        }
    }
    anchored
}

/// Anchored roots reachable through child-level skill links in `dir`,
/// including DANGLING children whose canonical is already gone — pruning
/// must still classify those under a managed root. Non-symlink children are
/// skipped without any git probing, so ordinary layouts pay one read_dir.
/// Each root carries the child NAMES that evidence it.
fn child_level_anchored_roots(dir: &Path) -> Vec<(PathBuf, AnchorEvidence)> {
    let mut roots: Vec<(PathBuf, Vec<String>)> = Vec::new();
    let mut probed_parents: Vec<(PathBuf, Option<PathBuf>)> = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    for entry in entries.flatten() {
        let child = entry.path();
        let Ok(meta) = std::fs::symlink_metadata(&child) else {
            continue;
        };
        if !meta.file_type().is_symlink() {
            continue;
        }
        let Some(name) = child.file_name().and_then(|n| n.to_str()).map(String::from) else {
            continue;
        };
        let lexical = normalize_absolute_path(&child);
        let Some(physical) = canonicalize_allowing_missing(&child) else {
            continue;
        };
        if physical == lexical {
            continue;
        }
        let Some(parent) = physical.parent().map(Path::to_path_buf) else {
            continue;
        };
        let root = match probed_parents.iter().find(|(probed, _)| *probed == parent) {
            Some((_, cached)) => cached.clone(),
            None => {
                let root = anchored_link_home(parent.clone())
                    .map(|home| home.checkout_root.join(".agents").join("skills"));
                probed_parents.push((parent, root.clone()));
                root
            }
        };
        let Some(root) = root else { continue };
        match roots.iter_mut().find(|(known, _)| *known == root) {
            Some((_, names)) => names.push(name),
            None => roots.push((root, vec![name])),
        }
    }
    roots
        .into_iter()
        .map(|(root, names)| (root, AnchorEvidence::Children(names)))
        .collect()
}

/// The other checkout's copy of this project's root: the repo layout is
/// identical in every checkout, so the project's repo-relative suffix (empty
/// for a toplevel project) transfers verbatim onto `checkout_toplevel`.
/// `None` when the suffix cannot be derived — callers fail closed rather
/// than guessing a root.
fn corresponding_project_root_in(checkout_toplevel: &Path) -> Option<PathBuf> {
    let own_toplevel = crate::path_safety::git_toplevel(&crate::config::project_root())?;
    let project_physical = std::fs::canonicalize(crate::config::project_root())
        .unwrap_or_else(|_| normalize_absolute_path(&crate::config::project_root()));
    let suffix = project_physical.strip_prefix(&own_toplevel).ok()?;
    Some(checkout_toplevel.join(suffix))
}

/// Is `physical_parent` a recognized skills surface of the checkout rooted
/// at `checkout_root` — its `.agents/skills` or one of its project-scope
/// harness skills dirs? Link homes and anchor evidence must come only from
/// these: any other same-repository directory reached through a symlink is
/// an alias, and treating it as a link home would delete/replace its
/// children as if they were skill artifacts.
fn is_recognized_skills_surface(checkout_root: &Path, physical_parent: &Path) -> bool {
    // Compare against the LITERAL expected paths under the physically
    // resolved checkout root — never canonicalize the candidates. Following
    // a candidate symlink would make the alias validate itself: with
    // `.claude/skills -> cli/src`, resolving `checkout/.claude/skills`
    // yields exactly the aliased physical_parent being questioned.
    let root_physical = std::fs::canonicalize(checkout_root)
        .unwrap_or_else(|_| normalize_absolute_path(checkout_root));
    let project_root = crate::config::project_root();
    let mut expected = vec![root_physical.join(".agents").join("skills")];
    for harness in Harness::ALL {
        if let Ok(rel) = harness.skills_dir(false).strip_prefix(&project_root) {
            expected.push(root_physical.join(rel));
        }
    }
    expected
        .into_iter()
        .any(|candidate| candidate == *physical_parent)
}

/// The physical home of a project-scope harness link whose parent directory
/// is symlinked into another checkout of the same repository.
struct LinkHome {
    /// Canonical directory the link is physically created in.
    physical_parent: PathBuf,
    /// Root of the same-repository checkout containing `physical_parent`.
    checkout_root: PathBuf,
}

/// Detect worktree indirection under `dest_parent`. Worktree setups symlink
/// shared harness dirs into the main checkout (vstack#886), so a link created
/// at an apparent worktree path may physically land in another checkout of
/// the project's repository. Returns `None` for the ordinary case (no symlink
/// indirection), for indirection into unrelated trees (for example a
/// `.claude` dir symlinked into a dotfiles checkout), and for a checkout
/// whose `.agents` fails the containment boundary — all of which keep
/// `relative_path`'s behavior.
fn same_repo_link_home(dest_parent: &Path) -> Option<LinkHome> {
    let lexical = normalize_absolute_path(dest_parent);
    let physical = canonicalize_allowing_missing(dest_parent)?;
    if physical == lexical {
        return None;
    }
    anchored_link_home(physical)
}

/// Child-level variant for a skill dir itself: partial-sharing layouts keep
/// the harness dir real and symlink each skill CHILD into the shared
/// checkout (worktree config.md), so parent-level probing alone would
/// mis-select a worktree-local canonical and materialize a real directory
/// over the child link.
fn skill_link_home(dest: &Path) -> Option<LinkHome> {
    if let Some(home) = dest.parent().and_then(same_repo_link_home) {
        return Some(home);
    }
    let lexical = normalize_absolute_path(dest);
    let physical = canonicalize_allowing_missing(dest)?;
    if physical == lexical {
        return None;
    }
    anchored_link_home(physical.parent()?.to_path_buf())
}

/// Validate that `physical_parent` lies in a same-repository checkout whose
/// `.agents` passes containment, and name that checkout's root.
fn anchored_link_home(physical_parent: PathBuf) -> Option<LinkHome> {
    // git needs an existing directory; the harness dir itself may not exist
    // on the physical side yet.
    let mut probe = physical_parent.as_path();
    while !probe.is_dir() {
        probe = probe.parent()?;
    }
    let project_common = crate::path_safety::git_common_dir(&crate::config::project_root())?;
    let (probe_common, mut checkout_root) = crate::path_safety::git_repo_identity(probe)?;
    if probe_common != project_common {
        return None;
    }
    // The project root may sit BELOW the git toplevel (a project marker in a
    // subdirectory). The anchor must land at the other checkout's copy of
    // THAT directory, not its toplevel — anchoring at the toplevel would
    // collide the nested project's canonicals with sibling projects' .agents.
    checkout_root = corresponding_project_root_in(&checkout_root)?;
    // Anchor evidence must come from a recognized skills surface of that
    // checkout. Git identity alone would admit an ALIAS — e.g.
    // `.claude/skills -> <main>/cli/src` — and installing through it would
    // remove_existing/replace children of an arbitrary repository directory
    // as if they were skill artifacts.
    if !is_recognized_skills_surface(&checkout_root, &physical_parent) {
        eprintln!(
            "  Warning: not anchoring through {}: not a recognized skills directory of {} (VST-195)",
            physical_parent.display(),
            checkout_root.display()
        );
        return None;
    }
    // Anchoring writes beneath the other checkout's .agents, so it gets the
    // same containment boundary the project's own .agents writes get. An
    // escaping .agents must never be written through.
    if let Err(err) = crate::path_safety::ensure_agents_dir_within_project(&checkout_root) {
        eprintln!(
            "  Warning: not anchoring skills in {}: {err} (VST-195)",
            checkout_root.display()
        );
        return None;
    }
    Some(LinkHome {
        physical_parent,
        checkout_root,
    })
}

/// Canonicalize `path`, tolerating missing trailing components: the nearest
/// resolvable ancestor is canonicalized and the missing remainder re-appended.
/// Symlinked ancestors still redirect — a shared `.claude` whose `skills`
/// child does not exist yet must resolve to the shared side, and a dangling
/// symlink is followed by hand rather than mistaken for its apparent path.
fn canonicalize_allowing_missing(path: &Path) -> Option<PathBuf> {
    let mut missing: Vec<std::ffi::OsString> = Vec::new();
    let mut current = path.to_path_buf();
    // Bounded like the kernel's symlink-resolution limit so a dangling
    // symlink cycle cannot spin forever.
    for _ in 0..40 {
        match std::fs::canonicalize(&current) {
            Ok(mut resolved) => {
                for name in missing.iter().rev() {
                    resolved.push(name);
                }
                return Some(resolved);
            }
            Err(_) => {
                if let Ok(target) = std::fs::read_link(&current) {
                    current = if target.is_absolute() {
                        target
                    } else {
                        current.parent()?.join(target)
                    };
                    continue;
                }
                missing.push(current.file_name()?.to_os_string());
                current = current.parent()?.to_path_buf();
            }
        }
    }
    // Exhausting the hop bound is a genuine resolution failure (a dangling or
    // cyclic symlink chain), not the ordinary "no indirection" case — say so,
    // since the caller's None silently skips anchoring (VST-195).
    eprintln!(
        "  Warning: could not resolve {} within {} symlink hops; treating as unanchored (VST-195)",
        path.display(),
        40
    );
    None
}

/// Compute the path to spell a symlink target from `from` to `to`:
/// relative for ordinary directories, absolute when `from` sits behind
/// symlink indirection (see body).
#[cfg(unix)]
fn relative_path(from: &Path, to: &Path) -> Result<PathBuf> {
    let from_lexical = normalize_absolute_path(from);
    let from_canonical = std::fs::canonicalize(from).unwrap_or_else(|_| from_lexical.clone());
    let to = std::fs::canonicalize(to).unwrap_or_else(|_| normalize_absolute_path(to));

    // If the apparent parent path differs from the real containing directory
    // (for example because an ancestor is a symlink), prefer an absolute
    // target over a confusing relative path that is computed from the real
    // path. Same-repository worktree indirection never reaches this branch —
    // install_skill resolves those links against their physical home first —
    // but the no-link_home case still does: unrelated-tree indirection (e.g.
    // `.claude` symlinked into a dotfiles checkout) is exactly what this
    // absolute fallback serves.
    if from_canonical != from_lexical {
        return Ok(to);
    }
    Ok(lexical_relative(&from_lexical, &to))
}

#[cfg(unix)]
fn lexical_relative(from: &Path, to: &Path) -> PathBuf {
    let from_parts: Vec<_> = from.components().collect();
    let to_parts: Vec<_> = to.components().collect();

    let common = from_parts
        .iter()
        .zip(to_parts.iter())
        .take_while(|(a, b)| a == b)
        .count();

    let mut rel = PathBuf::new();
    for _ in common..from_parts.len() {
        rel.push("..");
    }
    for part in &to_parts[common..] {
        rel.push(part);
    }

    rel
}

/// Recursively copy a directory.
///
/// Preserves symlinks instead of dereferencing them. `std::fs::copy` follows
/// symlinks and writes the resolved bytes, which made every package whose
/// tests/build produce symlink artifacts report `vstack verify -g` install
/// drift (source had a symlink, install had a real file with the resolved
/// content). Recreating the link via `std::os::unix::fs::symlink` keeps the
/// install dir byte-comparable to the source.
fn copy_dir(src: &Path, dst: &Path) -> Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in walkdir::WalkDir::new(src).min_depth(1) {
        let entry = entry?;
        let rel = entry.path().strip_prefix(src)?;
        let target = dst.join(rel);
        let file_type = entry.file_type();

        if file_type.is_symlink() {
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent)?;
            }
            // Replace any pre-existing entry at the destination so reinstall
            // is idempotent. `remove_file` works for both files and symlinks;
            // dirs need `remove_dir_all`.
            if target.is_symlink() || target.is_file() {
                std::fs::remove_file(&target).with_context(|| {
                    format!("removing existing {} for symlink replace", target.display())
                })?;
            } else if target.is_dir() {
                std::fs::remove_dir_all(&target).with_context(|| {
                    format!(
                        "removing existing dir {} for symlink replace",
                        target.display()
                    )
                })?;
            }
            let link_target = std::fs::read_link(entry.path())
                .with_context(|| format!("reading symlink target at {}", entry.path().display()))?;
            std::os::unix::fs::symlink(&link_target, &target).with_context(|| {
                format!(
                    "recreating symlink {} → {}",
                    target.display(),
                    link_target.display()
                )
            })?;
        } else if file_type.is_dir() {
            std::fs::create_dir_all(&target)?;
        } else {
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::copy(entry.path(), &target)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_install_updates_method_for_existing_entry() {
        let mut lock = LockFile::default();
        lock.add(LockEntry {
            name: "rust".into(),
            kind: ItemKind::Agent,
            source: "old-source".into(),
            source_repo: None,
            harnesses: vec![Harness::Pi.id().to_string()],
            method: InstallMethod::Symlink,
            installed_at: "2026-05-01T00:00:00Z".into(),
            source_hash: String::new(),
        });
        let results = vec![InstallResult {
            name: "rust".into(),
            kind: ItemKind::Agent,
            harness: Harness::ClaudeCode,
            path: PathBuf::new(),
            detail: String::new(),
        }];

        record_install(
            &mut lock,
            &results,
            "new-source",
            Some("vanillagreencom/vstack"),
            InstallMethod::Copy,
        );

        let entry = lock.entries.get("rust").expect("entry should exist");
        assert_eq!(entry.method, InstallMethod::Copy);
        assert_eq!(entry.source, "new-source");
        assert_eq!(entry.source_repo.as_deref(), Some("vanillagreencom/vstack"));
        assert!(entry.harnesses.contains(&Harness::Pi.id().to_string()));
        assert!(
            entry
                .harnesses
                .contains(&Harness::ClaudeCode.id().to_string())
        );
    }

    #[test]
    fn install_skill_applies_shared_skill_instructions_to_every_skill() {
        let root = std::env::temp_dir().join(format!(
            "vstack_shared_skill_instr_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let project = root.join("project");
        let source = root.join("source").join("github");
        std::fs::create_dir_all(&project).unwrap();
        std::fs::create_dir_all(&source).unwrap();
        std::fs::write(
            source.join("SKILL.md"),
            "---\nname: github\ndescription: GitHub ops\n---\n\n# GitHub\n\nBody.\n",
        )
        .unwrap();

        // The skill has NO entry of its own — only the shared key applies.
        let config: crate::project_config::ProjectConfig =
            toml::from_str("[skill-instructions]\nall = \"Shared skill rule.\"\n").unwrap();
        let instructions = config.skill_instructions_for("github");
        assert_eq!(instructions.as_deref(), Some("Shared skill rule."));

        let skill = Skill {
            name: "github".into(),
            description: "GitHub ops".into(),
            license: None,
            user_invocable: None,
            dependencies: None,
            body: String::new(),
            source_dir: source.clone(),
            resolved_deps: Vec::new(),
        };

        let result = crate::test_util::with_project_root(&project, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Copy,
                instructions.as_deref(),
            )
            .unwrap()
        });

        let installed = std::fs::read_to_string(result.path.join("SKILL.md")).unwrap();
        assert!(
            installed.contains("## Project Instructions"),
            "installed SKILL.md: {installed}"
        );
        assert!(
            installed.contains("Shared skill rule."),
            "installed SKILL.md: {installed}"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn remove_item_accepts_reserved_name_for_legacy_installs() {
        // `all` is reserved for NEW installs only; a project that installed an
        // item named `all` under a previous release must still be able to
        // remove it.
        let root = std::env::temp_dir().join(format!(
            "vstack_remove_reserved_name_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let project = root.join("project");
        let legacy_agent = project.join(".claude").join("agents").join("all.md");
        std::fs::create_dir_all(legacy_agent.parent().unwrap()).unwrap();
        std::fs::write(&legacy_agent, "# all\n").unwrap();

        let removed = crate::test_util::with_project_root(&project, || {
            remove_item("all", Some(ItemKind::Agent), &[Harness::ClaudeCode], false)
                .unwrap()
                .removed
        });
        assert!(removed.contains(&legacy_agent), "removed: {removed:?}");
        assert!(!legacy_agent.exists());

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn install_rejects_reserved_name() {
        let agent = Agent {
            name: "all".into(),
            description: "reserved".into(),
            model: "sonnet".into(),
            role: Default::default(),
            color: None,
            effort: None,
            body: String::new(),
            source_path: PathBuf::new(),
        };
        let err = install_agent(
            &agent,
            Harness::ClaudeCode,
            false,
            &[],
            &[],
            &crate::agent::AgentExtras::default(),
        )
        .err()
        .expect("install_agent must reject the reserved name");
        assert!(err.to_string().contains("reserved"), "got: {err}");

        let skill = Skill {
            name: "all".into(),
            description: "reserved".into(),
            license: None,
            user_invocable: None,
            dependencies: None,
            body: String::new(),
            source_dir: PathBuf::new(),
            resolved_deps: Vec::new(),
        };
        let err = install_skill(
            &skill,
            Harness::ClaudeCode,
            false,
            InstallMethod::Copy,
            None,
        )
        .err()
        .expect("install_skill must reject the reserved name");
        assert!(err.to_string().contains("reserved"), "got: {err}");
    }

    #[test]
    fn remove_item_reports_agent_delete_failure() {
        let root = std::env::temp_dir().join(format!(
            "vstack_remove_agent_failure_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let project = root.join("project");
        let bad_agent_path = project.join(".claude").join("agents").join("rust.md");
        std::fs::create_dir_all(&bad_agent_path).unwrap();

        let err = crate::test_util::with_project_root(&project, || {
            remove_item("rust", Some(ItemKind::Agent), &[Harness::ClaudeCode], false).unwrap_err()
        });
        let message = err.to_string();
        assert!(message.contains("agent rust removal failed"));
        assert!(message.contains("Claude Code project scope"));
        assert!(message.contains("rust.md"));
        assert!(bad_agent_path.is_dir());

        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn relative_path_uses_relative_target_for_normal_directories() {
        let root = std::env::temp_dir().join(format!(
            "vstack_relative_path_normal_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let from = root.join("a").join("b");
        let to = root.join("config").join("skills").join("rust-runtime");
        std::fs::create_dir_all(&from).unwrap();
        std::fs::create_dir_all(&to).unwrap();

        let rel = relative_path(&from, &to).unwrap();
        assert_eq!(rel, PathBuf::from("../../config/skills/rust-runtime"));

        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn relative_path_uses_absolute_target_when_parent_is_symlinked() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_relative_path_symlink_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let real_parent = root.join("real").join("skills");
        let apparent_parent = root.join("apparent");
        let target = root.join("config").join("skills").join("rust-runtime");

        std::fs::create_dir_all(&real_parent).unwrap();
        std::fs::create_dir_all(target.parent().unwrap()).unwrap();
        std::fs::create_dir_all(&target).unwrap();
        symlink(&real_parent, &apparent_parent).unwrap();

        let rel = relative_path(&apparent_parent, &target).unwrap();
        assert!(
            rel.is_absolute(),
            "expected absolute symlink target, got {rel:?}"
        );
        assert_eq!(rel, std::fs::canonicalize(&target).unwrap());

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Run a git command in `dir`, reporting only whether it succeeded. Tests
    /// that need a real repository skip themselves when git is unavailable
    /// rather than failing a host that simply has no git.
    fn git_ok(dir: &Path, args: &[&str]) -> bool {
        std::process::Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .output()
            .map(|out| out.status.success())
            .unwrap_or(false)
    }

    fn init_repo_with_commit(dir: &Path) -> bool {
        git_ok(dir, &["init", "-q", "-b", "main"])
            && git_ok(dir, &["config", "user.email", "test@example.com"])
            && git_ok(dir, &["config", "user.name", "Test"])
            && git_ok(dir, &["config", "commit.gpgsign", "false"])
            && std::fs::write(dir.join(".vstack-test-base"), "base\n").is_ok()
            && git_ok(dir, &["add", "-A"])
            && git_ok(dir, &["commit", "-q", "-m", "base"])
    }

    fn write_skill_source(root: &Path, name: &str) -> Skill {
        let source = root.join("source").join(name);
        std::fs::create_dir_all(&source).unwrap();
        std::fs::write(
            source.join("SKILL.md"),
            format!("---\nname: {name}\ndescription: Test skill\n---\n\n# {name}\n\nBody.\n"),
        )
        .unwrap();
        Skill {
            name: name.into(),
            description: "Test skill".into(),
            license: None,
            user_invocable: None,
            dependencies: None,
            body: String::new(),
            source_dir: source,
            resolved_deps: Vec::new(),
        }
    }

    /// A harness dir symlinked into the main checkout must be detected as
    /// same-repo indirection, resolving to main's physical dir and checkout
    /// root; a real (non-symlinked) dir has no separate physical home.
    #[cfg(unix)]
    #[test]
    fn same_repo_link_home_resolves_worktree_parent_to_main_checkout() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_link_home_worktree_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents").join("skills")).unwrap();

        let shared = crate::test_util::with_project_root(&wt, || {
            same_repo_link_home(&wt.join(".claude").join("skills"))
        })
        .expect("shared harness dir must resolve to a same-repo link home");
        assert_eq!(shared.physical_parent, main_skills.canonicalize().unwrap());
        assert_eq!(shared.checkout_root, main.canonicalize().unwrap());

        let local = crate::test_util::with_project_root(&wt, || {
            same_repo_link_home(&wt.join(".agents").join("skills"))
        });
        assert!(local.is_none(), "real dir must not get a link home");

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Anchoring in another checkout must apply the same `.agents`
    /// containment boundary the project's own writes get: when that
    /// checkout's `.agents` symlinks outside the repository, no write may
    /// follow it — install falls back to the unanchored path.
    #[cfg(unix)]
    #[test]
    fn install_skill_never_writes_through_an_escaping_agents_in_the_link_checkout() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_escaping_agents_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        let outside = root.join("outside");
        std::fs::create_dir_all(&main).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();
        // Main's .agents escapes the repository entirely.
        symlink(&outside, main.join(".agents")).unwrap();

        let skill = write_skill_source(&root, "github");
        let result = crate::test_util::with_project_root(&wt, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Symlink,
                None,
            )
        });
        // Fail CLOSED: the softer fallback (absolute link into the
        // worktree, warning on stderr) left a link in the other checkout
        // that dangles the moment this disposable worktree is removed.
        let err = match result {
            Ok(_) => panic!("expected refusal for an escaping link-checkout .agents"),
            Err(err) => err,
        };
        assert!(
            err.to_string().contains("refusing to install"),
            "expected the fail-closed refusal, got: {err}"
        );
        assert_eq!(
            std::fs::read_dir(&outside).unwrap().count(),
            0,
            "no write may land outside the repository"
        );
        assert!(
            std::fs::symlink_metadata(main_skills.join("github")).is_err(),
            "no link may be written into the other checkout"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Sharing the whole `.claude` dir leaves `main/.claude/skills` absent
    /// until first install; the redirect must still be detected by resolving
    /// through the nearest existing ancestor, and the install must create and
    /// anchor everything on the main side.
    #[cfg(unix)]
    #[test]
    fn install_skill_resolves_link_home_through_missing_harness_dir() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_missing_leaf_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        // Whole .claude shared; skills subdir does not exist yet anywhere.
        std::fs::create_dir_all(main.join(".claude")).unwrap();
        symlink(main.join(".claude"), wt.join(".claude")).unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();

        let skill = write_skill_source(&root, "github");
        crate::test_util::with_project_root(&wt, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Symlink,
                None,
            )
            .unwrap()
        });

        assert!(
            main.join(".agents/skills/github/SKILL.md").is_file(),
            "canonical copy must anchor in the main checkout"
        );
        let link = main.join(".claude").join("skills").join("github");
        assert_eq!(
            std::fs::read_link(&link).unwrap(),
            PathBuf::from("../../.agents/skills/github")
        );
        assert!(link.canonicalize().unwrap().join("SKILL.md").is_file());

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Reconciliation must agree with install's anchoring: a skill installed
    /// only for a shared-into-main harness has its sole canonical copy in the
    /// MAIN checkout, and a reconcile pass run from the worktree must not
    /// treat it as missing and drop the lock entry.
    #[cfg(unix)]
    #[test]
    fn reconcile_keeps_lock_entry_for_skill_anchored_in_main_checkout() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_reconcile_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();

        let skill = write_skill_source(&root, "github");
        crate::test_util::with_project_root(&wt, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Symlink,
                None,
            )
            .unwrap()
        });
        assert!(main.join(".agents/skills/github/.vstack-refreshed").is_file());
        assert!(
            !wt.join(".agents/skills/github").exists(),
            "split layout: no worktree-local canonical copy"
        );

        let mut lock = LockFile::default();
        lock.add(LockEntry {
            name: "github".into(),
            kind: ItemKind::Skill,
            source: "source".into(),
            source_repo: None,
            harnesses: vec![Harness::ClaudeCode.id().to_string()],
            method: InstallMethod::Symlink,
            installed_at: "2026-08-10T00:00:00Z".into(),
            source_hash: String::new(),
        });
        crate::test_util::with_project_root(&wt, || {
            crate::config::reconcile_lock_with_disk(&mut lock, false, "source")
        });

        assert!(
            lock.entries.contains_key("github"),
            "lock entry must survive reconciliation from the worktree"
        );
        assert!(
            main.join(".agents/skills/github/SKILL.md").is_file(),
            "main checkout's canonical copy must survive reconciliation"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Partial-sharing layout: the only evidence of the anchor is the child
    /// link removal is about to delete, so the anchor must be resolved
    /// BEFORE any unlinking — a post-unlink probe sees a purely local parent
    /// and the anchored-side bookkeeping (the surviving-copy note) misfires.
    #[cfg(unix)]
    #[test]
    fn remove_item_snapshots_child_link_anchor_before_unlinking() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_remove_snapshot_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_copy = main.join(".agents").join("skills").join("github");
        std::fs::create_dir_all(&main_copy).unwrap();
        std::fs::write(main_copy.join("SKILL.md"), "# github\n").unwrap();
        std::fs::write(main_copy.join(".vstack-refreshed"), "0").unwrap();
        std::fs::create_dir_all(wt.join(".agents").join("skills")).unwrap();
        let child = wt.join(".agents").join("skills").join("github");
        symlink(&main_copy, &child).unwrap();

        let outcome = crate::test_util::with_project_root(&wt, || {
            remove_item("github", Some(ItemKind::Skill), &[Harness::Codex], false).unwrap()
        });

        assert!(
            std::fs::symlink_metadata(&child).is_err(),
            "the child link must be removed"
        );
        assert!(
            main_copy.join("SKILL.md").is_file(),
            "main's shared copy must survive"
        );
        let expected = main
            .canonicalize()
            .unwrap()
            .join(".agents")
            .join("skills")
            .join("github");
        assert!(
            outcome.anchored_left.contains(&expected),
            "the anchor must be resolved before unlinking destroys the evidence, got {:?}",
            outcome.anchored_left
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Child-link evidence is per-skill: one legitimate child link must not
    /// turn the whole foreign root into evidence for OTHER skills — a stale
    /// lock entry whose skill has no artifact in this worktree must not be
    /// kept alive by an unrelated skill's child link.
    #[cfg(unix)]
    #[test]
    fn reconcile_drops_stale_entry_not_evidenced_by_child_links() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_unrelated_child_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        // Legitimate child link for skill X; skill Y exists only in main.
        for name in ["x-linked", "y-mainonly"] {
            let copy = main.join(".agents").join("skills").join(name);
            std::fs::create_dir_all(&copy).unwrap();
            std::fs::write(copy.join("SKILL.md"), format!("# {name}\n")).unwrap();
            std::fs::write(copy.join(".vstack-refreshed"), "0").unwrap();
        }
        std::fs::create_dir_all(wt.join(".agents").join("skills")).unwrap();
        symlink(
            main.join(".agents").join("skills").join("x-linked"),
            wt.join(".agents").join("skills").join("x-linked"),
        )
        .unwrap();

        let mut lock = LockFile::default();
        lock.add(LockEntry {
            name: "y-mainonly".into(),
            kind: ItemKind::Skill,
            source: "source".into(),
            source_repo: None,
            harnesses: vec![Harness::Codex.id().to_string()],
            method: InstallMethod::Symlink,
            installed_at: "2026-08-10T00:00:00Z".into(),
            source_hash: String::new(),
        });
        crate::test_util::with_project_root(&wt, || {
            crate::config::reconcile_lock_with_disk(&mut lock, false, "source")
        });

        assert!(
            !lock.entries.contains_key("y-mainonly"),
            "an unrelated child link must not keep another skill's stale entry alive"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Marker operations only on canonicals the operation owned: a removal
    /// whose harness never had a link for THIS skill must not clear the
    /// managed marker of a same-named install belonging to the other
    /// checkout — that marker is its disk-recovery evidence.
    #[cfg(unix)]
    #[test]
    fn remove_item_leaves_unowned_same_named_marker_intact() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_unowned_marker_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();

        // Main-only install named "dupe"; Claude never had a link for it.
        let dupe = main.join(".agents").join("skills").join("dupe");
        std::fs::create_dir_all(&dupe).unwrap();
        std::fs::write(dupe.join("SKILL.md"), "# dupe\n").unwrap();
        std::fs::write(dupe.join(".vstack-refreshed"), "0").unwrap();

        crate::test_util::with_project_root(&wt, || {
            remove_item("dupe", Some(ItemKind::Skill), &[Harness::ClaudeCode], false).unwrap()
        });

        assert!(dupe.join("SKILL.md").is_file());
        assert!(
            dupe.join(".vstack-refreshed").is_file(),
            "an unowned install's managed marker must survive a foreign removal"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Write-shy foreign canonicals: an install whose link lands in another
    /// checkout must LINK to that checkout's existing canonical as-is —
    /// rewriting its content would clobber the install it backs there;
    /// refreshing it is the owning checkout's job.
    #[cfg(unix)]
    #[test]
    fn install_skill_links_to_existing_foreign_canonical_without_rewriting() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_write_shy_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();

        // Main's canonical pre-exists with its own content and marker.
        let canonical = main.join(".agents").join("skills").join("github");
        std::fs::create_dir_all(&canonical).unwrap();
        std::fs::write(canonical.join("SKILL.md"), "owned by main\n").unwrap();
        std::fs::write(canonical.join(".vstack-refreshed"), "main\n").unwrap();

        let skill = write_skill_source(&root, "github");
        crate::test_util::with_project_root(&wt, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Symlink,
                None,
            )
            .unwrap()
        });

        assert_eq!(
            std::fs::read_to_string(canonical.join("SKILL.md")).unwrap(),
            "owned by main\n",
            "the foreign canonical's content must not be rewritten"
        );
        assert_eq!(
            std::fs::read_to_string(canonical.join(".vstack-refreshed")).unwrap(),
            "main\n",
            "the foreign canonical's marker must not be rewritten"
        );
        let link = main_skills.join("github");
        assert!(
            link.canonicalize().unwrap().join("SKILL.md").is_file(),
            "the link must resolve to the existing canonical"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// A canonical copy that existed SOLELY for this worktree's install must
    /// not resurrect after removal: the owning checkout's reconciliation
    /// adopts any marked dir in its own root (deliberately — see
    /// reconcile_does_not_attribute_orphaned_skill_to_source_hint), so the
    /// foreign remover must clear the managed marker on the copy it leaves
    /// behind. A checkout that still references the skill re-marks it on its
    /// next refresh.
    #[cfg(unix)]
    #[test]
    fn foreign_removal_does_not_let_owning_checkout_resurrect_the_skill() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_resurrect_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();

        // Skill exists only for the worktree's Claude install, anchored in
        // main; then the worktree removes it.
        let skill = write_skill_source(&root, "github");
        crate::test_util::with_project_root(&wt, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Symlink,
                None,
            )
            .unwrap()
        });
        crate::test_util::with_project_root(&wt, || {
            remove_item(
                "github",
                Some(ItemKind::Skill),
                &[Harness::ClaudeCode],
                false,
            )
            .unwrap()
        });
        assert!(
            main.join(".agents/skills/github/SKILL.md").is_file(),
            "conservative rule leaves the copy in place"
        );

        // The owning checkout's reconciliation must not adopt it back.
        let mut lock = LockFile::default();
        crate::test_util::with_project_root(&main, || {
            crate::config::reconcile_lock_with_disk(&mut lock, false, "source")
        });
        assert!(
            !lock.entries.contains_key("github"),
            "owning checkout must not resurrect the removed skill"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Anchored-root discovery must see child-level anchors: in the
    /// partial-sharing layout a dangling child link (its external canonical
    /// already deleted) is the ONLY evidence of the anchor, and without it
    /// the pruning pass cannot classify the link under a managed root.
    #[cfg(unix)]
    #[test]
    fn reconcile_prunes_dangling_child_link_after_canonical_removal() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_dangling_child_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        // Partial sharing: real .agents/skills, child linked into main —
        // whose canonical has since been deleted, dangling the child.
        std::fs::create_dir_all(main.join(".agents").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents").join("skills")).unwrap();
        let child = wt.join(".agents").join("skills").join("github");
        symlink(main.join(".agents").join("skills").join("github"), &child).unwrap();

        let mut lock = LockFile::default();
        crate::test_util::with_project_root(&wt, || {
            crate::config::reconcile_lock_with_disk(&mut lock, false, "source")
        });

        assert!(
            std::fs::symlink_metadata(&child).is_err(),
            "dangling child link must be pruned once its anchor is classified"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Containment must extend to `.agents/skills`: a real in-repo `.agents`
    /// whose `skills` subdir symlinks OUTSIDE the repository must fail the
    /// anchored-side validation, or install deletes/overwrites the external
    /// directory through it.
    #[cfg(unix)]
    #[test]
    fn install_skill_never_writes_through_an_escaping_agents_skills_subdir() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_escaping_skills_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        let outside = root.join("outside");
        std::fs::create_dir_all(&main).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();
        // Main's .agents is a REAL in-repo dir; only its skills subdir
        // escapes the repository.
        std::fs::create_dir_all(main.join(".agents")).unwrap();
        symlink(&outside, main.join(".agents").join("skills")).unwrap();

        let skill = write_skill_source(&root, "github");
        let result = crate::test_util::with_project_root(&wt, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Symlink,
                None,
            )
        });
        // Fail CLOSED, matching the link-checkout variant above.
        let err = match result {
            Ok(_) => panic!("expected refusal for an escaping .agents/skills in the link checkout"),
            Err(err) => err,
        };
        assert!(
            err.to_string().contains("refusing to install"),
            "expected the fail-closed refusal, got: {err}"
        );
        assert_eq!(
            std::fs::read_dir(&outside).unwrap().count(),
            0,
            "no write may follow the escaping .agents/skills"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// A reference must RESOLVE to the canonical dir it gates: a same-named
    /// COPY-mode harness dir is that harness's own install, not a reference
    /// to the canonical — recovering through it would re-type the skill as
    /// symlink-mode and let the next refresh replace the copy.
    #[cfg(unix)]
    #[test]
    fn reconcile_does_not_count_copy_mode_artifact_as_canonical_reference() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_copy_mode_gate_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();

        // Canonical copy backing main's own Codex install.
        let canonical = main.join(".agents").join("skills").join("github");
        std::fs::create_dir_all(&canonical).unwrap();
        std::fs::write(canonical.join("SKILL.md"), "# github\n").unwrap();
        std::fs::write(canonical.join(".vstack-refreshed"), "0").unwrap();
        // Same-named Claude COPY-mode install: a real dir, not a symlink.
        let copy_mode = main_skills.join("github");
        std::fs::create_dir_all(&copy_mode).unwrap();
        std::fs::write(copy_mode.join("SKILL.md"), "# github copy\n").unwrap();
        std::fs::write(copy_mode.join(".vstack-refreshed"), "0").unwrap();

        let mut lock = LockFile::default();
        crate::test_util::with_project_root(&wt, || {
            crate::config::reconcile_lock_with_disk(&mut lock, false, "source")
        });

        assert!(
            !lock.entries.contains_key("github"),
            "a copy-mode artifact must not count as a reference to the canonical"
        );
        assert!(
            std::fs::symlink_metadata(&copy_mode)
                .unwrap()
                .file_type()
                .is_dir(),
            "the copy-mode install must be left untouched"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// The stale-entry gate must normalize lock-entry harness ids the way
    /// the rest of the CLI does (`Harness::from_id`, which accepts aliases
    /// like "claude"): an alias spelling must still match the sharing
    /// harness of an anchored root, or the entry is wrongly dropped while
    /// its anchored copy exists.
    #[cfg(unix)]
    #[test]
    fn reconcile_keeps_alias_harness_entry_for_anchored_copy() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_alias_gate_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();

        // Anchored copy exists; no harness link anywhere, so the recovery
        // scan skips it and the entry reaches the stale gate.
        let copy = main.join(".agents").join("skills").join("github");
        std::fs::create_dir_all(&copy).unwrap();
        std::fs::write(copy.join("SKILL.md"), "# github\n").unwrap();
        std::fs::write(copy.join(".vstack-refreshed"), "0").unwrap();

        let mut lock = LockFile::default();
        lock.add(LockEntry {
            name: "github".into(),
            kind: ItemKind::Skill,
            source: "source".into(),
            source_repo: None,
            harnesses: vec!["claude".into()], // alias for claude-code
            method: InstallMethod::Symlink,
            installed_at: "2026-08-10T00:00:00Z".into(),
            source_hash: String::new(),
        });
        crate::test_util::with_project_root(&wt, || {
            crate::config::reconcile_lock_with_disk(&mut lock, false, "source")
        });

        assert!(
            lock.entries.contains_key("github"),
            "alias-spelled harness must still match the anchored root's sharing harness"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// The physically-canonical guard must compare physical locations, not
    /// spellings: with `.agents` itself a symlink (`main/.agents ->
    /// main/agents-store`), the constructed canonical spelling and the
    /// resolved dest differ as strings while naming the same directory. Raw
    /// equality misses, and install would delete the canonical copy and
    /// self-link it.
    #[cfg(unix)]
    #[test]
    fn install_skill_does_not_self_link_through_a_symlinked_agents_spelling() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_agents_spelling_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        // The worktree spells its .agents through the shared symlink into
        // main's real .agents: the constructed canonical spelling
        // (wt/.agents/skills/github) and the resolved dest differ as
        // strings while naming the same directory. (An .agents aliased to
        // an arbitrary in-repo store is NOT a supported layout — the
        // canonical root identity gates in path_safety refuse it.)
        std::fs::create_dir_all(main.join(".agents").join("skills")).unwrap();
        symlink(main.join(".agents"), wt.join(".agents")).unwrap();

        let skill = write_skill_source(&root, "github");
        crate::test_util::with_project_root(&wt, || {
            install_skill(&skill, Harness::Codex, false, InstallMethod::Symlink, None).unwrap()
        });

        let canonical = main.join(".agents").join("skills").join("github");
        let meta = std::fs::symlink_metadata(&canonical).unwrap();
        assert!(
            meta.file_type().is_dir(),
            "canonical copy must stay a real directory, not a symlink"
        );
        assert!(canonical.join("SKILL.md").is_file());

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Anchored roots must be scoped to the harnesses actually in play: with
    /// only `.claude/skills` shared, a main-checkout skill that exists solely
    /// for Codex (whose project dir is worktree-local) is main's own install.
    /// Removing that name from the worktree scoped to Codex must not reach
    /// into main, and a reconcile pass from the worktree must not claim it.
    #[cfg(unix)]
    #[test]
    fn worktree_operations_leave_other_harness_installs_in_main_untouched() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_harness_scope_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();

        // Main's own Codex-only install: canonical copy with marker, no
        // harness link visible through any shared dir, nothing in the wt.
        let solo = main.join(".agents").join("skills").join("solo");
        std::fs::create_dir_all(&solo).unwrap();
        std::fs::write(solo.join("SKILL.md"), "# solo\n").unwrap();
        std::fs::write(solo.join(".vstack-refreshed"), "0").unwrap();

        crate::test_util::with_project_root(&wt, || {
            remove_item("solo", Some(ItemKind::Skill), &[Harness::Codex], false).unwrap()
        });
        assert!(
            solo.join("SKILL.md").is_file(),
            "removal scoped to a non-sharing harness must not delete main's install"
        );

        let mut lock = LockFile::default();
        crate::test_util::with_project_root(&wt, || {
            crate::config::reconcile_lock_with_disk(&mut lock, false, "source")
        });
        assert!(
            !lock.entries.contains_key("solo"),
            "reconciliation from the worktree must not claim main's Codex-only install"
        );
        assert!(solo.join("SKILL.md").is_file());

        let _ = std::fs::remove_dir_all(&root);
    }

    /// The canonical copy is shared per-skill across all harnesses within
    /// its checkout: main's Codex install of X IS main/.agents/skills/X.
    /// A foreign worktree removing X for a shared harness must remove the
    /// link but leave the anchored canonical for that checkout's own
    /// operations to collect — deleting it would strand main's install.
    #[cfg(unix)]
    #[test]
    fn remove_item_preserves_anchored_canonical_shared_by_other_checkout_installs() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_shared_canonical_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();

        // wt installs for Claude: link in main, canonical anchored in main.
        // That same canonical dir IS main's own Codex install of the skill.
        let skill = write_skill_source(&root, "github");
        crate::test_util::with_project_root(&wt, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Symlink,
                None,
            )
            .unwrap()
        });
        let canonical = main.join(".agents").join("skills").join("github");
        assert!(canonical.join("SKILL.md").is_file());

        crate::test_util::with_project_root(&wt, || {
            remove_item(
                "github",
                Some(ItemKind::Skill),
                &[Harness::ClaudeCode],
                false,
            )
            .unwrap()
        });
        assert!(
            std::fs::symlink_metadata(main_skills.join("github")).is_err(),
            "the Claude link must be removed"
        );
        assert!(
            canonical.join("SKILL.md").is_file(),
            "the anchored canonical backs the checkout's own installs and must survive"
        );

        // The owning checkout's own removal collects it.
        crate::test_util::with_project_root(&main, || {
            remove_item("github", Some(ItemKind::Skill), &[Harness::Codex], false).unwrap()
        });
        assert!(
            std::fs::symlink_metadata(&canonical).is_err(),
            "the owning checkout's removal must delete its canonical copy"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Fully shared layout: the worktree's `.agents` is itself a symlink into
    /// the main checkout, so the project-spelled canonical (and Codex/Pi's
    /// skill dir, which is the same path) RESOLVES to the anchored canonical
    /// through the symlinked ancestor. Deletion must not follow it —
    /// `remove_dir_all` through that spelling destroys the main checkout's
    /// copy before the preservation pass can report it.
    #[cfg(unix)]
    #[test]
    fn remove_item_does_not_delete_foreign_canonical_through_shared_agents() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_shared_agents_remove_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(main.join(".agents").join("skills")).unwrap();
        symlink(main.join(".agents"), wt.join(".agents")).unwrap();

        let skill = write_skill_source(&root, "github");
        crate::test_util::with_project_root(&wt, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Symlink,
                None,
            )
            .unwrap()
        });
        let canonical = main.join(".agents").join("skills").join("github");
        assert!(canonical.join("SKILL.md").is_file());

        let outcome = crate::test_util::with_project_root(&wt, || {
            remove_item(
                "github",
                Some(ItemKind::Skill),
                &[Harness::ClaudeCode, Harness::Codex],
                false,
            )
            .unwrap()
        });

        assert!(
            std::fs::symlink_metadata(main_skills.join("github")).is_err(),
            "the Claude link must be removed"
        );
        assert!(
            canonical.join("SKILL.md").is_file(),
            "deletion must not follow the shared .agents into the main checkout's canonical"
        );
        let expected = main
            .canonicalize()
            .unwrap()
            .join(".agents")
            .join("skills")
            .join("github");
        assert!(
            outcome.anchored_left.contains(&expected),
            "the surviving canonical must be reported, got {:?}",
            outcome.anchored_left
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// An ordinary project-scope remove must DELETE its own canonical: the
    /// child link's LinkHome names this project as checkout, and admitting
    /// that into the anchored-preservation set would skip the canonical,
    /// clear its marker, and still report success.
    #[cfg(unix)]
    #[test]
    fn remove_item_deletes_own_canonical_for_ordinary_install() {
        let root = std::env::temp_dir().join(format!(
            "vstack_own_remove_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let project = root.join("project");
        std::fs::create_dir_all(&project).unwrap();
        if !init_repo_with_commit(&project) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }

        let skill = write_skill_source(&root, "github");
        crate::test_util::with_project_root(&project, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Symlink,
                None,
            )
            .unwrap()
        });
        let canonical = project.join(".agents").join("skills").join("github");
        assert!(canonical.join("SKILL.md").is_file());

        let outcome = crate::test_util::with_project_root(&project, || {
            remove_item(
                "github",
                Some(ItemKind::Skill),
                &[Harness::ClaudeCode],
                false,
            )
            .unwrap()
        });
        assert!(
            !canonical.exists(),
            "an ordinary remove must delete the project's own canonical"
        );
        assert!(
            outcome.anchored_left.is_empty(),
            "nothing is anchored elsewhere in an ordinary remove, got {:?}",
            outcome.anchored_left
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// A canonical still referenced by the OWNING checkout's own artifact
    /// keeps its marker through a foreign worktree's removal — clearing it
    /// would drop the surviving install from the owner's next disk recovery.
    #[cfg(unix)]
    #[test]
    fn remove_item_keeps_marker_when_owner_still_references_canonical() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_marker_survivor_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        // Main owns the canonical AND references it via its own child link;
        // the worktree shares per-child (partial sharing), so its dest is a
        // distinct artifact.
        std::fs::create_dir_all(main.join(".agents").join("skills")).unwrap();
        let canonical = main.join(".agents").join("skills").join("github");
        std::fs::create_dir_all(&canonical).unwrap();
        std::fs::write(canonical.join("SKILL.md"), "# github\n").unwrap();
        std::fs::write(canonical.join(".vstack-refreshed"), "0").unwrap();
        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        symlink(
            PathBuf::from("../../.agents/skills/github"),
            main_skills.join("github"),
        )
        .unwrap();
        let wt_skills = wt.join(".claude").join("skills");
        std::fs::create_dir_all(&wt_skills).unwrap();
        symlink(&canonical, wt_skills.join("github")).unwrap();

        let outcome = crate::test_util::with_project_root(&wt, || {
            remove_item(
                "github",
                Some(ItemKind::Skill),
                &[Harness::ClaudeCode],
                false,
            )
            .unwrap()
        });

        assert!(
            std::fs::symlink_metadata(wt_skills.join("github")).is_err(),
            "the worktree's own link is removed"
        );
        assert!(
            std::fs::symlink_metadata(main_skills.join("github")).is_ok(),
            "the owner's link is untouched"
        );
        assert!(
            canonical.join(".vstack-refreshed").is_file(),
            "the marker survives — the owner still references this canonical"
        );
        assert!(
            outcome.anchored_left.iter().any(|p| p.ends_with("github")),
            "the surviving canonical is reported, got {:?}",
            outcome.anchored_left
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// An UNMARKED same-named directory in another checkout is not provably
    /// a vstack install — install must refuse rather than recursively
    /// replace what may be manually maintained data.
    #[cfg(unix)]
    #[test]
    fn install_skill_refuses_unmarked_foreign_name_collision() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_unmarked_foreign_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();

        // Manually maintained data in main that merely shares the name:
        // no SKILL.md, no marker.
        let canonical = main.join(".agents").join("skills").join("github");
        std::fs::create_dir_all(&canonical).unwrap();
        std::fs::write(canonical.join("precious.txt"), "handmade\n").unwrap();

        let skill = write_skill_source(&root, "github");
        let result = crate::test_util::with_project_root(&wt, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Symlink,
                None,
            )
        });
        let err = match result {
            Ok(_) => panic!("expected the unmarked-collision refusal, got success"),
            Err(err) => err,
        };
        assert!(
            err.to_string().contains("refusing to replace"),
            "expected the unmarked-collision refusal, got: {err}"
        );
        assert_eq!(
            std::fs::read_to_string(canonical.join("precious.txt")).unwrap(),
            "handmade\n",
            "the foreign directory must be untouched"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// A worktree that INSTALLED through a fully shared harness dir owns
    /// that anchored canonical: a second refresh must copy updated source,
    /// not ride the write-shy fast path forever (SharedDir ownership
    /// evidence — the dest's parent resolves into the shared checkout).
    #[cfg(unix)]
    #[test]
    fn install_skill_refreshes_own_anchored_canonical_through_shared_dir() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_shared_refresh_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();

        let skill = write_skill_source(&root, "github");
        crate::test_util::with_project_root(&wt, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Symlink,
                None,
            )
            .unwrap()
        });
        let canonical = main.join(".agents").join("skills").join("github");
        assert!(canonical.join("SKILL.md").is_file());

        // Source changes; a NEW process refreshes (fresh PID → marker miss).
        std::fs::write(
            skill.source_dir.join("SKILL.md"),
            "---\nname: github\ndescription: Updated\n---\n\n# github v2\n",
        )
        .unwrap();
        let marker = canonical.join(".vstack-refreshed");
        std::fs::write(&marker, "0").unwrap();
        crate::test_util::with_project_root(&wt, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Symlink,
                None,
            )
            .unwrap()
        });
        let refreshed = std::fs::read_to_string(canonical.join("SKILL.md")).unwrap();
        assert!(
            refreshed.contains("github v2"),
            "the worktree's own anchored canonical must receive source updates, got: {refreshed}"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// A "foreign canonical" whose final component is a SYMLINK is malformed:
    /// `exists()`/`is_file()` follow it, so the write-shy fast path would
    /// link through it to wherever it points (potentially outside the
    /// repository), bypassing containment. It must be repaired into a real
    /// directory instead, without touching the symlink's target.
    #[cfg(unix)]
    #[test]
    fn install_skill_repairs_symlinked_foreign_canonical() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_symlinked_canonical_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();

        // Main's "canonical" is a symlink smuggling an external directory
        // that even carries a plausible SKILL.md.
        let external = root.join("external-target");
        std::fs::create_dir_all(&external).unwrap();
        std::fs::write(external.join("SKILL.md"), "# smuggled\n").unwrap();
        std::fs::create_dir_all(main.join(".agents").join("skills")).unwrap();
        let canonical = main.join(".agents").join("skills").join("github");
        symlink(&external, &canonical).unwrap();

        let skill = write_skill_source(&root, "github");
        crate::test_util::with_project_root(&wt, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Symlink,
                None,
            )
            .unwrap()
        });

        let meta = std::fs::symlink_metadata(&canonical).unwrap();
        assert!(
            meta.file_type().is_dir(),
            "the symlinked canonical must be replaced with a real directory"
        );
        assert!(canonical.join("SKILL.md").is_file());
        assert_eq!(
            std::fs::read_to_string(external.join("SKILL.md")).unwrap(),
            "# smuggled\n",
            "repair must unlink the symlink itself, never write through to its target"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// A managed-marker clear that fails must abort the removal BEFORE any
    /// unlinking: past that point the anchor evidence is gone, the caller
    /// drops the lock entry, and the still-marked canonical would be adopted
    /// back (resurrected) by the owning checkout's recovery.
    #[cfg(unix)]
    #[test]
    fn remove_item_aborts_before_unlink_when_marker_clear_fails() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_marker_clear_abort_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();

        let skill = write_skill_source(&root, "github");
        crate::test_util::with_project_root(&wt, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Symlink,
                None,
            )
            .unwrap()
        });
        let canonical = main.join(".agents").join("skills").join("github");
        assert!(canonical.join("SKILL.md").is_file());

        // Make the marker un-removable via remove_file: a non-empty
        // directory in its place fails with EISDIR.
        let marker = canonical.join(".vstack-refreshed");
        std::fs::remove_file(&marker).unwrap();
        std::fs::create_dir_all(marker.join("block")).unwrap();

        let err = crate::test_util::with_project_root(&wt, || {
            remove_item(
                "github",
                Some(ItemKind::Skill),
                &[Harness::ClaudeCode],
                false,
            )
            .unwrap_err()
        });
        assert!(
            err.to_string().contains("managed marker"),
            "expected the marker-clear abort, got: {err}"
        );
        assert!(
            std::fs::symlink_metadata(main_skills.join("github")).is_ok(),
            "the child link must survive an aborted removal (retryable)"
        );
        assert!(canonical.join("SKILL.md").is_file());

        let _ = std::fs::remove_dir_all(&root);
    }

    /// An ordinary existing child link (`.claude/skills/<name>` →
    /// `../../.agents/skills/<name>`) resolves to a LinkHome whose checkout
    /// IS this project. That must not be mistaken for a foreign canonical:
    /// write-shyness there would skip every refresh after the first install
    /// while still reporting success.
    #[cfg(unix)]
    #[test]
    fn install_skill_refreshes_own_canonical_behind_existing_child_link() {
        let root = std::env::temp_dir().join(format!(
            "vstack_own_canonical_refresh_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let project = root.join("project");
        std::fs::create_dir_all(&project).unwrap();
        if !init_repo_with_commit(&project) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }

        let skill = write_skill_source(&root, "github");
        crate::test_util::with_project_root(&project, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Symlink,
                None,
            )
            .unwrap()
        });
        let canonical = project.join(".agents").join("skills").join("github");
        assert!(canonical.join("SKILL.md").is_file());

        // A later run: the source changed and the same-process marker no
        // longer matches.
        std::fs::write(
            skill.source_dir.join("SKILL.md"),
            "---\nname: github\ndescription: Test skill\n---\n\n# github\n\nupdated body\n",
        )
        .unwrap();
        std::fs::write(canonical.join(".vstack-refreshed"), "0").unwrap();

        crate::test_util::with_project_root(&project, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Symlink,
                None,
            )
            .unwrap()
        });

        let refreshed = std::fs::read_to_string(canonical.join("SKILL.md")).unwrap();
        assert!(
            refreshed.contains("updated body"),
            "the project's own canonical must refresh from source, got: {refreshed}"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Write-shyness protects the owning checkout's VALID installs. A foreign
    /// canonical without SKILL.md was never one — linking to it AS-IS ships a
    /// broken skill — so install must repair it from source instead.
    #[cfg(unix)]
    #[test]
    fn install_skill_repairs_foreign_canonical_missing_skill_md() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_repair_canonical_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();

        // Main's canonical pre-exists MARKED but lost its payload — a
        // vstack install to repair (an unmarked stranger refuses instead;
        // see install_skill_refuses_unmarked_foreign_name_collision).
        let canonical = main.join(".agents").join("skills").join("github");
        std::fs::create_dir_all(&canonical).unwrap();
        std::fs::write(canonical.join("notes.txt"), "junk\n").unwrap();
        std::fs::write(canonical.join(".vstack-refreshed"), "0").unwrap();

        let skill = write_skill_source(&root, "github");
        crate::test_util::with_project_root(&wt, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Symlink,
                None,
            )
            .unwrap()
        });

        assert!(
            canonical.join("SKILL.md").is_file(),
            "an invalid foreign canonical must be repaired from source"
        );
        assert!(
            !canonical.join("notes.txt").exists(),
            "repair replaces the invalid directory wholesale"
        );
        let link = main_skills.join("github");
        assert!(link.canonicalize().unwrap().join("SKILL.md").is_file());

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Anchored recovery must scope the entry to the harnesses whose
    /// artifacts RESOLVE to the canonical: a same-named copy-mode directory
    /// for another harness is an independent install, and claiming it under
    /// the recovered Symlink entry would let the next refresh replace the
    /// copy with a link.
    #[cfg(unix)]
    #[test]
    fn reconcile_scopes_anchored_recovery_to_resolving_harnesses() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_mixed_copy_recovery_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents").join("skills")).unwrap();

        // Anchored canonical in main, referenced by the shared Claude link.
        let canonical = main.join(".agents").join("skills").join("github");
        std::fs::create_dir_all(&canonical).unwrap();
        std::fs::write(canonical.join("SKILL.md"), "# github\n").unwrap();
        std::fs::write(canonical.join(".vstack-refreshed"), "0").unwrap();
        symlink(
            PathBuf::from("../../.agents/skills/github"),
            main_skills.join("github"),
        )
        .unwrap();

        // Independent same-named copy-mode install for Cursor in the worktree.
        let cursor_copy = wt.join(".cursor").join("rules").join("github");
        std::fs::create_dir_all(&cursor_copy).unwrap();
        std::fs::write(cursor_copy.join("SKILL.md"), "cursor copy\n").unwrap();
        std::fs::write(cursor_copy.join(".vstack-refreshed"), "0").unwrap();

        let mut lock = LockFile::default();
        crate::test_util::with_project_root(&wt, || {
            crate::config::reconcile_lock_with_disk(&mut lock, false, "source")
        });

        let entry = lock
            .entries
            .get("github")
            .expect("anchored skill must be recovered");
        assert!(
            entry
                .harnesses
                .contains(&Harness::ClaudeCode.id().to_string()),
            "the resolving harness must be recorded, got {:?}",
            entry.harnesses
        );
        assert!(
            !entry.harnesses.contains(&Harness::Cursor.id().to_string()),
            "the independent copy install must not be claimed by the anchored entry, got {:?}",
            entry.harnesses
        );
        assert_eq!(
            std::fs::read_to_string(cursor_copy.join("SKILL.md")).unwrap(),
            "cursor copy\n"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Partial sharing links each skill CHILD into main while `.agents/skills`
    /// stays real (worktree config.md). Install must resolve the child-level
    /// symlink when selecting the canonical home and keep the child link —
    /// materializing a real directory over the link would fork the skill
    /// from the shared copy. The existing foreign canonical is linked to
    /// AS-IS (write-shy): its content belongs to the owning checkout's
    /// refresh, so the pre-existing content stays.
    #[cfg(unix)]
    #[test]
    fn install_skill_resolves_child_level_symlink_to_shared_canonical() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_child_link_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_copy = main.join(".agents").join("skills").join("github");
        std::fs::create_dir_all(&main_copy).unwrap();
        std::fs::write(main_copy.join("SKILL.md"), "stale\n").unwrap();
        std::fs::create_dir_all(wt.join(".agents").join("skills")).unwrap();
        symlink(&main_copy, wt.join(".agents").join("skills").join("github")).unwrap();

        let skill = write_skill_source(&root, "github");
        crate::test_util::with_project_root(&wt, || {
            install_skill(&skill, Harness::Codex, false, InstallMethod::Symlink, None).unwrap()
        });

        let child = wt.join(".agents").join("skills").join("github");
        assert!(
            std::fs::symlink_metadata(&child)
                .unwrap()
                .file_type()
                .is_symlink(),
            "the child link into main must be preserved, not materialized"
        );
        // The link must actually RESOLVE to main's copy — a spelling
        // computed at the foreign parent (`github`) would be a
        // self-referential loop in the local dir and a symlink-only
        // assertion would miss it.
        assert_eq!(
            std::fs::canonicalize(&child).unwrap(),
            std::fs::canonicalize(&main_copy).unwrap(),
            "the recreated child link must canonicalize to the shared canonical in main"
        );
        assert_eq!(
            std::fs::read_to_string(main_copy.join("SKILL.md")).unwrap(),
            "stale\n",
            "main's copy is the owning checkout's to refresh — not rewritten from here"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Broken-link pruning must also sweep the anchored checkout's harness
    /// dirs: a dangling link in a main-side dir the worktree does NOT share
    /// (main's own `.cursor/rules` here) is invisible to a prune that walks
    /// only the invoking checkout's dirs.
    #[cfg(unix)]
    #[test]
    fn reconcile_prunes_dangling_links_in_anchored_checkout_harness_dirs() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_anchored_prune_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();

        // Dangling link in a main dir the worktree does not share; its
        // target points at main's managed canonical root.
        let cursor_rules = main.join(".cursor").join("rules");
        std::fs::create_dir_all(&cursor_rules).unwrap();
        symlink(
            Path::new("../../.agents/skills/gone"),
            cursor_rules.join("gone"),
        )
        .unwrap();

        let mut lock = LockFile::default();
        crate::test_util::with_project_root(&wt, || {
            crate::config::reconcile_lock_with_disk(&mut lock, false, "source")
        });

        assert!(
            std::fs::symlink_metadata(cursor_rules.join("gone")).is_err(),
            "dangling link in the anchored checkout's unshared harness dir must be pruned"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Same-name collision across harnesses: scoping by harness set alone is
    /// not enough when the REQUESTED harness shares into main but never
    /// installed this skill — main's same-named copy belongs to another
    /// harness's install. An anchored root's copy is deletable only while
    /// the requesting harness's link proves this entry uses that root for
    /// this skill.
    #[cfg(unix)]
    #[test]
    fn remove_item_leaves_same_named_install_of_other_harness_in_main() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_name_collision_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();

        // Main-only Cursor install named "dupe": canonical copy + marker;
        // Claude never installed it, so no link exists in the shared dir.
        let dupe = main.join(".agents").join("skills").join("dupe");
        std::fs::create_dir_all(&dupe).unwrap();
        std::fs::write(dupe.join("SKILL.md"), "# dupe\n").unwrap();
        std::fs::write(dupe.join(".vstack-refreshed"), "0").unwrap();

        crate::test_util::with_project_root(&wt, || {
            remove_item("dupe", Some(ItemKind::Skill), &[Harness::ClaudeCode], false).unwrap()
        });
        assert!(
            dupe.join("SKILL.md").is_file(),
            "a sharing harness that never installed this skill must not delete main's same-named copy"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// A cyclic dangling symlink chain must exhaust the resolution bound and
    /// report failure rather than spinning or silently mis-resolving.
    #[cfg(unix)]
    #[test]
    fn canonicalize_allowing_missing_fails_closed_on_cyclic_symlinks() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_cyclic_symlinks_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        std::fs::create_dir_all(&root).unwrap();
        symlink(root.join("b"), root.join("a")).unwrap();
        symlink(root.join("a"), root.join("b")).unwrap();

        assert!(canonicalize_allowing_missing(&root.join("a").join("child")).is_none());

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Fully shared `.agents`: for Codex/Pi the harness dest IS the canonical
    /// copy, just spelled through the worktree's `.agents` symlink. Install
    /// must recognize the physical identity and keep the real directory — a
    /// naive dest != canonical comparison would replace the copy with a
    /// self-referential symlink.
    #[cfg(unix)]
    #[test]
    fn install_skill_does_not_self_link_a_physically_canonical_dest() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_self_link_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        std::fs::create_dir_all(main.join(".agents").join("skills")).unwrap();
        symlink(main.join(".agents"), wt.join(".agents")).unwrap();

        let skill = write_skill_source(&root, "github");
        crate::test_util::with_project_root(&wt, || {
            install_skill(&skill, Harness::Codex, false, InstallMethod::Symlink, None).unwrap()
        });

        let canonical = main.join(".agents").join("skills").join("github");
        let meta = std::fs::symlink_metadata(&canonical).unwrap();
        assert!(
            meta.file_type().is_dir(),
            "canonical copy must stay a real directory, not a symlink"
        );
        assert!(canonical.join("SKILL.md").is_file());

        let _ = std::fs::remove_dir_all(&root);
    }

    /// VST-195, split layout (worktree config.md "Symlink entries that shadow
    /// tracked content"): `.agents` holds tracked content, so it stays a REAL
    /// directory in the worktree while `.claude/skills` is shared into the
    /// main checkout. The harness link physically lands in main, so both the
    /// link spelling and the canonical copy backing it must anchor in main —
    /// a copy left in the worktree dies with the worktree.
    #[cfg(unix)]
    #[test]
    fn install_skill_from_worktree_keeps_main_checkout_links_repo_local() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_skill_link_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();

        let skill = write_skill_source(&root, "github");
        crate::test_util::with_project_root(&wt, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Symlink,
                None,
            )
            .unwrap()
        });

        let link = main_skills.join("github");
        assert!(link.is_symlink(), "expected symlink at {link:?}");
        let target = std::fs::read_link(&link).unwrap();
        assert!(
            !target.starts_with(&wt),
            "main-checkout link must not point into the worktree: {target:?}"
        );
        assert_eq!(
            target,
            PathBuf::from("../../.agents/skills/github"),
            "main-checkout link must use the repo-relative spelling"
        );
        assert!(
            main.join(".agents/skills/github/SKILL.md").is_file(),
            "canonical copy must land in the checkout where the link landed"
        );
        let resolved = link.canonicalize().unwrap();
        assert!(
            resolved.starts_with(main.canonicalize().unwrap()),
            "link must resolve inside the main checkout, got {resolved:?}"
        );

        // Everything must keep resolving after the worktree is gone.
        std::fs::remove_dir_all(&wt).unwrap();
        assert!(
            link.canonicalize().unwrap().join("SKILL.md").is_file(),
            "main-checkout link must survive worktree removal"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    /// The fully shared layout: both `.claude/skills` and `.agents` are
    /// symlinked into the main checkout. The generated link must resolve to a
    /// real directory inside the main checkout, independent of the worktree.
    #[cfg(unix)]
    #[test]
    fn install_skill_from_worktree_resolves_inside_main_checkout() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_worktree_skill_resolve_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let main = root.join("main");
        let wt = root.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        if !init_repo_with_commit(&main) {
            let _ = std::fs::remove_dir_all(&root);
            return; // git unavailable on this host
        }
        assert!(git_ok(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]));

        let main_skills = main.join(".claude").join("skills");
        std::fs::create_dir_all(&main_skills).unwrap();
        std::fs::create_dir_all(wt.join(".claude")).unwrap();
        symlink(&main_skills, wt.join(".claude").join("skills")).unwrap();
        std::fs::create_dir_all(main.join(".agents")).unwrap();
        symlink(main.join(".agents"), wt.join(".agents")).unwrap();

        let skill = write_skill_source(&root, "github");
        crate::test_util::with_project_root(&wt, || {
            install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Symlink,
                None,
            )
            .unwrap()
        });

        let link = main_skills.join("github");
        assert!(link.is_symlink(), "expected symlink at {link:?}");
        let resolved = link.canonicalize().unwrap();
        assert!(
            resolved.starts_with(main.canonicalize().unwrap()),
            "link must resolve inside the main checkout, got {resolved:?}"
        );
        assert!(resolved.join("SKILL.md").is_file());

        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn copy_dir_preserves_symlinks_instead_of_dereferencing() {
        // Reproduces the pi-claude-bridge install-drift bug: source ships a
        // symlink, install must too — otherwise verify reports drift on
        // every package whose tests/build emit symlink artifacts.
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_copy_dir_symlink_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let src = root.join("src");
        let dst = root.join("dst");
        std::fs::create_dir_all(src.join("logs")).unwrap();
        let real_log = src.join("logs").join("2026-05-10-provider-1.log");
        std::fs::write(&real_log, b"line one\nline two\n").unwrap();
        symlink(&real_log, src.join("logs").join("latest")).unwrap();

        copy_dir(&src, &dst).unwrap();

        let dst_latest = dst.join("logs").join("latest");
        let meta = std::fs::symlink_metadata(&dst_latest).unwrap();
        assert!(
            meta.file_type().is_symlink(),
            "copy_dir must preserve symlinks; got file_type={:?}",
            meta.file_type()
        );
        assert_eq!(
            std::fs::read_link(&dst_latest).unwrap(),
            real_log,
            "symlink target must round-trip"
        );
        // Reading through the symlink still resolves to the real file.
        assert_eq!(std::fs::read(&dst_latest).unwrap(), b"line one\nline two\n");

        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn copy_dir_replaces_existing_symlink_on_reinstall() {
        // Reinstall path: dst already has a symlink, src now points
        // somewhere else — dst must end up matching src's new target.
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "vstack_copy_dir_resymlink_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let src = root.join("src");
        let dst = root.join("dst");
        std::fs::create_dir_all(&src).unwrap();
        std::fs::create_dir_all(&dst).unwrap();
        std::fs::write(src.join("a.log"), b"A").unwrap();
        std::fs::write(src.join("b.log"), b"B").unwrap();
        symlink(src.join("b.log"), src.join("latest")).unwrap();

        // Pre-existing dst symlink pointing at A; copy_dir should replace
        // it with the new symlink pointing at B.
        std::fs::write(dst.join("a.log"), b"A").unwrap();
        std::fs::write(dst.join("b.log"), b"B").unwrap();
        symlink(dst.join("a.log"), dst.join("latest")).unwrap();

        copy_dir(&src, &dst).unwrap();

        let resolved = std::fs::read_link(dst.join("latest")).unwrap();
        assert_eq!(
            resolved,
            src.join("b.log"),
            "reinstall must overwrite stale symlink"
        );

        let _ = std::fs::remove_dir_all(&root);
    }
}
