use std::path::PathBuf;

use crate::error::Result;
use crate::hash::{hash_files, installation_hash};
use crate::lock::entry_key;
use crate::manifest::Method;
use crate::model::{HarnessId, ItemKind, Scope};
use crate::render::agent::merged_instructions;
use crate::render::skill::render_skill;

use super::desired::{Artifact, Desired, DesiredState, ItemCtx, native_dir, skill_canonical};

/// One physical skill surface and the harnesses that read it. Codex and Pi
/// both consume `.agents/skills` in a project, so they form one group and
/// carry exactly one variant; every other pairing today reads its own
/// directory. Variants render to the group's combined constraints, and a
/// variant whose bytes match the base tree deduplicates onto it.
struct SurfaceGroup {
    native: PathBuf,
    /// The name every member of this group lists the skill under — the
    /// directory's own name, which SKILL.md has to agree with.
    installed: String,
    members: Vec<HarnessId>,
}

/// One rendered variant: the tree's files and their content hash. A group
/// whose cap cannot be honored produces a refused placeholder and installs
/// nothing.
/// A rendered tree as apply materializes it: relative path, bytes.
type Files = Vec<(PathBuf, Vec<u8>)>;

struct Variant {
    files: Files,
    hash: String,
    refused: bool,
    /// How much of this tree its publisher wrote, where a record needs
    /// measuring against it.
    authored: Option<crate::quality::Authored>,
}

/// The tools that read a skill directory another tool owns, and what each
/// one reaches into. One file on disk is then a definition several tools
/// see; it is still one installation — counting it twice would offer a
/// removal that takes another tool's copy away — and the note is how the
/// duplicate reaches the user (matrix §R6).
fn cross_read_note(ctx: &ItemCtx, state: &mut DesiredState) {
    if !matches!(ctx.scope, Scope::Project { .. }) {
        return;
    }
    let readers: Vec<String> = [
        (HarnessId::Gemini, "`.agents/skills`"),
        (HarnessId::Copilot, "`.agents/skills` and `.claude/skills`"),
    ]
    .into_iter()
    .filter(|(harness, _)| {
        let adapter = crate::harness::adapter(*harness);
        adapter
            .detect(ctx.env, &adapter.default_global_root(ctx.env))
            .is_some()
    })
    .map(|(harness, dirs)| format!("{} reads {dirs}", harness.display_name()))
    .collect();
    if readers.is_empty() {
        return;
    }
    // The reach is a fact about the directories, not about any one skill,
    // so it is said once however many skills a scope installs.
    let note = format!(
        "skills: {}, as well as their own directories, so the skills installed here are already visible to them — one definition, counted once",
        readers.join(", and ")
    );
    if !state.notes.contains(&note) {
        state.notes.push(note);
    }
}

fn surface_groups(ctx: &ItemCtx) -> Vec<SurfaceGroup> {
    let mut groups: Vec<SurfaceGroup> = Vec::new();
    for harness in &ctx.harnesses {
        let Some(dir) = native_dir(ctx.env, ctx.scope, *harness, ItemKind::Skill) else {
            continue;
        };
        let installed = crate::harness::rendered_name(*harness, ctx.name);
        let native = dir.join(&installed);
        match groups.iter_mut().find(|group| group.native == native) {
            Some(group) => group.members.push(*harness),
            None => groups.push(SurfaceGroup {
                native,
                installed,
                members: vec![*harness],
            }),
        }
    }
    groups
}

pub(super) fn desired_skill(ctx: &ItemCtx, state: &mut DesiredState) -> Result<()> {
    let enabled = ctx.decl.enabled;
    let method = ctx.decl.method.unwrap_or(ctx.manifest.install.method);
    let groups = surface_groups(ctx);
    if groups.is_empty() {
        return Ok(());
    }
    // A skill's `[env]` defaults ride with an installation: a skill no
    // harness here installs seeds nothing, so nothing reaches the settings
    // file without passing the safety gate the installation passes.
    if enabled && matches!(ctx.scope, Scope::Project { .. }) {
        seed_settings_env(ctx, state)?;
    }
    // Gemini and Copilot read the skill directories other tools own, so one
    // tree can be a definition they see too — said out loud, never counted
    // twice.
    cross_read_note(ctx, state);
    if ctx.harnesses.contains(&HarnessId::Copilot) {
        super::copilot::switched_off_elsewhere(ctx, ItemKind::Skill, state);
    }
    let mut variants: Vec<Variant> = Vec::new();
    for group in &groups {
        variants.push(render_variant(ctx, state, group, enabled)?);
    }

    // The base tree is the scope's shared location; the group that natively
    // reads it owns it, the first group otherwise. A variant with the base's
    // bytes links to it; a divergent variant lives at its own surface
    // (project) or in the per-tool store (global).
    let base = skill_canonical(ctx.env, ctx.scope, ctx.name);
    let owner = groups
        .iter()
        .position(|group| group.native == base)
        .unwrap_or(0);
    for (index, group) in groups.iter().enumerate() {
        let variant = &variants[index];
        if variant.refused {
            continue;
        }
        let deduped =
            index == owner || (!variants[owner].refused && variant.hash == variants[owner].hash);
        let (canonical, link) = if method == Method::Copy {
            (group.native.clone(), None)
        } else if deduped {
            match group.native == base {
                true => (base.clone(), None),
                false => (base.clone(), Some(group.native.clone())),
            }
        } else {
            match ctx.scope {
                Scope::Project { .. } => (group.native.clone(), None),
                Scope::Global => (
                    ctx.env
                        .rendered_skill_variants_dir(group.members[0].name())
                        .join(&group.installed),
                    Some(group.native.clone()),
                ),
            }
        };
        for harness in &group.members {
            state.items.push(Desired {
                key: entry_key(ItemKind::Skill, ctx.name, *harness),
                kind: ItemKind::Skill,
                name: ctx.name.to_owned(),
                harness: *harness,
                enabled,
                method,
                source_name: ctx.decl.source.clone(),
                provenance: ctx.provenance.to_owned(),
                source_commit: ctx.source_commit.map(str::to_owned),
                recorded_fork: ctx.recorded_fork(ItemKind::Skill),
                hash: installation_hash(
                    ctx.sealed,
                    ctx.item_path,
                    ctx.manifest,
                    ItemKind::Skill,
                    ctx.name,
                    *harness,
                )?,
                upstream_skills: None,
                emitted: None,
                reasons: ctx.reasons_for(*harness),
                author_review: ctx.author_review.clone(),
                authored: variant.authored.clone(),
                artifact: Artifact::Tree {
                    canonical: canonical.clone(),
                    files: variant.files.clone(),
                    link: link.clone(),
                },
            });
        }
    }
    Ok(())
}

/// The `[env]` defaults this skill ships for the project's settings file.
/// Catalog content is foreign: a skill still shipping the old template name
/// keeps seeding, the new name winning when both ship. Both at once is said
/// out loud — the ignored file may be the one a reviewer read, and only the
/// catalog author can settle which is meant.
fn seed_settings_env(ctx: &ItemCtx, state: &mut DesiredState) -> Result<()> {
    let current = ctx
        .sealed
        .read_if_exists(&ctx.item_path.join(crate::settings_seed::SETTINGS_TEMPLATE))?;
    let legacy = ctx.sealed.read_if_exists(
        &ctx.item_path
            .join(crate::settings_seed::LEGACY_SETTINGS_TEMPLATE),
    )?;
    if current.is_some() && legacy.is_some() {
        state.warnings.push(super::ItemWarning {
            kind: ItemKind::Skill,
            name: ctx.name.to_owned(),
            harness: None,
            message: format!(
                "ships both `{}` and `{}` — settings defaults seed from `{}` only, and the other file is ignored",
                crate::settings_seed::SETTINGS_TEMPLATE,
                crate::settings_seed::LEGACY_SETTINGS_TEMPLATE,
                crate::settings_seed::SETTINGS_TEMPLATE,
            ),
            remediation: Some(format!(
                "keep one template in the skill — fold anything still wanted from `{}` into `{}` and delete it",
                crate::settings_seed::LEGACY_SETTINGS_TEMPLATE,
                crate::settings_seed::SETTINGS_TEMPLATE,
            )),
        });
    }
    if let Some(text) = current.or(legacy) {
        for entry in crate::settings_seed::extract_env_entries(&text) {
            state.settings_env.push(crate::settings_seed::SeededEnv {
                entry,
                owner: ctx.name.to_owned(),
            });
        }
    }
    Ok(())
}

/// Render one group's variant under its combined constraints: the tightest
/// byte cap any member enforces, applied after instruction injection.
fn render_variant(
    ctx: &ItemCtx,
    state: &mut DesiredState,
    group: &SurfaceGroup,
    enabled: bool,
) -> Result<Variant> {
    let instructions = merged_instructions(&ctx.manifest.skill_instructions, ctx.name);
    let mut files = render_skill(ctx.sealed, ctx.item_path, ctx.manifest, ctx.name)?;
    // A skill from a plugin-registry catalog installs under its plugin, and the
    // catalog's own SKILL.md knows nothing of that: the copy carries the
    // name the tool will list it under, the catalog keeps the name it wrote.
    if group.installed != ctx.name {
        crate::render::skill::set_skill_name(&mut files, &group.installed);
    }
    // The tightest cap in the group and the member that enforces it, taken
    // together: they are one fact, and reading them from separate passes
    // invites a fallback for a state that cannot happen.
    let capped = tightest_cap(group);
    if let Some((cap, capped_by)) = capped {
        let outcome = crate::render::split::enforce_body_cap(files, cap);
        if let Some(reason) = outcome.refusal {
            for harness in &group.members {
                state.refused.push(super::desired::Refused {
                    kind: ItemKind::Skill,
                    name: ctx.name.to_owned(),
                    harness: *harness,
                    reason: reason.clone(),
                });
            }
            return Ok(Variant {
                files: Vec::new(),
                hash: String::new(),
                refused: true,
                authored: None,
            });
        }
        for warning in outcome.warnings {
            state.warnings.push(super::ItemWarning {
                kind: ItemKind::Skill,
                name: ctx.name.to_owned(),
                harness: Some(capped_by),
                message: warning.message,
                remediation: warning.remediation,
            });
        }
        files = outcome.files;
    }
    // The group's members share one physical tree, so a rendering one of
    // their loaders rejects is refused for all of them — installing it for
    // the others would put the rejected file exactly where the first one
    // reads. Advisory findings are said once, whichever member raised them.
    let mut advisories: Vec<(HarnessId, crate::render::validate::Finding)> = Vec::new();
    for harness in &group.members {
        let findings = crate::render::validate::validate_skill_tree(
            *harness,
            ctx.name,
            &group.installed,
            &files,
        );
        if let Some(reason) = super::desired::refusal_reason(&findings) {
            for member in &group.members {
                state.refused.push(super::desired::Refused {
                    kind: ItemKind::Skill,
                    name: ctx.name.to_owned(),
                    harness: *member,
                    reason: reason.clone(),
                });
            }
            return Ok(Variant {
                files: Vec::new(),
                hash: String::new(),
                refused: true,
                authored: None,
            });
        }
        for finding in findings
            .into_iter()
            .filter(|finding| !finding.is_breakage())
        {
            if !advisories
                .iter()
                .any(|(_, said)| said.message == finding.message)
            {
                advisories.push((*harness, finding));
            }
        }
    }
    for (harness, finding) in advisories {
        state.warnings.push(super::ItemWarning {
            kind: ItemKind::Skill,
            name: ctx.name.to_owned(),
            harness: Some(harness),
            message: finding.message,
            remediation: Some(finding.remediation),
        });
    }
    if !enabled {
        for (rel, _) in &mut files {
            if rel == std::path::Path::new("SKILL.md") {
                *rel = PathBuf::from("SKILL.md.disabled");
            }
        }
    }
    let hash = hash_files(&files);
    let authored = match ctx.author_review.is_some() {
        true => authored_tree(&files, instructions.is_some()),
        false => None,
    };
    Ok(Variant {
        files,
        hash,
        refused: false,
        authored,
    })
}

/// How much of this rendered tree its publisher wrote: everything outside
/// the project's instructions block, a boundary the renderer put there
/// rather than anything read back out of the text.
///
/// Saying it as a boundary is what carries an occurrence through the split.
/// The block stays in the head while the publisher's own sections move to
/// `references/`, so their line lands in another file and one severity
/// lighter than a rendering of their bytes alone puts it — nothing to match
/// it to there, while a boundary has nothing to match. It is then settled
/// at the weight it is scored at, which is the only weight that matters.
///
/// `None` when the project supplied instructions and the rendering carries
/// no block for them: nothing here can then say which lines are whose, and
/// a record that cannot be bounded settles nothing.
fn authored_tree(files: &Files, injected: bool) -> Option<crate::quality::Authored> {
    let block = files.iter().find_map(|(rel, bytes)| {
        let text = std::str::from_utf8(bytes).ok()?;
        let (start, end) = crate::render::skill::instructions_block_range(text)?;
        Some(crate::quality::Injection {
            file: rel.clone(),
            lines: (line_at(text, start), line_at(text, end.saturating_sub(1))),
        })
    });
    match (injected, &block) {
        (true, None) => None,
        _ => Some(crate::quality::Authored::Around(block)),
    }
}

/// The line an offset falls on, counted from one, as a location names it.
fn line_at(text: &str, offset: usize) -> usize {
    text[..offset].lines().count().max(1)
}

/// The tightest body cap any member of this group enforces, and the member
/// that enforces it — one fact, read once, so the two renderings below
/// cannot be shaped differently.
fn tightest_cap(group: &SurfaceGroup) -> Option<(usize, HarnessId)> {
    group
        .members
        .iter()
        .filter_map(|h| {
            crate::harness::format_caps(*h)
                .skill_body_max_bytes
                .map(|c| (c, *h))
        })
        .min_by_key(|(cap, _)| *cap)
}
