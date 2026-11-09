//! What a preview gives the safety rules to read.
//!
//! Split out of `safety.rs`. One question, and the whole reason a preview
//! is worth showing: it has to be the reading an install's plan scores,
//! over the content the install would write.

use crate::engine::desired::SkillLines;
use crate::error::Result;
use crate::model::ItemKind;
use crate::quality::{AuditInput, AuditResult, Content, Publisher};

use super::super::Browsed;
use super::Item;

/// The tree this project would install, from the publisher's own bytes: a
/// marked block is the project's to write and never installs, and SKILL.md
/// carries the installed key set a copy does. Every tool reads the same
/// rendering, so there is one tree to score. Beside it, where its
/// SKILL.md's lines stand in the catalog's file, which is the file the
/// preview cites ([`crate::engine::desired::skill_tree_lines`], the
/// reading the plan cites by).
///
/// The project's own instructions are deliberately *not* folded in — the
/// page says so — because a preview is about the package, and the plan's
/// own scoring says what the combination scores.
fn installs_as(
    browsed: &Browsed,
    path: &std::path::Path,
) -> Result<(crate::render::skill::Files, SkillLines)> {
    let installed = crate::render::skill::installed_form(crate::render::skill::render_authored(
        &browsed.sealed,
        path,
    )?);
    let catalog = browsed
        .sealed
        .rendered_item(ItemKind::Skill, path)?
        .into_files();
    let (_, lines) = crate::engine::desired::skill_tree_lines(&catalog, &installed);
    Ok((installed, lines))
}

/// What a preview scores, and how a line it reads in the installed
/// SKILL.md is cited in the catalog's.
pub(super) struct Preview {
    pub(super) input: AuditInput,
    skill_lines: Option<SkillLines>,
}

impl Preview {
    /// The score, each finding in SKILL.md cited at the line the catalog's
    /// file holds it at, or at none where it sits in the frontmatter the
    /// copy rewrote: the place a reader opening the catalog finds it.
    pub(super) fn audit(self) -> AuditResult {
        let skill_file = crate::quality::tree_file_location(
            &self.input.location,
            crate::render::skill::SKILL_FILE,
        );
        let mut result = crate::quality::audit(self.input);
        if let Some(lines) = self.skill_lines {
            for finding in result
                .findings
                .iter_mut()
                .chain(&mut result.mentions)
                .chain(&mut result.accepted)
                .filter(|finding| finding.location == skill_file)
            {
                finding.line = finding.line.and_then(|line| lines.catalog_line(line));
            }
        }
        result
    }
}

pub(super) fn input_for(
    browsed: &Browsed,
    kind: ItemKind,
    name: &str,
    item: &Item,
) -> Result<Preview> {
    let path = &item.path;
    let location = browsed.sealed.catalog_path(path);
    let mut skill_lines = None;
    let content = match kind {
        // Through the same constructor the plan reads a tree with, over
        // the tree this project would install — the rendering every tool
        // gets — so preview and plan cannot disagree about one package.
        ItemKind::Skill => {
            let (files, lines) = installs_as(browsed, path)?;
            skill_lines = Some(lines);
            crate::quality::observe::tree_content_from_bytes(&files)
        }
        // A hook's script is what the harness runs; browse scores it as a hook
        // so the rules that read event/command/script fire here too, not only
        // in the plan. The MCP declaration and command bodies read as their
        // file text; the plan's own score is the one an install shows.
        ItemKind::Hook => Content::Hook {
            event: String::new(),
            matcher: None,
            command: location.clone(),
            values: None,
            script: Some(browsed.sealed.read_to_string(path)?),
        },
        _ => Content::Document {
            text: browsed.sealed.read_to_string(path)?,
        },
    };
    Ok(Preview {
        input: AuditInput {
            kind,
            name: name.to_owned(),
            harness: None,
            location,
            publisher: Publisher::of(&browsed.source.provenance),
            content,
        },
        skill_lines,
    })
}
