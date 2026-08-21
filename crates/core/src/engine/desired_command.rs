use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use crate::error::Result;
use crate::lock::EmittedArtifact;
use crate::model::{HarnessId, ItemKind};

use super::ItemWarning;
use super::desired::{
    Artifact, Desired, DesiredState, ItemCtx, native_dir, refusal_reason, target_harnesses,
};
use super::desired_kinds::declared;
use super::targets::disabled_name;

pub(super) fn desired_command(ctx: &ItemCtx, state: &mut DesiredState) -> Result<()> {
    let bytes = ctx.sealed.read(ctx.item_path)?;
    for harness in ctx.harnesses.clone() {
        let item = match crate::harness::capabilities(harness, ItemKind::Command).installs_as {
            None => native_file(ctx, state, harness, &bytes)?,
            Some(ItemKind::Skill) => as_skill(ctx, state, harness, &bytes)?,
            Some(kind) => {
                state.notes.push(format!(
                    "command {}: {} stores commands as {}s, which kendex cannot write",
                    ctx.name,
                    harness.display_name(),
                    kind.name()
                ));
                None
            }
        };
        state.items.extend(item);
    }
    Ok(())
}

/// The filename a command takes in the harness's own commands dir. Gemini
/// loads nothing but `.toml` from its, which is also what makes the rename
/// toggle safe there (matrix §1).
pub(super) fn command_file(harness: HarnessId, name: &str) -> String {
    let name = &crate::harness::rendered_name(harness, name);
    match harness {
        HarnessId::Gemini => format!("{name}.toml"),
        _ => format!("{name}.md"),
    }
}

/// The harness reads commands from a directory of its own: one file, named
/// for the command, parked under `.disabled` while it is turned off.
fn native_file(
    ctx: &ItemCtx,
    state: &mut DesiredState,
    harness: HarnessId,
    bytes: &[u8],
) -> Result<Option<Desired>> {
    let Some(dir) = native_dir(ctx.env, ctx.scope, harness, ItemKind::Command) else {
        return Ok(None);
    };
    // Every other harness reads the author's own file, which installs byte
    // for byte; Gemini reads a table, so its file is generated.
    let bytes = match harness {
        HarnessId::Gemini => match crate::render::command::gemini(bytes, ctx.name) {
            Ok(text) => text.into_bytes(),
            Err(reason) => {
                state.refused.push(super::desired::Refused {
                    kind: ItemKind::Command,
                    name: ctx.name.to_owned(),
                    harness,
                    reason,
                });
                return Ok(None);
            }
        },
        _ => bytes.to_vec(),
    };
    let findings =
        crate::render::validate::validate_command(harness, &String::from_utf8_lossy(&bytes));
    if let Some(reason) = refusal_reason(&findings) {
        state.refused.push(super::desired::Refused {
            kind: ItemKind::Command,
            name: ctx.name.to_owned(),
            harness,
            reason,
        });
        return Ok(None);
    }
    for finding in findings.iter().filter(|finding| !finding.is_breakage()) {
        state.warnings.push(ItemWarning {
            kind: ItemKind::Command,
            name: ctx.name.to_owned(),
            harness: Some(harness),
            message: finding.message.clone(),
            remediation: Some(finding.remediation.clone()),
        });
    }
    let file = dir.join(command_file(harness, ctx.name));
    let artifact = Artifact::File {
        path: match ctx.decl.enabled {
            true => file,
            false => disabled_name(&file),
        },
        bytes,
    };
    Ok(Some(declared(ctx, ItemKind::Command, harness, artifact)?))
}

/// Codex has no command directory to write to — it retired prompts in favor
/// of skills — so the command becomes a one-file skill tree on the skill
/// surface, and the lock carries the name and path it took.
fn as_skill(
    ctx: &ItemCtx,
    state: &mut DesiredState,
    harness: HarnessId,
    bytes: &[u8],
) -> Result<Option<Desired>> {
    let Some(dir) = native_dir(ctx.env, ctx.scope, harness, ItemKind::Skill) else {
        return Ok(None);
    };
    let Some(name) = emitted_name(ctx, state, harness) else {
        return Ok(None);
    };
    let body = String::from_utf8_lossy(bytes);
    let tree = dir.join(&name);
    // Through the same value a skill's tree travels in, so the file names
    // and anything that points into them can only ever move together —
    // there is nothing of the project's in a command's rendering today, and
    // this is not a thing to remember if that changes.
    let mut rendered = crate::render::skill::Rendered::plain(vec![(
        PathBuf::from("SKILL.md"),
        crate::render::command::codex_skill(&name, &body, ctx.name).into_bytes(),
    )]);
    // A command is one file the author cannot split themselves, so an
    // oversized one is cut into references/ exactly like a skill — nothing
    // is dropped, and only a body the splitter cannot cut is refused.
    if let Some(cap) = crate::harness::format_caps(harness).skill_body_max_bytes {
        let Some(capped) = split_to_cap(ctx, state, harness, rendered, cap) else {
            return Ok(None);
        };
        rendered = capped;
    }
    if !ctx.decl.enabled {
        rendered.disable();
    }
    let files = rendered.into_files();
    // Installed as a skill, it answers to the skill loader's rules — under
    // the emitted name, which is the one the user will type.
    let findings = crate::render::validate::validate_skill_tree(harness, ctx.name, &name, &files);
    if let Some(reason) = refusal_reason(&findings) {
        state.refused.push(super::desired::Refused {
            kind: ItemKind::Command,
            name: ctx.name.to_owned(),
            harness,
            reason,
        });
        return Ok(None);
    }
    for finding in findings.iter().filter(|finding| !finding.is_breakage()) {
        state.warnings.push(ItemWarning {
            kind: ItemKind::Command,
            name: ctx.name.to_owned(),
            harness: Some(harness),
            message: finding.message.clone(),
            remediation: Some(finding.remediation.clone()),
        });
    }
    // Pi reads the same project skill directory Codex does, so the generated
    // skill shows up there too. Saying so beats the user finding a command
    // they never declared for Pi in Pi's skill list.
    if native_dir(ctx.env, ctx.scope, HarnessId::Pi, ItemKind::Skill).as_ref() == Some(&dir) {
        state.warnings.push(ItemWarning {
            kind: ItemKind::Command,
            name: ctx.name.to_owned(),
            harness: Some(harness),
            message: format!(
                "installed as skill {name} in a directory Pi also reads, so Pi offers it too"
            ),
            remediation: Some(format!(
                "drop {} from this command's harnesses if Pi must not see it",
                harness.display_name()
            )),
        });
    }
    let artifact = Artifact::Tree {
        canonical: tree.clone(),
        files,
        link: None,
    };
    let mut item = declared(ctx, ItemKind::Command, harness, artifact)?;
    item.emitted = Some(EmittedArtifact {
        kind: ItemKind::Skill,
        name,
        paths: vec![tree],
    });
    Ok(Some(item))
}

/// Cut the generated skill down to the harness's byte cap. `None` means the
/// splitter could not cut it at all — one code block bigger than the cap —
/// and the command is refused for this harness rather than truncated.
fn split_to_cap(
    ctx: &ItemCtx,
    state: &mut DesiredState,
    harness: HarnessId,
    rendered: crate::render::skill::Rendered,
    cap: usize,
) -> Option<crate::render::skill::Rendered> {
    let outcome = crate::render::split::enforce_body_cap(rendered, cap);
    if let Some(reason) = outcome.refusal {
        state.refused.push(super::desired::Refused {
            kind: ItemKind::Command,
            name: ctx.name.to_owned(),
            harness,
            reason: format!("{reason} — break the block up in the command's own file"),
        });
        return None;
    }
    for warning in outcome.warnings {
        state.warnings.push(ItemWarning {
            kind: ItemKind::Command,
            name: ctx.name.to_owned(),
            harness: Some(harness),
            message: warning.message,
            remediation: Some(format!(
                "nothing to fix — {} reads the rest from references/; shorten the command to keep it in one file",
                harness.display_name()
            )),
        });
    }
    Some(outcome.rendered)
}

/// The name the generated skill takes. A real skill keeps its own name, so
/// a command that clashes is renamed and the user is told which name to
/// type; when both renames are taken too, nothing is written rather than
/// something being overwritten.
fn emitted_name(ctx: &ItemCtx, state: &mut DesiredState, harness: HarnessId) -> Option<String> {
    let installed = crate::harness::rendered_name(harness, ctx.name);
    match emitted_names(ctx, harness).remove(ctx.name).flatten() {
        Some(name) if name == installed => Some(name),
        Some(name) => {
            state.warnings.push(ItemWarning {
                kind: ItemKind::Command,
                name: ctx.name.to_owned(),
                harness: Some(harness),
                message: format!(
                    "{} is already taken on {}, so the command installs as {name}",
                    ctx.name,
                    harness.display_name()
                ),
                remediation: Some(format!(
                    "run it as {name} on {}, or rename one of the two",
                    harness.display_name()
                )),
            });
            Some(name)
        }
        None => {
            state.refused.push(super::desired::Refused {
                kind: ItemKind::Command,
                name: ctx.name.to_owned(),
                harness,
                reason: format!(
                    "{name}, {name}__command and {name}__cmd are all taken on {} — rename one of them",
                    harness.display_name(),
                    name = ctx.name
                ),
            });
            None
        }
    }
}

/// The name every declared command emits on this harness, resolved in one
/// pass so no two commands can pick the same tree. Skills hold their names
/// outright; among commands the first in name order keeps the plain name and
/// later ones take a suffix — a fixed order, so the answer does not depend on
/// which command was rendered first and never changes between audits.
fn emitted_names(ctx: &ItemCtx, harness: HarnessId) -> BTreeMap<String, Option<String>> {
    let mut taken = claimed_skill_names(ctx, harness);
    let mut chosen = BTreeMap::new();
    for (name, decl) in &ctx.manifest.commands {
        if !target_harnesses(decl, ctx.manifest, ItemKind::Command, ctx.scope).contains(&harness) {
            continue;
        }
        let free = free_name(&crate::harness::rendered_name(harness, name), &taken);
        if let Some(free) = &free {
            taken.insert(free.clone());
        }
        chosen.insert(name.clone(), free);
    }
    chosen
}

/// The first of `name`, `name__command` and `name__cmd` nothing holds yet.
fn free_name(name: &str, taken: &BTreeSet<String>) -> Option<String> {
    ["", "__command", "__cmd"]
        .into_iter()
        .map(|suffix| format!("{name}{suffix}"))
        .find(|candidate| !taken.contains(candidate))
}

/// Skill names this harness must not have taken from it: the ones declared
/// for it here, plus everything the source offers, since declaring one of
/// those is a single edit away.
fn claimed_skill_names(ctx: &ItemCtx, harness: HarnessId) -> BTreeSet<String> {
    let mut names: BTreeSet<String> = ctx
        .manifest
        .skills
        .iter()
        .filter(|(_, decl)| {
            target_harnesses(decl, ctx.manifest, ItemKind::Skill, ctx.scope).contains(&harness)
        })
        .map(|(name, _)| crate::harness::rendered_name(harness, name))
        .collect();
    // A catalog offers names as it declares them; what a skill would take
    // from a command is the name it installs under, which for an item that
    // carries its plugin is a different spelling.
    names.extend(
        crate::source::list_items(ctx.sealed, ctx.config, ItemKind::Skill)
            .iter()
            .map(|name| crate::harness::rendered_name(harness, name)),
    );
    names
}
