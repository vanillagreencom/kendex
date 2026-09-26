use std::path::PathBuf;

use crate::error::Result;
use crate::hash::{hash_files, in_place_installation_hash, installation_hash};
use crate::lock::{EmittedArtifact, entry_key};
use crate::manifest::Method;
use crate::model::{HarnessId, ItemKind, Scope};
use crate::render::skill::{SKILL_FILE, SkillText, render_skill};

use super::desired::{
    Artifact, Desired, DesiredState, IN_PLACE_DISABLED, ItemCtx, effective_method, in_place_source,
    native_dir, skill_canonical, skill_dir,
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

/// One group's rendering: the tree's files, their content hash and how its
/// `SKILL.md` read as text, or nothing where a member's loader rejected
/// the tree and the group installs nothing.
use crate::render::skill::Files;

enum Variant {
    Refused,
    Rendered {
        files: Files,
        hash: String,
        read_as: SkillText,
    },
}

/// The tools that will read this skill without being installed to. The
/// shared `.agents/skills` tree under the scope's root is read by every
/// harness but Claude Code in a project, and by every one but Claude Code
/// and Antigravity globally, so a skill written there is loaded by tools the
/// person never named — one definition, counted once, and said out loud so a
/// reader is not surprised by a tool that has it (matrix §R6).
fn cross_read_note(ctx: &ItemCtx, method: Method, state: &mut DesiredState) {
    if method == Method::Copy {
        return;
    }
    let shared = skill_canonical(ctx.env, ctx.scope, ctx.name);
    // The name the shared tree lists it under, which is what each reader's
    // loader is held to.
    let installed = crate::harness::canonical_name(ctx.name);
    let readers: Vec<HarnessId> = HarnessId::ALL
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
        // Reading the directory is not enough to be shown what is in it.
        // A name this loader will not take — capitals or an underscore
        // where names must be lower-kebab — makes the tree invisible
        // there, and counting that tool as already having the skill would
        // be counting a definition it cannot load.
        .filter(|harness| {
            crate::render::validate::validate_name(*harness, &installed)
                .iter()
                .all(|finding| !finding.is_breakage())
        })
        .collect();
    if readers.is_empty() {
        return;
    }
    // The reach is a fact about the directory, not about any one skill, so
    // it is said once however many skills a scope installs.
    let where_ = match ctx.scope {
        Scope::Global => "`~/.agents/skills`",
        Scope::Project { .. } => "`.agents/skills`",
    };
    let note = format!(
        "kendex-shared-skills: readers={record_arg0} path={record_arg1}\n{arg2} read {where_} too, so what is installed here is already visible to them — one definition, counted once",
        arg2 = readers
            .iter()
            .map(|harness| harness.display_name())
            .collect::<Vec<_>>()
            .join(", "),
        record_arg0 = crate::names::shown(
            &(readers
                .iter()
                .map(|harness| harness.name())
                .collect::<Vec<_>>()
                .join(","))
            .to_string()
        ),
        record_arg1 = crate::names::shown(where_.trim_matches('`')),
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
    let identity = (ItemKind::Skill, ctx.decl.source.as_str(), ctx.name);
    let source = in_place_source(ctx.env, ctx.scope, identity);
    if !enabled && source.is_some() {
        for group in &groups {
            refuse(ctx, state, group, IN_PLACE_DISABLED);
        }
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
    if ctx.harnesses.contains(&HarnessId::Copilot) {
        super::copilot::switched_off_elsewhere(ctx, ItemKind::Skill, state);
    }
    let variants = groups
        .iter()
        .map(|group| render_variant(ctx, state, group, enabled))
        .collect::<Result<Vec<Variant>>>()?;

    // The base tree is the scope's shared location; the group that natively
    // reads it owns it, the first group otherwise. A variant with the base's
    // bytes links to it; a divergent variant lives at its own surface, which
    // every group has at either scope.
    let base = skill_canonical(ctx.env, ctx.scope, ctx.name);
    let owner = groups
        .iter()
        .position(|group| group.native == base)
        .unwrap_or(0);
    // Where each group's tree lands, and whether it may land there at
    // all: a group deduplicates onto the owner's rendering, so its place
    // follows from what rendered and never from where the owner's tree
    // was then refused to stand.
    let mut trees: Vec<Option<Tree>> = Vec::with_capacity(groups.len());
    for (index, group) in groups.iter().enumerate() {
        let Variant::Rendered {
            files,
            hash,
            read_as,
        } = &variants[index]
        else {
            trees.push(None);
            continue;
        };
        let deduped = index == owner
            || matches!(&variants[owner], Variant::Rendered { hash: owned, .. } if owned == hash);
        let (canonical, link) = if method == Method::Copy {
            (group.native.clone(), None)
        } else if deduped {
            match group.native == base {
                true => (base.clone(), None),
                false => (base.clone(), Some(group.native.clone())),
            }
        } else {
            (group.native.clone(), None)
        };
        // The one place the question is answered: this tree is the source
        // exactly where the source is where it stands.
        let in_place = source.as_ref() == Some(&canonical);
        if in_place && let Some(reason) = in_place_refusal(ctx, group, *read_as) {
            refuse(ctx, state, group, &reason);
            trees.push(None);
            continue;
        }
        trees.push(Some(Tree {
            canonical,
            files: files.clone(),
            link,
            in_place,
        }));
    }
    // Only once the tree that would sit in the shared place is known to
    // land: a refused group installs nothing there, and saying what is
    // installed here reaches other tools would name a tree that is about
    // to be removed.
    if trees[owner].is_some() {
        cross_read_note(ctx, method, state);
    }
    for (group, tree) in groups.iter().zip(trees) {
        if let Some(tree) = tree {
            push_installs(ctx, state, group, tree, enabled, method)?;
        }
    }
    Ok(())
}

/// Why the tree standing at the in-place source installs nothing, or
/// `None` where its rendering may be written back. That rendering goes
/// over the person's own `SKILL.md` whole, so it may carry nothing the
/// person's bytes do not: a decode that repaired them would put U+FFFD
/// where they stood, and a name this pass rewrote would go into the
/// person's name line. A copy keeps either as its own render.
///
/// The in-place source serves its skills under their directory names,
/// which carry no `/`, so a declaration that would install under another
/// spelling is not found there and never reaches the rename; reaching it
/// would be the source and this pass disagreeing about what a name is,
/// said so rather than written into the person's file.
fn in_place_refusal(ctx: &ItemCtx, group: &SurfaceGroup, read_as: SkillText) -> Option<String> {
    match read_as {
        SkillText::Repaired => Some(format!(
            "its {SKILL_FILE} is not valid UTF-8, and the project-instructions block cannot be written into it without changing its bytes"
        )),
        SkillText::Exact if group.installed != ctx.name => Some(format!(
            "internal: in-place skill {} would render under the name {}, and the in-place source serves directory names alone",
            ctx.name, group.installed
        )),
        SkillText::Exact => None,
    }
}

/// The parts of one rendered tree, as [`Artifact::Tree`] carries them: a
/// skill installs as a tree and nothing else, so the installation is built
/// from these rather than from an artifact that could be any kind.
struct Tree {
    canonical: PathBuf,
    files: Files,
    link: Option<PathBuf>,
    in_place: bool,
}

/// One rendering as the installation every member of its group wants.
///
/// The tree is one set of bytes however many tools read it, so the two
/// things derived from those bytes — where they landed, and where they
/// came from — are derived once here and shared across the members.
fn push_installs(
    ctx: &ItemCtx,
    state: &mut DesiredState,
    group: &SurfaceGroup,
    tree: Tree,
    enabled: bool,
    method: Method,
) -> Result<()> {
    let Tree {
        canonical,
        files,
        link,
        in_place,
    } = tree;
    let artifact = Artifact::Tree {
        canonical: canonical.clone(),
        files,
        link,
        in_place,
    };
    // Where the tree and the link landed goes on the record. A tool's
    // directory moves between kendex versions, and a pass that derived
    // the place again would name one this install never wrote — the
    // link it did write is then findable only through the record. The
    // person's own source tree is never on it.
    let paths = artifact
        .paths()
        .into_iter()
        .filter(|path| !(in_place && *path == canonical))
        .collect();
    let emitted = Some(EmittedArtifact {
        kind: ItemKind::Skill,
        name: group.installed.clone(),
        paths,
    });
    let source = Some(ctx.source(&artifact)?);
    for harness in &group.members {
        // An in-place tree is the person's source: kendex writes no render
        // of it, so no rendered hash anchors an edit, and the inputs it
        // records are the sections that shape the block it does write.
        let (hash, rendered_hash) = match in_place {
            true => (
                in_place_installation_hash(ctx.manifest, ItemKind::Skill, ctx.name, *harness),
                None,
            ),
            false => (
                installation_hash(
                    ctx.sealed,
                    ctx.item_path,
                    ctx.manifest,
                    ItemKind::Skill,
                    ctx.name,
                    *harness,
                )?,
                artifact.rendered_hash(),
            ),
        };
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
            recorded_fork: ctx.manifest.recorded_fork(ItemKind::Skill, ctx.name),
            hash,
            rendered_hash,
            source: source.clone(),
            upstream_skills: None,
            emitted: emitted.clone(),
            reasons: ctx.reasons_for(*harness),
            artifact: artifact.clone(),
        });
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
    let (mut rendered, read_as) = render_skill(ctx.sealed, ctx.item_path, ctx.manifest, ctx.name)?;
    // `SKILL.md.disabled` is the name kendex keeps a switched-off
    // installation's content under, so a catalog shipping one of its own
    // has written down a tree that cannot be installed both ways: turning
    // this off renames one file onto the other, and one of the two is lost
    // with nothing said about it. `fork` refuses the same shape for the
    // same reason; there is nothing to choose between them here either.
    if let Some(reason) = both_names(rendered.files()) {
        refuse(ctx, state, group, &reason);
        return Ok(Variant::Refused);
    }
    // A skill from a plugin-registry catalog installs under its plugin, and the
    // catalog's own SKILL.md knows nothing of that. Whether the renamed
    // rendering may stand where it lands is the placement's question,
    // asked of each tree where it is placed (`in_place_refusal`).
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
            refuse(ctx, state, group, &reason);
            return Ok(Variant::Refused);
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
    Ok(Variant::Rendered {
        files: rendered.into_files(),
        hash,
        read_as,
    })
}

/// Nothing installs for this group, and every member is told why.
///
/// One rendering serves the whole group — they read one file on disk — so a
/// refusal is the group's, never one member's: installing it for the others
/// would put the rejected bytes exactly where the refusing one reads.
fn refuse(ctx: &ItemCtx, state: &mut DesiredState, group: &SurfaceGroup, reason: &str) {
    for harness in &group.members {
        state.refused.push(super::desired::Refused {
            kind: ItemKind::Skill,
            name: ctx.name.to_owned(),
            harness: *harness,
            reason: reason.to_owned(),
            provenance: ctx.provenance.to_owned(),
        });
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
