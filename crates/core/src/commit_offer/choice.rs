//! The choices an offer puts to a person, and why one it does not put is
//! missing. Both shells draw this list: the terminal keys it, the window
//! makes buttons of it, and neither decides on its own which choice stands.

use serde::{Deserialize, Serialize};
use specta::Type;

use super::{Branch, Offer, Unavailable};
use crate::decision::Need;

/// One of the four ways an offer is answered.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub enum Route {
    Commit,
    Push,
    PullRequest,
    Leave,
}

/// What a route changes, and where: the target the choice is bound to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum RouteEffect {
    /// A commit of the files on the branch the checkout is on.
    Commit { branch: String },
    /// That commit, pushed to the branch of the same name on the remote.
    Push { remote: String, branch: String },
    /// That commit, pushed to the branch a pull request is already open
    /// for, which adds the commit to it.
    AddToPullRequest {
        remote: String,
        branch: String,
        number: u32,
    },
    /// A commit on a new branch, pushed, and a pull request from it into
    /// the branch the checkout was on, which the checkout moves to.
    OpenPullRequest { branch: String, base: String },
    /// Nothing: the files stay as diffs.
    Leave,
}

/// A choice the offer puts to a person.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Choice {
    pub route: Route,
    pub effect: RouteEffect,
    /// The choice an answer that names none takes. Leaving the files is
    /// always the default: no other choice is taken unasked.
    pub default: bool,
}

/// Why a route is not on offer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Withheld {
    /// A precondition removed it.
    Unavailable(Unavailable),
    /// A pull request is already open for this branch, so there is none to
    /// open: pushing adds to it.
    AlreadyOpen(u64),
}

impl Offer {
    /// The choices this offer carries, in the order both shells draw them:
    /// commit, push, pull request, then leave, which is always last and
    /// always the default.
    pub fn choices(&self) -> Vec<Choice> {
        [Route::Commit, Route::Push, Route::PullRequest, Route::Leave]
            .into_iter()
            .filter_map(|route| {
                let effect = self.effect(route)?;
                Some(Choice {
                    route,
                    effect,
                    default: route == Route::Leave,
                })
            })
            .collect()
    }

    /// Why `route` is not on offer, or `None` where it stands.
    pub fn withheld(&self, route: Route) -> Option<Withheld> {
        match route {
            Route::Commit | Route::Leave => None,
            Route::Push => self.push.clone().err().map(Withheld::Unavailable),
            Route::PullRequest => match (&self.pull_request, &self.open) {
                (Err(why), _) => Some(Withheld::Unavailable(why.clone())),
                (Ok(()), Some(open)) => Some(Withheld::AlreadyOpen(open.number)),
                (Ok(()), None) => None,
            },
        }
    }

    /// What a route changes, or `None` where it is not on offer. A push
    /// stands only with a remote to push to: the pair is how the offer was
    /// built, and reading both keeps that true here.
    fn effect(&self, route: Route) -> Option<RouteEffect> {
        if self.withheld(route).is_some() {
            return None;
        }
        let branch = self.branch.clone();
        match route {
            Route::Commit => Some(RouteEffect::Commit { branch }),
            Route::Push => {
                let remote = self.remote.as_ref()?.name.clone();
                Some(match &self.open {
                    Some(open) => RouteEffect::AddToPullRequest {
                        remote,
                        branch,
                        number: u32::try_from(open.number).unwrap_or(u32::MAX),
                    },
                    None => RouteEffect::Push { remote, branch },
                })
            }
            Route::PullRequest => Some(RouteEffect::OpenPullRequest {
                branch: self.new_branch.clone(),
                base: branch,
            }),
            Route::Leave => Some(RouteEffect::Leave),
        }
    }

    /// Whether a refused push can be recovered by putting the commit on a
    /// branch of its own and opening a pull request from it: only where a
    /// pull request can be opened at all.
    pub fn recovers_refused_push(&self) -> bool {
        self.pull_request.is_ok()
    }
}

impl Branch {
    /// What a checkout in this state needs before an offer can be made:
    /// one on a branch is offered, and a commit anywhere else would land
    /// where nobody asked, so the person has to move the checkout first.
    pub fn need(&self) -> Need {
        match self {
            Branch::On(_) => Need::Decision,
            Branch::Detached | Branch::InProgress(_) => Need::Blocked,
        }
    }
}

#[cfg(test)]
mod tests;
