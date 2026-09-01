//! A captured agent must answer for every targeted harness from one source
//! revision.

use crate::engine::desired::target_harnesses;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{ItemDecl, Manifest};
use crate::model::{ItemKind, Scope};

pub(super) fn one_revision(
    env: &Env,
    scope: &Scope,
    after: &Manifest,
    decl: &ItemDecl,
    name: &str,
    read_at: Option<&str>,
) -> Result<()> {
    let lock = crate::lock::load(&crate::lock::lock_path(env, scope))?;
    let mut elsewhere: Vec<String> = Vec::new();
    for harness in target_harnesses(decl, after, ItemKind::Agent, scope) {
        let Some(entry) = lock
            .entries
            .get(&crate::lock::entry_key(ItemKind::Agent, name, harness))
        else {
            continue;
        };
        let at = entry.source_commit.as_deref();
        if at == read_at {
            continue;
        }
        elsewhere.push(match at {
            Some(commit) => format!("{} from {commit}", harness.display_name()),
            None => format!(
                "{}, whose revision the lock does not record",
                harness.display_name()
            ),
        });
    }
    if elsewhere.is_empty() {
        return Ok(());
    }
    Err(CoreError::ForkWidensAccess {
        name: crate::names::shown(name),
        problem: format!(
            "the tool settings {} state{}: {} — this copy is taken from {}, and a published file at one revision does not say what another one restricts. Refresh so every tool sits at the same revision, then keep it",
            match elsewhere.len() {
                1 => "the rendering it leaves behind".to_owned(),
                n => format!("the {n} renderings it leaves behind"),
            },
            if elsewhere.len() == 1 { "s" } else { "" },
            elsewhere.join(", "),
            read_at.unwrap_or("a revision nothing recorded")
        ),
    })
}
