use std::path::PathBuf;

use crate::error::Result;
use crate::hash::{hash_files, installation_hash};
use crate::lock::{EmittedArtifact, entry_key};
use crate::manifest::Method;
use crate::model::{HarnessId, ItemKind, Scope};
use crate::render::skill::render_skill;

use super::desired::{
    Artifact, Desired, DesiredState, ItemCtx, effective_method, native_dir, skill_canonical,
    skill_dir,
};

/// One physical skill surface and the harnesses that read it. Every tool but
/// Claude Code consumes `.agents/skills` in a project, so they form one group
/// and carry exactly one variant; a copy delivery splits them back into the
/// directories they each read alone. Variants render to the group's combined
/// constraints, and a variant whose bytes match the base tree deduplicates
/// onto it.
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
use crate::render::skill::Files;

struct Variant {
    files: Files,
    hash: String,
    refused: bool,
}

/// The tools that will read this skill without being installed to. Every
/// harness but Claude Code reads a project's `.agents/skills` tree, so a
/// skill written there is loaded by tools the person never named — one
/// definition, counted once, and said out loud so a reader is not surprised
/// by a tool that has it (matrix §R6).
fn cross_read_note(ctx: &ItemCtx, method: Method, state: &mut DesiredState) {
    if !matches!(ctx.scope, Scope::Project { .. }) || method == Method::Copy {
        return;
    }
    let shared = skill_canonical(ctx.env, ctx.scope, ctx.name);
    let readers: Vec<String> = HarnessId::ALL
        .into_iter()
        .filter(|harness| !ctx.harnesses.contains(harness))
        .filter(|harness| {
            native_dir(ctx.env, ctx.scope, *harness, ItemKind::Skill)
                .is_some_and(|dir| shared.starts_with(dir))
        })
        .filter(|harness| {
            let adapter = crate::harness::adapter(*harness);
            adapter
                .detect(ctx.env, &adapter.default_global_root(ctx.env))
                .is_some()
        })
        .map(|harness| harness.display_name().to_owned())
        .collect();
    if readers.is_empty() {
        return;
    }
    // The reach is a fact about the directory, not about any one skill, so
    // it is said once however many skills a scope installs.
    let note = format!(
        "skills: {} read `.agents/skills` too, so what is installed here is already visible to them — one definition, counted once",
        readers.join(", ")
    );
    if !state.notes.contains(&note) {
        state.notes.push(note);
    }
}

fn surface_groups(ctx: &ItemCtx, method: Method) -> Vec<SurfaceGroup> {
    let mut groups: Vec<SurfaceGroup> = Vec::new();
    for harness in &ctx.harnesses {
        // A copy is a tree only this tool reads, so it goes in this tool's
        // own directory where it has one — several tools copying into the
        // shared tree would be one tree with several owners, which is the
        // shape the shared read already covers.
        let Some(dir) = skill_dir(ctx.env, ctx.scope, *harness, method) else {
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
    let method = effective_method(ctx.decl, ctx.manifest);
    let groups = surface_groups(ctx, method);
    if groups.is_empty() {
        super::settings_scan::seeds_nothing(
            ctx.scope,
            ctx.name,
            "no tool here holds a skill, so nothing it declares is seeded",
            &mut state.settings_templates,
        );
        return Ok(());
    }
    // A skill's `[env]` defaults ride with an installation: a skill no
    // harness here installs seeds nothing, so nothing reaches the settings
    // file that no installation here asked for.
    if matches!(ctx.scope, Scope::Project { .. }) {
        match enabled {
            true => seed_settings_env(ctx, state)?,
            false => super::settings_scan::seeds_nothing(
                ctx.scope,
                ctx.name,
                "this skill is switched off here, so nothing it declares is seeded",
                &mut state.settings_templates,
            ),
        }
    }
    cross_read_note(ctx, method, state);
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
        let artifact = Artifact::Tree {
            canonical,
            files: variant.files.clone(),
            link,
        };
        // Where the tree and the link landed goes on the record. A tool's
        // directory moves between kendex versions, and a pass that derived
        // the place again would name one this install never wrote — the
        // link it did write is then findable only through the record.
        let emitted = Some(EmittedArtifact {
            kind: ItemKind::Skill,
            name: group.installed.clone(),
            paths: artifact.paths(),
        });
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
                emitted: emitted.clone(),
                reasons: ctx.reasons_for(*harness),
                artifact: artifact.clone(),
            });
        }
    }
    Ok(())
}

/// The `[env]` defaults this skill ships for the project's settings file,
/// and the template's own text for the settings view to read strictly.
fn seed_settings_env(ctx: &ItemCtx, state: &mut DesiredState) -> Result<()> {
    let current = ctx
        .sealed
        .read_if_exists(&ctx.item_path.join(crate::settings_seed::SETTINGS_TEMPLATE))?;
    let source = match current {
        Some(text) => {
            for entry in crate::settings_seed::extract_env_entries(&text) {
                state.settings_env.push(crate::settings_seed::SeededEnv {
                    entry,
                    owner: ctx.name.to_owned(),
                });
            }
            crate::settings_template::TemplateSource::Text(text)
        }
        None => crate::settings_template::TemplateSource::Absent,
    };
    state.settings_templates.insert(ctx.name.to_owned(), source);
    Ok(())
}

/// Render one group's variant: one tree every member reads byte-for-byte,
/// validated against each member's loader.
fn render_variant(
    ctx: &ItemCtx,
    state: &mut DesiredState,
    group: &SurfaceGroup,
    enabled: bool,
) -> Result<Variant> {
    let mut rendered = render_skill(ctx.sealed, ctx.item_path, ctx.manifest, ctx.name)?;
    // `SKILL.md.disabled` is the name kendex keeps a switched-off
    // installation's content under, so a catalog shipping one of its own
    // has written down a tree that cannot be installed both ways: turning
    // this off renames one file onto the other, and one of the two is lost
    // with nothing said about it. `fork` refuses the same shape for the
    // same reason; there is nothing to choose between them here either.
    if let Some(reason) = both_names(rendered.files()) {
        return Ok(refuse(ctx, state, group, &reason));
    }
    // A skill from a plugin-registry catalog installs under its plugin, and the
    // catalog's own SKILL.md knows nothing of that.
    if group.installed != ctx.name {
        rendered.set_skill_name(&group.installed);
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
            rendered.files(),
        );
        if let Some(reason) = super::desired::refusal_reason(&findings) {
            return Ok(refuse(ctx, state, group, &reason));
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
        rendered.disable();
    }
    let hash = hash_files(rendered.files());
    Ok(Variant {
        files: rendered.into_files(),
        hash,
        refused: false,
    })
}

/// Nothing installs for this group, and every member is told why.
///
/// One rendering serves the whole group — they read one file on disk — so a
/// refusal is the group's, never one member's: installing it for the others
/// would put the rejected bytes exactly where the refusing one reads.
fn refuse(ctx: &ItemCtx, state: &mut DesiredState, group: &SurfaceGroup, reason: &str) -> Variant {
    for harness in &group.members {
        state.refused.push(super::desired::Refused {
            kind: ItemKind::Skill,
            name: ctx.name.to_owned(),
            harness: *harness,
            reason: reason.to_owned(),
        });
    }
    Variant {
        files: Vec::new(),
        hash: String::new(),
        refused: true,
    }
}

/// Why a tree carrying both spellings of its own skill file installs
/// nothing, or `None` where it carries one of them.
fn both_names(files: &Files) -> Option<String> {
    let holds = |name: &str| files.iter().any(|(rel, _)| rel.to_str() == Some(name));
    (holds("SKILL.md") && holds("SKILL.md.disabled")).then(|| {
        "the catalog ships both SKILL.md and SKILL.md.disabled, and switching this off \
         would write one over the other"
            .to_owned()
    })
}
