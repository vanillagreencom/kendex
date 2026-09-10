//! What each choice runs in the terminal, and what it says when a step of
//! it refuses.
//!
//! Every route ends in an [`Outcome`], which is what the closing ledger
//! reads back and what decides the exit code. A refusal is never silent
//! and never summarised: the step's own words are printed, then the way on
//! that step's state allows.

use kendex_core::commit_offer::{self, Committed, Offer, Selection};
use kendex_core::engine::GeneratedPaths;

use super::block::{self, Recover, Retry};
use super::{Asking, Choice, Outcome};

type Taken = Result<Outcome, Box<dyn std::error::Error>>;

/// Take one choice. `asking` is whether a person is at the prompt: a flag
/// answers once and reports, where a person is offered the way on that the
/// state allows.
pub fn take(
    offer: &Offer,
    generated: &GeneratedPaths,
    choice: Choice,
    given: Option<String>,
    asking: Asking,
) -> Taken {
    match choice {
        Choice::Leave => Ok(Outcome::Nothing),
        Choice::Commit => straight(offer, generated, given, asking, Push::No),
        Choice::Push => straight(offer, generated, given, asking, Push::Yes),
        Choice::Pr => pull_request(offer, generated, given, asking),
    }
}

/// Whether the route pushes the commit it makes.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Push {
    Yes,
    No,
}

/// The message this route commits with: the one a flag gave, or the
/// default with the person's chance to change it.
fn message(offer: &Offer, given: Option<String>, asking: Asking) -> std::io::Result<String> {
    match given {
        Some(message) => Ok(message),
        None => match asking {
            Asking::No => Ok(offer.message.clone()),
            Asking::Yes => block::message(&offer.message),
        },
    }
}

/// `commit`, and `push` — the two routes that commit on the branch the
/// checkout is already on.
fn straight(
    offer: &Offer,
    generated: &GeneratedPaths,
    given: Option<String>,
    asking: Asking,
    then: Push,
) -> Taken {
    let root = &offer.scan.root;
    // Read before the commit: it is the commit a recovery would put the
    // branch back to, and after the commit it is no longer what `HEAD`
    // names.
    let before = commit_offer::previous_head(root).unwrap_or(None);
    let mut message = message(offer, given, asking)?;
    loop {
        match commit_offer::commit(root, generated, &message, &Selection::All) {
            Ok(Committed::Nothing) => {
                block::nothing_to_commit();
                return Ok(Outcome::Nothing);
            }
            Ok(Committed::Made { sha, files, .. }) => {
                block::committed(&sha, files, None);
                return match then {
                    Push::No => Ok(Outcome::Committed(files)),
                    Push::Yes => pushed(offer, files, &message, before.as_deref(), asking),
                };
            }
            Err(refused) => {
                block::refused(block::commit_refused_head(&refused.failed), &refused.failed);
                if let Some(count) = refused.still_staged {
                    block::still_staged(count);
                }
                match again(asking)? {
                    Retry::Leave => return Ok(Outcome::CommitRefused),
                    Retry::Same => {}
                    Retry::Different => message = block::message(&message)?,
                }
            }
        }
    }
}

/// The ways on from a refused commit, where there is a person to offer
/// them to.
fn again(asking: Asking) -> std::io::Result<Retry> {
    match asking {
        Asking::No => Ok(Retry::Leave),
        Asking::Yes => block::after_refusal(),
    }
}

/// Push the commit the `push` route just made, on the branch it is on.
fn pushed(
    offer: &Offer,
    files: usize,
    message: &str,
    before: Option<&str>,
    asking: Asking,
) -> Taken {
    let Some(remote) = offer.remote.as_ref() else {
        return Err("the push route ran with no remote".into());
    };
    match commit_offer::push(
        &offer.scan.root,
        &remote.name,
        &offer.branch,
        remote.tracked,
    ) {
        Ok(_) => {
            block::pushed(&remote.name, &offer.branch);
            Ok(Outcome::Pushed(files))
        }
        Err(failed) => {
            block::refused("the push was refused", &failed);
            block::commit_is_on(&offer.branch);
            // The recovery for a refused push is to put the commit on a
            // branch of its own, so it is offered only where a pull
            // request can be opened from that branch — and only to a
            // person, since a flag answered one question and not this one.
            if offer.pull_request.is_err() || asking == Asking::No {
                return Ok(Outcome::PushRefused);
            }
            match block::after_push_refusal()? {
                Recover::Leave => Ok(Outcome::PushRefused),
                Recover::PullRequest => recover(offer, files, message, before),
            }
        }
    }
}

/// Push the commit that already exists to a branch of its own and open the
/// pull request, without moving the branch the person is on. The title is
/// the message the commit was made with, which is the one the person
/// settled on.
fn recover(offer: &Offer, files: usize, message: &str, before: Option<&str>) -> Taken {
    let Some(remote) = offer.remote.as_ref() else {
        return Err("the recovery ran with no remote".into());
    };
    if let Err(failed) = commit_offer::push_head(&offer.scan.root, &remote.name, &offer.new_branch)
    {
        block::refused("the push was refused", &failed);
        return Ok(Outcome::PushRefused);
    }
    block::pushed(&remote.name, &offer.new_branch);
    match commit_offer::open_pull_request(
        &remote.url,
        &offer.new_branch,
        &offer.branch,
        message,
        files,
    ) {
        Err(failed) => {
            block::refused("the pull request was refused", &failed);
            block::branch_is_on(&remote.name, &offer.new_branch);
            Ok(Outcome::PullRequestRefused)
        }
        Ok(opened) => {
            block::opened(&opened.url);
            // The local branch is left carrying the commit, and the run
            // says how to put it back without doing it: kendex never
            // moves a branch ref backwards.
            match before {
                Some(before) => block::how_to_put_back(&offer.branch, before),
                None => block::first_commit_stays(&offer.branch),
            }
            Ok(Outcome::PullRequest(files))
        }
    }
}

/// The `pr` route: switch to a branch of its own, commit there, push it,
/// and open the pull request.
///
/// The switch comes before the commit, so the branch the person was on
/// gains no commit and needs nothing undone.
fn pull_request(
    offer: &Offer,
    generated: &GeneratedPaths,
    given: Option<String>,
    asking: Asking,
) -> Taken {
    let root = &offer.scan.root;
    block::will_move(&offer.new_branch, &offer.branch);
    let message = message(offer, given, asking)?;
    if let Err(failed) = commit_offer::start_branch(root, &offer.new_branch) {
        block::refused("the branch could not be made", &failed);
        // The checkout has not moved and nothing is staged, so the other
        // choices still stand — carrying the message already settled on,
        // so it is not asked for twice.
        return without_pull_request(offer, generated, Some(message), asking);
    }
    let (sha, files) = match commit_offer::commit(root, generated, &message, &Selection::All) {
        Ok(Committed::Nothing) => {
            // The checkout already moved to a branch that will now carry
            // no commit, so kendex clears that leftover the way it does
            // after a refused commit.
            block::nothing_to_commit();
            return match commit_offer::abandon_branch(root, &offer.new_branch) {
                Ok(()) => {
                    block::back_on(&offer.branch, &offer.new_branch);
                    Ok(Outcome::Nothing)
                }
                Err(failed) => {
                    block::refused(block::NOT_PUT_BACK, &failed);
                    Ok(Outcome::CommitRefused)
                }
            };
        }
        Ok(Committed::Made { sha, files, .. }) => (sha, files),
        Err(refused) => return abandoned(offer, generated, refused, message, asking),
    };
    block::committed(&sha, files, Some(&offer.new_branch));
    let Some(remote) = offer.remote.as_ref() else {
        return Err("the pull-request route ran with no remote".into());
    };
    if let Err(failed) = commit_offer::push(root, &remote.name, &offer.new_branch, false) {
        block::refused("the push was refused", &failed);
        // The commit is already on a branch of its own, which is what the
        // refused-push recovery would have made, so there is no further
        // way on to offer.
        block::commit_is_on(&offer.new_branch);
        return Ok(Outcome::PushRefused);
    }
    block::pushed(&remote.name, &offer.new_branch);
    match commit_offer::open_pull_request(
        &remote.url,
        &offer.new_branch,
        &offer.branch,
        &message,
        files,
    ) {
        Err(failed) => {
            block::refused("the pull request was refused", &failed);
            block::branch_is_on(&remote.name, &offer.new_branch);
            Ok(Outcome::PullRequestRefused)
        }
        Ok(opened) => {
            block::opened(&opened.url);
            block::now_on(&offer.new_branch);
            Ok(Outcome::PullRequest(files))
        }
    }
}

/// The commit on the new branch refused. The branch carries no commit of
/// its own, so kendex clears its own leftover — back to where the person
/// was, and the empty branch removed — and asks again.
fn abandoned(
    offer: &Offer,
    generated: &GeneratedPaths,
    refused: commit_offer::CommitFailure,
    message: String,
    asking: Asking,
) -> Taken {
    block::refused(block::commit_refused_head(&refused.failed), &refused.failed);
    if let Some(count) = refused.still_staged {
        block::still_staged(count);
    }
    if let Err(failed) = commit_offer::abandon_branch(&offer.scan.root, &offer.new_branch) {
        // Reported, and the run stops here rather than trying anything
        // else: the checkout is on the branch kendex made.
        block::refused(block::NOT_PUT_BACK, &failed);
        return Ok(Outcome::CommitRefused);
    }
    block::back_on(&offer.branch, &offer.new_branch);
    // Committing again is the route the person chose, run again from its
    // start: the branch is made once more and the commit lands on it. The
    // message is the one they settled on, not the default.
    match again(asking)? {
        Retry::Leave => Ok(Outcome::CommitRefused),
        Retry::Same => pull_request(offer, generated, Some(message), asking),
        Retry::Different => {
            let message = block::message(&message)?;
            pull_request(offer, generated, Some(message), asking)
        }
    }
}

/// After the branch could not be made: the same choices without `pr`. The
/// checkout has not moved and nothing is staged.
fn without_pull_request(
    offer: &Offer,
    generated: &GeneratedPaths,
    given: Option<String>,
    asking: Asking,
) -> Taken {
    if asking == Asking::No {
        return Ok(Outcome::CommitRefused);
    }
    let choices = block::without_pull_request(offer);
    match block::pick(&choices)? {
        Choice::Leave => Ok(Outcome::CommitRefused),
        Choice::Commit => straight(offer, generated, given, asking, Push::No),
        Choice::Push => straight(offer, generated, given, asking, Push::Yes),
        // Filtered out of the list this answer came from.
        Choice::Pr => unreachable!("the pull-request choice was picked from a list without it"),
    }
}
