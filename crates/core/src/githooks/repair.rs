//! Rewriting the receipt-listed entrypoints to the bytes this binary
//! writes — the upgrade path for entrypoints that call the retired
//! `vstack` name. Everything the receipt records stays put — directory
//! name, `core.hooksPath`, leases — while the receipt's paths stay true.
//! The receipt is a claim and the bytes are the proof: a slot whose
//! current content is not one of our own entrypoints belongs to whoever
//! edited it, and one such file refuses the whole repair. Without a
//! receipt there is nothing to rewrite under: install owns the
//! receiptless repairs.

use std::path::Path;

use crate::apply::{Op, PlannedOp, Pre};
use crate::env::Env;
use crate::error::Result;

use super::{
    HOOKS, HooksReport, NOTHING_INSTALLED, RECEIPT_FILE, Repo, entrypoint, err, load_receipt,
    uninstall,
};

pub fn repair(env: &Env, dir: &Path) -> Result<HooksReport> {
    let repo = Repo::at(dir)?;
    let (_, lines) =
        crate::apply::execute_common(env, &repo.scope(), &repo.common_dir, || plan(&repo))?;
    Ok(HooksReport { lines })
}

fn plan(repo: &Repo) -> Result<(Vec<PlannedOp>, Vec<String>)> {
    let Some(receipt) = load_receipt(repo)? else {
        return Err(err(format!(
            "{NOTHING_INSTALLED} — nothing to repair; `kendex guard install` arms it"
        )));
    };
    let hooks_dir = repo.hooks_dir()?;
    // A write through a linked directory lands wherever the link points —
    // not in a directory kendex created.
    if hooks_dir.is_symlink() {
        return Err(err(format!(
            "{} is a symlink — kendex refuses to write through a link it did not create; remove the link and rerun",
            hooks_dir.display()
        )));
    }
    // The receipt proves ownership of the directory it names and no
    // other. When the live directory is a different one — the repository
    // moved, or the receipt was edited — install owns re-recording.
    // Compared as filesystem identities, not strings: macOS reaches /tmp
    // and /var through symlinks, so the recorded spelling and the resolved
    // one routinely name the same directory.
    let same_dir = receipt.hooks_path == hooks_dir.display().to_string()
        || std::path::Path::new(&receipt.hooks_path)
            .canonicalize()
            .ok()
            .zip(hooks_dir.canonicalize().ok())
            .is_some_and(|(recorded, live)| recorded == live);
    if !same_dir {
        return Err(err(format!(
            "the receipt records {} but the live hooks directory is {} — refusing to rewrite; `kendex guard install` re-records ownership",
            receipt.hooks_path,
            hooks_dir.display()
        )));
    }
    let mut ops = Vec::new();
    for name in &receipt.files {
        if name == RECEIPT_FILE {
            continue;
        }
        // A receipt listing a file no entrypoint exists for is not ours to
        // rewrite — refusing beats inventing a script for an unknown name.
        if !HOOKS.contains(&name.as_str()) {
            return Err(err(format!(
                "the receipt lists {name}, which is not a hook this binary writes — refusing to rewrite it"
            )));
        }
        let path = hooks_dir.join(name);
        if path.is_symlink() {
            return Err(err(format!(
                "{} is a symlink — kendex refuses to write through a link it did not create; remove it and rerun",
                path.display()
            )));
        }
        // The receipt alone is not proof of these bytes: an entrypoint
        // someone edited is their hook now, and overwriting it would
        // silently disable whatever they wired in. A missing slot is
        // still ours to restore — the receipt lists it and nothing
        // contradicts the claim.
        if path.exists() && !uninstall::written_by_us(name, &path)? {
            return Err(err(format!(
                "{} is not a file kendex wrote — refusing to overwrite a hand-edited entrypoint; move it aside and rerun",
                path.display()
            )));
        }
        ops.push(PlannedOp {
            description: format!("rewrite the {name} entrypoint"),
            op: Op::WriteExecutable {
                pre: Pre::observed(&path)?,
                path,
                bytes: entrypoint(name).into_bytes(),
            },
        });
    }
    Ok((
        ops,
        vec![format!(
            "entrypoints rewritten in {} — core.hooksPath and the receipt are untouched",
            hooks_dir.display()
        )],
    ))
}
