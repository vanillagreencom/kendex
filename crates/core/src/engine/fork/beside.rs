//! Keeping a user's edits beside the source's version: the edited
//! installation becomes a local fork under a new name, and the original
//! declaration stays on its source. The follow-up apply renders both — the
//! source's content under the name it always had, the edits under the name
//! the user chose.

use super::{Capture, capture, capture_ops, edited_rendering, local_item, provenance};
use crate::apply::{Op, Plan, PlannedOp, Pre};
use crate::engine::ops::manifest_for_mutation;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{self, LOCAL_SOURCE_NAME};
use crate::model::{HarnessId, ItemKind, Scope};

/// Turn one edited installation into a local fork under `new_name`,
/// leaving `name` declared from its source. `rev` moves the original's
/// hold along when its place is held, so the source version that lands is
/// the newest rather than the one the edits were made on; `None` leaves
/// the hold as it is.
///
/// The plan: capture the edited bytes into the local source under the
/// new name, trash the edited artifact so the follow-up apply re-renders
/// the original from its source, and write the manifest — the new name
/// declared `local` with the original's provenance recorded on it.
pub fn fork_beside(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
    new_name: &str,
    rev: Option<&str>,
) -> Result<Plan> {
    let mut manifest = manifest_for_mutation(env, scope)?;
    let Some(decl) = manifest.declared(kind).get(name).cloned() else {
        return Err(CoreError::NotDeclared {
            kind,
            name: name.to_owned(),
        });
    };
    if let Some(problem) = crate::names::item_problem(new_name) {
        return Err(CoreError::ItemNotInSource {
            name: problem,
            source_name: "the new name".to_owned(),
        });
    }
    if manifest.declared(kind).contains_key(new_name) {
        return Err(CoreError::SourceCollision {
            name: new_name.to_owned(),
            existing: "this scope's manifest".to_owned(),
            requested: LOCAL_SOURCE_NAME.to_owned(),
        });
    }
    // A stranger's local item under the new name is not an earlier copy of
    // this one, so it is never trashed to make room.
    if local_item(env, scope, kind, new_name).exists() {
        return Err(CoreError::SourceCollision {
            name: new_name.to_owned(),
            existing: "this scope's local source".to_owned(),
            requested: LOCAL_SOURCE_NAME.to_owned(),
        });
    }
    let edited = edited_rendering(env, scope, kind, name, harness)?;
    let captured = named(capture(kind, &edited)?, new_name);
    let mut ops = capture_ops(env, scope, kind, new_name, &edited, captured)?;
    let provenance = provenance(env, scope, kind, name, &manifest, &decl)?;

    let mut own = decl;
    own.source = LOCAL_SOURCE_NAME.to_owned();
    own.rev = None;
    manifest.declared_mut(kind).insert(new_name.to_owned(), own);
    manifest
        .forks
        .entry(kind)
        .or_default()
        .insert(new_name.to_owned(), provenance);
    if let Some(rev) = rev {
        manifest
            .declared_mut(kind)
            .get_mut(name)
            .unwrap_or_else(|| unreachable!("declared above"))
            .rev = Some(rev.to_owned());
    }

    let manifest_path = manifest::manifest_path(env, scope);
    ops.push(PlannedOp {
        description: format!("record the fork of {name} as {new_name} in kendex.toml"),
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

/// The captured bytes answering to `name`. A tool knows a skill or agent by
/// the name its frontmatter gives, and discovery treats a directory and its
/// frontmatter disagreeing as a finding — so a copy under a new name says
/// that name, or it would shadow the original it sits beside.
fn named(captured: Capture, name: &str) -> Capture {
    match captured {
        Capture::Tree(files) => Capture::Tree(
            files
                .into_iter()
                .map(|(rel, bytes)| match rel.to_str() {
                    Some("SKILL.md") => (rel, with_name(bytes, name)),
                    _ => (rel, bytes),
                })
                .collect(),
        ),
        Capture::File(bytes) => Capture::File(with_name(bytes, name)),
    }
}

/// `bytes` with the frontmatter's `name:` scalar replaced. Bytes that are
/// not text, carry no frontmatter, or name nothing come back untouched: the
/// edit is the user's and only the identity line is this operation's.
fn with_name(bytes: Vec<u8>, name: &str) -> Vec<u8> {
    let Ok(text) = std::str::from_utf8(&bytes) else {
        return bytes;
    };
    let Ok((yaml, body)) = crate::frontmatter::split(text) else {
        return bytes;
    };
    let mut renamed = String::with_capacity(text.len());
    let mut found = false;
    for line in yaml.split_inclusive('\n') {
        if !found && line.starts_with("name:") {
            let eol = line.strip_suffix('\n').map_or("", |_| "\n");
            renamed.push_str(&format!("name: {name}{eol}"));
            found = true;
        } else {
            renamed.push_str(line);
        }
    }
    if !found {
        return bytes;
    }
    format!("---\n{renamed}---\n{body}").into_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn with_name_replaces_only_the_frontmatter_name() {
        let text = "---\nname: gh\ndescription: about gh\n---\nname: gh in the body\n";
        let renamed =
            String::from_utf8(with_name(text.as_bytes().to_vec(), "gh-edited")).unwrap_or_default();
        assert_eq!(
            renamed,
            "---\nname: gh-edited\ndescription: about gh\n---\nname: gh in the body\n"
        );
    }

    #[test]
    fn with_name_leaves_text_without_a_name_or_frontmatter_alone() {
        for text in ["---\ndescription: d\n---\nBody.\n", "No frontmatter.\n"] {
            assert_eq!(with_name(text.as_bytes().to_vec(), "x"), text.as_bytes());
        }
        let binary = vec![0xff, 0xfe, 0x00];
        assert_eq!(with_name(binary.clone(), "x"), binary);
    }
}
