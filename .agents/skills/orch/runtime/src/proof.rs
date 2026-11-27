//! The `read-proof` verb: one item's validate stages
//! and recorded restack skips read through `ops::proof`, the one reader,
//! under the project's declaration from the settings. The read records
//! nothing. It reads committed bases and an open round's current HEAD tree
//! with `git rev-parse`, and judges a docs pass under a read with a base by
//! the validation start's docs reader. An unreadable tree or docs verdict
//! supplies no coverage.
use agent_runtime::record;
use std::path::Path;
use std::time::Duration;

use agent_runtime::host::{self, Place};

use crate::error::{Error, Result};
use crate::ops::proof::{Declaration, ProofRead, ReadProof, RestackSkip};
use crate::settings::Settings;
use crate::state::{self, ItemState};
use crate::validate;

/// The bound on one tree read.
const READ_TIMEOUT: Duration = Duration::from_secs(120);

/// Read the proof of `item` for `request`.
pub fn run(settings: &Settings, item: &str, request: &ReadProof) -> Result<ProofRead> {
    let path = state::item_path(&settings.state_dir, item);
    let snapshot = validate::load(&path)?.ok_or_else(|| {
        Error::Runtime(agent_runtime::Error::RecordMissing { path: path.clone() })
    })?;
    let stages = snapshot.view::<ItemState>(&path)?.stages;
    let skips: Vec<RestackSkip> =
        record::field(&path, &snapshot.doc, "restack_skips")?.unwrap_or_default();
    let worktree: Option<String> = record::field(&path, &snapshot.doc, "worktree")?;
    let worktree = worktree.filter(|w| !w.is_empty());
    let declaration = Declaration::of(&settings.validate);
    let mut tree_of = |commit: &str| {
        worktree
            .as_deref()
            .and_then(|worktree| committed_tree(Path::new(worktree), commit))
    };
    // Submit and restack name the head's merge base with the base branch,
    // the base a docs run classifies against.
    let docs_base = request.base.as_deref();
    let mut docs_only = |commit: &str| {
        let (worktree, base) = (worktree.as_deref()?, docs_base?);
        validate::docs_only(settings, Path::new(worktree), commit, base)
    };
    Ok(crate::ops::proof::read(
        &stages,
        &skips,
        request,
        &declaration,
        &mut tree_of,
        &mut docs_only,
    ))
}

/// The committed tree of `commit` in `worktree`, `None` where git cannot
/// name one: an unreadable base is never coverage.
#[allow(
    clippy::disallowed_methods,
    reason = "the proof read's one read of the worktree: git naming a base commit's tree, a read before no record and never an effect on a lane or a controller"
)]
fn committed_tree(worktree: &Path, commit: &str) -> Option<String> {
    let spec = format!("{commit}^{{tree}}");
    let out = host::run_tagged_in(
        "proof",
        "git",
        Path::new("git"),
        "rev-parse",
        &["rev-parse", "--verify", "-q", &spec],
        Place {
            cwd: Some(worktree),
            env: &[],
        },
        READ_TIMEOUT,
    )
    .ok()?;
    out.status
        .success()
        .then(|| host::stdout_text(&out).trim().to_owned())
        .filter(|tree| !tree.is_empty())
}
