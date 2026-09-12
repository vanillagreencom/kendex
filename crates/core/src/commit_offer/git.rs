//! Every git call the offer makes, under the bound its step names.
//!
//! One runner, because the answer a step gives when it fails is what both
//! surfaces draw: the program's own words whole, or the bound it ran past.
//! A per-call-site reading of an exit status would put a different shape
//! behind each step.

use std::path::Path;
use std::process::Output;

use crate::process::Hardened;

use super::{Failed, Refusal, Remote, Step};

/// Run one git call, bounded by its step, and hand back its output or the
/// failure both surfaces draw.
///
/// A refusal is the program's words, not a verdict about them: nothing is
/// summarised, truncated to a first line, or matched against a pattern.
/// A cap is deliberately not set — [`Hardened::max_output`] refuses the
/// whole call when the cap is passed, and its error carries none of what
/// the program said, which would lose exactly the words the offer
/// promises.
pub fn run(hardened: Hardened, step: Step) -> Result<Vec<u8>, Failed> {
    let output = match hardened.timeout(step.bound()).run() {
        Ok(output) => output,
        Err(error) => {
            return Err(Failed {
                step,
                refusal: refusal(&error),
            });
        }
    };
    if output.status.success() {
        return Ok(output.stdout);
    }
    Err(Failed {
        step,
        refusal: Refusal::Said(said(&output)),
    })
}

/// The program's own words, one line at a time, in order, with nothing
/// dropped: stdout first, then stderr.
///
/// stderr goes last so the block ends on the refusal itself, which is what
/// both git and gh write there. stdout carries whatever ran and passed on
/// the way — a pre-push hook prints its own lines there and git keeps them
/// — so a block ending on stdout ends on a hook reporting success under a
/// push the remote rejected, with the rejection scrolled off the top.
///
/// Takes the whole [`Output`] rather than two byte slices, which are the
/// same type and would transpose silently.
fn said(output: &Output) -> Vec<String> {
    let lines = |bytes: &[u8]| -> Vec<String> {
        String::from_utf8_lossy(bytes)
            .lines()
            .map(str::to_owned)
            .collect()
    };
    let mut all = lines(&output.stdout);
    all.extend(lines(&output.stderr));
    all
}

/// What a call that never produced an exit status says for itself. A
/// program that is not on the machine, one whose pipes broke, and one that
/// ran past its bound are three different answers, and the offer draws
/// each of them differently.
pub(super) fn refusal(error: &crate::error::CoreError) -> Refusal {
    match error {
        crate::error::CoreError::CommandNotStarted { .. } => Refusal::NotStarted(error.to_string()),
        crate::error::CoreError::Io { source, .. }
            if source.kind() == std::io::ErrorKind::TimedOut =>
        {
            Refusal::TimedOut
        }
        other => Refusal::Said(vec![other.to_string()]),
    }
}

/// A git read whose non-zero exit is git refusing, not answering — the
/// status read the whole offer is derived from. Its words reach the person.
pub fn read_required(root: &Path, args: &[&str]) -> Result<Vec<u8>, Failed> {
    run(Hardened::git(args, Some(root)), Step::Read)
}

/// A git read of the checkout, under the read bound. Used where a non-zero
/// exit is an answer rather than a failure — an unset config key, an
/// unborn `HEAD` — and the caller says which.
pub fn read(root: &Path, args: &[&str]) -> Result<Option<Vec<u8>>, Failed> {
    let hardened = Hardened::git(args, Some(root)).timeout(Step::READ);
    match hardened.run() {
        Ok(output) if output.status.success() => Ok(Some(output.stdout)),
        Ok(_) => Ok(None),
        Err(error) => Err(Failed {
            step: Step::Read,
            refusal: refusal(&error),
        }),
    }
}

/// One line of git's answer, trimmed of the newline git ends it with.
fn line(bytes: Vec<u8>) -> String {
    String::from_utf8_lossy(&bytes).trim_end().to_owned()
}

/// The branch `HEAD` points at, or `None` where the checkout is on no
/// branch. `git symbolic-ref --quiet HEAD` exits non-zero on a detached
/// `HEAD`, which is the whole of the detection.
pub fn head_branch(root: &Path) -> Result<Option<String>, Failed> {
    let Some(bytes) = read(root, &["symbolic-ref", "--quiet", "--short", "HEAD"])? else {
        return Ok(None);
    };
    let name = line(bytes);
    Ok(match name.is_empty() {
        true => None,
        false => Some(name),
    })
}

/// The remotes this repository declares, in git's order.
pub fn remotes(root: &Path) -> Result<Vec<String>, Failed> {
    let Some(bytes) = read(root, &["remote"])? else {
        return Ok(Vec::new());
    };
    Ok(String::from_utf8_lossy(&bytes)
        .lines()
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(str::to_owned)
        .collect())
}

/// The remote the offer pushes to: the current branch's upstream remote;
/// else `origin`; else the only remote when the project has exactly one;
/// else none, and push and pull request are unavailable.
///
/// By rule and never by a prompt: the offer already asks one question, and
/// a second one about a choice the repository itself answers would be a
/// question with a right answer.
pub fn choose_remote(root: &Path, branch: &str) -> Result<Option<Remote>, Failed> {
    let upstream = read(
        root,
        &["config", "--get", &format!("branch.{branch}.remote")],
    )?
    .map(line)
    .filter(|name| !name.is_empty());
    let declared = remotes(root)?;
    let name = match upstream.clone() {
        Some(name) if declared.contains(&name) => Some(name),
        // A branch configured to push to a remote the repository no longer
        // declares is not a remote: falling through to the rest of the
        // rule answers with one that exists, or with none.
        _ => match declared.iter().any(|known| known == "origin") {
            true => Some("origin".to_owned()),
            false => match declared.as_slice() {
                [only] => Some(only.clone()),
                _ => None,
            },
        },
    };
    let Some(name) = name else {
        return Ok(None);
    };
    let Some(url) = read(root, &["remote", "get-url", &name])?.map(line) else {
        // A declared remote with no URL is not one this offer can push to
        // or bind `gh` against.
        return Ok(None);
    };
    // Tracked means this branch's own upstream is the remote that was
    // chosen. A branch with no upstream that fell through to `origin` is
    // not tracking it, and its first push has to say so.
    let tracked = upstream.as_deref() == Some(name.as_str())
        && read(
            root,
            &["config", "--get", &format!("branch.{branch}.merge")],
        )?
        .map(line)
        .is_some_and(|value| !value.is_empty());
    Ok(Some(Remote { name, url, tracked }))
}

/// The first free `kendex/renders`, `kendex/renders-2`, `kendex/renders-3`
/// and so on.
///
/// Free means no local ref and no remote-tracking ref for the chosen
/// remote already carries the name, both read from this repository. kendex
/// runs no `git ls-remote`: it is a network call before a choice has even
/// been made, and a name only the remote knows about surfaces as a refused
/// push, which already has its own state.
pub fn first_free_branch(root: &Path, remote: Option<&Remote>) -> Result<String, Failed> {
    // `git show-ref` exits 1 with no output in a repository that carries no
    // refs at all, which is the state a first write into a fresh `git init`
    // reaches. Every name is free there.
    let refs = read(root, &["show-ref"])?.unwrap_or_default();
    let held: Vec<String> = String::from_utf8_lossy(&refs)
        .lines()
        .filter_map(|row| row.split_once(' ').map(|(_, name)| name.trim().to_owned()))
        .collect();
    let taken = |name: &str| {
        let local = format!("refs/heads/{name}");
        let tracking = remote.map(|remote| format!("refs/remotes/{}/{name}", remote.name));
        held.iter()
            .any(|got| *got == local || Some(got.as_str()) == tracking.as_deref())
    };
    let mut nth = 1u32;
    loop {
        let name = match nth {
            1 => BRANCH.to_owned(),
            n => format!("{BRANCH}-{n}"),
        };
        if !taken(&name) {
            return Ok(name);
        }
        nth += 1;
    }
}

/// The branch kendex opens a pull request from.
pub const BRANCH: &str = "kendex/renders";

/// Whether `HEAD` resolves to a commit.
///
/// Asked with the exit status rather than with the presence of output,
/// because those two are different questions here. `git rev-parse --verify
/// --quiet HEAD` exits 1 and prints nothing for an unborn `HEAD`, and 128
/// for a repository git cannot read; [`read`] maps both to `None`, so a
/// caller reading born-ness off it would take a broken repository for an
/// empty one.
///
/// That distinction is not cosmetic where a restore asks it. A restore puts
/// a path back to what the last commit holds, and takes it away where the
/// last commit holds nothing — so an unborn answer given for a transport
/// failure turns "put my files back" into "take my files away". The rule
/// [`super::changes`] already states for its own reads is this one.
pub fn born(root: &Path) -> Result<bool, Failed> {
    let hardened = Hardened::git(&["rev-parse", "--verify", "--quiet", "HEAD"], Some(root))
        .timeout(Step::READ);
    match hardened.run() {
        Ok(output) if output.status.success() => Ok(true),
        // git's own exit for "this repository has no commit yet". Every
        // other status is git failing and travels as the failure it is.
        Ok(output) if output.status.code() == Some(1) => Ok(false),
        Ok(output) => Err(Failed {
            step: Step::Read,
            refusal: Refusal::Said(said(&output)),
        }),
        Err(error) => Err(Failed {
            step: Step::Read,
            refusal: refusal(&error),
        }),
    }
}

/// The short name of the commit `HEAD` points at, or `None` in a
/// repository with no commit yet — the state a first kendex write in a
/// fresh `git init` reaches. Read before a commit, it is the commit a
/// recovery would put the branch back to, and there is nothing to put it
/// back to when there is none.
///
/// A read that failed answers `None` here, which is right for the one thing
/// this answer is used for: the line naming a commit to go back to is left
/// out rather than guessed at. A caller asking whether the repository HAS a
/// commit wants [`born`], where that conflation would cost something.
pub fn previous_head(root: &Path) -> Result<Option<String>, Failed> {
    Ok(read(root, &["rev-parse", "--short", "HEAD"])?
        .map(line)
        .filter(|sha| !sha.is_empty()))
}

/// The short name of the commit that was just made, for the line that
/// reports it.
pub fn head_short(root: &Path) -> Result<String, Failed> {
    let bytes = run(
        Hardened::git(&["rev-parse", "--short", "HEAD"], Some(root)),
        Step::Read,
    )?;
    Ok(line(bytes))
}

/// The inventory a commit recorded, as the paths it names relative to the
/// project root.
///
/// Read at `HEAD`, because the offer needs the paths a sweep has just
/// removed and those are gone from the working tree by then. An unborn
/// `HEAD`, a project with no inventory committed yet, and an inventory
/// that will not parse all contribute nothing: none of them is a repository
/// this offer cannot read, and none names a path to add.
pub fn committed_inventory(root: &Path) -> Result<std::collections::BTreeSet<String>, Failed> {
    let spec = format!("HEAD:{}", crate::engine::generated_paths::INVENTORY);
    let Some(bytes) = read(root, &["show", &spec])? else {
        return Ok(std::collections::BTreeSet::new());
    };
    Ok(serde_json::from_slice(&bytes).unwrap_or_default())
}
